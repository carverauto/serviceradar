defmodule ServiceRadarWebNG.Observability.SignalDisplay do
  @moduledoc """
  Resolves and renders package-owned signal display contracts into safe view data.
  """

  @contract_roots [
    File.cwd!(),
    Path.expand("../..", File.cwd!()),
    Path.expand("../../../../../", __DIR__)
  ]
  @resolve_contract_path fn relative_path, roots ->
    Enum.find_value(roots, fn root ->
      path = Path.expand(relative_path, root)

      if File.exists?(path), do: path
    end) ||
      raise File.Error, reason: :enoent, action: "read file", path: relative_path
  end

  @powerdns_contract_path @resolve_contract_path.(
                            "addons/powerdns/display/dns_activity.display.json",
                            @contract_roots
                          )
  @axis_contract_path @resolve_contract_path.(
                        "go/cmd/wasm-plugins/axis/display/event_log_activity.display.json",
                        @contract_roots
                      )
  @protect_contract_path @resolve_contract_path.(
                           "go/cmd/wasm-plugins/unifi-protect/display/camera_event.display.json",
                           @contract_roots
                         )
  @proxmox_contract_path @resolve_contract_path.(
                           "go/cmd/wasm-plugins/proxmox/display/resource_event.display.json",
                           @contract_roots
                         )
  @external_resource @powerdns_contract_path
  @external_resource @axis_contract_path
  @external_resource @protect_contract_path
  @external_resource @proxmox_contract_path
  @built_in_contracts %{
    {"powerdns", "0.1.0", "com.carverauto.powerdns.dns_activity", "1.0.0"} =>
      @powerdns_contract_path |> File.read!() |> Jason.decode!(),
    {"axis-camera", "0.1.0", "com.carverauto.axis_camera.event_log", "1.0.0"} =>
      @axis_contract_path |> File.read!() |> Jason.decode!(),
    {"unifi-protect-camera", "0.1.0", "com.carverauto.unifi_protect.camera_event", "1.0.0"} =>
      @protect_contract_path |> File.read!() |> Jason.decode!(),
    {"proxmox-inventory", "0.1.1", "com.carverauto.proxmox.resource_event", "1.0.0"} =>
      @proxmox_contract_path |> File.read!() |> Jason.decode!()
  }

  @max_widgets 24
  @max_fields 64
  @max_value_length 240

  @doc "Resolve the display contract referenced by a stored event/log row."
  @spec resolve_contract(map(), keyword()) :: {:ok, map()} | :error
  def resolve_contract(record, opts \\ [])

  def resolve_contract(record, opts) when is_map(record) do
    configured = Keyword.get(opts, :contracts) || configured_contracts()

    with %{} = signal_schema <- signal_schema_ref(record),
         key = contract_key(signal_schema),
         %{} = contract <- Map.get(configured, key) || built_in_contract(key) do
      {:ok, contract}
    else
      _ -> :error
    end
  end

  def resolve_contract(_record, _opts), do: :error

  @doc "Render a record through a display contract into bounded widget view data."
  @spec render(map(), map()) :: {:ok, [map()]} | :error
  def render(record, contract) when is_map(record) and is_map(contract) do
    widgets =
      contract
      |> Map.get("widgets", [])
      |> List.wrap()
      |> Enum.take(@max_widgets)
      |> Enum.flat_map(&render_widget(record, &1))

    if widgets == [], do: :error, else: {:ok, widgets}
  end

  def render(_record, _contract), do: :error

  @doc "Resolve and render a record in one call."
  @spec render_record(map(), keyword()) :: {:ok, [map()]} | :error
  def render_record(record, opts \\ []) do
    with {:ok, contract} <- resolve_contract(record, opts) do
      render(record, contract)
    end
  end

  defp configured_contracts do
    :serviceradar_web_ng
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:contracts, %{})
  end

  defp built_in_contract(key), do: Map.get(@built_in_contracts, key)

  defp contract_key(signal_schema) do
    {
      Map.get(signal_schema, "producer_id"),
      Map.get(signal_schema, "producer_version"),
      Map.get(signal_schema, "schema_id"),
      Map.get(signal_schema, "schema_version")
    }
  end

  defp signal_schema_ref(record) do
    get_in(record, ["metadata", "service_radar", "signal_schema"]) ||
      get_in(record, ["metadata", :service_radar, :signal_schema]) ||
      signal_schema_ref_from_attributes(Map.get(record, "attributes")) ||
      signal_schema_ref_from_attributes(Map.get(record, "resource_attributes"))
  end

  defp signal_schema_ref_from_attributes(%{} = attributes) do
    get_in(attributes, ["service_radar", "signal_schema"]) ||
      get_in(attributes, [:service_radar, :signal_schema]) ||
      flattened_signal_schema_ref(attributes, "service_radar.signal_schema.") ||
      flattened_signal_schema_ref(attributes, "serviceradar.signal_schema.")
  end

  defp signal_schema_ref_from_attributes(_attributes), do: nil

  defp flattened_signal_schema_ref(attributes, prefix) do
    schema_ref =
      Enum.reduce(attributes, %{}, fn
        {key, value}, acc when is_binary(key) ->
          if String.starts_with?(key, prefix) do
            Map.put(acc, String.replace_prefix(key, prefix, ""), value)
          else
            acc
          end

        _entry, acc ->
          acc
      end)

    if map_size(schema_ref) == 0, do: nil, else: schema_ref
  end

  defp render_widget(record, %{"type" => "summary"} = widget) do
    [
      %{
        type: :summary,
        title: display_value(path_value(record, Map.get(widget, "title"))),
        message: display_value(path_value(record, Map.get(widget, "message"))),
        source: display_value(path_value(record, Map.get(widget, "source"))),
        severity: display_value(path_value(record, Map.get(widget, "severity")))
      }
    ]
  end

  defp render_widget(record, %{"type" => "facts"} = widget) do
    fields =
      widget
      |> Map.get("fields", [])
      |> render_fields(record)

    if fields == [], do: [], else: [%{type: :facts, fields: fields}]
  end

  defp render_widget(record, %{"type" => "badges"} = widget) do
    fields =
      widget
      |> Map.get("fields", [])
      |> render_fields(record)

    if fields == [], do: [], else: [%{type: :badges, fields: fields}]
  end

  defp render_widget(record, %{"type" => "timeline"} = widget) do
    fields =
      widget
      |> Map.get("fields", [])
      |> render_fields(record)

    if fields == [], do: [], else: [%{type: :timeline, fields: fields}]
  end

  defp render_widget(record, %{"type" => "json_section"} = widget) do
    sections =
      widget
      |> Map.get("paths", [])
      |> List.wrap()
      |> Enum.take(@max_fields)
      |> Enum.flat_map(fn path ->
        case path_value(record, path) do
          value when is_map(value) or is_list(value) ->
            [%{path: path, value: value, json: Jason.encode!(value, pretty: true)}]

          _ ->
            []
        end
      end)

    if sections == [] do
      []
    else
      [%{type: :json_section, title: clean_label(Map.get(widget, "title")), sections: sections}]
    end
  end

  defp render_widget(_record, _widget), do: []

  defp render_fields(fields, record) do
    fields
    |> List.wrap()
    |> Enum.take(@max_fields)
    |> Enum.flat_map(fn
      %{"label" => label, "path" => path} = field ->
        case path_value(record, path) do
          nil ->
            []

          "" ->
            []

          value ->
            [
              %{
                label: clean_label(label),
                path: path,
                value: display_value(value),
                tone: clean_label(Map.get(field, "tone"))
              }
            ]
        end

      _ ->
        []
    end)
  end

  defp path_value(_record, path) when not is_binary(path), do: nil

  defp path_value(record, path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce_while(record, fn key, current ->
      case current do
        map when is_map(map) ->
          value = Map.get(map, key)
          if is_nil(value), do: {:halt, nil}, else: {:cont, value}

        list when is_list(list) ->
          case Integer.parse(key) do
            {index, ""} -> {:cont, Enum.at(list, index)}
            _ -> {:halt, nil}
          end

        _ ->
          {:halt, nil}
      end
    end)
  end

  defp display_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> truncate_value()
  end

  defp display_value(value) when is_integer(value) or is_float(value) or is_boolean(value), do: to_string(value)

  defp display_value(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp display_value(nil), do: nil
  defp display_value(value), do: value |> to_string() |> truncate_value()

  defp truncate_value(value) do
    if String.length(value) > @max_value_length do
      String.slice(value, 0, @max_value_length) <> "..."
    else
      value
    end
  end

  defp clean_label(nil), do: nil
  defp clean_label(value) when is_binary(value), do: truncate_value(String.trim(value))
  defp clean_label(value), do: value |> to_string() |> truncate_value()
end
