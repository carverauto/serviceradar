defmodule ServiceRadar.Plugins.Manifest do
  @moduledoc """
  Validates and normalizes the plugin manifest stored in plugin.yaml.

  The manifest is the source of truth for plugin capabilities, permissions,
  and resource requests. Validation is intentionally strict to prevent
  unsafe defaults from being imported.
  """

  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.IntegrationDescriptor
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
    "action-only:v1"
  ]
  @allowed_producer_dispatch_scopes ["assignment", "package", "target_query"]
  @allowed_producer_command_types ["plugin.run_action", "addon.run_command"]
  @allowed_producer_schedule_types ["interval", "cron", "manual"]
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
  @max_yaml_bytes 262_144
  @max_signal_ref_length 160
  @max_signal_path_length 240

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

  defp display_contract_errors(display_contract) do
    case validate_display_contract(display_contract) do
      :ok -> []
      {:error, errs} -> errs
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
