defmodule ServiceRadarWebNG.Dashboards.Definition do
  @moduledoc """
  Validates a declarative dashboard definition.

  A definition is a plain decoded JSON map describing one authored dashboard and
  its panels. It is the portable form: the product ships its built-in dashboards
  as definitions, and an operator can export a dashboard they built in the builder
  to the same shape and import it elsewhere.

  ## Why validation lives here and not in the tests

  Every rule below was, at some point, only asserted by a test that recomputed the
  rule itself -- which is not a check, because the test and the code could drift
  and the test would still pass. Validation is production behaviour: the loader
  refuses a bad definition and names the file and field. Tests then exercise THIS
  function rather than restating its logic.

  ## The rules, and what each one prevents

    * `version` must be present and known. An unrecognised version is a refusal,
      never a skip: a definition the loader silently ignores is indistinguishable
      from one that was never shipped.
    * Every panel must declare a grid `layout`. An omitted layout is not "let the
      renderer choose" -- `LayoutHelpers.panel_grid_style/2` defaults a missing one
      to x=0, y=0, w=12, h=4, so panels that all omit it land in the same cell and
      only one is visible. That shipped, and read as a renderer bug.
    * Panels must not overlap, for the same reason.
    * `visual_type` must be one the resource accepts, or the create fails at
      import time rather than at validation time.
    * A data binding must name a field the panel's own query actually selects. A
      binding naming something absent renders an empty panel with no error.
  """

  alias ServiceRadar.Dashboards.DashboardPanel

  @supported_versions [1]
  @grid_columns 12

  # A `time:<duration>` group dimension projects its bucket under this key. The
  # compiler produces it, so it never appears in the query text.
  @implicit_bucket_field "bucket"

  @type t :: %{
          version: pos_integer(),
          slug: String.t(),
          title: String.t(),
          description: String.t() | nil,
          default_time_range: String.t() | nil,
          metadata: map(),
          variables: map(),
          panels: [map()]
        }

  @doc "Versions this loader understands."
  @spec supported_versions() :: [pos_integer()]
  def supported_versions, do: @supported_versions

  @doc "Visual types the panel resource will accept."
  @spec allowed_visual_types() :: [atom()]
  def allowed_visual_types do
    DashboardPanel
    |> Ash.Resource.Info.attribute(:visual_type)
    |> Map.fetch!(:constraints)
    |> Keyword.fetch!(:one_of)
  end

  @doc """
  Validates a decoded definition map.

  `source` names where it came from, so an error can point at a file.
  """
  @spec validate(map(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def validate(raw, source) when is_map(raw) do
    with :ok <- validate_version(raw, source),
         {:ok, slug} <- required_string(raw, "slug", source),
         {:ok, title} <- required_string(raw, "title", source),
         {:ok, panels} <- validate_panels(raw, source) do
      {:ok,
       %{
         version: raw["version"],
         slug: slug,
         title: title,
         description: raw["description"],
         default_time_range: raw["default_time_range"],
         metadata: Map.get(raw, "metadata") || %{},
         variables: Map.get(raw, "variables") || %{},
         panels: panels
       }}
    end
  end

  def validate(_raw, source), do: {:error, "#{source}: definition must be a JSON object"}

  defp validate_version(%{"version" => version}, source) when is_integer(version) do
    if version in @supported_versions do
      :ok
    else
      {:error,
       "#{source}: unsupported definition version #{version}; " <>
         "this build understands #{inspect(@supported_versions)}"}
    end
  end

  defp validate_version(_raw, source),
    do: {:error, "#{source}: missing required integer \"version\""}

  defp required_string(raw, key, source) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{source}: missing required non-empty string #{inspect(key)}"}
    end
  end

  defp validate_panels(%{"panels" => panels}, source) when is_list(panels) and panels != [] do
    panels
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {panel, index}, {:ok, acc} ->
      case validate_panel(panel, index, source) do
        {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} ->
        validated = Enum.reverse(validated)

        with :ok <- refute_overlap(validated, source) do
          {:ok, validated}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_panels(_raw, source),
    do: {:error, "#{source}: \"panels\" must be a non-empty array"}

  defp validate_panel(panel, index, source) when is_map(panel) do
    where = "#{source} panel #{index}"

    with {:ok, title} <- required_string(panel, "title", where),
         {:ok, query} <- required_string(panel, "srql_query", where),
         {:ok, visual} <- validate_visual_type(panel, where),
         {:ok, layout} <- validate_layout(panel, where),
         binding = Map.get(panel, "data_binding") || %{},
         :ok <- validate_binding(binding, query, where) do
      {:ok,
       %{
         title: title,
         srql_query: query,
         visual_type: visual,
         data_binding: binding,
         display_config: Map.get(panel, "display_config") || %{},
         visual_config: Map.get(panel, "visual_config") || %{},
         layout: layout,
         position: Map.get(panel, "position", index)
       }}
    end
  end

  defp validate_panel(_panel, index, source),
    do: {:error, "#{source} panel #{index}: must be a JSON object"}

  # Compares string forms rather than converting input to an atom, so an unknown
  # visual type cannot create one.
  defp validate_visual_type(panel, where) do
    raw = Map.get(panel, "visual_type")

    case Enum.find(allowed_visual_types(), fn allowed -> to_string(allowed) == raw end) do
      nil ->
        {:error,
         "#{where}: visual_type #{inspect(raw)} is not accepted by the panel resource; " <>
           "allowed: #{Enum.map_join(allowed_visual_types(), ", ", &to_string/1)}"}

      atom ->
        {:ok, atom}
    end
  end

  defp validate_layout(panel, where) do
    layout = Map.get(panel, "layout")

    cond do
      not is_map(layout) or layout == %{} ->
        {:error,
         "#{where}: missing \"layout\". Panels without one all default to the same " <>
           "grid cell and only one renders."}

      not Enum.all?(~w(x y w h), &is_integer(Map.get(layout, &1))) ->
        {:error, "#{where}: layout needs integer x, y, w and h"}

      layout["x"] < 0 or layout["x"] > @grid_columns - 1 ->
        {:error, "#{where}: layout x must be within the #{@grid_columns}-column grid"}

      layout["w"] < 1 or layout["x"] + layout["w"] > @grid_columns ->
        {:error, "#{where}: layout overflows the #{@grid_columns}-column grid"}

      layout["y"] < 0 or layout["h"] < 1 ->
        {:error, "#{where}: layout y and h must be non-negative and h at least 1"}

      true ->
        {:ok, layout}
    end
  end

  defp validate_binding(binding, query, where) when is_map(binding) do
    binding
    |> Enum.reject(fn {_key, field} -> selects_field?(query, field) end)
    |> case do
      [] ->
        :ok

      [{key, field} | _] ->
        {:error,
         "#{where}: binding #{inspect(key)} names #{inspect(field)}, which the panel's " <>
           "query does not select: #{query}"}
    end
  end

  defp validate_binding(_binding, _query, where),
    do: {:error, "#{where}: data_binding must be a JSON object"}

  @doc """
  Whether an SRQL query selects `field`, as a stats alias, a group dimension, or
  the implicit time bucket.

  Public because it is the rule a definition is judged by; tests exercise it
  directly rather than reimplementing it.
  """
  @spec selects_field?(String.t(), String.t()) :: boolean()
  def selects_field?(query, field) when is_binary(query) and is_binary(field) do
    Regex.match?(~r/ as #{Regex.escape(field)}(?!\w)/, query) or
      field in group_dimensions(query) or
      (field == @implicit_bucket_field and String.contains?(query, "by time:"))
  end

  def selects_field?(_query, _field), do: false

  # A multi-aggregation stats expression is quoted, so the `by` clause can end at
  # a closing quote rather than at whitespace:
  #
  #     stats:"loss_ratio(sent, received) as loss, count() as n by hop_number" sort:...
  #
  # Splitting on whitespace alone yields `hop_number"` and the dimension fails to
  # match a binding that names it. Real shipped data caught this, not a test.
  defp group_dimensions(query) do
    case :binary.split(query, " by ") do
      [_, after_by] ->
        after_by
        |> String.split(~r/ sort:| limit:/, parts: 2)
        |> hd()
        |> String.split([" ", ","], trim: true)
        |> Enum.map(&String.trim(&1, "\""))
        |> Enum.map(&String.trim(&1, "'"))
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp refute_overlap(panels, source) do
    cells =
      Enum.flat_map(panels, fn panel ->
        l = panel.layout

        for cx <- l["x"]..(l["x"] + l["w"] - 1),
            cy <- l["y"]..(l["y"] + l["h"] - 1),
            do: {cx, cy}
      end)

    if length(Enum.uniq(cells)) == length(cells) do
      :ok
    else
      {:error, "#{source}: panels overlap in the grid, so at least one would be hidden"}
    end
  end
end
