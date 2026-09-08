defmodule ServiceRadar.Credentials.SecretBroker do
  @moduledoc """
  Provider-neutral credential resolution boundary.

  The broker hides whether a credential is internally encrypted or externally
  referenced. Plugins should receive broker grants and host-function policies;
  they should not call this module or provider adapters directly.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialErrorClassifier
  alias ServiceRadar.Credentials.CredentialEventWriter
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.CredentialSecretProvider
  alias ServiceRadar.Credentials.CredentialSecretResolutionAudit
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretProviderAdapters.OpenBao
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Vault

  @default_external_lease_seconds 300

  @type resolved_secret :: %{
          required(:value) => String.t(),
          required(:source_type) => :internal_encrypted | :external_reference,
          required(:secret) => map() | struct(),
          optional(:provider) => map() | struct() | nil,
          optional(:lease_expires_at) => DateTime.t() | nil,
          optional(:cache_status) => atom() | nil,
          optional(:metadata) => map()
        }

  @doc """
  Resolves a reusable network credential secret by ID.

  External references require a validated broker grant and a matching
  resolution location. Internal credentials continue to decrypt through
  AshCloak/Cloak-managed storage.
  """
  @spec resolve_network_credential_secret(String.t(), keyword()) ::
          {:ok, resolved_secret()} | {:error, atom() | {atom(), term()}}
  def resolve_network_credential_secret(secret_id, opts \\ []) when is_binary(secret_id) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_secret_broker))

    with {:ok, secret} <- NetworkCredentialSecret.get_secret_by_id(secret_id, actor: actor) do
      resolve_loaded_secret(secret, opts)
    end
  end

  @doc """
  Resolves a credential through an already-loaded broker grant.

  This is the intended entry point for task runners and agent-side broker
  integrations that have been handed a scoped grant instead of plaintext
  credentials.
  """
  @spec resolve_with_grant(map() | struct(), keyword()) ::
          {:ok, resolved_secret()} | {:error, atom() | {atom(), term()}}
  def resolve_with_grant(grant, opts \\ []) when is_map(grant) do
    with {:ok, secret_id} <- secret_id_from_grant(grant),
         :ok <-
           CredentialBrokerGrant.validate_loaded_grant(
             grant_with_secret_id(grant, secret_id),
             Keyword.put(opts, :secret_id, secret_id)
           ) do
      resolve_network_credential_secret(secret_id, grant_resolution_opts(grant, opts))
    end
  end

  @doc """
  Resolves an already-loaded credential through an already-loaded broker grant.
  """
  @spec resolve_loaded_secret_with_grant(map() | struct(), map() | struct(), keyword()) ::
          {:ok, resolved_secret()} | {:error, atom() | {atom(), term()}}
  def resolve_loaded_secret_with_grant(secret, grant, opts \\ [])
      when is_map(secret) and is_map(grant) do
    secret_id = string_value(value(secret, :id))

    with {:ok, grant_secret_id} <- secret_id_from_grant(grant),
         true <- grant_secret_id == secret_id,
         :ok <-
           CredentialBrokerGrant.validate_loaded_grant(
             grant_with_secret_id(grant, grant_secret_id),
             Keyword.put(opts, :secret_id, secret_id)
           ) do
      resolve_loaded_secret(secret, grant_resolution_opts(grant, opts))
    else
      false -> {:error, {:grant_scope_mismatch, :secret_id}}
      error -> error
    end
  end

  @doc """
  Resolves an already-loaded credential secret.
  """
  @spec resolve_loaded_secret(map() | struct(), keyword()) ::
          {:ok, resolved_secret()} | {:error, atom() | {atom(), term()}}
  def resolve_loaded_secret(secret, opts \\ []) when is_map(secret) do
    case source_type(secret) do
      :internal_encrypted ->
        resolve_internal(secret, opts)

      :external_reference ->
        resolve_external(secret, opts)

      other ->
        {:error, {:unsupported_credential_source_type, other}}
    end
  end

  @spec external_reference?(map() | struct()) :: boolean()
  def external_reference?(secret) when is_map(secret),
    do: source_type(secret) == :external_reference

  @doc """
  Tests an external secret provider through the broker boundary.

  The caller supplies a provider record or provider ID plus a provider-specific
  reference. The broker owns adapter dispatch and provider health transitions so
  UI/API code never calls secret provider adapters directly.
  """
  @spec test_provider_reference(String.t() | map() | struct(), map(), keyword()) ::
          {:ok, map()} | {:error, atom() | {atom(), term()}}
  def test_provider_reference(provider_or_id, reference_attrs, opts \\ [])

  def test_provider_reference(provider_id, reference_attrs, opts) when is_binary(provider_id) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_secret_provider_test))

    with {:ok, provider} <- CredentialSecretProvider.get_by_id(provider_id, actor: actor) do
      test_provider_reference(provider, reference_attrs, opts)
    end
  end

  def test_provider_reference(provider, reference_attrs, opts)
      when is_map(provider) and is_map(reference_attrs) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_secret_provider_test))

    with {:ok, adapter} <- adapter_for_provider(provider, opts),
         reference = provider_test_reference(provider, reference_attrs),
         {:ok, result} <- call_provider_test(adapter, reference, provider, opts) do
      mark_provider_test(provider, :success, "Provider test succeeded", actor, opts)
      {:ok, CredentialRedactor.redact(result)}
    else
      {:error, reason} = error ->
        mark_provider_test(
          provider,
          provider_test_outcome(reason),
          provider_test_message(reason),
          actor,
          opts
        )

        error
    end
  end

  @spec source_type(map() | struct()) :: atom()
  def source_type(secret) when is_map(secret) do
    secret
    |> value(:source_type)
    |> normalize_atom(:internal_encrypted)
  end

  defp resolve_internal(secret, opts) do
    with {:ok, payload} <- decrypt_internal_payload(secret),
         true <- payload != "" do
      resolved = %{
        value: payload,
        source_type: :internal_encrypted,
        secret: secret,
        provider: nil,
        cache_status: :disabled,
        metadata: %{}
      }

      maybe_audit(:success, secret, nil, resolved, opts)
      {:ok, resolved}
    else
      {:error, reason} ->
        maybe_audit(:failed, secret, nil, %{error_class: :invalid_reference}, opts)
        {:error, reason}

      _ ->
        maybe_audit(:failed, secret, nil, %{error_class: :invalid_reference}, opts)
        {:error, :missing_internal_secret_payload}
    end
  end

  defp resolve_external(secret, opts) do
    if external_resolution_allowed?(opts) do
      opts =
        opts
        |> Keyword.put(:audit?, true)
        |> put_grant_id_from_grant()

      do_resolve_external(secret, opts)
    else
      {:error, :external_secret_requires_broker_grant}
    end
  end

  defp external_resolution_allowed?(opts) do
    is_map(Keyword.get(opts, :grant))
  end

  defp secret_id_from_grant(grant) do
    case value(grant, :secret_id) || secret_id_from_ref(value(grant, :secret_ref)) do
      secret_id when is_binary(secret_id) and secret_id != "" -> {:ok, secret_id}
      _ -> {:error, :grant_missing_secret_id}
    end
  end

  defp secret_id_from_ref(ref) when is_binary(ref) do
    case SecretRefs.network_credential_ref_id(ref) do
      {:ok, secret_id} -> secret_id
      {:error, _reason} -> nil
    end
  end

  defp secret_id_from_ref(_ref), do: nil

  defp grant_with_secret_id(grant, secret_id) do
    if present?(string_value(value(grant, :secret_id))) do
      grant
    else
      Map.put(grant, :secret_id, secret_id)
    end
  end

  defp put_grant_id_from_grant(opts) do
    case {Keyword.get(opts, :grant_id), Keyword.get(opts, :grant)} do
      {nil, %{} = grant} -> Keyword.put(opts, :grant_id, string_value(value(grant, :id)))
      {"", %{} = grant} -> Keyword.put(opts, :grant_id, string_value(value(grant, :id)))
      _other -> opts
    end
  end

  defp grant_resolution_opts(grant, opts) do
    opts
    |> Keyword.put(:grant, grant)
    |> Keyword.put(:grant_id, string_value(value(grant, :id)))
    |> Keyword.put(:allow_external_resolution?, true)
    |> Keyword.put(:trusted_broker_context?, true)
    |> Keyword.put_new(:consumer_kind, value(grant, :consumer_kind))
    |> Keyword.put_new(:consumer_id, value(grant, :consumer_id))
    |> Keyword.put_new(:purpose, value(grant, :purpose))
    |> Keyword.put_new(:target_kind, value(grant, :target_kind))
    |> Keyword.put_new(:target_id, value(grant, :target_id))
    |> Keyword.put_new(:agent_id, value(grant, :agent_id))
    |> Keyword.put_new(:resolution_location, value(grant, :resolution_location))
  end

  defp do_resolve_external(secret, opts) do
    requested_location =
      opts
      |> Keyword.get(:resolution_location, value(secret, :resolution_location) || :control_plane)
      |> normalize_atom(:control_plane)

    audit_opts = Keyword.put(opts, :resolution_location, requested_location)

    case provider_for_secret(secret, opts) do
      {:ok, provider} ->
        resolve_external_with_provider(secret, provider, requested_location, audit_opts)

      {:error, reason} = error ->
        maybe_audit(:failed, secret, nil, audit_error(reason), audit_opts)
        error
    end
  end

  defp resolve_external_with_provider(secret, provider, requested_location, opts) do
    with :ok <- provider_enabled?(provider, opts),
         :ok <- resolution_location_allowed?(provider, requested_location),
         {:ok, adapter} <- adapter_for_provider(provider, opts),
         {:ok, adapter_result} <-
           adapter.resolve(external_reference(secret, provider), provider, opts),
         {:ok, lease_expires_at} <- effective_lease_expires_at(adapter_result, opts) do
      resolved = %{
        value: Map.fetch!(adapter_result, :value),
        source_type: :external_reference,
        secret: secret,
        provider: provider,
        lease_expires_at: lease_expires_at,
        cache_status: Map.get(adapter_result, :cache_status, :miss),
        metadata: Map.get(adapter_result, :metadata, %{})
      }

      maybe_audit(:success, secret, provider, resolved, opts)
      {:ok, resolved}
    else
      {:error, reason} = error ->
        maybe_audit(:failed, secret, provider, audit_error(reason), opts)
        error
    end
  end

  defp decrypt_internal_payload(secret) do
    case value(secret, :secret_payload) do
      payload when is_binary(payload) and payload != "" ->
        {:ok, payload}

      _ ->
        decrypt_ash_cloak_payload(value(secret, :encrypted_secret_payload))
    end
  end

  defp decrypt_ash_cloak_payload(encrypted) when is_binary(encrypted) and encrypted != "" do
    with {:ok, decoded} <- Base.decode64(encrypted),
         decrypted = Vault.decrypt!(decoded),
         payload when is_binary(payload) <- Ash.Helpers.non_executable_binary_to_term(decrypted),
         true <- payload != "" do
      {:ok, payload}
    else
      _ -> {:error, :missing_internal_secret_payload}
    end
  rescue
    _ -> {:error, :missing_internal_secret_payload}
  end

  defp decrypt_ash_cloak_payload(_), do: {:error, :missing_internal_secret_payload}

  defp provider_for_secret(secret, opts) do
    cond do
      provider = Keyword.get(opts, :provider) ->
        {:ok, provider}

      provider = loaded_relationship(value(secret, :secret_provider)) ->
        {:ok, provider}

      provider_id = value(secret, :secret_provider_id) ->
        actor = Keyword.get(opts, :actor, SystemActor.system(:credential_secret_broker))
        CredentialSecretProvider.get_by_id(to_string(provider_id), actor: actor)

      true ->
        {:error, :missing_secret_provider}
    end
  end

  defp loaded_relationship(%Ash.NotLoaded{}), do: nil
  defp loaded_relationship(value), do: value

  defp provider_enabled?(provider, opts) do
    cond do
      Keyword.get(opts, :allow_disabled_provider?, false) ->
        :ok

      value(provider, :enabled) == true ->
        :ok

      true ->
        {:error, :provider_disabled}
    end
  end

  defp resolution_location_allowed?(provider, requested_location) do
    locations =
      provider
      |> value(:resolution_locations)
      |> List.wrap()
      |> Enum.map(&normalize_atom(&1, nil))
      |> Enum.reject(&is_nil/1)

    if requested_location in locations do
      :ok
    else
      {:error, {:resolution_location_not_allowed, requested_location}}
    end
  end

  defp adapter_for_provider(provider, opts) do
    provider_type = provider |> value(:provider_type) |> normalize_atom(nil)

    adapters =
      Keyword.get(opts, :adapters) ||
        Application.get_env(:serviceradar_core, :secret_provider_adapters, %{})

    adapter =
      Keyword.get(opts, :adapter) ||
        Map.get(adapters, provider_type) ||
        Map.get(adapters, to_string(provider_type)) ||
        built_in_adapter(provider_type)

    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         function_exported?(adapter, :resolve, 3) do
      {:ok, adapter}
    else
      {:error, :adapter_unavailable}
    end
  end

  defp built_in_adapter(:stub), do: ServiceRadar.Credentials.SecretProviderAdapters.Stub
  defp built_in_adapter(:openbao), do: OpenBao
  defp built_in_adapter(:vault), do: OpenBao
  defp built_in_adapter(_provider_type), do: nil

  defp provider_test_reference(provider, attrs) do
    %{
      provider_type: provider |> value(:provider_type) |> normalize_atom(nil),
      external_secret_ref: value(attrs, :external_secret_ref),
      external_secret_version: value(attrs, :external_secret_version),
      external_secret_fields: value(attrs, :external_secret_fields) || %{},
      credential_kind: value(attrs, :credential_kind),
      metadata: value(attrs, :metadata) || %{}
    }
  end

  defp call_provider_test(adapter, reference, provider, opts) do
    cond do
      function_exported?(adapter, :test, 3) ->
        adapter.test(reference, provider, opts)

      function_exported?(adapter, :resolve, 3) ->
        case adapter.resolve(reference, provider, opts) do
          {:ok, resolved} ->
            {:ok, Map.take(resolved, [:cache_status, :lease_expires_at, :metadata])}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, :adapter_unavailable}
    end
  end

  defp mark_provider_test(provider, outcome, message, actor, opts) do
    if Keyword.get(opts, :record_provider_state?, true) do
      action =
        case outcome do
          :success -> :record_test_success
          :unavailable -> :record_test_unavailable
          _ -> :record_test_failure
        end

      provider
      |> Ash.Changeset.for_update(action, %{last_test_message: message}, actor: actor)
      |> Ash.update(actor: actor)

      :ok
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp provider_test_outcome(reason) do
    case reason do
      :missing_endpoint_url -> :unavailable
      :missing_provider_token -> :unavailable
      :unreachable -> :unavailable
      {:unreachable, _reason} -> :unavailable
      :timeout -> :unavailable
      {:http_error, status} when is_integer(status) and status >= 500 -> :unavailable
      {:provider_http_error, status} when is_integer(status) and status >= 500 -> :unavailable
      _ -> :failed
    end
  end

  defp provider_test_message({:provider_http_error, status}) when is_integer(status),
    do: "provider_http_error:#{status}"

  defp provider_test_message({:http_error, status}) when is_integer(status),
    do: "provider_http_error:#{status}"

  defp provider_test_message({:unreachable, reason}), do: "unreachable:#{safe_reason(reason)}"

  defp provider_test_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp provider_test_message(_reason), do: "provider_test_failed"

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 128)
  defp safe_reason(_reason), do: "transport_error"

  defp external_reference(secret, provider) do
    %{
      provider_type: provider |> value(:provider_type) |> normalize_atom(nil),
      external_secret_ref: value(secret, :external_secret_ref),
      external_secret_version: value(secret, :external_secret_version),
      external_secret_fields: value(secret, :external_secret_fields) || %{},
      credential_kind: value(secret, :credential_kind),
      metadata: value(secret, :metadata) || %{}
    }
  end

  defp effective_lease_expires_at(adapter_result, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, provider_lease} <- datetime_value(Map.get(adapter_result, :lease_expires_at)),
         :ok <- provider_lease_active?(provider_lease, now),
         {:ok, grant_expires_at} <-
           opts |> Keyword.get(:grant) |> value(:expires_at) |> datetime_value() do
      {:ok, earliest_datetime(provider_lease, grant_expires_at) || default_external_lease(now)}
    end
  end

  defp provider_lease_active?(nil, _now), do: :ok

  defp provider_lease_active?(%DateTime{} = provider_lease, %DateTime{} = now) do
    if DateTime.after?(provider_lease, now), do: :ok, else: {:error, :provider_lease_expired}
  end

  defp earliest_datetime(nil, right), do: right
  defp earliest_datetime(left, nil), do: left

  defp earliest_datetime(%DateTime{} = left, %DateTime{} = right) do
    if DateTime.before?(left, right), do: left, else: right
  end

  defp default_external_lease(now),
    do: DateTime.add(now, @default_external_lease_seconds, :second)

  defp datetime_value(nil), do: {:ok, nil}
  defp datetime_value(%DateTime{} = value), do: {:ok, value}

  defp datetime_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_lease_expiration}
    end
  end

  defp datetime_value(_value), do: {:error, :invalid_lease_expiration}

  defp maybe_audit(outcome, secret, provider, result, opts) do
    if Keyword.get(opts, :audit?, false) do
      attrs = audit_attrs(outcome, secret, provider, result, opts)

      # A caller may pass an `:audit_sink` fun to DEFER the write (e.g. agent
      # config generation, which resolves credentials on every poll just to
      # compute the version hash but should only commit an audit when the config
      # is actually delivered). Without a sink, write immediately.
      case Keyword.get(opts, :audit_sink) do
        sink when is_function(sink, 1) -> sink.(attrs)
        _ -> write_audit(attrs)
      end

      :ok
    else
      :ok
    end
  rescue
    exception ->
      require Logger

      Logger.warning("Failed to write credential secret resolution audit",
        reason: Exception.message(exception)
      )

      :ok
  end

  @doc """
  Commits a credential-secret-resolution audit row (and observability event)
  from prepared `attrs`. Public so a deferred-audit sink can flush audits that
  were collected during resolution but only committed once the material is
  actually delivered (see `AgentConfigGenerator`). Never raises into the caller.
  """
  @spec write_audit(map()) :: :ok
  def write_audit(attrs) when is_map(attrs) do
    audit_actor = SystemActor.system(:credential_secret_broker_audit)
    _audit_result = CredentialSecretResolutionAudit.create_audit(attrs, actor: audit_actor)
    CredentialEventWriter.write_secret_resolution(attrs)
    :ok
  rescue
    exception ->
      require Logger

      Logger.warning("Failed to write credential secret resolution audit",
        reason: Exception.message(exception)
      )

      :ok
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp string_value(nil), do: nil
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value), do: to_string(value)

  defp audit_attrs(outcome, secret, provider, result, opts) do
    %{
      secret_id: value(secret, :id),
      secret_provider_id: provider && value(provider, :id),
      grant_id: Keyword.get(opts, :grant_id),
      consumer_kind: Keyword.get(opts, :consumer_kind, :test),
      consumer_id: Keyword.get(opts, :consumer_id),
      purpose: Keyword.get(opts, :purpose),
      target_kind: Keyword.get(opts, :target_kind),
      target_id: Keyword.get(opts, :target_id),
      agent_id: Keyword.get(opts, :agent_id),
      resolution_location: Keyword.get(opts, :resolution_location, :control_plane),
      outcome: outcome,
      error_class: Map.get(result, :error_class),
      cache_status: Map.get(result, :cache_status),
      lease_expires_at: Map.get(result, :lease_expires_at),
      metadata: CredentialRedactor.redact(Map.get(result, :metadata, %{})),
      occurred_at: utc_now()
    }
  end

  defp utc_now do
    DateTime.truncate(DateTime.utc_now(), :second)
  end

  defp audit_error({error_class, _detail}) when is_atom(error_class),
    do: %{error_class: CredentialErrorClassifier.audit_error_class(error_class)}

  defp audit_error(error_class) when is_atom(error_class),
    do: %{error_class: CredentialErrorClassifier.audit_error_class(error_class)}

  defp audit_error(_), do: %{error_class: :internal_error}

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp value(_map, _key), do: nil

  defp normalize_atom(value, _default) when is_atom(value), do: value

  defp normalize_atom(value, default) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> default
      trimmed -> String.to_existing_atom(trimmed)
    end
  rescue
    ArgumentError -> default
  end

  defp normalize_atom(_value, default), do: default
end
