defmodule ServiceRadar.Dashboards.Manifest do
  @moduledoc """
  Validates and normalizes browser dashboard package manifests.

  Dashboard packages are browser-side renderer packages, not agent-executed
  plugins. The manifest is JSON so it can be validated consistently in the
  control plane and browser package host.
  """

  alias ServiceRadar.Plugins.ConfigSchema

  @enforce_keys [
    :id,
    :name,
    :version,
    :renderer,
    :data_frames,
    :capabilities,
    :settings_schema
  ]
  defstruct [
    :id,
    :name,
    :version,
    :description,
    :vendor,
    :renderer,
    :data_frames,
    :capabilities,
    :settings_schema,
    :source,
    :schema_version
  ]

  @type renderer :: %{
          required(:kind) => String.t(),
          required(:interface_version) => String.t(),
          required(:artifact) => String.t(),
          required(:sha256) => String.t(),
          optional(:entrypoint) => String.t(),
          optional(:exports) => [String.t()]
        }

  @type data_frame :: %{
          required(:id) => String.t(),
          required(:query) => String.t(),
          required(:encoding) => String.t(),
          optional(:required) => boolean(),
          optional(:limit) => pos_integer(),
          optional(:fields) => [String.t()],
          optional(:coordinates) => map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          version: String.t(),
          description: String.t() | nil,
          vendor: String.t() | nil,
          renderer: renderer(),
          data_frames: [data_frame()],
          capabilities: [String.t()],
          settings_schema: map(),
          source: map(),
          schema_version: pos_integer()
        }

  @allowed_capabilities ~w(
    srql.execute
    saved_queries.read
    dashboard.preferences.read
    dashboard.preferences.write
    navigation.open
    popup.open
    details.open
    map.basemap.read
    map.deck.render
  )
  @allowed_encodings ~w(json_rows arrow_ipc)
  @allowed_renderer_kinds ~w(browser_wasm browser_module)
  @allowed_interface_versions ~w(dashboard-wasm-v1 dashboard-browser-module-v1)
  @id_pattern_source "^[a-z0-9][a-z0-9._-]{1,127}$"
  @id_pattern Regex.compile!(@id_pattern_source)
  @max_json_bytes 262_144

  @doc """
  Parse and validate a dashboard package manifest from JSON.
  """
  @spec from_json(binary()) :: {:ok, t()} | {:error, [String.t()]}
  def from_json(json) when is_binary(json) do
    with :ok <- validate_json_size(json),
         {:ok, value} <- Jason.decode(json),
         true <- is_map(value) do
      from_map(value)
    else
      false ->
        {:error, ["manifest json must decode to an object"]}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, ["invalid json: #{Exception.message(error)}"]}

      {:error, errors} when is_list(errors) ->
        {:error, errors}
    end
  end

  def from_json(_json), do: {:error, ["manifest json must be a string"]}

  @doc """
  Validate a dashboard package manifest map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, [String.t()]}
  def from_map(map) when is_map(map) do
    map = stringify_keys(map)
    errors = validate_root_keys(map, [])

    {schema_version, errors} =
      optional_positive_int(Map.get(map, "schema_version"), "schema_version", errors)

    {id, errors} = required_string(map, "id", errors)
    {name, errors} = required_string(map, "name", errors)
    {version, errors} = required_string(map, "version", errors)
    errors = validate_id(id, errors)
    errors = validate_semver(version, errors)

    {renderer, errors} = validate_renderer(Map.get(map, "renderer"), errors)
    {data_frames, errors} = validate_data_frames(Map.get(map, "data_frames"), errors)
    {capabilities, errors} = validate_capabilities(Map.get(map, "capabilities"), errors)
    {settings_schema, errors} = validate_settings_schema(Map.get(map, "settings_schema"), errors)

    description = normalize_string(Map.get(map, "description"))
    vendor = normalize_string(Map.get(map, "vendor"))
    source = normalize_map(Map.get(map, "source")) || %{}

    if errors == [] do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         version: version,
         description: description,
         vendor: vendor,
         renderer: renderer,
         data_frames: data_frames,
         capabilities: capabilities,
         settings_schema: settings_schema,
         source: source,
         schema_version: schema_version || 1
       }}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  def from_map(_), do: {:error, ["manifest must be an object"]}

  defp validate_json_size(json) when byte_size(json) > @max_json_bytes do
    {:error, ["manifest json exceeds maximum size"]}
  end

  defp validate_json_size(_json), do: :ok

  defp validate_root_keys(map, errors) do
    allowed = ~w(
      schema_version id name version description vendor renderer data_frames
      capabilities settings_schema source
    )

    validate_keys(map, allowed, "manifest", errors)
  end

  defp validate_renderer(nil, errors), do: {nil, ["missing required field: renderer" | errors]}

  defp validate_renderer(value, errors) when is_map(value) do
    renderer = stringify_keys(value)

    errors =
      renderer
      |> validate_keys(
        ~w(kind interface_version artifact sha256 entrypoint exports trust),
        "renderer",
        errors
      )
      |> validate_allowed_string(renderer, "kind", @allowed_renderer_kinds, "renderer.kind")
      |> validate_allowed_string(
        renderer,
        "interface_version",
        @allowed_interface_versions,
        "renderer.interface_version"
      )

    {artifact, errors} = required_string(renderer, "artifact", errors, "renderer.artifact")
    {sha256, errors} = required_string(renderer, "sha256", errors, "renderer.sha256")
    errors = validate_sha256(sha256, errors)
    errors = validate_renderer_interface_pair(renderer, errors)
    {trust, errors} = validate_renderer_trust(renderer, errors)
    {entrypoint, errors} = optional_string(renderer, "entrypoint", errors, "renderer.entrypoint")
    {exports, errors} = optional_string_list(renderer, "exports", errors, "renderer.exports")

    normalized = %{
      "kind" => Map.get(renderer, "kind"),
      "interface_version" => Map.get(renderer, "interface_version"),
      "artifact" => artifact,
      "sha256" => sha256
    }

    normalized =
      normalized
      |> maybe_put("entrypoint", entrypoint)
      |> maybe_put("exports", exports)
      |> maybe_put("trust", trust)

    {normalized, errors}
  end

  defp validate_renderer(_value, errors), do: {nil, ["renderer must be an object" | errors]}

  defp validate_renderer_interface_pair(
         %{"kind" => "browser_wasm", "interface_version" => "dashboard-wasm-v1"},
         errors
       ),
       do: errors

  defp validate_renderer_interface_pair(
         %{"kind" => "browser_module", "interface_version" => "dashboard-browser-module-v1"},
         errors
       ),
       do: errors

  defp validate_renderer_interface_pair(%{"kind" => kind, "interface_version" => interface}, errors)
       when is_binary(kind) and is_binary(interface) do
    ["renderer.interface_version #{interface} is not valid for renderer.kind #{kind}" | errors]
  end

  defp validate_renderer_interface_pair(_renderer, errors), do: errors

  defp validate_renderer_trust(%{"kind" => "browser_module"} = renderer, errors) do
    case Map.get(renderer, "trust") do
      "trusted" -> {"trusted", errors}
      nil -> {nil, ["renderer.trust must be trusted for browser_module renderers" | errors]}
      value -> {nil, ["renderer.trust must be trusted for browser_module renderers (got #{value})" | errors]}
    end
  end

  defp validate_renderer_trust(%{"trust" => trust}, errors) when not is_nil(trust) do
    {nil, ["renderer.trust is only supported for browser_module renderers" | errors]}
  end

  defp validate_renderer_trust(_renderer, errors), do: {nil, errors}

  defp validate_data_frames(nil, errors),
    do: {[], ["missing required field: data_frames" | errors]}

  defp validate_data_frames(value, errors) when is_list(value) and value != [] do
    {frames, errors} =
      value
      |> Enum.with_index()
      |> Enum.reduce({[], errors}, fn {frame, index}, {frames, acc} ->
        case validate_data_frame(frame, index, acc) do
          {nil, acc} -> {frames, acc}
          {frame, acc} -> {[frame | frames], acc}
        end
      end)

    frames = Enum.reverse(frames)
    errors = validate_unique_frame_ids(frames, errors)
    {frames, errors}
  end

  defp validate_data_frames(_value, errors) do
    {[], ["data_frames must be a non-empty list" | errors]}
  end

  defp validate_data_frame(value, index, errors) when is_map(value) do
    frame = stringify_keys(value)
    path = "data_frames[#{index}]"

    errors =
      frame
      |> validate_keys(~w(id query encoding required limit fields coordinates), path, errors)
      |> validate_allowed_string(frame, "encoding", @allowed_encodings, "#{path}.encoding")

    {id, errors} = required_string(frame, "id", errors, "#{path}.id")
    {query, errors} = required_string(frame, "query", errors, "#{path}.query")
    {limit, errors} = optional_positive_int(Map.get(frame, "limit"), "#{path}.limit", errors)
    {fields, errors} = optional_string_list(frame, "fields", errors, "#{path}.fields")
    {coordinates, errors} = validate_coordinates(Map.get(frame, "coordinates"), path, errors)

    required =
      case Map.get(frame, "required") do
        nil -> true
        value when is_boolean(value) -> value
        _ -> true
      end

    errors =
      if Map.has_key?(frame, "required") and not is_boolean(Map.get(frame, "required")) do
        ["#{path}.required must be a boolean" | errors]
      else
        errors
      end

    normalized =
      %{
        "id" => id,
        "query" => query,
        "encoding" => Map.get(frame, "encoding"),
        "required" => required
      }
      |> maybe_put("limit", limit)
      |> maybe_put("fields", fields)
      |> maybe_put("coordinates", coordinates)

    {normalized, errors}
  end

  defp validate_data_frame(_value, index, errors) do
    {nil, ["data_frames[#{index}] must be an object" | errors]}
  end

  defp validate_coordinates(nil, _path, errors), do: {nil, errors}

  defp validate_coordinates(value, path, errors) when is_map(value) do
    coordinates = stringify_keys(value)

    errors =
      validate_keys(coordinates, ~w(latitude longitude geometry), "#{path}.coordinates", errors)

    coordinate_fields =
      coordinates
      |> Map.take(["latitude", "longitude", "geometry"])
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        value = normalize_string(value)
        if value, do: Map.put(acc, key, value), else: acc
      end)

    errors =
      if map_size(coordinate_fields) == 0 do
        ["#{path}.coordinates must include latitude/longitude or geometry field names" | errors]
      else
        errors
      end

    {coordinate_fields, errors}
  end

  defp validate_coordinates(_value, path, errors) do
    {nil, ["#{path}.coordinates must be an object" | errors]}
  end

  defp validate_capabilities(nil, errors),
    do: {[], ["missing required field: capabilities" | errors]}

  defp validate_capabilities(value, errors) when is_list(value) and value != [] do
    capabilities =
      value
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    errors =
      cond do
        capabilities == [] ->
          ["capabilities must be a non-empty list of strings" | errors]

        length(capabilities) != length(value) ->
          ["capabilities must contain only non-empty strings" | errors]

        true ->
          unsupported = Enum.reject(capabilities, &(&1 in @allowed_capabilities))

          case unsupported do
            [] ->
              errors

            _ ->
              [
                "capabilities contain unsupported values: #{Enum.join(unsupported, ", ")}"
                | errors
              ]
          end
      end

    {capabilities, errors}
  end

  defp validate_capabilities(_value, errors) do
    {[], ["capabilities must be a non-empty list of strings" | errors]}
  end

  defp validate_settings_schema(nil, errors), do: {%{}, errors}

  defp validate_settings_schema(value, errors) when is_map(value) do
    schema = stringify_keys(value)

    case ConfigSchema.validate_schema(schema) do
      :ok -> {schema, errors}
      {:error, schema_errors} -> {schema, Enum.reduce(schema_errors, errors, &[&1 | &2])}
    end
  end

  defp validate_settings_schema(_value, errors) do
    {%{}, ["settings_schema must be an object" | errors]}
  end

  defp validate_unique_frame_ids(frames, errors) do
    ids = Enum.map(frames, &Map.get(&1, "id"))

    case ids -- Enum.uniq(ids) do
      [] ->
        errors

      duplicates ->
        ["data_frames contain duplicate ids: #{Enum.join(Enum.uniq(duplicates), ", ")}" | errors]
    end
  end

  defp validate_allowed_string(errors, map, key, allowed, path) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if value in allowed do
          errors
        else
          ["#{path} must be one of: #{Enum.join(allowed, ", ")} (got #{value})" | errors]
        end

      nil ->
        ["#{path} is required" | errors]

      _ ->
        ["#{path} must be a string" | errors]
    end
  end

  defp validate_sha256(nil, errors), do: errors

  defp validate_sha256(value, errors) do
    if Regex.match?(~r/^[a-fA-F0-9]{64}$/, value) do
      errors
    else
      ["renderer.sha256 must be a 64-character hex digest" | errors]
    end
  end

  defp validate_id(nil, errors), do: errors

  defp validate_id(value, errors) do
    if Regex.match?(@id_pattern, value) do
      errors
    else
      ["id must match #{@id_pattern_source}" | errors]
    end
  end

  defp validate_semver(nil, errors), do: errors

  defp validate_semver(version, errors) do
    case Version.parse(version) do
      {:ok, _} -> errors
      :error -> ["version must be a valid semver string" | errors]
    end
  end

  defp validate_keys(map, allowed, path, errors) do
    unknown =
      map
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in allowed))

    case unknown do
      [] -> errors
      _ -> ["#{path} contains unsupported keys: #{Enum.join(unknown, ", ")}" | errors]
    end
  end

  defp required_string(map, key, errors, path \\ nil) do
    path = path || key

    case Map.get(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          {nil, ["#{path} must be a non-empty string" | errors]}
        else
          {value, errors}
        end

      nil ->
        {nil, ["missing required field: #{path}" | errors]}

      _ ->
        {nil, ["#{path} must be a non-empty string" | errors]}
    end
  end

  defp optional_string(map, key, errors, path) do
    case Map.get(map, key) do
      nil ->
        {nil, errors}

      value when is_binary(value) ->
        value = String.trim(value)
        {if(value == "", do: nil, else: value), errors}

      _ ->
        {nil, ["#{path} must be a string" | errors]}
    end
  end

  defp optional_string_list(map, key, errors, path) do
    case Map.get(map, key) do
      nil ->
        {nil, errors}

      value when is_list(value) ->
        normalized = Enum.map(value, &normalize_string/1)

        if Enum.all?(normalized, &is_binary/1) do
          {normalized, errors}
        else
          {nil, ["#{path} must be a list of non-empty strings" | errors]}
        end

      _ ->
        {nil, ["#{path} must be a list of strings" | errors]}
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

  defp optional_positive_int(_value, key, errors) do
    {nil, ["#{key} must be a positive integer" | errors]}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_map(value) when is_map(value), do: stringify_keys(value)
  defp normalize_map(_), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_), do: nil
end
