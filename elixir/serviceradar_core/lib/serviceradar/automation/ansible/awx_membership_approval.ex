defmodule ServiceRadar.Automation.Ansible.AwxMembershipApproval do
  @moduledoc """
  Human approval boundary for one proposed AWX host membership.

  The request carries the complete source tuple and the generation,
  fingerprint, and canonical link-evidence digest shown to the reviewer. The
  service reloads the user and role profile from storage, ignores permissions
  cached in the caller's scope, and performs a compare-and-swap update over the
  exact current proposal. Reconciliation can propose or quarantine a link, but
  it cannot call this service as a system actor to approve one.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.User

  @permission "ansible.controllers.manage"
  @store_actor SystemActor.system(:awx_membership_approval_store)
  @max_generation 9_223_372_036_854_775_807
  @request_keys MapSet.new(~w(
    membership_id
    controller_id
    inventory_id
    awx_host_id
    canonical_device_uid
    source_generation
    source_fingerprint
    link_evidence_digest
  ))
  @source_evidence_keys MapSet.new(~w(
    kind
    controller_id
    inventory_id
    awx_host_id
    matching_device_uids
    match_count
  ))
  @fingerprint_regex ~r/\Asha256:[0-9a-f]{64}\z/
  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @type approval_request :: %{
          membership_id: String.t(),
          controller_id: String.t(),
          inventory_id: pos_integer(),
          awx_host_id: pos_integer(),
          canonical_device_uid: String.t(),
          source_generation: pos_integer(),
          source_fingerprint: String.t(),
          link_evidence_digest: String.t()
        }

  @doc """
  Approves one exact proposed membership as the currently logged-in human.

  A `ServiceRadarWebNG.Accounts.Scope`-shaped map or the user actor itself may
  be passed as the second argument. The caller's cached permission set is never
  used as approval authority.
  """
  @spec approve(map(), map()) :: {:ok, AwxHostMembership.t()} | {:error, term()}
  def approve(request, scope_or_actor), do: approve(request, scope_or_actor, [])

  @doc false
  @spec approve(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def approve(request, scope_or_actor, opts) when is_map(request) and is_list(opts) do
    dependencies = dependencies(opts)
    actor = initiating_actor(scope_or_actor)

    with {:ok, request} <- normalize_request(request),
         {:ok, actor_id} <- human_actor_id(actor),
         {:ok, current_user} <- load_current_user(dependencies, actor_id),
         :ok <- validate_current_user(current_user, actor_id),
         {:ok, authority} <- load_authority(dependencies, current_user),
         true <-
           MapSet.member?(authority.permissions, @permission) ||
             {:error, :current_permission_denied},
         {:ok, membership} <- load_membership(dependencies, request.membership_id),
         :ok <- validate_membership(membership, request),
         approved_at = dependencies.now.(),
         true <- is_struct(approved_at, DateTime) || {:error, :approval_clock_invalid},
         authorized_actor = authorized_actor(current_user, authority.permissions),
         attrs = approval_attributes(request, membership, approved_at),
         {:ok, approved} <-
           dependencies.approve_membership.(membership, attrs, authorized_actor) do
      {:ok, approved}
    else
      false -> {:error, :membership_approval_denied}
      {:error, _reason} = error -> error
      _ -> {:error, :membership_approval_denied}
    end
  rescue
    _ -> {:error, :membership_approval_denied}
  end

  def approve(_request, _scope_or_actor, _opts), do: {:error, :invalid_approval_request}

  @doc "Returns the canonical digest a reviewer must bind to the displayed link evidence."
  @spec link_evidence_digest(map()) :: {:ok, String.t()} | {:error, term()}
  def link_evidence_digest(evidence) when is_map(evidence), do: CanonicalJSON.digest(evidence)
  def link_evidence_digest(_evidence), do: {:error, :invalid_link_evidence}

  defp dependencies(opts) do
    overrides = Keyword.get(opts, :dependencies, %{})

    Map.merge(
      %{
        load_user: &default_load_user/1,
        load_authority: &default_load_authority/1,
        load_membership: &default_load_membership/1,
        approve_membership: &default_approve_membership/3,
        now: &DateTime.utc_now/0
      },
      overrides
    )
  end

  defp normalize_request(request) do
    with {:ok, request} <- normalize_keys(request),
         true <- MapSet.new(Map.keys(request)) == @request_keys,
         {:ok, membership_id} <- canonical_uuid(request["membership_id"]),
         {:ok, controller_id} <- canonical_uuid(request["controller_id"]),
         {:ok, inventory_id} <- positive_integer(request["inventory_id"]),
         {:ok, awx_host_id} <- positive_integer(request["awx_host_id"]),
         {:ok, canonical_device_uid} <- device_uid(request["canonical_device_uid"]),
         {:ok, source_generation} <- source_generation(request["source_generation"]),
         {:ok, source_fingerprint} <- source_fingerprint(request["source_fingerprint"]),
         {:ok, link_evidence_digest} <- digest(request["link_evidence_digest"]) do
      {:ok,
       %{
         membership_id: membership_id,
         controller_id: controller_id,
         inventory_id: inventory_id,
         awx_host_id: awx_host_id,
         canonical_device_uid: canonical_device_uid,
         source_generation: source_generation,
         source_fingerprint: source_fingerprint,
         link_evidence_digest: link_evidence_digest
       }}
    else
      _ -> {:error, :invalid_approval_request}
    end
  end

  defp normalize_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(normalized, key) do
        {:cont, {:ok, Map.put(normalized, key, value)}}
      else
        _ -> {:halt, {:error, :invalid_approval_request}}
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, :invalid_approval_request}

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

  defp load_authority(dependencies, current_user) do
    case dependencies.load_authority.(current_user) do
      {:ok, %{permissions: %MapSet{} = permissions, profile_versions: profile_versions}}
      when is_list(profile_versions) ->
        {:ok, %{permissions: permissions, profile_versions: profile_versions}}

      _ ->
        {:error, :approval_principal_profile_unavailable}
    end
  end

  defp load_membership(dependencies, membership_id) do
    case dependencies.load_membership.(membership_id) do
      {:ok, membership} when not is_nil(membership) -> {:ok, membership}
      _ -> {:error, :membership_not_found}
    end
  end

  defp validate_membership(membership, request) do
    with :ok <- exact_source_identity(membership, request),
         :ok <- exact_source_version(membership, request),
         :ok <- current_proposal(membership),
         :ok <- exact_device_link(membership, request),
         :ok <- exact_evidence_digest(membership, request) do
      unambiguous_evidence(membership, request)
    end
  end

  defp exact_source_identity(membership, request) do
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

  defp exact_source_version(membership, request) do
    if field(membership, :source_generation) == request.source_generation and
         field(membership, :source_fingerprint) == request.source_fingerprint do
      :ok
    else
      {:error, :membership_evidence_changed}
    end
  end

  defp current_proposal(membership) do
    cond do
      field(membership, :current) != true or field(membership, :enabled) != true or
          not is_nil(field(membership, :expired_at)) ->
        {:error, :membership_not_current}

      field(membership, :link_disposition) != :proposed ->
        {:error, :membership_not_proposed}

      true ->
        :ok
    end
  end

  defp exact_device_link(membership, request) do
    if field(membership, :canonical_device_uid) == request.canonical_device_uid,
      do: :ok,
      else: {:error, :membership_identity_changed}
  end

  defp exact_evidence_digest(membership, request) do
    case link_evidence_digest(field(membership, :link_evidence)) do
      {:ok, digest} when digest == request.link_evidence_digest -> :ok
      _ -> {:error, :membership_evidence_changed}
    end
  end

  defp unambiguous_evidence(membership, request) do
    evidence = field(membership, :link_evidence)

    with true <- is_map(evidence),
         {:ok, evidence} <- normalize_keys(evidence),
         true <- MapSet.new(Map.keys(evidence)) == @source_evidence_keys,
         true <- evidence["kind"] == "stored_awx_source_tuple",
         true <- canonical_string(evidence["controller_id"]) == request.controller_id,
         true <- evidence["inventory_id"] == request.inventory_id,
         true <- evidence["awx_host_id"] == request.awx_host_id,
         true <- evidence["matching_device_uids"] == [request.canonical_device_uid],
         true <- evidence["match_count"] == 1 do
      :ok
    else
      _ -> {:error, :membership_link_ambiguous}
    end
  end

  defp approval_attributes(request, membership, approved_at) do
    %{
      controller_id: request.controller_id,
      inventory_id: request.inventory_id,
      awx_host_id: request.awx_host_id,
      canonical_device_uid: request.canonical_device_uid,
      source_generation: request.source_generation,
      source_fingerprint: request.source_fingerprint,
      expected_link_evidence: field(membership, :link_evidence),
      link_evidence_digest: request.link_evidence_digest,
      approved_at: approved_at
    }
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

  defp default_load_membership(membership_id) do
    case AwxHostMembership.get_by_id(membership_id, actor: @store_actor) do
      {:ok, %AwxHostMembership{} = membership} -> {:ok, membership}
      _ -> {:error, :membership_not_found}
    end
  end

  defp default_approve_membership(membership, attrs, actor) do
    membership
    |> Ash.Changeset.for_update(:approve_link, attrs, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid_uuid}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp source_generation(value) when is_integer(value) and value > 0 and value <= @max_generation,
    do: {:ok, value}

  defp source_generation(_value), do: {:error, :invalid_source_generation}

  defp device_uid(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 1_024,
      do: {:ok, value},
      else: {:error, :invalid_device_uid}
  end

  defp device_uid(_value), do: {:error, :invalid_device_uid}

  defp source_fingerprint(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(@fingerprint_regex, value),
      do: {:ok, value},
      else: {:error, :invalid_source_fingerprint}
  end

  defp source_fingerprint(_value), do: {:error, :invalid_source_fingerprint}

  defp digest(value) when is_binary(value) do
    value = String.trim(value)
    if Regex.match?(@digest_regex, value), do: {:ok, value}, else: {:error, :invalid_digest}
  end

  defp digest(_value), do: {:error, :invalid_digest}

  defp canonical_string(nil), do: nil
  defp canonical_string(value), do: value |> to_string() |> String.downcase()

  defp field(struct_or_map, key) when is_map(struct_or_map), do: Map.get(struct_or_map, key)
end
