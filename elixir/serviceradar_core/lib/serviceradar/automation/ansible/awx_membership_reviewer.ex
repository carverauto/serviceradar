defmodule ServiceRadar.Automation.Ansible.AwxMembershipReviewer do
  @moduledoc """
  Reviewer boundary shared by the human AWX membership actions: approving a
  proposal (`AwxMembershipApproval`) and releasing a quarantine
  (`AwxMembershipQuarantineRelease`).

  It resolves the initiating human from a `ServiceRadarWebNG.Accounts.Scope`
  shaped map or a user actor, reloads that user and its effective authority
  from storage, and ignores any permission set cached in the caller's scope.
  It also parses and compares the evidence fields both actions bind to. The
  error codes are the ones membership approval has always returned.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.User

  @permission "ansible.controllers.manage"
  @store_actor SystemActor.system(:awx_membership_approval_store)
  @fingerprint_regex ~r/\Asha256:[0-9a-f]{64}\z/
  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @doc "The system actor reviewer services use to read and write storage."
  def store_actor, do: @store_actor

  @doc "Default `load_user`/`load_authority` dependencies merged with `overrides`."
  @spec dependencies(map()) :: map()
  def dependencies(overrides) do
    Map.merge(
      %{load_user: &default_load_user/1, load_authority: &default_load_authority/1},
      overrides
    )
  end

  @doc """
  Returns the actor that may perform a membership review action: the freshly
  loaded, active, human user with `ansible.controllers.manage`, carrying the
  permissions loaded from storage.
  """
  @spec authorize(map(), map()) :: {:ok, map()} | {:error, atom()}
  def authorize(scope_or_actor, dependencies) do
    with {:ok, actor_id} <- human_actor_id(initiating_actor(scope_or_actor)),
         {:ok, user} <- load_current_user(dependencies, actor_id),
         :ok <- validate_current_user(user, actor_id),
         {:ok, permissions} <- load_permissions(dependencies, user) do
      if MapSet.member?(permissions, @permission),
        do: {:ok, authorized_actor(user, permissions)},
        else: {:error, :current_permission_denied}
    end
  end

  @doc """
  Normalizes a request whose keys must be exactly `keys` (strings or atoms),
  parsing each with the parser of the same name. Returns `{:error, error}` for
  any missing, extra, duplicated or invalid field.
  """
  @spec normalize_request(map(), [String.t()], atom()) :: {:ok, map()} | {:error, atom()}
  def normalize_request(request, keys, error) when is_map(request) do
    with {:ok, request} <- string_keyed(request),
         true <- MapSet.new(Map.keys(request)) == MapSet.new(keys),
         {:ok, parsed} <- parse_fields(request, keys) do
      {:ok, parsed}
    else
      _ -> {:error, error}
    end
  end

  def normalize_request(_request, _keys, error), do: {:error, error}

  @doc "Returns the canonical digest a reviewer must bind to the displayed link evidence."
  @spec link_evidence_digest(map()) :: {:ok, String.t()} | {:error, term()}
  def link_evidence_digest(evidence) when is_map(evidence), do: CanonicalJSON.digest(evidence)
  def link_evidence_digest(_evidence), do: {:error, :invalid_link_evidence}

  @doc "The membership is the one the request names, by ID and AWX source tuple."
  def exact_source_identity(membership, request) do
    current = {
      canonical_string(field(membership, :id)),
      canonical_string(field(membership, :controller_id)),
      field(membership, :inventory_id),
      field(membership, :awx_host_id)
    }

    expected = {
      request.membership_id,
      request.controller_id,
      request.inventory_id,
      request.awx_host_id
    }

    if current == expected, do: :ok, else: {:error, :membership_identity_changed}
  end

  @doc "The membership still has the generation, fingerprint and evidence the reviewer saw."
  def exact_source_evidence(membership, request) do
    with true <-
           field(membership, :source_generation) == request.source_generation and
             field(membership, :source_fingerprint) == request.source_fingerprint,
         {:ok, digest} <- link_evidence_digest(field(membership, :link_evidence)),
         true <- digest == request.link_evidence_digest do
      :ok
    else
      _ -> {:error, :membership_evidence_changed}
    end
  end

  @doc false
  def field(struct_or_map, key) when is_map(struct_or_map), do: Map.get(struct_or_map, key)

  defp parse_fields(request, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, parsed} ->
      case parse(key, request[key]) do
        {:ok, value} -> {:cont, {:ok, Map.put(parsed, String.to_existing_atom(key), value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp parse(key, value) when key in ["membership_id", "controller_id"], do: canonical_uuid(value)
  defp parse(key, value) when key in ["inventory_id", "awx_host_id"], do: positive_integer(value)
  defp parse("canonical_device_uid", value), do: device_uid(value)
  defp parse("source_generation", value), do: source_generation(value)
  defp parse("source_fingerprint", value), do: matching(value, @fingerprint_regex)
  defp parse("link_evidence_digest", value), do: matching(value, @digest_regex)

  @doc "Returns `map` with string keys, or an error when two keys name the same string."
  @spec string_keyed(map()) :: {:ok, map()} | {:error, :invalid_request}
  def string_keyed(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(normalized, key) do
        {:cont, {:ok, Map.put(normalized, key, value)}}
      else
        _ -> {:halt, {:error, :invalid_request}}
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, :invalid_request}

  defp initiating_actor(%{user: user}), do: user
  defp initiating_actor(%{"user" => user}), do: user
  defp initiating_actor(actor), do: actor

  defp human_actor_id(%{role: :system}), do: {:error, :human_approval_required}

  defp human_actor_id(%{principal_type: type}) when type not in [:human, "human"],
    do: {:error, :human_approval_required}

  defp human_actor_id(%{"principal_type" => type}) when type not in [:human, "human"],
    do: {:error, :human_approval_required}

  defp human_actor_id(%{id: id}) when not is_nil(id), do: non_empty_id(id)
  defp human_actor_id(%{"id" => id}) when not is_nil(id), do: non_empty_id(id)
  defp human_actor_id(_actor), do: {:error, :human_approval_required}

  defp non_empty_id(id) do
    id = to_string(id)
    if id == "", do: {:error, :human_approval_required}, else: {:ok, id}
  end

  defp load_current_user(dependencies, actor_id) do
    case dependencies.load_user.(actor_id) do
      {:ok, user} when not is_nil(user) -> {:ok, user}
      _ -> {:error, :approval_principal_unavailable}
    end
  end

  defp validate_current_user(user, actor_id) do
    cond do
      to_string(field(user, :id)) != actor_id -> {:error, :approval_principal_changed}
      field(user, :status) not in [:active, "active"] -> {:error, :approval_principal_disabled}
      field(user, :role) in [:system, "system"] -> {:error, :human_approval_required}
      true -> :ok
    end
  end

  defp load_permissions(dependencies, user) do
    case dependencies.load_authority.(user) do
      {:ok, %{permissions: %MapSet{} = permissions, profile_versions: versions}}
      when is_list(versions) ->
        {:ok, permissions}

      _ ->
        {:error, :approval_principal_profile_unavailable}
    end
  end

  defp authorized_actor(user, permissions) do
    %{
      id: to_string(field(user, :id)),
      role: field(user, :role),
      status: field(user, :status),
      principal_type: :human,
      permissions: permissions
    }
  end

  defp default_load_user(actor_id) do
    case User.get_by_id(actor_id, actor: @store_actor) do
      {:ok, %User{} = user} -> {:ok, user}
      _ -> {:error, :approval_principal_unavailable}
    end
  end

  defp default_load_authority(%User{} = user), do: RBAC.effective_authority(user, @store_actor)
  defp default_load_authority(_user), do: {:error, :approval_principal_profile_unavailable}

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid_uuid}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp source_generation(value) when is_integer(value),
    do: source_generation(Integer.to_string(value))

  defp source_generation(value) when is_binary(value) do
    case AwxLaunchContract.validate_membership_generation(value) do
      :ok -> {:ok, String.to_integer(value)}
      {:error, _reason} -> {:error, :invalid_source_generation}
    end
  end

  defp source_generation(_value), do: {:error, :invalid_source_generation}

  defp device_uid(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 1_024,
      do: {:ok, value},
      else: {:error, :invalid_device_uid}
  end

  defp device_uid(_value), do: {:error, :invalid_device_uid}

  defp matching(value, regex) when is_binary(value) do
    value = String.trim(value)
    if Regex.match?(regex, value), do: {:ok, value}, else: {:error, :invalid_format}
  end

  defp matching(_value, _regex), do: {:error, :invalid_format}

  defp canonical_string(nil), do: nil
  defp canonical_string(value), do: value |> to_string() |> String.downcase()
end
