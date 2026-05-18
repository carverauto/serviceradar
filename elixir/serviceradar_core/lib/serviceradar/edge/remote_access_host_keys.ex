defmodule ServiceRadar.Edge.RemoteAccessHostKeys do
  @moduledoc """
  Host-key trust lifecycle for ServiceRadar-native remote access.

  The manager keeps the policy behavior explicit:

  * first observations are reviewable `:pending` records
  * trust-on-first-use observations become `:trusted` only when no trusted key
    already exists for the same routed target
  * new keys for a target with an existing trusted key become `:conflict`
  * trust, revocation, and rotation transitions are audited
  """

  import Ash.Expr

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.RemoteAccessHostKey
  alias ServiceRadar.Events.AuditWriter

  require Ash.Query

  @default_protocol :ssh
  @default_target_port 22
  @default_source :agent_observed
  @trusted_statuses [:trusted]

  @type observe_result ::
          {:ok,
           %{host_key: RemoteAccessHostKey.t(), decision: atom(), conflict_with: [String.t()]}}
          | {:error, term()}

  @spec list(map(), keyword()) :: {:ok, [RemoteAccessHostKey.t()]} | {:error, term()}
  def list(filters \\ %{}, opts \\ []) do
    actor = operation_actor(opts)

    RemoteAccessHostKey
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> apply_filters(filters)
    |> Ash.Query.sort(last_seen_at: :desc, inserted_at: :desc)
    |> Ash.read()
  end

  @spec get(String.t(), keyword()) ::
          {:ok, RemoteAccessHostKey.t()} | {:error, :not_found | term()}
  def get(id, opts \\ []) when is_binary(id) do
    case RemoteAccessHostKey.get_by_id(id, actor: operation_actor(opts)) do
      {:ok, %RemoteAccessHostKey{} = host_key} ->
        {:ok, host_key}

      {:ok, nil} ->
        {:error, :not_found}

      {:error, reason} ->
        if ash_not_found?(reason), do: {:error, :not_found}, else: {:error, reason}
    end
  end

  @spec observe(map(), keyword()) :: observe_result()
  def observe(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, normalized} <- normalize_observation(attrs),
         {:ok, existing} <- get_existing(normalized, opts) do
      case existing do
        %RemoteAccessHostKey{} = host_key ->
          record_seen(host_key, normalized, opts)

        nil ->
          create_observation(normalized, opts)
      end
    end
  end

  @spec trust(RemoteAccessHostKey.t() | String.t(), keyword()) ::
          {:ok, RemoteAccessHostKey.t()} | {:error, term()}
  def trust(host_key_or_id, opts \\ []) do
    with {:ok, %RemoteAccessHostKey{} = host_key} <- resolve(host_key_or_id, opts),
         :ok <- ensure_trust_allowed(host_key, opts),
         {:ok, updated} <-
           RemoteAccessHostKey.trust(
             host_key,
             trust_attrs(host_key, opts),
             actor: operation_actor(opts)
           ) do
      write_audit(:remote_access_host_key_trusted, updated, opts)
      {:ok, updated}
    end
  end

  @spec reject(RemoteAccessHostKey.t() | String.t(), keyword()) ::
          {:ok, RemoteAccessHostKey.t()} | {:error, term()}
  def reject(host_key_or_id, opts \\ []) do
    with {:ok, %RemoteAccessHostKey{} = host_key} <- resolve(host_key_or_id, opts),
         {:ok, updated} <-
           RemoteAccessHostKey.reject(
             host_key,
             %{
               rejected_at: RemoteAccessHostKey.utc_now(),
               rejected_by: actor_id(opts),
               rejection_reason: reason(opts),
               metadata: merge_metadata(host_key.metadata, Keyword.get(opts, :metadata, %{}))
             },
             actor: operation_actor(opts)
           ) do
      write_audit(:remote_access_host_key_rejected, updated, opts)
      {:ok, updated}
    end
  end

  @spec revoke(RemoteAccessHostKey.t() | String.t(), keyword()) ::
          {:ok, RemoteAccessHostKey.t()} | {:error, term()}
  def revoke(host_key_or_id, opts \\ []) do
    with {:ok, %RemoteAccessHostKey{} = host_key} <- resolve(host_key_or_id, opts),
         {:ok, updated} <-
           RemoteAccessHostKey.revoke(
             host_key,
             %{
               revoked_at: RemoteAccessHostKey.utc_now(),
               revoked_by: actor_id(opts),
               revocation_reason: reason(opts),
               metadata: merge_metadata(host_key.metadata, Keyword.get(opts, :metadata, %{}))
             },
             actor: operation_actor(opts)
           ) do
      write_audit(:remote_access_host_key_revoked, updated, opts)
      {:ok, updated}
    end
  end

  @spec rotate(
          RemoteAccessHostKey.t() | String.t(),
          RemoteAccessHostKey.t() | String.t(),
          keyword()
        ) ::
          {:ok, %{rotated: RemoteAccessHostKey.t(), trusted: RemoteAccessHostKey.t()}}
          | {:error, term()}
  def rotate(old_host_key_or_id, new_host_key_or_id, opts \\ []) do
    with {:ok, %RemoteAccessHostKey{} = old_host_key} <- resolve(old_host_key_or_id, opts),
         {:ok, %RemoteAccessHostKey{} = new_host_key} <- resolve(new_host_key_or_id, opts),
         :ok <- ensure_same_target(old_host_key, new_host_key),
         {:ok, trusted_new} <-
           trust(
             new_host_key,
             opts
             |> Keyword.put(:allow_conflict_trust?, true)
             |> Keyword.put(:supersedes_host_key_id, old_host_key.id)
           ),
         {:ok, rotated_old} <-
           RemoteAccessHostKey.mark_rotated(
             old_host_key,
             %{
               rotated_at: RemoteAccessHostKey.utc_now(),
               rotated_by: actor_id(opts),
               replacement_host_key_id: trusted_new.id,
               rotation_reason: reason(opts),
               metadata: merge_metadata(old_host_key.metadata, Keyword.get(opts, :metadata, %{}))
             },
             actor: operation_actor(opts)
           ) do
      write_audit(:remote_access_host_key_rotated, rotated_old, opts, %{
        replacement_host_key_id: trusted_new.id,
        supersedes_host_key_id: old_host_key.id
      })

      {:ok, %{rotated: rotated_old, trusted: trusted_new}}
    end
  end

  defp create_observation(attrs, opts) do
    with {:ok, existing_for_target} <- list_for_target(attrs, opts) do
      trusted = Enum.filter(existing_for_target, &(&1.status in @trusted_statuses))
      status = initial_status(attrs, trusted)
      now = RemoteAccessHostKey.utc_now()

      create_attrs =
        attrs
        |> Map.put(:status, status)
        |> Map.put(:first_seen_at, now)
        |> Map.put(:last_seen_at, now)
        |> Map.put(:seen_count, 1)
        |> maybe_put_trusted(status, opts, now)

      with {:ok, host_key} <-
             RemoteAccessHostKey.create_host_key(create_attrs, actor: operation_actor(opts)) do
        action =
          if status == :conflict,
            do: :remote_access_host_key_conflict_detected,
            else: :remote_access_host_key_observed

        write_audit(action, host_key, opts, %{conflict_with: Enum.map(trusted, & &1.id)})

        {:ok,
         %{
           host_key: host_key,
           decision: status,
           conflict_with: Enum.map(trusted, & &1.id)
         }}
      end
    end
  end

  defp record_seen(%RemoteAccessHostKey{} = host_key, attrs, opts) do
    next_count = max((host_key.seen_count || 0) + 1, 1)
    metadata = merge_metadata(host_key.metadata, attrs.metadata)

    action =
      if host_key.status == :conflict,
        do: :mark_conflict,
        else: :record_seen

    update_attrs = %{
      last_seen_at: RemoteAccessHostKey.utc_now(),
      seen_count: next_count,
      metadata: metadata
    }

    with {:ok, updated} <-
           apply(RemoteAccessHostKey, action, [
             host_key,
             update_attrs,
             [actor: operation_actor(opts)]
           ]) do
      {:ok, %{host_key: updated, decision: updated.status, conflict_with: []}}
    end
  end

  defp get_existing(attrs, opts) do
    case RemoteAccessHostKey.get_by_target_fingerprint(
           attrs.agent_id,
           attrs.target_host,
           attrs.target_port,
           attrs.protocol,
           attrs.fingerprint_sha256,
           actor: operation_actor(opts)
         ) do
      {:ok, %RemoteAccessHostKey{} = host_key} -> {:ok, host_key}
      {:ok, nil} -> {:ok, nil}
      {:error, reason} -> if ash_not_found?(reason), do: {:ok, nil}, else: {:error, reason}
    end
  end

  defp list_for_target(attrs, opts) do
    RemoteAccessHostKey.list_for_target(
      attrs.agent_id,
      attrs.target_host,
      attrs.target_port,
      attrs.protocol,
      actor: operation_actor(opts)
    )
  end

  defp initial_status(%{source: :trust_on_first_use}, []), do: :trusted
  defp initial_status(_attrs, [_trusted | _rest]), do: :conflict
  defp initial_status(_attrs, _trusted), do: :pending

  defp maybe_put_trusted(attrs, :trusted, opts, now) do
    attrs
    |> Map.put(:trusted_at, now)
    |> Map.put(:trusted_by, actor_id(opts))
  end

  defp maybe_put_trusted(attrs, _status, _opts, _now), do: attrs

  defp normalize_observation(attrs) do
    with {:ok, target_host} <- required_string(value(attrs, "target_host"), :target_host),
         {:ok, agent_id} <- required_string(value(attrs, "agent_id"), :agent_id),
         {:ok, key_type} <- required_string(value(attrs, "key_type"), :key_type),
         {:ok, fingerprint} <-
           required_string(value(attrs, "fingerprint_sha256"), :fingerprint_sha256),
         {:ok, target_port} <- target_port(value(attrs, "target_port")),
         {:ok, protocol} <- protocol(value(attrs, "protocol")),
         {:ok, source} <- source(value(attrs, "source")) do
      {:ok,
       %{
         device_uid: optional_string(value(attrs, "device_uid")),
         target_host: target_host,
         target_port: target_port,
         protocol: protocol,
         agent_id: agent_id,
         gateway_id: optional_string(value(attrs, "gateway_id")),
         key_type: key_type,
         fingerprint_sha256: fingerprint,
         public_key: optional_string(value(attrs, "public_key")),
         source: source,
         metadata: normalize_metadata(value(attrs, "metadata"))
       }}
    end
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:agent_id, value}, query when is_binary(value) ->
        Ash.Query.filter(query, expr(agent_id == ^value))

      {"agent_id", value}, query when is_binary(value) ->
        Ash.Query.filter(query, expr(agent_id == ^value))

      {:device_uid, value}, query when is_binary(value) ->
        Ash.Query.filter(query, expr(device_uid == ^value))

      {"device_uid", value}, query when is_binary(value) ->
        Ash.Query.filter(query, expr(device_uid == ^value))

      {:target_host, value}, query when is_binary(value) ->
        Ash.Query.filter(query, expr(target_host == ^value))

      {"target_host", value}, query when is_binary(value) ->
        Ash.Query.filter(query, expr(target_host == ^value))

      {:status, value}, query when is_atom(value) ->
        Ash.Query.filter(query, expr(status == ^value))

      {"status", value}, query when is_binary(value) ->
        case status(value) do
          {:ok, status} -> Ash.Query.filter(query, expr(status == ^status))
          :error -> query
        end

      _other, query ->
        query
    end)
  end

  defp resolve(%RemoteAccessHostKey{} = host_key, _opts), do: {:ok, host_key}
  defp resolve(id, opts) when is_binary(id), do: get(id, opts)

  defp ash_not_found?(%NotFound{}), do: true

  defp ash_not_found?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &ash_not_found?/1)
  end

  defp ash_not_found?(_reason), do: false

  defp ensure_same_target(old_host_key, new_host_key) do
    fields = [:agent_id, :target_host, :target_port, :protocol]

    if Enum.all?(fields, &(Map.fetch!(old_host_key, &1) == Map.fetch!(new_host_key, &1))) do
      :ok
    else
      {:error, :host_key_target_mismatch}
    end
  end

  defp ensure_trust_allowed(%RemoteAccessHostKey{status: :conflict}, opts) do
    if Keyword.get(opts, :allow_conflict_trust?) == true and
         is_binary(Keyword.get(opts, :supersedes_host_key_id)) do
      :ok
    else
      {:error, :host_key_conflict_requires_rotation}
    end
  end

  defp ensure_trust_allowed(%RemoteAccessHostKey{status: :rejected}, _opts),
    do: {:error, :host_key_rejected}

  defp ensure_trust_allowed(_host_key, _opts), do: :ok

  defp trust_attrs(host_key, opts) do
    %{
      trusted_at: RemoteAccessHostKey.utc_now(),
      trusted_by: actor_id(opts),
      supersedes_host_key_id: Keyword.get(opts, :supersedes_host_key_id),
      metadata: merge_metadata(host_key.metadata, Keyword.get(opts, :metadata, %{}))
    }
  end

  defp required_string(value, field) do
    case optional_string(value) do
      nil -> {:error, {:missing_required, field}}
      present -> {:ok, present}
    end
  end

  defp optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp target_port(nil), do: {:ok, @default_target_port}
  defp target_port(value) when is_integer(value) and value in 1..65_535, do: {:ok, value}

  defp target_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} -> target_port(port)
      _error -> {:error, :invalid_target_port}
    end
  end

  defp target_port(_value), do: {:error, :invalid_target_port}

  defp protocol(nil), do: {:ok, @default_protocol}
  defp protocol(:ssh), do: {:ok, :ssh}
  defp protocol("ssh"), do: {:ok, :ssh}
  defp protocol(_value), do: {:error, :unsupported_protocol}

  defp source(nil), do: {:ok, @default_source}

  defp source(value) when value in [:agent_observed, :known_hosts, :trust_on_first_use, :manual],
    do: {:ok, value}

  defp source(value) when is_binary(value) do
    case value do
      "agent_observed" -> {:ok, :agent_observed}
      "known_hosts" -> {:ok, :known_hosts}
      "trust_on_first_use" -> {:ok, :trust_on_first_use}
      "manual" -> {:ok, :manual}
      _other -> {:error, :unsupported_source}
    end
  end

  defp source(_value), do: {:error, :unsupported_source}

  defp status(value) do
    case value do
      "pending" -> {:ok, :pending}
      "trusted" -> {:ok, :trusted}
      "conflict" -> {:ok, :conflict}
      "rotated" -> {:ok, :rotated}
      "revoked" -> {:ok, :revoked}
      "rejected" -> {:ok, :rejected}
      _other -> :error
    end
  end

  defp normalize_metadata(value) when is_map(value) do
    value
    |> stringify_map()
    |> CredentialRedactor.redact()
  end

  defp normalize_metadata(_value), do: %{}

  defp merge_metadata(left, right) do
    Map.merge(normalize_metadata(left), normalize_metadata(right))
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key =
        case key do
          atom when is_atom(atom) -> Atom.to_string(atom)
          binary when is_binary(binary) -> binary
          other -> inspect(other)
        end

      value =
        case value do
          nested when is_map(nested) -> stringify_map(nested)
          list when is_list(list) -> Enum.map(list, &stringify_value/1)
          other -> other
        end

      {key, value}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value), do: value

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || value_by_existing_atom(map, key)
  end

  defp value(_map, _key), do: nil

  defp value_by_existing_atom(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp operation_actor(opts) do
    Keyword.get(opts, :actor) ||
      actor_from_scope(Keyword.get(opts, :scope)) ||
      SystemActor.system(:remote_access_host_keys)
  end

  defp actor_from_scope(%{user: nil}), do: nil

  defp actor_from_scope(%{user: user} = scope) when not is_nil(user) do
    %{
      id: Map.get(user, :id),
      email: Map.get(user, :email),
      role: Map.get(user, :role),
      permissions: Map.get(scope, :permissions)
    }
  end

  defp actor_from_scope(_scope), do: nil

  defp actor_id(opts) do
    case operation_actor(opts) do
      %{id: id} when is_binary(id) -> id
      %{email: email} when is_binary(email) -> email
      _other -> nil
    end
  end

  defp reason(opts), do: opts |> Keyword.get(:reason) |> optional_string()

  defp write_audit(action, host_key, opts, extra \\ %{}) do
    writer = Keyword.get(opts, :audit_writer, AuditWriter)

    writer.write_async(
      action: action,
      resource_type: "remote_access_host_key",
      resource_id: host_key.id,
      resource_name: "#{host_key.target_host}:#{host_key.target_port}",
      actor: operation_actor(opts),
      details:
        host_key
        |> audit_details(extra)
        |> CredentialRedactor.redact()
    )
  end

  defp audit_details(host_key, extra) do
    Map.merge(
      %{
        device_uid: host_key.device_uid,
        target_host: host_key.target_host,
        target_port: host_key.target_port,
        protocol: Atom.to_string(host_key.protocol),
        agent_id: host_key.agent_id,
        gateway_id: host_key.gateway_id,
        key_type: host_key.key_type,
        fingerprint_sha256: host_key.fingerprint_sha256,
        status: Atom.to_string(host_key.status),
        source: Atom.to_string(host_key.source),
        supersedes_host_key_id: host_key.supersedes_host_key_id,
        replacement_host_key_id: host_key.replacement_host_key_id
      },
      extra
    )
  end
end
