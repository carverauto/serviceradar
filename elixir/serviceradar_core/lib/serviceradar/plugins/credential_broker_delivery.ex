defmodule ServiceRadar.Plugins.CredentialBrokerDelivery do
  @moduledoc """
  Delivery-time materialization of credential-broker grants embedded in plugin
  assignment params.

  Policy materialization (`ServiceRadar.Credentials.PluginAssignmentMaterializer`)
  bakes a short-TTL broker grant payload into the assignment `params_template`.
  Scheduled (non-action) WASM plugin executions on the agent never call the
  control-plane broker, so the stored grant payload goes stale and the plugin
  sees only an unresolved `*_secret_ref`. This module runs at agent config
  generation ("push") time and guarantees:

    * the delivered `credential_broker` payload is never expired — a stale or
      missing/unloadable grant is re-minted through the broker grant resource
      with the same scope (refresh-on-expiry);
    * the freshly validated grant is returned so the caller can resolve the
      referenced secret through `ServiceRadar.Credentials.SecretBroker`
      (`resolve_with_grant/2`), which both unlocks external-reference secrets
      and writes a `credential_secret_resolution_audits` row per resolution.

  The module never raises into config generation: any failure leaves the
  params untouched and returns `nil` for the grant so the caller falls back to
  the historical (grant-less) resolution path.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Plugins.MapUtils
  alias ServiceRadar.Plugins.SecretRefs

  require Logger

  @broker_schema "serviceradar.edge_credential_broker_grant.v1"
  # A grant must remain valid for at least this long after config generation to
  # be reused; otherwise it is re-minted. Keeps agents from receiving material
  # that expires in-flight.
  @default_min_remaining_seconds 60
  @type refresh_result :: {map(), CredentialBrokerGrant.t() | map() | nil}

  @doc """
  Refreshes the embedded `credential_broker` payload(s) in assignment params.

  Looks at the top-level params and, for `serviceradar.plugin_inputs.v1`
  payloads, the nested `"template"`. Returns `{params, grant}` where `grant`
  is the loaded-or-reminted grant usable with
  `SecretBroker.resolve_with_grant/2`, or `nil` when the params carry no
  broker payload (or refresh failed).

  Options:

    * `:actor` — defaults to a `:plugin_credential_delivery` system actor
    * `:now` — clock override for tests
    * `:min_remaining_seconds` — freshness margin (default #{@default_min_remaining_seconds})
    * `:agent_id` — agent the config is generated for; used when the stored
      payload lacks a target agent
    * `:grant_loader` — `(grant_id, actor -> {:ok, grant} | {:error, term})`
    * `:grant_issuer` — `(attrs, actor -> {:ok, grant} | {:error, term})`
  """
  @spec refresh_embedded_grant(map(), keyword()) :: refresh_result()
  def refresh_embedded_grant(params, opts \\ [])

  def refresh_embedded_grant(params, opts) when is_map(params) do
    params = MapUtils.stringify_keys_or_empty(params)

    case broker_payload_location(params) do
      nil ->
        {params, nil}

      {path, payload} ->
        case ensure_fresh_grant(payload, opts) do
          {:ok, grant, refreshed_payload} ->
            {put_in_params(params, path, refreshed_payload), grant}

          {:error, reason} ->
            Logger.warning(
              "Failed to refresh credential broker grant for plugin config delivery: #{inspect(reason)}"
            )

            {params, nil}
        end
    end
  end

  def refresh_embedded_grant(params, _opts), do: {params, nil}

  @doc """
  Returns `params` with the embedded `credential_broker` payload reduced to its
  scope: no grant id and no expiry.

  For agents that resolve by binding. Nothing is issued here; core issues or
  reuses the grant when the agent asks for the credential, so the delivered
  config no longer changes when a grant rotates. Stored assignments written
  before the reconcile stopped minting still carry an old grant id, which this
  removes.
  """
  @spec scope_only(map()) :: map()
  def scope_only(params) when is_map(params) do
    params = MapUtils.stringify_keys_or_empty(params)

    case broker_payload_location(params) do
      nil ->
        params

      {path, payload} ->
        put_in_params(params, path, Map.drop(payload, ["grant_id", "expires_at"]))
    end
  end

  def scope_only(params), do: params

  @doc """
  Grant issue attrs for an embedded `credential_broker` payload, as config
  delivery and resolve-by-binding both rebuild them. `:agent_id` and
  `:consumer_id` fill a payload that lacks them.
  """
  @spec grant_attrs_from_payload(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def grant_attrs_from_payload(payload, opts \\ []) when is_map(payload),
    do: issue_attrs_from_payload(payload, opts)

  @doc """
  Refreshes credential-broker payloads embedded in a top-level `"controllers"`
  list.

  Returns `{params, grants}` where `grants` is a list of `{index, grant}` pairs
  for controller entries whose payload was usable or successfully re-minted.
  The caller can use the grant at that index to resolve the controller's own
  `*_secret_ref` fields without leaking a grant across controllers.
  """
  @spec refresh_controller_grants(map(), keyword()) ::
          {map(), [{non_neg_integer(), CredentialBrokerGrant.t() | map()}]}
  def refresh_controller_grants(params, opts \\ [])

  def refresh_controller_grants(params, opts) when is_map(params) do
    params = MapUtils.stringify_keys_or_empty(params)

    case Map.get(params, "controllers") do
      controllers when is_list(controllers) ->
        {refreshed, grants} =
          controllers
          |> Enum.with_index()
          |> Enum.map_reduce([], fn {controller, index}, acc ->
            refresh_controller_grant(controller, index, acc, opts)
          end)

        {Map.put(params, "controllers", refreshed), Enum.reverse(grants)}

      _ ->
        {params, []}
    end
  end

  def refresh_controller_grants(params, _opts), do: {params, []}

  @doc """
  Returns the broker options used to resolve secret material with a refreshed
  grant at config delivery time. Resolution writes an audit row per attempt.
  """
  @spec broker_resolution_opts(map() | struct(), keyword()) :: keyword()
  def broker_resolution_opts(grant, opts \\ []) do
    actor = Keyword.get(opts, :actor, default_actor())

    Enum.reject(
      [
        actor: actor,
        audit?: true,
        agent_id: value(grant, :agent_id) || Keyword.get(opts, :agent_id),
        resolution_location: value(grant, :resolution_location)
      ],
      fn {_key, opt_value} -> is_nil(opt_value) end
    )
  end

  @doc false
  @spec broker_payload?(term()) :: boolean()
  def broker_payload?(%{} = payload) do
    (Map.get(payload, "schema") || Map.get(payload, :schema)) == @broker_schema
  end

  def broker_payload?(_payload), do: false

  # -- internals --------------------------------------------------------------

  defp broker_payload_location(params) do
    template = Map.get(params, "template")

    cond do
      broker_payload?(Map.get(params, "credential_broker")) ->
        {["credential_broker"], Map.get(params, "credential_broker")}

      is_map(template) and broker_payload?(Map.get(template, "credential_broker")) ->
        {["template", "credential_broker"], Map.get(template, "credential_broker")}

      true ->
        nil
    end
  end

  defp put_in_params(params, [key], payload), do: Map.put(params, key, payload)

  defp put_in_params(params, [outer, inner], payload) do
    Map.update(params, outer, %{inner => payload}, &Map.put(&1, inner, payload))
  end

  defp refresh_controller_grant(controller, index, acc, opts) when is_map(controller) do
    controller = MapUtils.stringify_keys_or_empty(controller)

    case Map.get(controller, "credential_broker") do
      payload when is_map(payload) ->
        case ensure_fresh_grant(payload, opts) do
          {:ok, grant, refreshed_payload} ->
            {Map.put(controller, "credential_broker", refreshed_payload), [{index, grant} | acc]}

          {:error, reason} ->
            Logger.warning(
              "Failed to refresh controller credential broker grant for plugin config delivery: #{inspect(reason)}",
              controller_index: index,
              controller_id: string_value(controller, "controller_id")
            )

            {controller, acc}
        end

      _ ->
        {controller, acc}
    end
  end

  defp refresh_controller_grant(controller, _index, acc, _opts), do: {controller, acc}

  defp ensure_fresh_grant(payload, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    margin = Keyword.get(opts, :min_remaining_seconds, @default_min_remaining_seconds)
    actor = Keyword.get(opts, :actor, default_actor())

    case load_reusable_grant(payload, now, margin, actor, opts) do
      {:ok, grant} ->
        {:ok, grant, payload}

      :remint ->
        remint_grant(payload, actor, opts)
    end
  end

  defp load_reusable_grant(payload, now, margin, actor, opts) do
    grant_id = string_value(payload, "grant_id")

    with true <- fresh_enough?(payload_expires_at(payload), now, margin),
         true <- is_binary(grant_id) and grant_id != "",
         {:ok, grant} <- load_grant(grant_id, actor, opts),
         true <- grant_status_usable?(grant),
         true <- fresh_enough?(value(grant, :expires_at), now, margin) do
      {:ok, grant}
    else
      _ -> :remint
    end
  end

  defp load_grant(grant_id, actor, opts) do
    loader = Keyword.get(opts, :grant_loader, &default_grant_loader/2)
    loader.(grant_id, actor)
  rescue
    exception -> {:error, {:grant_load_failed, Exception.message(exception)}}
  end

  defp default_grant_loader(grant_id, actor) do
    CredentialBrokerGrant.get_by_id(grant_id, actor: actor)
  end

  defp grant_status_usable?(grant) do
    case value(grant, :status) do
      status when status in [:issued, :active, "issued", "active"] -> true
      _ -> false
    end
  end

  defp fresh_enough?(%DateTime{} = expires_at, now, margin) do
    DateTime.after?(expires_at, DateTime.shift(now, second: margin))
  end

  defp fresh_enough?(_expires_at, _now, _margin), do: false

  defp payload_expires_at(payload) do
    case value(payload, :expires_at) do
      %DateTime{} = expires_at ->
        expires_at

      expires_at when is_binary(expires_at) ->
        case DateTime.from_iso8601(expires_at) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp remint_grant(payload, actor, opts) do
    with {:ok, attrs} <- issue_attrs_from_payload(payload, opts),
         {:ok, grant} <- issue_grant(attrs, actor, opts) do
      {:ok, grant, CredentialBrokerGrant.to_payload(grant, payload_extras(payload))}
    end
  end

  defp issue_grant(attrs, actor, opts) do
    issuer = Keyword.get(opts, :grant_issuer, &default_grant_issuer/2)

    case issuer.(attrs, actor) do
      {:ok, %{} = grant} -> {:ok, grant}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_grant_issuer_result, other}}
    end
  rescue
    exception -> {:error, {:grant_issue_failed, Exception.message(exception)}}
  end

  # A grant of identical scope that outlives the freshness margin is delivered
  # again rather than minting one per config generation.
  defp default_grant_issuer(attrs, actor) do
    CredentialBrokerGrant.reuse_or_issue(attrs,
      actor: actor,
      min_remaining_seconds: @default_min_remaining_seconds
    )
  end

  defp issue_attrs_from_payload(payload, opts) do
    secret_ref = string_value(payload, "credential_secret_ref")
    consumer = map_value(payload, "consumer")
    target = map_value(payload, "target")
    allow = map_value(payload, "allow")

    with {:ok, secret_id} <- secret_id_from_ref(secret_ref) do
      {:ok,
       %{
         secret_id: secret_id,
         secret_ref: secret_ref,
         credential_rule_id: string_value(payload, "credential_rule_id"),
         grant_type: string_value(payload, "grant_type") || "plugin_credential",
         consumer_kind: consumer_kind(consumer),
         consumer_id: string_value(consumer, "id") || Keyword.get(opts, :consumer_id),
         purpose: string_value(consumer, "purpose") || "plugin_execution",
         target_kind: string_value(target, "kind"),
         target_id: string_value(target, "id"),
         agent_id: string_value(target, "agent_id") || Keyword.get(opts, :agent_id),
         resolution_location: resolution_location(payload),
         allowed_schemes: list_value(allow, "schemes"),
         allowed_methods: list_value(allow, "methods"),
         allowed_paths: list_value(allow, "paths"),
         allowed_hosts: list_value(allow, "hosts"),
         allowed_ports: list_value(allow, "ports"),
         request_body_policy: map_value(allow, "request_body") || %{},
         inject: map_value(payload, "inject") || %{},
         ttl_seconds: int_value(payload, "ttl_seconds", 300)
       }
       |> Enum.reject(fn {_key, attr_value} -> is_nil(attr_value) end)
       |> Map.new()}
    end
  end

  defp secret_id_from_ref(ref) when is_binary(ref) and ref != "" do
    case SecretRefs.network_credential_ref_id(ref) do
      {:ok, secret_id} -> {:ok, secret_id}
      {:error, reason} -> {:error, {:invalid_credential_secret_ref, reason}}
    end
  end

  defp secret_id_from_ref(_ref), do: {:error, :missing_credential_secret_ref}

  defp consumer_kind(consumer) do
    case string_value(consumer, "kind") do
      kind when is_binary(kind) and kind != "" -> safe_existing_atom(kind, :plugin)
      _ -> :plugin
    end
  end

  defp resolution_location(payload) do
    case string_value(payload, "resolution_location") do
      location when is_binary(location) and location != "" ->
        safe_existing_atom(location, :agent)

      _ ->
        :agent
    end
  end

  defp safe_existing_atom(value, default) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> default
  end

  defp payload_extras(payload) do
    payload
    |> MapUtils.stringify_keys_or_empty()
    |> Map.drop(CredentialBrokerGrant.reserved_payload_keys())
  end

  defp default_actor, do: SystemActor.system(:plugin_credential_delivery)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key)) || atom_key_value(map, key)

  defp value(_map, _key), do: nil

  defp atom_key_value(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp atom_key_value(_map, _key), do: nil

  defp string_value(map, key) do
    case value(map, key) do
      result when is_binary(result) ->
        case String.trim(result) do
          "" -> nil
          trimmed -> trimmed
        end

      result when is_atom(result) and not is_nil(result) ->
        Atom.to_string(result)

      _ ->
        nil
    end
  end

  defp map_value(map, key) do
    case value(map, key) do
      %{} = result -> result
      _ -> nil
    end
  end

  defp list_value(map, key) do
    case value(map, key) do
      result when is_list(result) -> result
      _ -> nil
    end
  end

  defp int_value(map, key, default) do
    case value(map, key) do
      result when is_integer(result) and result > 0 ->
        result

      result when is_binary(result) ->
        case Integer.parse(result) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end
end
