defmodule ServiceRadar.Plugins.Manifest do
  @moduledoc """
  Validates and normalizes the plugin manifest stored in plugin.yaml.

  The manifest is the source of truth for plugin capabilities, permissions,
  and resource requests. Validation is intentionally strict to prevent
  unsafe defaults from being imported.
  """

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
    :source,
    :schema_version,
    :display_contract
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
          source: map(),
          schema_version: pos_integer() | nil,
          display_contract: map()
        }

  @allowed_runtimes ["none", "wasi-preview1"]
  @allowed_outputs ["serviceradar.plugin_result.v1"]
  @allowed_capabilities [
    "get_config",
    "log",
    "submit_result",
    "http_request",
    "tcp_connect",
    "tcp_read",
    "tcp_write",
    "tcp_close",
    "udp_sendto"
  ]

  @doc """
  Parse and validate a plugin manifest from YAML.
  """
  @spec from_yaml(String.t()) :: {:ok, t()} | {:error, [String.t()]}
  def from_yaml(yaml) when is_binary(yaml) do
    with {:ok, map} <- parse_yaml(yaml) do
      from_map(map)
    end
  end

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

    runtime = fetch(map, :runtime)
    errors = validate_runtime(runtime, errors)

    description = fetch(map, :description)
    schema_version = fetch(map, :schema_version)
    {schema_version, errors} = optional_positive_int(schema_version, :schema_version, errors)
    source = normalize_map(fetch(map, :source)) || %{}
    display_contract = normalize_map(fetch(map, :display_contract)) || %{}
    errors = display_contract_errors(display_contract) ++ errors

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
         permissions: permissions || %{},
         resources: resources,
         outputs: outputs,
         source: source,
         schema_version: schema_version,
         display_contract: display_contract
       }}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  def from_map(_), do: {:error, ["manifest must be a map"]}

  alias ServiceRadar.Plugins.ConfigSchema

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

  defp display_contract_errors(display_contract) do
    case validate_display_contract(display_contract) do
      :ok -> []
      {:error, errs} -> errs
    end
  end

  defp parse_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, ["invalid yaml: #{inspect(reason)}"]}
      value -> {:ok, value}
    end
  rescue
    error -> {:error, ["invalid yaml: #{Exception.message(error)}"]}
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
    case fetch(map, key) do
      value when is_list(value) ->
        {normalize_string_list(value), validate_string_list(key, value, errors)}

      nil ->
        {[], ["missing required field: #{key}" | errors]}

      _ ->
        {[], ["#{key} must be a list of strings" | errors]}
    end
  end

  defp validate_string_list(key, list, errors) do
    if Enum.all?(list, &is_binary/1) and list != [] do
      errors
    else
      ["#{key} must be a non-empty list of strings" | errors]
    end
  end

  defp required_map(map, key, errors) do
    case normalize_map(fetch(map, key)) do
      value when is_map(value) ->
        {value, errors}

      nil ->
        {%{}, ["missing required field: #{key}" | errors]}

      _ ->
        {%{}, ["#{key} must be a map" | errors]}
    end
  end

  defp validate_semver(nil, errors), do: errors

  defp validate_semver(version, errors) when is_binary(version) do
    case Version.parse(version) do
      {:ok, _} -> errors
      :error -> ["version must be a valid semver string" | errors]
    end
  end

  defp validate_semver(_version, errors), do: errors

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

  defp validate_runtime(nil, errors), do: errors

  defp validate_runtime(runtime, errors) when is_binary(runtime) do
    if runtime in @allowed_runtimes do
      errors
    else
      ["runtime must be one of: #{Enum.join(@allowed_runtimes, ", ")}" | errors]
    end
  end

  defp validate_runtime(_runtime, errors),
    do: ["runtime must be a string" | errors]

  defp required_positive_int(map, key, errors) do
    case normalize_int(fetch(map, key)) do
      value when is_integer(value) and value > 0 ->
        {value, errors}

      nil ->
        {nil, ["missing required field: resources.#{key}" | errors]}

      _ ->
        {nil, ["resources.#{key} must be a positive integer" | errors]}
    end
  end

  defp optional_nonneg_int(map, key, errors) do
    case normalize_int(fetch(map, key)) do
      nil -> {nil, errors}
      value when is_integer(value) and value >= 0 -> {value, errors}
      _ -> {nil, ["resources.#{key} must be a non-negative integer" | errors]}
    end
  end

  defp optional_string_list(map, key, errors) do
    case fetch(map, key) do
      nil ->
        {[], errors}

      value when is_list(value) ->
        {normalize_string_list(value), validate_optional_string_list(key, value, errors)}

      _ ->
        {[], ["#{key} must be a list of strings" | errors]}
    end
  end

  defp optional_int_list(map, key, errors) do
    case fetch(map, key) do
      nil ->
        {[], errors}

      value when is_list(value) ->
        {normalize_int_list(value), validate_int_list(key, value, errors)}

      _ ->
        {[], ["#{key} must be a list of integers" | errors]}
    end
  end

  defp validate_int_list(key, list, errors) do
    if Enum.all?(list, fn item -> is_integer(normalize_int(item)) end) do
      errors
    else
      ["#{key} must be a list of integers" | errors]
    end
  end

  defp validate_optional_string_list(key, list, errors) do
    if Enum.all?(list, &is_binary/1) do
      errors
    else
      ["#{key} must be a list of strings" | errors]
    end
  end

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
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
end
