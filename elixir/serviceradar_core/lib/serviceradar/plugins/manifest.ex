defmodule ServiceRadar.Plugins.Manifest do
  @moduledoc """
  Validates and normalizes the plugin manifest stored in plugin.yaml.

  The manifest is the source of truth for plugin capabilities, permissions,
  and resource requests. Validation is intentionally strict to prevent
  unsafe defaults from being imported.

  ## The `notifications:` block

  A package that ships notifier providers declares them here (design D2, tasks
  3.1.1). Each entry describes ONE notifier and carries exactly these keys:

      notifications:
        - key: pagerduty_events_v2      # slug; what NotificationProvider.action_key names
          display_name: PagerDuty Events v2
          description: Routes alerts to a PagerDuty Events v2 integration key
          entrypoint: notify_pagerduty  # exported guest function
          config_schema:                # JSON Schema subset, ConfigSchema-validated
            type: object
            properties:
              routing_key:
                type: string
          capabilities: [send, test, resolve_update]
          payload_formats: [pagerduty_v2, json]
          routes: [control_plane, edge_agent]
          credential_requirements:
            routing_key:
              injection_mode: http_header
              name: Authorization
              scheme: Bearer
          inbound:
            enabled: false

  `key`, `display_name`, `entrypoint`, `capabilities`, and `payload_formats` are
  required. `routes` defaults to `["control_plane"]`, `config_schema` and
  `credential_requirements` default to empty, and `inbound` defaults to
  disabled. Unknown keys are REJECTED rather than ignored, so a manifest that
  misspells one fails at import instead of shipping a notifier whose
  credentials or callback configuration silently vanished.

  Two rules bind this block to the rest of the system:

    * `capabilities` MUST contain both `send` and `test` (tasks 3.1.1a).
    * a package with notifier entries MUST request the `notify:v1` capability,
      and a package requesting `notify:v1` MUST declare notifier entries. Either
      half alone is inert - the agent refuses a notifier without the capability,
      and the capability with no notifier grants nothing.
  """

  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.IntegrationDescriptor
  alias ServiceRadar.Plugins.NotificationCredentialRequirement
  alias ServiceRadar.Plugins.ValueUtils

  @enforce_keys [:id, :name, :version, :entrypoint, :capabilities, :outputs, :resources]
  defstruct [
    :id,
    :name,
    :version,
    :description,
    :entrypoint,
    :runtime,
    :capabilities,
    :permissions,
    :resources,
    :outputs,
    :actions,
    :source,
    :schema_version,
    :display_contract,
    :signal_schemas,
    :producer_schedules,
    :alert_rules,
    :snmp_requirements,
    :notifications,
    :integrations
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          version: String.t(),
          description: String.t() | nil,
          entrypoint: String.t(),
          runtime: String.t() | nil,
          capabilities: [String.t()],
          permissions: map(),
          resources: map(),
          outputs: String.t(),
          actions: [map()],
          source: map(),
          schema_version: pos_integer() | nil,
          display_contract: map(),
          signal_schemas: [map()],
          producer_schedules: [map()],
          alert_rules: [map()],
          snmp_requirements: [map()],
          notifications: [map()],
          integrations: IntegrationDescriptor.descriptor()
        }

  @allowed_runtimes ["none", "wasi-preview1"]
  @allowed_outputs [
    "serviceradar.plugin_result.v1",
    "serviceradar.camera_stream.v1",
    "serviceradar.proxmox_console.v1"
  ]
  @allowed_capabilities [
    "get_config",
    "log",
    "submit_result",
    "emit_telemetry",
    "http_request",
    "websocket_connect",
    "websocket_send",
    "websocket_recv",
    "websocket_close",
    "camera_media_stream",
    "proxmox_console_stream",
    "tcp_connect",
    "tcp_read",
    "tcp_write",
    "tcp_close",
    "udp_sendto",
    "artifact-staging:v1",
    "advisory-feed:v1",
    "producer-schedule:v1",
    "action-result-ingest:v1",
    "action-only:v1",
    "notify:v1"
  ]

  # `notify:v1` is the ONLY capability in the list above that is enforced by
  # this validator AND by the runtime host. `go/pkg/agent` refuses a notification
  # dispatch for an assignment whose narrowed capability set omits it
  # (`plugin_runtime_notify.go`). `advisory-feed:v1` and `producer-schedule:v1`
  # are declared here and enforced nowhere, which is the defect this change was
  # required not to repeat.
  @notify_capability "notify:v1"
  @allowed_producer_dispatch_scopes ["assignment", "package", "target_query"]
  @allowed_producer_command_types ["plugin.run_action", "addon.run_command"]
  @allowed_producer_schedule_types ["interval", "cron", "manual"]
  # A plugin proposes rules; it never activates them. `enabled` is deliberately
  # NOT accepted -- see AlertRuleCatalog for why a manifest must not be able to
  # turn on something that pages people.
  @allowed_alert_rule_signals ~w(metric log event)

  @allowed_alert_rule_keys ~w(
    name
    description
    signal
    match
    group_by
    threshold
    window_seconds
    bucket_seconds
    cooldown_seconds
    renotify_seconds
    event
    alert
  )

  # A plugin declares the SNMP data it needs; it never arms the polling.
  # `enabled`, `is_default`, `priority`, and `agent_ids` are deliberately NOT
  # accepted -- see SNMPRequirementCatalog for why a manifest must not be able
  # to start outbound probing of real inventory, nor outrank an operator's own
  # profile. Neither are any credential keys: SNMP credentials come from
  # Settings -> Credential Rules and are bound by an operator, never shipped or
  # named in a package.
  @allowed_snmp_requirement_keys ~w(
    name
    description
    category
    default_poll_interval_seconds
    default_timeout_seconds
    default_retries
    target_hint
    oids
  )

  @allowed_snmp_oid_keys ~w(
    oid
    name
    data_type
    scale
    delta
    mode
    max_rows
    walk_timeout_seconds
  )

  # Mirrors DataType in go/pkg/agent/snmp/types.go.
  @allowed_snmp_data_types ~w(counter gauge boolean bytes string float)
  @allowed_snmp_modes ~w(get walk)

  # Mirrors maxOIDNameLength in go/pkg/agent/snmp/config.go.
  @max_snmp_oid_name_length 64

  # Rejected outright rather than ignored, so a manifest that tries to ship a
  # credential or arm its own polling fails loudly at import instead of having
  # the key silently dropped.
  @refused_snmp_requirement_keys ~w(
    enabled
    is_default
    priority
    agent_ids
    host
    port
    version
    community
    username
    security_level
    auth_protocol
    auth_password
    priv_protocol
    priv_password
    credential_secret_id
  )

  @allowed_producer_schedule_keys ~w(
    id
    schedule_id
    label
    description
    action_id
    command_type
    default_cadence_seconds
    min_cadence_seconds
    max_cadence_seconds
    allow_cron
    schedule_type
    cron_expression
    jitter_seconds
    settings_schema
    credential_requirements
    payload_template
    redaction
    dispatch_scope
    timeout_seconds
  )
  @allowed_signal_types ["event", "log"]
  @allowed_signal_payload_kinds ["ocsf_event", "otel_log"]
  @allowed_signal_schema_keys ~w(
    id
    version
    signal_type
    payload_kind
    payload_schema
    display_contract
    display_contract_id
    display_contract_version
    ocsf_schema_version
    class_uid
    type_uid
  )
  # --- notifications: block (design D2, tasks 3.1.1) ---------------------
  #
  # The keys below are the WHOLE contract. Both SDKs emit exactly these names
  # (tasks 3.8.1) and anything else is rejected rather than ignored, so a
  # manifest that misspells a key fails at import instead of silently shipping a
  # notifier with, say, no credential requirements.
  #
  # Two near-miss spellings were considered and rejected during design and are
  # therefore NOT accepted here: `provider_key` (the entry key is `key`; the
  # provider key is chosen by the operator when the NotificationProvider row is
  # created) and `inbound_callback` (that is the name of the CAPABILITY; the
  # block that configures it is `inbound`).
  @allowed_notification_keys ~w(
    key
    display_name
    description
    entrypoint
    config_schema
    capabilities
    payload_formats
    routes
    credential_requirements
    inbound
  )

  # Mirrors `ServiceRadar.Notifications.NotificationProvider` capabilities.
  # It is deliberately a second literal list rather than a compile-time
  # reference: `NotificationProvider` belongs_to `Plugins.PluginPackage`, whose
  # validation calls back into this module, so naming the resource here would
  # close a compile cycle. `manifest_notifications_test.exs` asserts the two
  # lists are equal, which is what keeps them from drifting.
  @allowed_notification_capabilities ~w(
    send
    test
    resolve_update
    inbound_callback
    rich_payload
    attachments
    threading
  )

  # Both are mandatory in every tier (design D2, tasks 3.1.1a): "test-send
  # before saving" only works uniformly if no provider can opt out of `test`.
  @required_notification_capabilities ~w(send test)

  @allowed_notification_payload_formats ~w(
    slack_blocks
    discord_embed
    markdown
    plain
    html
    pagerduty_v2
    json
  )

  @allowed_notification_routes ~w(control_plane edge_agent)

  @allowed_notification_inbound_keys ~w(
    enabled
    signature
    signature_header
    timestamp_header
    tolerance_seconds
    path_suffix
  )

  @allowed_notification_inbound_signatures ~w(none hmac_sha256)

  # The CANONICAL injection mode names only (design Security, tasks 3.2.4).
  # `ServiceRadar.Plugins.IntegrationDescriptor` additionally accepts the
  # shorthands `header`, `http_basic_auth`, `query_param`, and `http_query`;
  # this block deliberately does not, so a plugin author never learns a spelling
  # one surface accepts and another does not.
  #
  # NOTE: none of these six rewrites a URL PATH. A destination whose secret
  # lives in the path (Slack and Discord incoming webhooks) cannot be served by
  # credential injection on the edge route at all; it uses the bot-token API or
  # `host_params_json`. A `url_path` mode is out of scope for v1 and must not be
  # added here without adding it to the host first.
  @allowed_credential_injection_modes NotificationCredentialRequirement.modes()

  @max_yaml_bytes 262_144
  @max_signal_ref_length 160
  @max_signal_path_length 240
  @max_notifications 32
  @max_notification_credential_requirements 16
  @default_inbound_tolerance_seconds 300
  @max_inbound_tolerance_seconds 900

  @doc """
  Parse and validate a plugin manifest from YAML.
  """
  @spec from_yaml(String.t()) :: {:ok, t()} | {:error, [String.t()]}
  def from_yaml(yaml) when is_binary(yaml) do
    with {:ok, map} <- parse_yaml_map(yaml) do
      from_map(map)
    end
  end

  @doc """
  Parse plugin manifest YAML into a map using the same safety checks as validation.
  """
  @spec parse_yaml_map(String.t()) :: {:ok, map()} | {:error, [String.t()]}
  def parse_yaml_map(yaml) when is_binary(yaml) do
    with :ok <- validate_yaml_size(yaml),
         :ok <- validate_yaml_safety(yaml),
         {:ok, value} <- parse_yaml(yaml),
         true <- is_map(value) do
      {:ok, value}
    else
      false -> {:error, ["manifest yaml must decode to a map"]}
      {:error, errors} when is_list(errors) -> {:error, errors}
    end
  end

  def parse_yaml_map(_yaml), do: {:error, ["manifest yaml must be a string"]}

  @doc """
  Validate a plugin manifest map (already parsed).
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, [String.t()]}
  def from_map(map) when is_map(map) do
    errors = []

    {id, errors} = required_string(map, :id, errors)
    {name, errors} = required_string(map, :name, errors)
    {version, errors} = required_string(map, :version, errors)
    {entrypoint, errors} = required_string(map, :entrypoint, errors)
    {outputs, errors} = required_string(map, :outputs, errors)
    {capabilities, errors} = required_string_list(map, :capabilities, errors)
    {resources, errors} = required_map(map, :resources, errors)

    errors = validate_semver(version, errors)
    errors = validate_outputs(outputs, errors)
    errors = validate_capabilities(capabilities, errors)

    {resources, errors} = validate_resources(resources, errors)
    {permissions, errors} = validate_permissions(fetch(map, :permissions), errors)
    {actions, errors} = validate_actions(fetch(map, :actions), errors)

    runtime = fetch(map, :runtime)
    errors = validate_runtime(runtime, errors)

    description = fetch(map, :description)
    schema_version = fetch(map, :schema_version)
    {schema_version, errors} = optional_positive_int(schema_version, :schema_version, errors)
    source = normalize_map(fetch(map, :source)) || %{}
    display_contract = normalize_map(fetch(map, :display_contract)) || %{}
    errors = display_contract_errors(display_contract) ++ errors
    {signal_schemas, errors} = validate_signal_schemas(fetch(map, :signal_schemas), errors)

    {producer_schedules, errors} =
      validate_producer_schedules(fetch(map, :producer_schedules), errors)

    {alert_rules, errors} = validate_alert_rules(fetch(map, :alert_rules), errors)

    {snmp_requirements, errors} =
      validate_snmp_requirements(fetch(map, :snmp_requirements), errors)

    raw_notifications = fetch(map, :notifications)
    {notifications, errors} = validate_notifications(raw_notifications, errors)
    errors = validate_notify_capability_coherence(capabilities, raw_notifications, errors)

    {integrations, errors} =
      case IntegrationDescriptor.validate(fetch(map, :integrations), producer_schedules) do
        {:ok, integrations} ->
          {integrations, errors}

        {:error, integration_errors} ->
          {IntegrationDescriptor.empty(), integration_errors ++ errors}
      end

    if errors == [] do
      schema_version = schema_version || 1

      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         version: version,
         description: normalize_string(description),
         entrypoint: entrypoint,
         runtime: normalize_string(runtime),
         capabilities: capabilities,
         permissions: permissions,
         resources: resources,
         outputs: outputs,
         actions: actions,
         source: source,
         schema_version: schema_version,
         display_contract: display_contract,
         signal_schemas: signal_schemas,
         producer_schedules: producer_schedules,
         alert_rules: alert_rules,
         snmp_requirements: snmp_requirements,
         notifications: notifications,
         integrations: integrations
       }}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  def from_map(_), do: {:error, ["manifest must be a map"]}

  @doc """
  Validate an optional JSON config schema bundled with the plugin.
  """
  @spec validate_config_schema(binary() | map() | nil) :: :ok | {:error, [String.t()]}
  def validate_config_schema(nil), do: :ok

  def validate_config_schema(schema) when is_map(schema) do
    ConfigSchema.validate_schema(schema)
  end

  def validate_config_schema(schema) when is_binary(schema) do
    case Jason.decode(schema) do
      {:ok, value} when is_map(value) ->
        ConfigSchema.validate_schema(value)

      {:ok, _} ->
        {:error, ["config schema must be a JSON object"]}

      {:error, reason} ->
        {:error, ["invalid config schema JSON: #{Exception.message(reason)}"]}
    end
  end

  def validate_config_schema(_), do: {:error, ["config schema must be JSON"]}

  @doc """
  Validate an optional display contract map.
  """
  @spec validate_display_contract(map() | nil) :: :ok | {:error, [String.t()]}
  def validate_display_contract(nil), do: :ok

  def validate_display_contract(contract) when is_map(contract), do: :ok

  def validate_display_contract(_), do: {:error, ["display contract must be a JSON object"]}

  @doc """
  Validate optional log/event signal schema declarations bundled with the package.
  """
  @spec validate_signal_schemas([map()] | nil) :: :ok | {:error, [String.t()]}
  def validate_signal_schemas(nil), do: :ok

  def validate_signal_schemas(signal_schemas) do
    case validate_signal_schemas(signal_schemas, []) do
      {_normalized, []} -> :ok
      {_normalized, errors} -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Validate optional package-owned producer schedule declarations.
  """
  @spec validate_producer_schedules([map()] | nil) :: :ok | {:error, [String.t()]}
  def validate_producer_schedules(nil), do: :ok

  def validate_producer_schedules(producer_schedules) do
    case validate_producer_schedules(producer_schedules, []) do
      {_normalized, []} -> :ok
      {_normalized, errors} -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Validate the optional package-owned `notifications:` block.
  """
  @spec validate_notifications([map()] | nil) :: :ok | {:error, [String.t()]}
  def validate_notifications(nil), do: :ok

  def validate_notifications(notifications) do
    case validate_notifications(notifications, []) do
      {_normalized, []} -> :ok
      {_normalized, errors} -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  The notifier keys a package's manifest declares, in declaration order.

  This is the resolver behind `NotificationProvider.action_key` (tasks 3.1.1b):
  a provider row may only name a notifier its package actually ships. The
  manifest map is re-validated here rather than trusted, because a stored
  manifest predates whatever validation the current release performs.

  Returns `{:error, errors}` when the block is present but invalid, and
  `{:ok, []}` when the package declares no notifiers at all - the caller
  distinguishes "this package ships no notifier" from "this manifest is broken".
  """
  @spec notification_keys(map()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def notification_keys(manifest) when is_map(manifest) do
    with {:ok, entries} <- notification_entries(manifest) do
      {:ok, Enum.map(entries, &Map.fetch!(&1, "key"))}
    end
  end

  def notification_keys(_manifest), do: {:error, ["manifest must be a map"]}

  @doc """
  The validated notifier entries a package's manifest declares, in declaration
  order.

  The whole entry, not just its `key`, because the UI resolves a notifier's
  `config_schema` from HERE at runtime rather than from the copy taken when the
  provider row was created (tasks 3.5.1, 3.5.4). Re-validating rather than
  trusting the stored manifest is the same rule `notification_keys/1` follows: a
  stored manifest predates whatever validation the current release performs.
  """
  @spec notification_entries(map()) :: {:ok, [map()]} | {:error, [String.t()]}
  def notification_entries(manifest) when is_map(manifest) do
    case validate_notifications(fetch(manifest, :notifications), []) do
      {normalized, []} -> {:ok, normalized}
      {_normalized, errors} -> {:error, Enum.reverse(errors)}
    end
  end

  def notification_entries(_manifest), do: {:error, ["manifest must be a map"]}

  @doc "The capability a package must request to run any notifier on an agent."
  @spec notify_capability() :: String.t()
  def notify_capability, do: @notify_capability

  @doc "Capability names a `notifications:` entry may declare."
  @spec allowed_notification_capabilities() :: [String.t()]
  def allowed_notification_capabilities, do: @allowed_notification_capabilities

  @doc "Payload format names a `notifications:` entry may declare."
  @spec allowed_notification_payload_formats() :: [String.t()]
  def allowed_notification_payload_formats, do: @allowed_notification_payload_formats

  @doc "Execution routes a `notifications:` entry may declare."
  @spec allowed_notification_routes() :: [String.t()]
  def allowed_notification_routes, do: @allowed_notification_routes

  @doc "Canonical credential injection mode names accepted in a `notifications:` entry."
  @spec allowed_credential_injection_modes() :: [String.t()]
  def allowed_credential_injection_modes, do: @allowed_credential_injection_modes

  defp display_contract_errors(display_contract) do
    case validate_display_contract(display_contract) do
      :ok -> []
      {:error, errs} -> errs
    end
  end

  # A `notifications:` block and the `notify:v1` capability are two halves of one
  # declaration, and either half alone is inert: a block without the capability
  # is a notifier the agent refuses to run, and the capability without a block is
  # a permission with nothing behind it. Both directions are rejected so the
  # incoherence surfaces at import rather than as an undeliverable page.
  #
  # The check reads the RAW block rather than the normalized entries: an entry
  # that failed its own validation is dropped from the normalized list, and
  # keying on that would bury the real error under a second, misleading one
  # about a missing block.
  defp validate_notify_capability_coherence(capabilities, raw_notifications, errors)
       when is_list(capabilities) do
    declared? = @notify_capability in capabilities
    notifiers? = raw_notifications not in [nil, []]

    cond do
      declared? and not notifiers? ->
        [
          "capabilities declare #{@notify_capability} but the manifest has no notifications entries"
          | errors
        ]

      notifiers? and not declared? ->
        [
          "notifications requires the #{@notify_capability} capability to be declared"
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_notify_capability_coherence(_capabilities, _raw_notifications, errors), do: errors

  defp validate_notifications(nil, errors), do: {[], errors}

  defp validate_notifications(notifications, errors) when is_list(notifications) do
    if length(notifications) > @max_notifications do
      {[], ["notifications must declare at most #{@max_notifications} entries" | errors]}
    else
      notifications
      |> Enum.with_index(1)
      |> Enum.reduce({[], errors}, fn {notification, index}, {acc, errors} ->
        case validate_notification(notification, index) do
          {:ok, normalized} -> {[normalized | acc], errors}
          {:error, notification_errors} -> {acc, notification_errors ++ errors}
        end
      end)
      |> then(fn {entries, errors} ->
        entries = Enum.reverse(entries)
        {entries, duplicate_notification_key_errors(entries) ++ errors}
      end)
    end
  end

  defp validate_notifications(_notifications, errors),
    do: {[], ["notifications must be a list" | errors]}

  # A duplicate key makes `action_key` resolution ambiguous, so the provider
  # binding in 3.1.1b would admit a row whose target is undecidable.
  defp duplicate_notification_key_errors(entries) do
    entries
    |> Enum.map(&Map.fetch!(&1, "key"))
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(fn {key, _count} -> "notifications key #{key} is declared more than once" end)
  end

  defp validate_notification(notification, index) when is_map(notification) do
    notification = normalize_map(notification) || %{}
    errors = unknown_notification_key_errors(notification, index)

    {key, errors} = required_notification_string(notification, :key, index, errors)
    errors = validate_notification_key(errors, key, index)

    {display_name, errors} =
      required_notification_string(notification, :display_name, index, errors)

    {entrypoint, errors} = required_notification_string(notification, :entrypoint, index, errors)

    {description, errors} =
      optional_notification_string(notification, :description, index, errors)

    {capabilities, errors} =
      required_notification_enum_list(
        notification,
        :capabilities,
        @allowed_notification_capabilities,
        index,
        errors
      )

    errors = validate_required_notification_capabilities(errors, capabilities, index)

    {payload_formats, errors} =
      required_notification_enum_list(
        notification,
        :payload_formats,
        @allowed_notification_payload_formats,
        index,
        errors
      )

    {routes, errors} =
      optional_notification_enum_list(
        notification,
        :routes,
        @allowed_notification_routes,
        index,
        errors
      )

    routes = if routes == [], do: ["control_plane"], else: routes

    {config_schema, errors} = validate_notification_config_schema(notification, index, errors)

    {credential_requirements, errors} =
      validate_notification_credential_requirements(notification, index, errors)

    {inbound, errors} = validate_notification_inbound(notification, index, errors)
    errors = validate_inbound_capability_coherence(errors, capabilities, inbound, index)

    if errors == [] do
      {:ok,
       maybe_put_string(
         %{
           "key" => key,
           "display_name" => display_name,
           "entrypoint" => entrypoint,
           "config_schema" => config_schema,
           "capabilities" => capabilities,
           "payload_formats" => payload_formats,
           "routes" => routes,
           "credential_requirements" => credential_requirements,
           "inbound" => inbound
         },
         "description",
         description
       )}
    else
      {:error, errors}
    end
  end

  defp validate_notification(_notification, index),
    do: {:error, ["notifications[#{index}] must be a map"]}

  defp unknown_notification_key_errors(notification, index) do
    notification
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in @allowed_notification_keys))
    |> Enum.map(&"notifications[#{index}].#{&1} is not allowed")
  end

  defp validate_notification_key(errors, nil, _index), do: errors

  defp validate_notification_key(errors, value, index) do
    cond do
      String.length(value) > @max_signal_ref_length ->
        ["notifications[#{index}].key exceeds maximum length" | errors]

      Regex.match?(~r/^[a-z0-9][a-z0-9_.-]*$/, value) ->
        errors

      true ->
        [
          "notifications[#{index}].key must use lowercase letters, numbers, dots, underscores, or hyphens"
          | errors
        ]
    end
  end

  defp validate_required_notification_capabilities(errors, capabilities, index) do
    case Enum.reject(@required_notification_capabilities, &(&1 in capabilities)) do
      [] ->
        errors

      missing ->
        [
          "notifications[#{index}].capabilities must include #{Enum.join(@required_notification_capabilities, " and ")}; missing #{Enum.join(missing, ", ")}"
          | errors
        ]
    end
  end

  defp validate_notification_config_schema(notification, index, errors) do
    case fetch(notification, :config_schema) do
      nil ->
        {%{}, errors}

      value when is_map(value) ->
        schema = normalize_map(value) || %{}

        if schema == %{} do
          {schema, errors}
        else
          case ConfigSchema.validate_schema(schema) do
            :ok ->
              {schema, errors}

            {:error, schema_errors} ->
              {%{},
               Enum.map(schema_errors, &"notifications[#{index}].config_schema: #{&1}") ++ errors}
          end
        end

      _other ->
        {%{}, ["notifications[#{index}].config_schema must be a map" | errors]}
    end
  end

  defp validate_notification_credential_requirements(notification, index, errors) do
    case fetch(notification, :credential_requirements) do
      nil ->
        {%{}, errors}

      value when is_map(value) ->
        requirements = normalize_map(value) || %{}

        if map_size(requirements) > @max_notification_credential_requirements do
          {%{},
           [
             "notifications[#{index}].credential_requirements must declare at most #{@max_notification_credential_requirements} entries"
             | errors
           ]}
        else
          normalize_credential_requirements(requirements, index, errors)
        end

      _other ->
        {%{}, ["notifications[#{index}].credential_requirements must be a map" | errors]}
    end
  end

  defp normalize_credential_requirements(requirements, index, errors) do
    Enum.reduce(requirements, {%{}, errors}, fn {name, requirement}, {acc, errors} ->
      name = to_string(name)

      cond do
        not Regex.match?(~r/^[a-z0-9][a-z0-9_.-]*$/, name) ->
          {acc,
           [
             "notifications[#{index}].credential_requirements.#{name} must use lowercase letters, numbers, dots, underscores, or hyphens"
             | errors
           ]}

        not is_map(requirement) ->
          {acc,
           [
             "notifications[#{index}].credential_requirements.#{name} must be a map"
             | errors
           ]}

        true ->
          path = "notifications[#{index}].credential_requirements.#{name}"

          case NotificationCredentialRequirement.normalize(requirement, path) do
            {:ok, normalized} ->
              {Map.put(acc, name, normalized), errors}

            {:error, requirement_errors} ->
              {acc, Enum.reverse(requirement_errors, errors)}
          end
      end
    end)
  end

  defp validate_notification_inbound(notification, index, errors) do
    case fetch(notification, :inbound) do
      nil ->
        {default_inbound(), errors}

      value when is_map(value) ->
        inbound = normalize_map(value) || %{}
        errors = unknown_inbound_key_errors(inbound, index) ++ errors
        enabled? = truthy?(fetch(inbound, :enabled))

        {signature, errors} = optional_notification_string(inbound, :signature, index, errors)
        signature = signature || "none"

        errors =
          if signature in @allowed_notification_inbound_signatures do
            errors
          else
            [
              "notifications[#{index}].inbound.signature must be one of: #{Enum.join(@allowed_notification_inbound_signatures, ", ")}"
              | errors
            ]
          end

        {signature_header, errors} =
          optional_notification_string(inbound, :signature_header, index, errors)

        {timestamp_header, errors} =
          optional_notification_string(inbound, :timestamp_header, index, errors)

        {path_suffix, errors} =
          optional_notification_string(inbound, :path_suffix, index, errors)

        {tolerance_seconds, errors} = inbound_tolerance_seconds(inbound, index, errors)

        errors = inbound_coherence_errors(errors, enabled?, signature, signature_header, index)
        errors = inbound_path_suffix_errors(errors, enabled?, path_suffix, index)

        inbound =
          %{
            "enabled" => enabled?,
            "signature" => signature,
            "tolerance_seconds" => tolerance_seconds || @default_inbound_tolerance_seconds
          }
          |> maybe_put_string("signature_header", signature_header)
          |> maybe_put_string("timestamp_header", timestamp_header)
          |> maybe_put_string("path_suffix", path_suffix)

        {inbound, errors}

      _other ->
        {default_inbound(), ["notifications[#{index}].inbound must be a map" | errors]}
    end
  end

  defp default_inbound do
    %{
      "enabled" => false,
      "signature" => "none",
      "tolerance_seconds" => @default_inbound_tolerance_seconds
    }
  end

  defp unknown_inbound_key_errors(inbound, index) do
    inbound
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in @allowed_notification_inbound_keys))
    |> Enum.map(&"notifications[#{index}].inbound.#{&1} is not allowed")
  end

  defp inbound_tolerance_seconds(inbound, index, errors) do
    case normalize_int(fetch(inbound, :tolerance_seconds)) do
      nil ->
        {nil, errors}

      value when value > 0 and value <= @max_inbound_tolerance_seconds ->
        {value, errors}

      _other ->
        {nil,
         [
           "notifications[#{index}].inbound.tolerance_seconds must be a positive integer of at most #{@max_inbound_tolerance_seconds}"
           | errors
         ]}
    end
  end

  # An enabled callback that signs nothing accepts any caller who guesses the
  # route, so the signed shape is mandatory rather than a default the author can
  # forget. The header name is what the verifier reads the signature from, so an
  # `hmac_sha256` declaration without one cannot be verified at all.
  defp inbound_coherence_errors(errors, false, _signature, _signature_header, _index), do: errors

  defp inbound_coherence_errors(errors, true, "none", _signature_header, index) do
    [
      "notifications[#{index}].inbound.signature must be hmac_sha256 when inbound is enabled"
      | errors
    ]
  end

  defp inbound_coherence_errors(errors, true, _signature, nil, index) do
    [
      "notifications[#{index}].inbound.signature_header is required when a signature is declared"
      | errors
    ]
  end

  defp inbound_coherence_errors(errors, true, _signature, _signature_header, _index), do: errors

  defp inbound_path_suffix_errors(errors, false, _path_suffix, _index), do: errors

  defp inbound_path_suffix_errors(errors, true, nil, index) do
    ["notifications[#{index}].inbound.path_suffix is required when inbound is enabled" | errors]
  end

  defp inbound_path_suffix_errors(errors, true, path_suffix, index) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, path_suffix) do
      errors
    else
      [
        "notifications[#{index}].inbound.path_suffix must use lowercase letters, numbers, underscores, or hyphens"
        | errors
      ]
    end
  end

  defp validate_inbound_capability_coherence(errors, capabilities, inbound, index) do
    declared? = "inbound_callback" in capabilities
    enabled? = Map.get(inbound, "enabled", false)

    cond do
      enabled? and not declared? ->
        [
          "notifications[#{index}].inbound requires the inbound_callback capability"
          | errors
        ]

      declared? and not enabled? ->
        [
          "notifications[#{index}].capabilities declare inbound_callback but inbound is not enabled"
          | errors
        ]

      true ->
        errors
    end
  end

  defp required_notification_string(notification, key, index, errors) do
    case normalize_string(fetch(notification, key)) do
      nil -> {nil, ["notifications[#{index}].#{key} must be a non-empty string" | errors]}
      "" -> {nil, ["notifications[#{index}].#{key} must be a non-empty string" | errors]}
      value -> {value, errors}
    end
  end

  defp optional_notification_string(notification, key, index, errors) do
    case fetch(notification, key) do
      nil ->
        {nil, errors}

      value ->
        case normalize_string(value) do
          nil ->
            {nil, ["notifications[#{index}].#{key} must be a non-empty string" | errors]}

          "" ->
            {nil, ["notifications[#{index}].#{key} must be a non-empty string" | errors]}

          normalized ->
            {normalized, errors}
        end
    end
  end

  # A notifier that declares no capability, or no payload format, cannot deliver
  # anything: format negotiation would fail at dispatch time on a provider that
  # saved cleanly. Both lists are therefore required and non-empty.
  defp required_notification_enum_list(notification, key, allowed, index, errors) do
    case fetch(notification, key) do
      nil ->
        {[], ["notifications[#{index}].#{key} must be a non-empty list of strings" | errors]}

      [] ->
        {[], ["notifications[#{index}].#{key} must be a non-empty list of strings" | errors]}

      _present ->
        optional_notification_enum_list(notification, key, allowed, index, errors)
    end
  end

  defp optional_notification_enum_list(notification, key, allowed, index, errors) do
    case fetch(notification, key) do
      nil ->
        {[], errors}

      list when is_list(list) ->
        values = normalize_string_list(list)

        cond do
          length(values) != length(list) ->
            {[], ["notifications[#{index}].#{key} must be a list of strings" | errors]}

          (invalid = Enum.reject(values, &(&1 in allowed))) != [] ->
            {[],
             [
               "notifications[#{index}].#{key} contains unsupported entries: #{Enum.join(invalid, ", ")}"
               | errors
             ]}

          values != Enum.uniq(values) ->
            {[], ["notifications[#{index}].#{key} must not repeat an entry" | errors]}

          true ->
            {values, errors}
        end

      _other ->
        {[], ["notifications[#{index}].#{key} must be a list of strings" | errors]}
    end
  end

  defp validate_signal_schemas(nil, errors), do: {[], errors}

  defp validate_signal_schemas(signal_schemas, errors) when is_list(signal_schemas) do
    signal_schemas
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {schema, index}, {acc, errors} ->
      case validate_signal_schema(schema, index) do
        {:ok, normalized} -> {[normalized | acc], errors}
        {:error, schema_errors} -> {acc, schema_errors ++ errors}
      end
    end)
    |> then(fn {schemas, errors} -> {Enum.reverse(schemas), errors} end)
  end

  defp validate_signal_schemas(_signal_schemas, errors),
    do: {[], ["signal_schemas must be a list" | errors]}

  defp validate_alert_rules(nil, errors), do: {[], errors}

  defp validate_alert_rules(rules, errors) when is_list(rules) do
    rules
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {rule, index}, {acc, errors} ->
      case validate_alert_rule(rule, index) do
        {:ok, normalized} -> {[normalized | acc], errors}
        {:error, rule_errors} -> {acc, rule_errors ++ errors}
      end
    end)
    |> then(fn {rules, errors} -> {Enum.reverse(rules), errors} end)
  end

  defp validate_alert_rules(_rules, errors), do: {[], ["alert_rules must be a list" | errors]}

  defp validate_alert_rule(rule, index) when is_map(rule) do
    rule = normalize_map(rule) || %{}
    errors = unknown_alert_rule_key_errors(rule, index)

    {name, errors} =
      case normalize_string(fetch(rule, :name)) do
        value when is_binary(value) and value != "" -> {value, errors}
        _ -> {nil, ["alert_rules[#{index}].name must be a non-empty string" | errors]}
      end

    signal = normalize_string(fetch(rule, :signal)) || "metric"

    errors =
      if signal in @allowed_alert_rule_signals do
        errors
      else
        [
          "alert_rules[#{index}].signal must be one of: #{Enum.join(@allowed_alert_rule_signals, ", ")}"
          | errors
        ]
      end

    # A rule whose match is empty matches EVERY record on its signal. That is
    # not a plausible thing to ship deliberately, and it would fire on the first
    # metric that arrived, so it is rejected rather than accepted and disabled.
    match = fetch(rule, :match)

    errors =
      if is_map(match) and map_size(match) > 0 do
        errors
      else
        ["alert_rules[#{index}].match must be a non-empty map" | errors]
      end

    group_by = fetch(rule, :group_by)

    errors =
      cond do
        is_nil(group_by) ->
          errors

        is_list(group_by) and group_by != [] and Enum.all?(group_by, &is_binary/1) ->
          errors

        true ->
          ["alert_rules[#{index}].group_by must be a non-empty list of strings" | errors]
      end

    if errors == [] do
      {:ok, Map.put(rule, "name", name)}
    else
      {:error, errors}
    end
  end

  defp validate_alert_rule(_rule, index), do: {:error, ["alert_rules[#{index}] must be a map"]}

  defp unknown_alert_rule_key_errors(rule, index) do
    rule
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in @allowed_alert_rule_keys))
    |> Enum.map(&"alert_rules[#{index}].#{&1} is not allowed")
  end

  defp validate_snmp_requirements(nil, errors), do: {[], errors}

  defp validate_snmp_requirements(requirements, errors) when is_list(requirements) do
    requirements
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {requirement, index}, {acc, errors} ->
      case validate_snmp_requirement(requirement, index) do
        {:ok, normalized} -> {[normalized | acc], errors}
        {:error, requirement_errors} -> {acc, requirement_errors ++ errors}
      end
    end)
    |> then(fn {requirements, errors} -> {Enum.reverse(requirements), errors} end)
  end

  defp validate_snmp_requirements(_requirements, errors),
    do: {[], ["snmp_requirements must be a list" | errors]}

  defp validate_snmp_requirement(requirement, index) when is_map(requirement) do
    requirement = normalize_map(requirement) || %{}
    errors = snmp_requirement_key_errors(requirement, index)

    {name, errors} =
      case normalize_string(fetch(requirement, :name)) do
        value when is_binary(value) and value != "" -> {value, errors}
        _ -> {nil, ["snmp_requirements[#{index}].name must be a non-empty string" | errors]}
      end

    errors =
      errors
      |> snmp_positive_integer_errors(requirement, :default_poll_interval_seconds, index)
      |> snmp_positive_integer_errors(requirement, :default_timeout_seconds, index)
      |> snmp_positive_integer_errors(requirement, :default_retries, index)
      |> snmp_oids_errors(requirement, index)

    if errors == [] do
      # Store the NORMALIZED oids, not the raw ones. Validation reads through
      # normalize_string, so an OID with surrounding whitespace validates fine;
      # storing the raw value would then materialize a template the agent
      # rejects on `isValidOID`, and the target would be silently dropped at the
      # far end rather than refused here.
      {:ok,
       requirement
       |> Map.put("name", name)
       |> Map.put("oids", normalize_snmp_oids(fetch(requirement, :oids)))}
    else
      {:error, errors}
    end
  end

  defp validate_snmp_requirement(_requirement, index),
    do: {:error, ["snmp_requirements[#{index}] must be a map"]}

  defp normalize_snmp_oids(oids) when is_list(oids), do: Enum.map(oids, &normalize_snmp_oid/1)

  defp normalize_snmp_oid(oid) do
    oid = normalize_map(oid) || %{}

    Enum.reduce(~w(oid name data_type mode), oid, fn key, acc ->
      case normalize_string(fetch(acc, key)) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp snmp_requirement_key_errors(requirement, index) do
    keys = requirement |> Map.keys() |> Enum.map(&to_string/1)

    refused =
      keys
      |> Enum.filter(&(&1 in @refused_snmp_requirement_keys))
      |> Enum.map(fn key ->
        "snmp_requirements[#{index}].#{key} is not allowed: " <>
          "a plugin declares what it needs polled, and never credentials, targets, or whether to poll"
      end)

    unknown =
      keys
      |> Enum.reject(&(&1 in @allowed_snmp_requirement_keys))
      |> Enum.reject(&(&1 in @refused_snmp_requirement_keys))
      |> Enum.map(&"snmp_requirements[#{index}].#{&1} is not allowed")

    refused ++ unknown
  end

  defp snmp_positive_integer_errors(errors, requirement, key, index) do
    case fetch(requirement, key) do
      nil ->
        errors

      value when is_integer(value) and value > 0 ->
        errors

      _ ->
        ["snmp_requirements[#{index}].#{key} must be a positive integer" | errors]
    end
  end

  defp snmp_oids_errors(errors, requirement, index) do
    case fetch(requirement, :oids) do
      oids when is_list(oids) and oids != [] ->
        oids
        |> Enum.with_index(1)
        |> Enum.reduce(errors, fn {oid, oid_index}, acc ->
          snmp_oid_errors(acc, oid, index, oid_index)
        end)

      _ ->
        ["snmp_requirements[#{index}].oids must be a non-empty list" | errors]
    end
  end

  # Every constraint here is one the Go agent applies too. It is enforced at
  # import because ValidateForAgent drops a target it cannot use: a malformed
  # OID would otherwise be accepted into a package, materialize into a profile,
  # and then silently collect nothing.
  defp snmp_oid_errors(errors, oid, index, oid_index) when is_map(oid) do
    oid = normalize_map(oid) || %{}
    path = "snmp_requirements[#{index}].oids[#{oid_index}]"

    errors =
      oid
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in @allowed_snmp_oid_keys))
      |> Enum.map(&"#{path}.#{&1} is not allowed")
      |> Kernel.++(errors)

    errors
    |> snmp_oid_string_errors(oid, path)
    |> snmp_oid_enum_errors(oid, path)
    |> snmp_oid_number_errors(oid, path)
  end

  defp snmp_oid_errors(errors, _oid, index, oid_index),
    do: ["snmp_requirements[#{index}].oids[#{oid_index}] must be a map" | errors]

  defp snmp_oid_string_errors(errors, oid, path) do
    errors =
      case normalize_string(fetch(oid, :oid)) do
        value when is_binary(value) -> snmp_oid_format_errors(errors, value, path)
        _ -> ["#{path}.oid must be a string" | errors]
      end

    case normalize_string(fetch(oid, :name)) do
      value
      when is_binary(value) and value != "" and byte_size(value) <= @max_snmp_oid_name_length ->
        errors

      _ ->
        [
          "#{path}.name must be a non-empty string of at most #{@max_snmp_oid_name_length} bytes"
          | errors
        ]
    end
  end

  # Mirrors isValidOID in go/pkg/agent/snmp/config.go: the `.1.3.6.1.` prefix
  # and all-numeric arcs.
  defp snmp_oid_format_errors(errors, value, path) do
    numeric_arcs? =
      value
      |> String.trim_leading(".")
      |> String.split(".")
      |> then(
        &(&1 != [] and Enum.all?(&1, fn arc -> arc != "" and String.match?(arc, ~r/^\d+$/) end))
      )

    if String.starts_with?(value, ".1.3.6.1.") and numeric_arcs? do
      errors
    else
      ["#{path}.oid must start with .1.3.6.1. and contain only numeric arcs" | errors]
    end
  end

  defp snmp_oid_enum_errors(errors, oid, path) do
    errors =
      case normalize_string(fetch(oid, :data_type)) do
        value when value in @allowed_snmp_data_types ->
          errors

        _ ->
          [
            "#{path}.data_type must be one of: #{Enum.join(@allowed_snmp_data_types, ", ")}"
            | errors
          ]
      end

    case normalize_string(fetch(oid, :mode)) do
      nil -> errors
      value when value in @allowed_snmp_modes -> errors
      _ -> ["#{path}.mode must be one of: #{Enum.join(@allowed_snmp_modes, ", ")}" | errors]
    end
  end

  defp snmp_oid_number_errors(errors, oid, path) do
    errors =
      case fetch(oid, :delta) do
        nil -> errors
        value when is_boolean(value) -> errors
        _ -> ["#{path}.delta must be a boolean" | errors]
      end

    Enum.reduce([:scale, :max_rows, :walk_timeout_seconds], errors, fn key, acc ->
      case fetch(oid, key) do
        nil -> acc
        value when is_number(value) and value >= 0 -> acc
        _ -> ["#{path}.#{key} must be a non-negative number" | acc]
      end
    end)
  end

  defp validate_producer_schedules(nil, errors), do: {[], errors}

  defp validate_producer_schedules(producer_schedules, errors) when is_list(producer_schedules) do
    producer_schedules
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {schedule, index}, {acc, errors} ->
      case validate_producer_schedule(schedule, index) do
        {:ok, normalized} -> {[normalized | acc], errors}
        {:error, schedule_errors} -> {acc, schedule_errors ++ errors}
      end
    end)
    |> then(fn {schedules, errors} -> {Enum.reverse(schedules), errors} end)
  end

  defp validate_producer_schedules(_producer_schedules, errors),
    do: {[], ["producer_schedules must be a list" | errors]}

  defp validate_producer_schedule(schedule, index) when is_map(schedule) do
    schedule = normalize_map(schedule) || %{}
    errors = unknown_producer_schedule_key_errors(schedule, index)

    {schedule_id, errors} =
      optional_producer_schedule_string(schedule, :schedule_id, index, errors)

    {id, errors} = optional_producer_schedule_string(schedule, :id, index, errors)
    schedule_id = schedule_id || id

    errors =
      if is_nil(schedule_id) do
        ["producer_schedules[#{index}].schedule_id must be a non-empty string" | errors]
      else
        validate_producer_schedule_id(errors, schedule_id, "schedule_id", index)
      end

    {label, errors} = required_producer_schedule_string(schedule, :label, index, errors)

    {description, errors} =
      optional_producer_schedule_string(schedule, :description, index, errors)

    {action_id, errors} = optional_producer_schedule_string(schedule, :action_id, index, errors)

    {command_type, errors} =
      optional_producer_schedule_string(schedule, :command_type, index, errors)

    command_type = command_type || "plugin.run_action"

    errors =
      cond do
        command_type not in @allowed_producer_command_types ->
          [
            "producer_schedules[#{index}].command_type must be one of: #{Enum.join(@allowed_producer_command_types, ", ")}"
            | errors
          ]

        command_type in @allowed_producer_command_types and is_nil(action_id) ->
          [
            "producer_schedules[#{index}].action_id is required for #{command_type}"
            | errors
          ]

        true ->
          errors
      end

    {schedule_type, errors} =
      optional_producer_schedule_string(schedule, :schedule_type, index, errors)

    schedule_type = schedule_type || "interval"

    errors =
      if schedule_type in @allowed_producer_schedule_types do
        errors
      else
        [
          "producer_schedules[#{index}].schedule_type must be one of: #{Enum.join(@allowed_producer_schedule_types, ", ")}"
          | errors
        ]
      end

    {default_cadence_seconds, errors} =
      optional_producer_schedule_positive_int(
        schedule,
        :default_cadence_seconds,
        index,
        errors
      )

    {min_cadence_seconds, errors} =
      optional_producer_schedule_positive_int(schedule, :min_cadence_seconds, index, errors)

    {max_cadence_seconds, errors} =
      optional_producer_schedule_positive_int(schedule, :max_cadence_seconds, index, errors)

    default_cadence_seconds = default_cadence_seconds || 86_400
    min_cadence_seconds = min_cadence_seconds || 300
    max_cadence_seconds = max_cadence_seconds || 2_592_000

    errors =
      cond do
        min_cadence_seconds > max_cadence_seconds ->
          [
            "producer_schedules[#{index}].min_cadence_seconds must be <= max_cadence_seconds"
            | errors
          ]

        default_cadence_seconds < min_cadence_seconds or
            default_cadence_seconds > max_cadence_seconds ->
          [
            "producer_schedules[#{index}].default_cadence_seconds must be within cadence bounds"
            | errors
          ]

        true ->
          errors
      end

    {jitter_seconds, errors} =
      optional_producer_schedule_nonneg_int(schedule, :jitter_seconds, index, errors)

    {timeout_seconds, errors} =
      optional_producer_schedule_positive_int(schedule, :timeout_seconds, index, errors)

    {cron_expression, errors} =
      optional_producer_schedule_string(schedule, :cron_expression, index, errors)

    {dispatch_scope, errors} =
      optional_producer_schedule_string(schedule, :dispatch_scope, index, errors)

    dispatch_scope = dispatch_scope || "assignment"

    errors =
      if dispatch_scope in @allowed_producer_dispatch_scopes do
        errors
      else
        [
          "producer_schedules[#{index}].dispatch_scope must be one of: #{Enum.join(@allowed_producer_dispatch_scopes, ", ")}"
          | errors
        ]
      end

    {settings_schema, errors} =
      optional_producer_schedule_map(schedule, :settings_schema, index, errors)

    {credential_requirements, errors} =
      optional_producer_schedule_map(schedule, :credential_requirements, index, errors)

    {payload_template, errors} =
      optional_producer_schedule_map(schedule, :payload_template, index, errors)

    {redaction, errors} = optional_producer_schedule_map(schedule, :redaction, index, errors)

    if errors == [] do
      {:ok,
       %{
         "schedule_id" => schedule_id,
         "label" => label,
         "command_type" => command_type,
         "action_id" => action_id,
         "schedule_type" => schedule_type,
         "default_cadence_seconds" => default_cadence_seconds,
         "min_cadence_seconds" => min_cadence_seconds,
         "max_cadence_seconds" => max_cadence_seconds,
         "allow_cron" => truthy?(fetch(schedule, :allow_cron)),
         "jitter_seconds" => jitter_seconds || 0,
         "timeout_seconds" => timeout_seconds || 300,
         "settings_schema" => settings_schema,
         "credential_requirements" => credential_requirements,
         "payload_template" => payload_template,
         "redaction" => redaction,
         "dispatch_scope" => dispatch_scope
       }
       |> maybe_put_string("description", description)
       |> maybe_put_string("cron_expression", cron_expression)}
    else
      {:error, errors}
    end
  end

  defp validate_producer_schedule(_schedule, index),
    do: {:error, ["producer_schedules[#{index}] must be a map"]}

  defp unknown_producer_schedule_key_errors(schedule, index) do
    schedule
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in @allowed_producer_schedule_keys))
    |> Enum.map(&"producer_schedules[#{index}].#{&1} is not allowed")
  end

  defp required_producer_schedule_string(schedule, key, index, errors) do
    case normalize_string(fetch(schedule, key)) do
      nil ->
        {nil, ["producer_schedules[#{index}].#{key} must be a non-empty string" | errors]}

      "" ->
        {nil, ["producer_schedules[#{index}].#{key} must be a non-empty string" | errors]}

      value ->
        {value, errors}
    end
  end

  defp optional_producer_schedule_string(schedule, key, index, errors) do
    case fetch(schedule, key) do
      nil ->
        {nil, errors}

      value ->
        case normalize_string(value) do
          nil ->
            {nil, ["producer_schedules[#{index}].#{key} must be a non-empty string" | errors]}

          "" ->
            {nil, ["producer_schedules[#{index}].#{key} must be a non-empty string" | errors]}

          normalized ->
            {normalized, errors}
        end
    end
  end

  defp optional_producer_schedule_map(schedule, key, index, errors) do
    case fetch(schedule, key) do
      nil -> {%{}, errors}
      value when is_map(value) -> {normalize_map(value) || %{}, errors}
      _ -> {%{}, ["producer_schedules[#{index}].#{key} must be a map" | errors]}
    end
  end

  defp optional_producer_schedule_positive_int(schedule, key, index, errors) do
    case normalize_int(fetch(schedule, key)) do
      nil -> {nil, errors}
      value when value > 0 -> {value, errors}
      _ -> {nil, ["producer_schedules[#{index}].#{key} must be a positive integer" | errors]}
    end
  end

  defp optional_producer_schedule_nonneg_int(schedule, key, index, errors) do
    case normalize_int(fetch(schedule, key)) do
      nil -> {nil, errors}
      value when value >= 0 -> {value, errors}
      _ -> {nil, ["producer_schedules[#{index}].#{key} must be a non-negative integer" | errors]}
    end
  end

  defp validate_producer_schedule_id(errors, value, field, index) do
    cond do
      String.length(value) > @max_signal_ref_length ->
        ["producer_schedules[#{index}].#{field} exceeds maximum length" | errors]

      Regex.match?(~r/^[a-z0-9][a-z0-9_.-]*$/, value) ->
        errors

      true ->
        [
          "producer_schedules[#{index}].#{field} must use lowercase letters, numbers, dots, underscores, or hyphens"
          | errors
        ]
    end
  end

  defp validate_signal_schema(schema, index) when is_map(schema) do
    schema = normalize_map(schema) || %{}

    errors = unknown_signal_schema_key_errors(schema, index)

    {id, errors} = required_signal_string(schema, :id, index, errors)
    {version, errors} = required_signal_string(schema, :version, index, errors)
    {signal_type, errors} = required_signal_string(schema, :signal_type, index, errors)
    {payload_kind, errors} = required_signal_string(schema, :payload_kind, index, errors)
    {payload_schema, errors} = required_signal_string(schema, :payload_schema, index, errors)
    {display_contract, errors} = required_signal_string(schema, :display_contract, index, errors)

    {display_contract_id, errors} =
      required_signal_string(schema, :display_contract_id, index, errors)

    {display_contract_version, errors} =
      required_signal_string(schema, :display_contract_version, index, errors)

    errors =
      errors
      |> validate_signal_id(id, "id", index)
      |> validate_signal_semver(version, "version", index)
      |> validate_signal_enum(signal_type, "signal_type", @allowed_signal_types, index)
      |> validate_signal_enum(
        payload_kind,
        "payload_kind",
        @allowed_signal_payload_kinds,
        index
      )
      |> validate_signal_path(payload_schema, "payload_schema", index)
      |> validate_signal_path(display_contract, "display_contract", index)
      |> validate_signal_id(display_contract_id, "display_contract_id", index)
      |> validate_signal_semver(display_contract_version, "display_contract_version", index)

    {ocsf_schema_version, errors} =
      optional_signal_string(schema, :ocsf_schema_version, index, errors)

    errors = validate_signal_semver(errors, ocsf_schema_version, "ocsf_schema_version", index)

    {class_uid, errors} = optional_signal_positive_int(schema, :class_uid, index, errors)
    {type_uid, errors} = optional_signal_positive_int(schema, :type_uid, index, errors)

    if errors == [] do
      {:ok,
       %{
         "id" => id,
         "version" => version,
         "signal_type" => signal_type,
         "payload_kind" => payload_kind,
         "payload_schema" => payload_schema,
         "display_contract" => display_contract,
         "display_contract_id" => display_contract_id,
         "display_contract_version" => display_contract_version
       }
       |> maybe_put_string("ocsf_schema_version", ocsf_schema_version)
       |> maybe_put_int("class_uid", class_uid)
       |> maybe_put_int("type_uid", type_uid)}
    else
      {:error, errors}
    end
  end

  defp validate_signal_schema(_schema, index),
    do: {:error, ["signal_schemas[#{index}] must be a map"]}

  defp unknown_signal_schema_key_errors(schema, index) do
    schema
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in @allowed_signal_schema_keys))
    |> Enum.map(&"signal_schemas[#{index}].#{&1} is not allowed")
  end

  defp required_signal_string(schema, key, index, errors) do
    case normalize_string(fetch(schema, key)) do
      nil ->
        {nil, ["signal_schemas[#{index}].#{key} must be a non-empty string" | errors]}

      "" ->
        {nil, ["signal_schemas[#{index}].#{key} must be a non-empty string" | errors]}

      value ->
        {value, errors}
    end
  end

  defp optional_signal_string(schema, key, index, errors) do
    case fetch(schema, key) do
      nil ->
        {nil, errors}

      value ->
        case normalize_string(value) do
          nil ->
            {nil, ["signal_schemas[#{index}].#{key} must be a non-empty string" | errors]}

          "" ->
            {nil, ["signal_schemas[#{index}].#{key} must be a non-empty string" | errors]}

          normalized ->
            {normalized, errors}
        end
    end
  end

  defp optional_signal_positive_int(schema, key, index, errors) do
    case fetch(schema, key) do
      nil ->
        {nil, errors}

      value ->
        case normalize_int(value) do
          int when is_integer(int) and int > 0 ->
            {int, errors}

          _ ->
            {nil, ["signal_schemas[#{index}].#{key} must be a positive integer" | errors]}
        end
    end
  end

  defp validate_signal_id(errors, nil, _field, _index), do: errors

  defp validate_signal_id(errors, value, field, index) do
    cond do
      String.length(value) > @max_signal_ref_length ->
        ["signal_schemas[#{index}].#{field} exceeds maximum length" | errors]

      Regex.match?(~r/^[a-z0-9][a-z0-9_.-]*$/, value) ->
        errors

      true ->
        [
          "signal_schemas[#{index}].#{field} must use lowercase letters, numbers, dots, underscores, or hyphens"
          | errors
        ]
    end
  end

  defp validate_signal_semver(errors, nil, _field, _index), do: errors

  defp validate_signal_semver(errors, value, field, index) do
    case Version.parse(value) do
      {:ok, _version} -> errors
      :error -> ["signal_schemas[#{index}].#{field} must be a valid semver string" | errors]
    end
  end

  defp validate_signal_enum(errors, nil, _field, _allowed, _index), do: errors

  defp validate_signal_enum(errors, value, field, allowed, index) do
    if value in allowed do
      errors
    else
      [
        "signal_schemas[#{index}].#{field} must be one of: #{Enum.join(allowed, ", ")}"
        | errors
      ]
    end
  end

  defp validate_signal_path(errors, nil, _field, _index), do: errors

  defp validate_signal_path(errors, value, field, index) do
    cond do
      String.length(value) > @max_signal_path_length ->
        ["signal_schemas[#{index}].#{field} exceeds maximum length" | errors]

      String.starts_with?(value, "/") ->
        ["signal_schemas[#{index}].#{field} must be a relative bundle path" | errors]

      value |> String.split("/") |> Enum.any?(&(&1 == "..")) ->
        ["signal_schemas[#{index}].#{field} must not traverse directories" | errors]

      not String.ends_with?(value, ".json") ->
        ["signal_schemas[#{index}].#{field} must reference a JSON file" | errors]

      true ->
        errors
    end
  end

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_int(map, _key, nil), do: map
  defp maybe_put_int(map, key, value), do: Map.put(map, key, value)

  defp parse_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, ["invalid yaml: #{inspect(reason)}"]}
    end
  rescue
    error -> {:error, ["invalid yaml: #{Exception.message(error)}"]}
  end

  defp validate_yaml_size(yaml) when byte_size(yaml) > @max_yaml_bytes do
    {:error, ["manifest yaml exceeds maximum size"]}
  end

  defp validate_yaml_size(_yaml), do: :ok

  defp validate_yaml_safety(yaml) do
    if yaml_uses_aliases?(yaml) do
      {:error, ["yaml anchors and aliases are not allowed"]}
    else
      :ok
    end
  end

  defp yaml_uses_aliases?(yaml) do
    Regex.match?(~r/(^|[\s\[{,])[&*][A-Za-z0-9_-]+/m, yaml) or
      Regex.match?(~r/(^|\s)<<\s*:/m, yaml)
  end

  defp required_string(map, key, errors) do
    case fetch(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          {nil, ["#{key} must be a non-empty string" | errors]}
        else
          {trimmed, errors}
        end

      nil ->
        {nil, ["missing required field: #{key}" | errors]}

      _ ->
        {nil, ["#{key} must be a non-empty string" | errors]}
    end
  end

  defp required_string_list(map, key, errors) do
    required_list_field(
      map,
      key,
      errors,
      &normalize_string_list/1,
      fn list -> Enum.all?(list, &is_binary/1) and list != [] end,
      "#{key} must be a non-empty list of strings",
      "#{key} must be a list of strings"
    )
  end

  defp required_map(map, key, errors) do
    case normalize_map(fetch(map, key)) do
      value when is_map(value) ->
        {value, errors}

      nil ->
        {%{}, ["missing required field: #{key}" | errors]}
    end
  end

  defp validate_semver(nil, errors), do: errors

  defp validate_semver(version, errors) when is_binary(version) do
    case Version.parse(version) do
      {:ok, _} -> errors
      :error -> ["version must be a valid semver string" | errors]
    end
  end

  defp optional_positive_int(nil, _key, errors), do: {nil, errors}

  defp optional_positive_int(value, _key, errors) when is_integer(value) and value > 0 do
    {value, errors}
  end

  defp optional_positive_int(value, key, errors) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> {int, errors}
      _ -> {nil, ["#{key} must be a positive integer" | errors]}
    end
  end

  defp optional_positive_int(_value, key, errors),
    do: {nil, ["#{key} must be a positive integer" | errors]}

  defp validate_outputs(outputs, errors) do
    if outputs in @allowed_outputs do
      errors
    else
      ["outputs must be one of: #{Enum.join(@allowed_outputs, ", ")}" | errors]
    end
  end

  defp validate_capabilities(capabilities, errors) do
    invalid =
      capabilities
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @allowed_capabilities))

    if invalid == [] do
      errors
    else
      ["capabilities include unsupported entries: #{Enum.join(invalid, ", ")}" | errors]
    end
  end

  defp validate_resources(resources, errors) do
    resources = normalize_map(resources) || %{}

    {requested_memory_mb, errors} =
      required_positive_int(resources, :requested_memory_mb, errors)

    {requested_cpu_ms, errors} =
      required_positive_int(resources, :requested_cpu_ms, errors)

    {max_open_connections, errors} =
      optional_nonneg_int(resources, :max_open_connections, errors)

    {%{
       requested_memory_mb: requested_memory_mb,
       requested_cpu_ms: requested_cpu_ms,
       max_open_connections: max_open_connections
     }, errors}
  end

  defp validate_permissions(nil, errors), do: {%{}, errors}

  defp validate_permissions(permissions, errors) when is_map(permissions) do
    permissions = normalize_map(permissions) || %{}

    {allowed_domains, errors} =
      optional_string_list(permissions, :allowed_domains, errors)

    {allowed_networks, errors} =
      optional_string_list(permissions, :allowed_networks, errors)

    {allowed_ports, errors} =
      optional_int_list(permissions, :allowed_ports, errors)

    {%{
       allowed_domains: allowed_domains,
       allowed_networks: allowed_networks,
       allowed_ports: allowed_ports
     }, errors}
  end

  defp validate_permissions(_permissions, errors),
    do: {%{}, ["permissions must be a map" | errors]}

  defp validate_actions(nil, errors), do: {[], errors}

  defp validate_actions(actions, errors) when is_list(actions) do
    actions
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {action, index}, {acc, errors} ->
      case validate_action(action, index) do
        {:ok, normalized} -> {[normalized | acc], errors}
        {:error, action_errors} -> {acc, action_errors ++ errors}
      end
    end)
    |> then(fn {actions, errors} -> {Enum.reverse(actions), errors} end)
  end

  defp validate_actions(_actions, errors), do: {[], ["actions must be a list" | errors]}

  defp validate_action(action, index) when is_map(action) do
    action = normalize_map(action) || %{}
    errors = forbidden_ui_contract_errors(action, index)

    {action_id, errors} = required_action_string(action, :action_id, index, errors)
    {label, errors} = required_action_string(action, :label, index, errors)
    {scopes, errors} = required_action_scopes(action, index, errors)
    {version, errors} = optional_action_string(action, :version, index, errors)
    {description, errors} = optional_action_string(action, :description, index, errors)

    {required_context, errors} =
      optional_action_string_list(action, :required_context, index, errors)

    {input_schema, errors} = optional_action_map(action, :input_schema, index, errors)

    {timeout_seconds, errors} =
      optional_action_positive_int(action, :timeout_seconds, index, errors)

    {safety_classification, errors} = optional_action_safety(action, index, errors)

    {credential_requirements, errors} =
      optional_action_map(action, :credential_requirements, index, errors)

    if errors == [] do
      {:ok,
       %{
         action_id: action_id,
         version: version || "1.0.0",
         label: label,
         description: description,
         scopes: scopes,
         required_context: required_context,
         input_schema: input_schema,
         timeout_seconds: timeout_seconds || 60,
         safety_classification: safety_classification || "standard",
         requires_confirmation: truthy?(fetch(action, :requires_confirmation)),
         credential_requirements: credential_requirements,
         result_schema_version:
           normalize_string(fetch(action, :result_schema_version)) ||
             "serviceradar.northbound_action_result.v1"
       }}
    else
      {:error, errors}
    end
  end

  defp validate_action(_action, index), do: {:error, ["actions[#{index}] must be a map"]}

  defp forbidden_ui_contract_errors(action, index) do
    forbidden = ~w(html raw_html javascript js component component_ref live_view react ui_code)

    action
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in forbidden))
    |> Enum.map(
      &"actions[#{index}].#{&1} is not allowed; actions may not ship provider-owned UI code"
    )
  end

  defp required_action_string(action, key, index, errors) do
    case normalize_string(fetch(action, key)) do
      nil -> {nil, ["actions[#{index}].#{key} must be a non-empty string" | errors]}
      value -> {value, errors}
    end
  end

  defp optional_action_string(action, key, _index, errors) do
    {normalize_string(fetch(action, key)), errors}
  end

  defp required_action_scopes(action, index, errors) do
    {scopes, errors} = optional_action_string_list(action, :scopes, index, errors)
    invalid = Enum.reject(scopes, &(&1 in ["device", "interface", "event"]))

    cond do
      scopes == [] ->
        {[], ["actions[#{index}].scopes must include at least one scope" | errors]}

      invalid != [] ->
        {scopes,
         [
           "actions[#{index}].scopes contains unsupported scopes: #{Enum.join(invalid, ", ")}"
           | errors
         ]}

      true ->
        {scopes, errors}
    end
  end

  defp optional_action_string_list(action, key, index, errors) do
    case fetch(action, key) do
      nil ->
        {[], errors}

      list when is_list(list) ->
        values = normalize_string_list(list)

        if length(values) == length(list) do
          {values, errors}
        else
          {values, ["actions[#{index}].#{key} must be a list of strings" | errors]}
        end

      _ ->
        {[], ["actions[#{index}].#{key} must be a list of strings" | errors]}
    end
  end

  defp optional_action_map(action, key, index, errors) do
    case fetch(action, key) do
      nil -> {%{}, errors}
      value when is_map(value) -> {normalize_map(value) || %{}, errors}
      _ -> {%{}, ["actions[#{index}].#{key} must be a map" | errors]}
    end
  end

  defp optional_action_positive_int(action, key, index, errors) do
    case normalize_int(fetch(action, key)) do
      nil -> {nil, errors}
      value when value > 0 -> {value, errors}
      _ -> {nil, ["actions[#{index}].#{key} must be a positive integer" | errors]}
    end
  end

  defp optional_action_safety(action, index, errors) do
    value = normalize_string(fetch(action, :safety_classification))

    if is_nil(value) or value in ["read_only", "standard", "destructive"] do
      {value, errors}
    else
      {nil,
       [
         "actions[#{index}].safety_classification must be read_only, standard, or destructive"
         | errors
       ]}
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp validate_runtime(nil, errors), do: errors

  defp validate_runtime(runtime, errors) when is_binary(runtime) do
    if runtime in @allowed_runtimes do
      errors
    else
      ["runtime must be one of: #{Enum.join(@allowed_runtimes, ", ")}" | errors]
    end
  end

  defp validate_runtime(_runtime, errors), do: ["runtime must be a string" | errors]

  defp required_positive_int(map, key, errors) do
    int_field(
      map,
      key,
      errors,
      required?: true,
      valid?: &(&1 > 0),
      missing_message: "missing required field: resources.#{key}",
      invalid_message: "resources.#{key} must be a positive integer"
    )
  end

  defp optional_nonneg_int(map, key, errors) do
    int_field(
      map,
      key,
      errors,
      required?: false,
      valid?: &(&1 >= 0),
      invalid_message: "resources.#{key} must be a non-negative integer"
    )
  end

  defp optional_string_list(map, key, errors) do
    optional_list_field(
      map,
      key,
      errors,
      &normalize_string_list/1,
      fn list -> Enum.all?(list, &is_binary/1) end,
      "#{key} must be a list of strings"
    )
  end

  defp optional_int_list(map, key, errors) do
    optional_list_field(
      map,
      key,
      errors,
      &normalize_int_list/1,
      fn list -> Enum.all?(list, fn item -> is_integer(normalize_int(item)) end) end,
      "#{key} must be a list of integers"
    )
  end

  defp fetch(map, key) when is_map(map) do
    ValueUtils.raw_value(map, [key, to_string(key)])
  end

  defp normalize_map(nil), do: nil
  defp normalize_map(map) when is_map(map), do: map

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_), do: nil

  defp normalize_string_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_int_list(list) do
    list
    |> Enum.map(&normalize_int/1)
    |> Enum.filter(&is_integer/1)
  end

  defp normalize_int(value) when is_integer(value), do: value

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_int(_), do: nil

  defp required_list_field(
         map,
         key,
         errors,
         normalize_fun,
         valid_fun,
         invalid_message,
         type_message
       ) do
    case fetch(map, key) do
      nil ->
        {[], ["missing required field: #{key}" | errors]}

      value when is_list(value) ->
        normalized = normalize_fun.(value)

        if valid_fun.(value) do
          {normalized, errors}
        else
          {normalized, [invalid_message | errors]}
        end

      _ ->
        {[], [type_message | errors]}
    end
  end

  defp optional_list_field(map, key, errors, normalize_fun, valid_fun, invalid_message) do
    case fetch(map, key) do
      nil ->
        {[], errors}

      value when is_list(value) ->
        normalized = normalize_fun.(value)

        if valid_fun.(value) do
          {normalized, errors}
        else
          {normalized, [invalid_message | errors]}
        end

      _ ->
        {[], [invalid_message | errors]}
    end
  end

  defp int_field(map, key, errors, opts) do
    raw = fetch(map, key)
    value = normalize_int(raw)
    required? = Keyword.get(opts, :required?, false)
    valid_fun = Keyword.fetch!(opts, :valid?)
    invalid_message = Keyword.fetch!(opts, :invalid_message)
    missing_message = Keyword.get(opts, :missing_message)

    cond do
      is_nil(raw) and required? ->
        {nil, [missing_message | errors]}

      is_nil(raw) ->
        {nil, errors}

      is_integer(value) and valid_fun.(value) ->
        {value, errors}

      true ->
        {nil, [invalid_message | errors]}
    end
  end
end
