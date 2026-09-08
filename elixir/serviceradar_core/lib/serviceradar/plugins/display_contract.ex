defmodule ServiceRadar.Plugins.DisplayContract do
  @moduledoc """
  Validates and normalizes a package-shipped display contract document.

  A display contract is DATA. It names paths into a record and the widget kind
  each path renders as; it never carries markup, a component name, or anything
  else that would let a package author decide what code the UI runs. That is the
  whole reason this module exists: without it a package could ship an arbitrary
  JSON blob straight into a renderer, and the nine UI-code keys the manifest
  validator already hard-rejects on an `actions:` entry
  (`ServiceRadar.Plugins.Manifest`, `forbidden_ui_contract_errors/2`) would have
  a second, unguarded door. The check here is deliberately DEEPER than the
  manifest's: it rejects those keys at ANY depth in the document, not only at the
  top of a widget.

  ## Document shape

      {
        "id": "com.example.thing.display",
        "version": "1.0.0",
        "schema_id": "com.example.thing",
        "schema_version": "1.0.0",
        "surface": "signal",
        "widgets": [ ... ]
      }

  `id` and `version` identify the contract and are how it is versioned and
  stored: a package's contracts are persisted keyed by `"<id>@<version>"`, so
  shipping a new revision of a contract is a version bump rather than an
  in-place edit, and an operator can tell two revisions apart.

  `schema_id` / `schema_version` bind the contract to what it renders:

    * `surface: "signal"` (the default) binds to a `signal_schemas` entry's
      `id` / `version`, which together with the package's own id and version is
      the four-part key `ServiceRadarWebNG.Observability.SignalDisplay` resolves.
    * `surface: "notification_delivery"` and `"notification_channel_health"`
      bind `schema_id` to a `key` in the package's `notifications:` block, so a
      notifier can describe how its delivery receipts and health detail render.

  Unknown top-level keys, unknown widget types, and unknown widget keys are all
  REJECTED rather than ignored, for the same reason the manifest rejects unknown
  keys: a misspelling must fail at import instead of silently shipping a
  contract with half of it missing.

  Every list and string is bounded here as well as at render time. Render-time
  bounds protect the browser; import-time bounds stop an unbounded document from
  being persisted onto a package row in the first place.
  """

  @allowed_top_level_keys ~w(id version schema_id schema_version surface widgets)

  @default_surface "signal"
  @allowed_surfaces ~w(signal notification_delivery notification_channel_health)

  # Widget type -> the keys that type accepts. This mirrors what
  # `SignalDisplay.render_widget/2` actually reads; a key the renderer ignores is
  # rejected here rather than persisted as decoration nobody will honour.
  @widget_keys %{
    "summary" => ~w(type title message source severity),
    "facts" => ~w(type title fields),
    "badges" => ~w(type title fields),
    "timeline" => ~w(type title fields),
    "json_section" => ~w(type title paths),
    "table" => ~w(type title path columns)
  }

  @allowed_field_keys ~w(label path tone format)
  @allowed_column_keys ~w(label path format)
  @allowed_temporal_formats ~w(timestamp unix_nano)

  # The nine keys `ServiceRadar.Plugins.Manifest` refuses on an action. A display
  # contract must not become a way around that rejection.
  @forbidden_keys ~w(html raw_html javascript js component component_ref live_view react ui_code)

  @max_widgets 24
  @max_fields 64
  @max_paths 64
  @max_columns 8
  @max_string_length 240
  @max_id_length 160
  @max_document_keys 4096

  @id_regex ~r/^[a-z0-9][a-z0-9_.-]*$/
  @semver_regex ~r/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/
  # A render path is a dotted key walk with optional numeric list indexes. It is
  # never evaluated, only split on ".", so the character class is what keeps a
  # path from carrying anything a future renderer might be tempted to interpret.
  @path_regex ~r/^[A-Za-z0-9_][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)*$/

  @type contract :: %{optional(String.t()) => term()}

  @doc "The widget types a contract may use."
  @spec widget_types() :: [String.t()]
  def widget_types, do: @widget_keys |> Map.keys() |> Enum.sort()

  @doc "The surfaces a contract may declare."
  @spec surfaces() :: [String.t()]
  def surfaces, do: @allowed_surfaces

  @doc "The UI-code keys refused at any depth of a contract document."
  @spec forbidden_keys() :: [String.t()]
  def forbidden_keys, do: @forbidden_keys

  @doc "The default surface for a contract that does not declare one."
  @spec default_surface() :: String.t()
  def default_surface, do: @default_surface

  @doc """
  Validate and normalize one contract document.

  Returns the normalized contract with string keys, a defaulted `surface`, and
  every widget reduced to the keys its type accepts.
  """
  @spec validate(term()) :: {:ok, contract()} | {:error, [String.t()]}
  def validate(document) do
    with {:ok, map} <- decode(document) do
      case validate_map(map) do
        {:ok, contract} -> {:ok, contract}
        {:error, errors} -> {:error, Enum.uniq(errors)}
      end
    end
  end

  @doc """
  Validate a collection of contract documents into a storage map.

  Accepts either a map of `%{source_name => document}` (a bundle path, say) or a
  list of documents, and returns `%{"<id>@<version>" => contract}`. Two documents
  that normalize to the same key are an error: a package that ships a contract
  twice has an undecidable binding, exactly like a duplicate `notifications:`
  key.
  """
  @spec validate_all(term()) ::
          {:ok, %{optional(String.t()) => contract()}} | {:error, [String.t()]}
  def validate_all(nil), do: {:ok, %{}}
  def validate_all(documents) when documents == %{}, do: {:ok, %{}}

  def validate_all(documents) when is_map(documents) or is_list(documents) do
    documents |> normalize_sources() |> validate_sources()
  end

  def validate_all(_documents), do: {:error, ["display contracts must be a map or a list"]}

  @doc """
  Split a collection of contract documents into the ones that validate and the
  reasons the rest did not.

  This is the BUNDLE importers' entry point, and it differs from
  `validate_all/1` on purpose. A signed plugin bundle may carry a `display/`
  entry that is not a contract at all - a placeholder, a leftover, a file a
  future release will interpret - and refusing the whole package for a UI-only
  file would reject an otherwise valid, signed artifact over something that
  cannot affect what the plugin does. So a bundle's bad contract is dropped and
  reported, while a contract supplied directly through the API or the admin UI
  still fails loudly through `validate_all/1`: there, the operator typed it and
  a silent drop would be a lie.

  Dropped is not the same as ignored. The errors returned here are recorded on
  the package so an operator can see that a contract was refused and why, rather
  than only noticing that a panel never renders.
  """
  @spec partition(term()) :: {%{optional(String.t()) => contract()}, [String.t()]}
  def partition(documents) when is_map(documents) or is_list(documents) do
    documents
    |> normalize_sources()
    |> Enum.reduce({%{}, []}, fn {source, document}, {contracts, errors} ->
      case validate(document) do
        {:ok, contract} ->
          contract_key = key(contract)

          if Map.has_key?(contracts, contract_key) do
            {contracts,
             ["#{source}: display contract #{contract_key} is declared more than once" | errors]}
          else
            {Map.put(contracts, contract_key, contract), errors}
          end

        {:error, contract_errors} ->
          {contracts, Enum.map(contract_errors, &"#{source}: #{&1}") ++ errors}
      end
    end)
    |> then(fn {contracts, errors} -> {contracts, Enum.reverse(errors)} end)
  end

  def partition(_documents), do: {%{}, ["display contracts must be a map or a list"]}

  @doc "The storage key a normalized contract is filed under."
  @spec key(contract()) :: String.t() | nil
  def key(%{"id" => id, "version" => version}) when is_binary(id) and is_binary(version) do
    id <> "@" <> version
  end

  def key(_contract), do: nil

  @doc """
  The signal binding of a normalized contract, or `nil` when it renders a
  non-signal surface.
  """
  @spec signal_binding(contract()) :: {String.t(), String.t()} | nil
  def signal_binding(%{
        "surface" => @default_surface,
        "schema_id" => id,
        "schema_version" => version
      }) do
    {id, version}
  end

  def signal_binding(_contract), do: nil

  # --- validation ----------------------------------------------------------

  defp normalize_sources(documents) when is_map(documents) do
    documents
    |> Enum.map(fn {source, document} -> {to_string(source), document} end)
    |> Enum.sort_by(fn {source, _document} -> source end)
  end

  defp normalize_sources(documents) when is_list(documents) do
    documents
    |> Enum.with_index()
    |> Enum.map(fn {document, index} -> {"[#{index}]", document} end)
  end

  defp validate_sources(sourced) do
    {contracts, errors} =
      Enum.reduce(sourced, {%{}, []}, fn {source, document}, {acc, errors} ->
        case validate(document) do
          {:ok, contract} ->
            contract_key = key(contract)

            if Map.has_key?(acc, contract_key) do
              {acc,
               ["#{source}: display contract #{contract_key} is declared more than once" | errors]}
            else
              {Map.put(acc, contract_key, contract), errors}
            end

          {:error, contract_errors} ->
            {acc, Enum.map(contract_errors, &"#{source}: #{&1}") ++ errors}
        end
      end)

    if errors == [], do: {:ok, contracts}, else: {:error, Enum.reverse(errors)}
  end

  defp decode(document) when is_binary(document) do
    case Jason.decode(document) do
      {:ok, %{} = map} ->
        {:ok, map}

      {:ok, _other} ->
        {:error, ["display contract must be a JSON object"]}

      {:error, reason} ->
        {:error, ["invalid display contract JSON: #{Exception.message(reason)}"]}
    end
  end

  defp decode(%{} = document), do: {:ok, document}
  defp decode(_document), do: {:error, ["display contract must be a JSON object"]}

  defp validate_map(map) do
    map = stringify(map)

    with :ok <- validate_document_size(map),
         :ok <- validate_no_forbidden_keys(map) do
      build(map)
    end
  end

  defp validate_document_size(map) do
    if count_keys(map, 0) > @max_document_keys do
      {:error, ["display contract is too large"]}
    else
      :ok
    end
  end

  defp count_keys(_value, count) when count > @max_document_keys, do: count

  defp count_keys(%{} = map, count) do
    Enum.reduce(map, count + map_size(map), fn {_key, value}, acc -> count_keys(value, acc) end)
  end

  defp count_keys(list, count) when is_list(list) do
    Enum.reduce(list, count, fn value, acc -> count_keys(value, acc) end)
  end

  defp count_keys(_value, count), do: count

  # Depth-first over the whole document, not just the widget heads. A package
  # that buries `"html"` inside a field or a nested object is refused with the
  # same message as one that puts it at the top.
  defp validate_no_forbidden_keys(value) do
    case forbidden_key_in(value) do
      nil ->
        :ok

      key ->
        {:error, ["display contract key #{key} is not allowed; contracts may not ship UI code"]}
    end
  end

  defp forbidden_key_in(%{} = map) do
    Enum.find_value(map, fn {key, value} ->
      if key in @forbidden_keys, do: key, else: forbidden_key_in(value)
    end)
  end

  defp forbidden_key_in(list) when is_list(list), do: Enum.find_value(list, &forbidden_key_in/1)
  defp forbidden_key_in(_value), do: nil

  defp build(map) do
    errors = unknown_key_errors(map, @allowed_top_level_keys, "display contract")

    {id, errors} = required_id(map, "id", errors)
    {version, errors} = required_semver(map, "version", errors)
    {schema_id, errors} = required_id(map, "schema_id", errors)
    {schema_version, errors} = required_semver(map, "schema_version", errors)
    {surface, errors} = surface(map, errors)
    {widgets, errors} = widgets(map, errors)

    if errors == [] do
      {:ok,
       %{
         "id" => id,
         "version" => version,
         "schema_id" => schema_id,
         "schema_version" => schema_version,
         "surface" => surface,
         "widgets" => widgets
       }}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp surface(map, errors) do
    case Map.get(map, "surface") do
      nil ->
        {@default_surface, errors}

      value when is_binary(value) ->
        if value in @allowed_surfaces do
          {value, errors}
        else
          {nil,
           [
             "display contract surface must be one of #{Enum.join(@allowed_surfaces, ", ")}"
             | errors
           ]}
        end

      _other ->
        {nil, ["display contract surface must be a string" | errors]}
    end
  end

  defp widgets(map, errors) do
    case Map.get(map, "widgets") do
      list when is_list(list) and list != [] ->
        if length(list) > @max_widgets do
          {[], ["display contract declares more than #{@max_widgets} widgets" | errors]}
        else
          list
          |> Enum.with_index()
          |> Enum.reduce({[], errors}, fn {widget, index}, {acc, errors} ->
            case widget(widget, index) do
              {:ok, normalized} -> {[normalized | acc], errors}
              {:error, widget_errors} -> {acc, widget_errors ++ errors}
            end
          end)
          |> then(fn {acc, errors} -> {Enum.reverse(acc), errors} end)
        end

      [] ->
        {[], ["display contract must declare at least one widget" | errors]}

      _other ->
        {[], ["display contract widgets must be a list" | errors]}
    end
  end

  defp widget(widget, index) when is_map(widget) do
    type = Map.get(widget, "type")

    case Map.get(@widget_keys, type) do
      nil ->
        {:error, ["widgets[#{index}].type must be one of #{Enum.join(widget_types(), ", ")}"]}

      allowed ->
        errors = unknown_key_errors(widget, allowed, "widgets[#{index}]")

        {normalized, errors} = widget_body(type, widget, index, errors)

        if errors == [] do
          {:ok, Map.put(normalized, "type", type)}
        else
          {:error, Enum.reverse(errors)}
        end
    end
  end

  defp widget(_widget, index), do: {:error, ["widgets[#{index}] must be a map"]}

  defp widget_body("summary", widget, index, errors) do
    {title, errors} = optional_path(widget, "title", "widgets[#{index}]", errors)
    {message, errors} = optional_path(widget, "message", "widgets[#{index}]", errors)
    {source, errors} = optional_path(widget, "source", "widgets[#{index}]", errors)
    {severity, errors} = optional_path(widget, "severity", "widgets[#{index}]", errors)

    body =
      %{}
      |> put_present("title", title)
      |> put_present("message", message)
      |> put_present("source", source)
      |> put_present("severity", severity)

    if body == %{} do
      {body, ["widgets[#{index}] summary must name at least one path" | errors]}
    else
      {body, errors}
    end
  end

  defp widget_body(type, widget, index, errors) when type in ["facts", "badges", "timeline"] do
    {title, errors} = optional_label(widget, "title", "widgets[#{index}]", errors)
    {fields, errors} = fields(widget, index, errors)

    {put_present(%{"fields" => fields}, "title", title), errors}
  end

  defp widget_body("json_section", widget, index, errors) do
    {title, errors} = optional_label(widget, "title", "widgets[#{index}]", errors)

    {paths, errors} =
      case Map.get(widget, "paths") do
        list when is_list(list) and list != [] ->
          if length(list) > @max_paths do
            {[], ["widgets[#{index}].paths declares more than #{@max_paths} entries" | errors]}
          else
            list
            |> Enum.with_index()
            |> Enum.reduce({[], errors}, fn {path, path_index}, {acc, errors} ->
              case normalize_path(path) do
                {:ok, value} ->
                  {[value | acc], errors}

                :error ->
                  {acc, ["widgets[#{index}].paths[#{path_index}] is not a valid path" | errors]}
              end
            end)
            |> then(fn {acc, errors} -> {Enum.reverse(acc), errors} end)
          end

        _other ->
          {[], ["widgets[#{index}].paths must be a non-empty list of paths" | errors]}
      end

    {put_present(%{"paths" => paths}, "title", title), errors}
  end

  defp widget_body("table", widget, index, errors) do
    {title, errors} = optional_label(widget, "title", "widgets[#{index}]", errors)

    {path, errors} =
      case normalize_path(Map.get(widget, "path")) do
        {:ok, value} -> {value, errors}
        :error -> {nil, ["widgets[#{index}].path must be a valid path" | errors]}
      end

    {columns, errors} = columns(widget, index, errors)

    {put_present(%{"path" => path, "columns" => columns}, "title", title), errors}
  end

  defp fields(widget, index, errors) do
    case Map.get(widget, "fields") do
      list when is_list(list) and list != [] ->
        if length(list) > @max_fields do
          {[], ["widgets[#{index}].fields declares more than #{@max_fields} entries" | errors]}
        else
          list
          |> Enum.with_index()
          |> Enum.reduce({[], errors}, fn {field, field_index}, {acc, errors} ->
            case field(field, "widgets[#{index}].fields[#{field_index}]") do
              {:ok, normalized} -> {[normalized | acc], errors}
              {:error, field_errors} -> {acc, field_errors ++ errors}
            end
          end)
          |> then(fn {acc, errors} -> {Enum.reverse(acc), errors} end)
        end

      _other ->
        {[], ["widgets[#{index}].fields must be a non-empty list" | errors]}
    end
  end

  defp field(field, prefix) when is_map(field) do
    errors = unknown_key_errors(field, @allowed_field_keys, prefix)

    {label, errors} = required_label(field, "label", prefix, errors)

    {path, errors} =
      case normalize_path(Map.get(field, "path")) do
        {:ok, value} -> {value, errors}
        :error -> {nil, ["#{prefix}.path must be a valid path" | errors]}
      end

    {tone, errors} = optional_label(field, "tone", prefix, errors)
    {format, errors} = optional_temporal_format(field, prefix, errors)

    if errors == [] do
      {:ok,
       %{"label" => label, "path" => path}
       |> put_present("tone", tone)
       |> put_present("format", format)}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp field(_field, prefix), do: {:error, ["#{prefix} must be a map"]}

  defp columns(widget, index, errors) do
    case Map.get(widget, "columns") do
      list when is_list(list) and list != [] ->
        if length(list) > @max_columns do
          {[], ["widgets[#{index}].columns declares more than #{@max_columns} entries" | errors]}
        else
          list
          |> Enum.with_index()
          |> Enum.reduce({[], errors}, fn {column, column_index}, {acc, errors} ->
            case column(column, "widgets[#{index}].columns[#{column_index}]") do
              {:ok, normalized} -> {[normalized | acc], errors}
              {:error, column_errors} -> {acc, column_errors ++ errors}
            end
          end)
          |> then(fn {acc, errors} -> {Enum.reverse(acc), errors} end)
        end

      _other ->
        {[], ["widgets[#{index}].columns must be a non-empty list" | errors]}
    end
  end

  defp column(column, prefix) when is_map(column) do
    errors = unknown_key_errors(column, @allowed_column_keys, prefix)
    {label, errors} = required_label(column, "label", prefix, errors)

    {path, errors} =
      case normalize_path(Map.get(column, "path")) do
        {:ok, value} -> {value, errors}
        :error -> {nil, ["#{prefix}.path must be a valid path" | errors]}
      end

    {format, errors} = optional_temporal_format(column, prefix, errors)

    if errors == [] do
      {:ok, put_present(%{"label" => label, "path" => path}, "format", format)}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp column(_column, prefix), do: {:error, ["#{prefix} must be a map"]}

  defp optional_temporal_format(map, prefix, errors) do
    case Map.get(map, "format") do
      nil ->
        {nil, errors}

      format when format in @allowed_temporal_formats ->
        {format, errors}

      _ ->
        {nil,
         [
           "#{prefix}.format must be one of #{Enum.join(@allowed_temporal_formats, ", ")}"
           | errors
         ]}
    end
  end

  # --- primitives ----------------------------------------------------------

  defp unknown_key_errors(map, allowed, prefix) do
    map
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort()
    |> Enum.map(&"#{prefix}.#{&1} is not allowed")
    |> Enum.reverse()
  end

  defp required_id(map, key, errors) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            {nil, ["display contract #{key} must be a non-empty string" | errors]}

          String.length(trimmed) > @max_id_length ->
            {nil, ["display contract #{key} exceeds maximum length" | errors]}

          Regex.match?(@id_regex, trimmed) ->
            {trimmed, errors}

          true ->
            {nil,
             [
               "display contract #{key} must use lowercase letters, numbers, dots, underscores, or hyphens"
               | errors
             ]}
        end

      _other ->
        {nil, ["display contract #{key} must be a non-empty string" | errors]}
    end
  end

  defp required_semver(map, key, errors) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if Regex.match?(@semver_regex, trimmed) do
          {trimmed, errors}
        else
          {nil, ["display contract #{key} must be a valid semver string" | errors]}
        end

      _other ->
        {nil, ["display contract #{key} must be a valid semver string" | errors]}
    end
  end

  defp required_label(map, key, prefix, errors) do
    case optional_label(map, key, prefix, errors) do
      {nil, errors} -> {nil, ["#{prefix}.#{key} must be a non-empty string" | errors]}
      {value, errors} -> {value, errors}
    end
  end

  defp optional_label(map, key, prefix, errors) do
    case Map.get(map, key) do
      nil ->
        {nil, errors}

      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            {nil, errors}

          String.length(trimmed) > @max_string_length ->
            {nil, ["#{prefix}.#{key} exceeds maximum length" | errors]}

          true ->
            {trimmed, errors}
        end

      _other ->
        {nil, ["#{prefix}.#{key} must be a string" | errors]}
    end
  end

  defp optional_path(map, key, prefix, errors) do
    case Map.get(map, key) do
      nil ->
        {nil, errors}

      value ->
        case normalize_path(value) do
          {:ok, path} -> {path, errors}
          :error -> {nil, ["#{prefix}.#{key} must be a valid path" | errors]}
        end
    end
  end

  defp normalize_path(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.length(trimmed) <= @max_string_length and
         Regex.match?(@path_regex, trimmed) do
      {:ok, trimmed}
    else
      :error
    end
  end

  defp normalize_path(_value), do: :error

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp stringify(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
