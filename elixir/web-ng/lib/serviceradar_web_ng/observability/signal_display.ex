defmodule ServiceRadarWebNG.Observability.SignalDisplay do
  @moduledoc """
  Resolves and renders package-owned signal display contracts into safe view data.

  ## Where a contract comes from

  Resolution is ordered, and the first hit wins:

    1. an explicit `:contracts` map passed by the caller (tests, and the
       `:serviceradar_web_ng` application override);
    2. `ServiceRadarWebNG.Observability.ContractRegistry` - the RUNTIME index of
       what installed, approved packages actually ship;
    3. `@built_in_contracts` - the compile-time first-party map.

  Step 2 is the point of tasks 3.5.1. Before it, step 3 was the only source, so a
  third-party package could not ship a renderable contract without recompiling
  web-ng even though packages already persist `signal_schemas`. Step 3 is
  deliberately KEPT rather than migrated: the six first-party contracts it holds
  are not shipped inside their add-on bundles (`addons/powerdns` ships
  `addon.yaml` and `config.schema.json` only), so deleting it would stop
  first-party signals rendering. It is now the fallback for packages that ship
  no contract of their own.

  ## Degradation

  A contract that is missing resolves to `:error` and the caller renders the page
  without a contract block, which is what has always happened. A contract that
  is PRESENT but broken is different: `render_with_diagnostics/2` drops the
  widgets it cannot render, reports why, and - through
  `render_or_generic/2` - falls back to a bounded generic view built from the
  record itself. A third party's malformed contract degrades its own panel; it
  never takes out the operator's page.
  """

  alias ServiceRadarWebNG.Observability.ContractRegistry

  @typedoc """
  Why part of a contract did not render. Enumerable rather than logged, so the
  UI can show an operator the reason next to the panel that degraded.
  """
  @type diagnostic :: %{
          kind: :unknown_widget | :empty_widget | :invalid_contract | :degraded,
          detail: String.t()
        }

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
  @trivy_contract_path @resolve_contract_path.(
                         "go/pkg/trivysidecar/display/vulnerability_report.display.json",
                         @contract_roots
                       )
  @falco_contract_path @resolve_contract_path.(
                         "integrations/falco/display/runtime_event.display.json",
                         @contract_roots
                       )
  @external_resource @powerdns_contract_path
  @external_resource @axis_contract_path
  @external_resource @protect_contract_path
  @external_resource @proxmox_contract_path
  @external_resource @trivy_contract_path
  @external_resource @falco_contract_path
  @powerdns_signal_schema_ref %{
    "producer_id" => "powerdns",
    "producer_version" => "0.1.7",
    "schema_id" => "com.carverauto.powerdns.dns_activity",
    "schema_version" => "1.0.0"
  }
  @trivy_signal_schema_ref %{
    "producer_id" => "trivy",
    "producer_version" => "0.69.1",
    "schema_id" => "com.carverauto.trivy.vulnerability_report",
    "schema_version" => "1.0.0"
  }
  @falco_signal_schema_ref %{
    "producer_id" => "falco",
    "producer_version" => "1.0.0",
    "schema_id" => "com.carverauto.falco.runtime_event",
    "schema_version" => "1.0.0"
  }
  @built_in_contracts %{
    {"powerdns", "0.1.0", "com.carverauto.powerdns.dns_activity", "1.0.0"} =>
      @powerdns_contract_path |> File.read!() |> Jason.decode!(),
    {"powerdns", "0.1.1", "com.carverauto.powerdns.dns_activity", "1.0.0"} =>
      @powerdns_contract_path |> File.read!() |> Jason.decode!(),
    {"powerdns", "0.1.7", "com.carverauto.powerdns.dns_activity", "1.0.0"} =>
      @powerdns_contract_path |> File.read!() |> Jason.decode!(),
    {"axis-camera", "0.1.0", "com.carverauto.axis_camera.event_log", "1.0.0"} =>
      @axis_contract_path |> File.read!() |> Jason.decode!(),
    {"axis-camera", "0.1.3", "com.carverauto.axis_camera.event_log", "1.0.0"} =>
      @axis_contract_path |> File.read!() |> Jason.decode!(),
    {"unifi-protect-camera", "0.1.0", "com.carverauto.unifi_protect.camera_event", "1.0.0"} =>
      @protect_contract_path |> File.read!() |> Jason.decode!(),
    {"unifi-protect-camera", "0.1.4", "com.carverauto.unifi_protect.camera_event", "1.0.0"} =>
      @protect_contract_path |> File.read!() |> Jason.decode!(),
    {"proxmox-inventory", "0.1.1", "com.carverauto.proxmox.resource_event", "1.0.0"} =>
      @proxmox_contract_path |> File.read!() |> Jason.decode!(),
    {"proxmox-inventory", "0.1.7", "com.carverauto.proxmox.resource_event", "1.0.0"} =>
      @proxmox_contract_path |> File.read!() |> Jason.decode!(),
    {"proxmox-inventory", "0.1.8", "com.carverauto.proxmox.resource_event", "1.0.0"} =>
      @proxmox_contract_path |> File.read!() |> Jason.decode!(),
    {"trivy", "0.69.1", "com.carverauto.trivy.vulnerability_report", "1.0.0"} =>
      @trivy_contract_path |> File.read!() |> Jason.decode!(),
    {"falco", "1.0.0", "com.carverauto.falco.runtime_event", "1.0.0"} =>
      @falco_contract_path |> File.read!() |> Jason.decode!()
  }

  @max_widgets 24
  @max_fields 64
  @max_table_rows 50
  @max_table_columns 8
  @max_value_length 240
  @max_generic_fields 24

  @doc "Resolve the display contract referenced by a stored event/log row."
  @spec resolve_contract(map(), keyword()) :: {:ok, map()} | :error
  def resolve_contract(record, opts \\ [])

  def resolve_contract(record, opts) when is_map(record) do
    case resolve_contract_with_source(record, opts) do
      {:ok, contract, _source} -> {:ok, contract}
      :error -> :error
    end
  end

  def resolve_contract(_record, _opts), do: :error

  @doc """
  Resolve a contract and report which of the three sources supplied it.

  The source is what makes a support question answerable: "the package shipped a
  contract and it is being used" and "the package shipped nothing and the
  built-in is being used" produce identical widgets and completely different
  next steps.
  """
  @spec resolve_contract_with_source(map(), keyword()) ::
          {:ok, map(), :override | :runtime | :built_in} | :error
  def resolve_contract_with_source(record, opts \\ [])

  def resolve_contract_with_source(record, opts) when is_map(record) do
    configured = Keyword.get(opts, :contracts) || configured_contracts()

    case signal_schema_ref(record) do
      %{} = signal_schema ->
        key = contract_key(signal_schema)

        cond do
          contract = contract_map(Map.get(configured, key)) -> {:ok, contract, :override}
          contract = runtime_contract(key) -> {:ok, contract, :runtime}
          contract = contract_map(built_in_contract(key)) -> {:ok, contract, :built_in}
          true -> :error
        end

      _ ->
        :error
    end
  end

  def resolve_contract_with_source(_record, _opts), do: :error

  # The runtime index is best-effort by construction: it is an ETS read against
  # a table a supervised process owns, and a render must survive that process
  # not being up yet (boot, a test that starts no application tree) by falling
  # through to the compile-time map rather than raising in a LiveView mount.
  defp runtime_contract({producer_id, producer_version, schema_id, schema_version} = key) do
    if Enum.all?(Tuple.to_list(key), &is_binary/1) do
      case ContractRegistry.lookup_signal(producer_id, producer_version, schema_id, schema_version) do
        {:ok, contract} -> contract
        :error -> nil
      end
    end
  end

  # NOTE: contract_key/1 always builds a 4-tuple, so runtime_contract/1 is
  # total without a catch-all. Do not re-add one: a non-tuple key would be a
  # caller bug that should raise, not silently resolve to nil.
  defp contract_map(%{} = contract), do: contract
  defp contract_map(_value), do: nil

  @doc "Render a record through a display contract into bounded widget view data."
  @spec render(map(), map()) :: {:ok, [map()]} | :error
  def render(record, contract) when is_map(record) and is_map(contract) do
    widgets =
      contract
      |> Map.get("widgets", [])
      |> List.wrap()
      |> Enum.take(@max_widgets)
      |> Enum.with_index()
      |> Enum.flat_map(fn {widget, contract_index} ->
        record
        |> render_widget(widget)
        |> Enum.map(&Map.put(&1, :contract_index, contract_index))
      end)

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

  @doc """
  Render a record through a contract, reporting what could not be rendered.

  Unrenderable widgets are DROPPED, never raised on and never rendered as
  themselves. A third-party contract naming a widget type this release does not
  implement - or naming paths that hold nothing in this particular record - is a
  normal condition, not a page failure, and the diagnostic is how an operator
  finds out which it was.
  """
  @spec render_with_diagnostics(map(), map()) :: {[map()], [diagnostic()]}
  def render_with_diagnostics(record, contract) when is_map(record) and is_map(contract) do
    contract
    |> Map.get("widgets", [])
    |> List.wrap()
    |> Enum.take(@max_widgets)
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {widget, contract_index}, {widgets, diagnostics} ->
      {rendered, widget_diagnostics} = render_widget_diagnosed(record, widget)
      rendered = Enum.map(rendered, &Map.put(&1, :contract_index, contract_index))
      {widgets ++ rendered, diagnostics ++ widget_diagnostics}
    end)
  end

  def render_with_diagnostics(_record, _contract) do
    {[], [%{kind: :invalid_contract, detail: "contract and record must both be objects"}]}
  end

  @doc """
  Render a record through a contract, or through a bounded generic view when
  there is no usable contract.

  `contract` may be `nil`, which is the "this package ships nothing for this
  surface" case rather than an error. This is the entry point the notification
  surfaces use (tasks 3.5.4): a channel's config, a delivery receipt, and a
  channel's health all render through a package contract when one exists and
  through the generic view when one does not, so a package that ships no
  contract and a package whose contract is broken produce the same readable
  panel instead of a blank one.
  """
  @spec render_or_generic(map(), map() | nil, keyword()) :: {[map()], [diagnostic()]}
  def render_or_generic(record, contract, opts \\ [])

  def render_or_generic(record, %{} = contract, opts) when is_map(record) do
    case render_with_diagnostics(record, contract) do
      {[], diagnostics} ->
        {generic_widgets(record, opts),
         diagnostics ++
           [%{kind: :degraded, detail: "contract rendered no widgets; showing a generic view"}]}

      {widgets, diagnostics} ->
        {widgets, diagnostics}
    end
  end

  def render_or_generic(record, nil, opts) when is_map(record) do
    {generic_widgets(record, opts), []}
  end

  def render_or_generic(_record, _contract, _opts), do: {[], []}

  @doc """
  A bounded, contract-free view of a record.

  Scalars become one `facts` widget and containers become one `json_section`,
  under the same length and count limits a contract-driven render obeys. It
  carries no package-supplied labels, so it is safe to render for a record whose
  contract was rejected.
  """
  @spec generic_widgets(map(), keyword()) :: [map()]
  def generic_widgets(record, opts \\ [])

  def generic_widgets(%{} = record, opts) do
    limit = Keyword.get(opts, :limit, @max_generic_fields)
    title = Keyword.get(opts, :title)

    {containers, scalars} =
      record
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.split_with(fn {_key, value} -> is_map(value) or is_list(value) end)

    fields =
      scalars
      |> Enum.take(limit)
      |> Enum.flat_map(fn {key, value} ->
        case display_value(value) do
          blank when blank in [nil, ""] -> []
          value -> [%{label: humanize(key), path: key, value: value, tone: nil}]
        end
      end)

    sections =
      containers
      |> Enum.take(limit)
      |> Enum.map(fn {key, value} ->
        %{path: key, value: value, json: Jason.encode!(value, pretty: true)}
      end)

    Enum.reject(
      [
        if(fields == [], do: nil, else: %{type: :facts, fields: fields}),
        if(sections == [], do: nil, else: %{type: :json_section, title: title, sections: sections})
      ],
      &is_nil/1
    )
  end

  def generic_widgets(_record, _opts), do: []

  # The widget types this release renders. Deliberately a literal rather than a
  # call into `ServiceRadar.Plugins.DisplayContract`: the validator's list is
  # what a package may DECLARE and this is what this release can DRAW, and the
  # two are allowed to differ during a rollout where a newer validator ships
  # first. `signal_display_test.exs` asserts they agree today, which is what
  # keeps an accidental divergence from going unnoticed.
  @renderable_widget_types ~w(summary facts badges timeline json_section table)

  @doc "The widget types this release can render."
  @spec renderable_widget_types() :: [String.t()]
  def renderable_widget_types, do: @renderable_widget_types

  defp render_widget_diagnosed(record, widget) when is_map(widget) do
    type = Map.get(widget, "type")

    if type in @renderable_widget_types do
      case render_widget(record, widget) do
        [] -> {[], [%{kind: :empty_widget, detail: "#{type} widget matched no values in this record"}]}
        widgets -> {widgets, []}
      end
    else
      {[], [%{kind: :unknown_widget, detail: "widget type #{inspect(type)} is not rendered by this release"}]}
    end
  end

  defp render_widget_diagnosed(_record, _widget) do
    {[], [%{kind: :invalid_contract, detail: "widget must be an object"}]}
  end

  defp humanize(key) do
    key
    |> String.replace(["_", "."], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
    |> clean_label()
  end

  defp configured_contracts do
    :serviceradar_web_ng
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:contracts, %{})
  end

  defp built_in_contract({producer_id, _producer_version, schema_id, schema_version} = key) do
    Map.get(@built_in_contracts, key) ||
      Enum.find_value(@built_in_contracts, fn
        {{^producer_id, _known_producer_version, ^schema_id, ^schema_version}, contract} -> contract
        _entry -> nil
      end)
  end

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
      signal_schema_ref_from_attributes(Map.get(record, "resource_attributes")) ||
      inferred_signal_schema_ref(record)
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

  defp inferred_signal_schema_ref(record) do
    service_radar = service_radar_metadata(record)

    cond do
      powerdns_dns_activity?(record, service_radar) ->
        @powerdns_signal_schema_ref

      trivy_vulnerability_report?(record, service_radar) ->
        @trivy_signal_schema_ref

      falco_runtime_event?(record, service_radar) ->
        @falco_signal_schema_ref

      true ->
        nil
    end
  end

  defp service_radar_metadata(record) do
    metadata = Map.get(record, "metadata") || Map.get(record, :metadata) || %{}

    Map.get(metadata, "service_radar") ||
      Map.get(metadata, :service_radar) ||
      %{}
  end

  defp powerdns_dns_activity?(record, service_radar) do
    source_type = map_value(service_radar, "source_type")
    addon_id = map_value(service_radar, "addon_id")
    log_name = map_value(record, "log_name")

    powerdns_source? = addon_id == "powerdns" or source_type == "powerdns" or log_name == "pdns.ocsf"

    powerdns_source? and
      (integer_value(map_value(record, "class_uid")) == 4003 or log_name == "pdns.ocsf")
  end

  defp trivy_vulnerability_report?(record, service_radar) do
    source_type = map_value(service_radar, "source_type")
    log_provider = map_value(record, "log_provider")
    log_name = map_value(record, "log_name")
    metadata = map_value(record, "metadata") || %{}
    report_kind = map_value(metadata, "report_kind") || raw_path_value(record, ["report_kind"])

    (source_type == "trivy" or log_provider == "trivy" or log_name == "trivy.report.vulnerability") and
      report_kind == "VulnerabilityReport"
  end

  defp falco_runtime_event?(record, service_radar) do
    source_type = map_value(service_radar, "source_type")
    log_provider = map_value(record, "log_provider")
    log_name = map_value(record, "log_name")
    metadata = map_value(record, "metadata") || %{}
    signal = map_value(metadata, "security_signal") || %{}

    (source_type == "falco" or log_provider == "falco" or String.starts_with?(log_name || "", "falco.")) and
      map_value(signal, "source") in [nil, "falco"]
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || atom_key_value(map, key)
  end

  defp map_value(_map, _key), do: nil

  defp atom_key_value(map, "source_type"), do: Map.get(map, :source_type)
  defp atom_key_value(map, "addon_id"), do: Map.get(map, :addon_id)
  defp atom_key_value(map, "log_name"), do: Map.get(map, :log_name)
  defp atom_key_value(map, "class_uid"), do: Map.get(map, :class_uid)
  defp atom_key_value(map, "log_provider"), do: Map.get(map, :log_provider)
  defp atom_key_value(map, "metadata"), do: Map.get(map, :metadata)
  defp atom_key_value(map, "raw_data"), do: Map.get(map, :raw_data)
  defp atom_key_value(map, "report_kind"), do: Map.get(map, :report_kind)
  defp atom_key_value(map, "security_signal"), do: Map.get(map, :security_signal)
  defp atom_key_value(map, "source"), do: Map.get(map, :source)
  defp atom_key_value(_map, _key), do: nil

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_value), do: nil

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

  defp render_widget(record, %{"type" => "table"} = widget) do
    rows = path_value(record, Map.get(widget, "path"))
    columns = table_columns(widget)

    if is_list(rows) and columns != [] do
      rendered_rows =
        rows
        |> Enum.take(@max_table_rows)
        |> Enum.flat_map(&render_table_row(&1, columns))

      if rendered_rows == [] do
        []
      else
        [
          %{
            type: :table,
            title: clean_label(Map.get(widget, "title")),
            columns: Enum.map(columns, &Map.take(&1, [:label, :path, :format])),
            rows: rendered_rows
          }
        ]
      end
    else
      []
    end
  end

  defp render_widget(_record, _widget), do: []

  defp table_columns(widget) do
    widget
    |> Map.get("columns", [])
    |> List.wrap()
    |> Enum.take(@max_table_columns)
    |> Enum.flat_map(fn
      %{"label" => label, "path" => path} = column when is_binary(path) ->
        [%{label: clean_label(label), path: path, format: temporal_format(column)}]

      _ ->
        []
    end)
  end

  defp render_table_row(%{} = row, columns) do
    values =
      Enum.map(columns, fn column ->
        %{
          label: column.label,
          path: column.path,
          format: column.format,
          value: display_value(path_value(row, column.path)) || "-"
        }
      end)

    if Enum.all?(values, &(&1.value == "-")), do: [], else: [%{values: values}]
  end

  defp render_table_row(_row, _columns), do: []

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
                tone: clean_label(Map.get(field, "tone")),
                format: temporal_format(field)
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

  defp raw_path_value(record, path) do
    record
    |> map_value("raw_data")
    |> case do
      raw when is_map(raw) -> get_in(raw, path)
      _ -> nil
    end
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

  defp temporal_format(%{} = field) do
    case Map.get(field, "format") do
      format when format in ["timestamp", "unix_nano"] -> format
      _ -> nil
    end
  end

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
