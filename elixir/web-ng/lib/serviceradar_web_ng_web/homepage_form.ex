defmodule ServiceRadarWebNGWeb.HomepageForm do
  @moduledoc """
  Profile and user-group homepage controls.

  The stored value is a kind plus an optional dashboard id. The form never
  accepts a free-text URL. Listing a dashboard here does not share it.
  """

  alias ServiceRadar.Identity.Homepage
  alias ServiceRadarWebNG.Dashboards

  @profile_choices [
    {"Inherit", "inherit"},
    {"Platform default", "platform"},
    {"Dashboards list", "dashboards"},
    {"Specific dashboard", "dashboard"}
  ]

  @group_choices [
    {"No group homepage", "inherit"},
    {"Platform default", "platform"},
    {"Dashboards list", "dashboards"},
    {"Specific dashboard", "dashboard"}
  ]

  @spec profile_choices() :: [{String.t(), String.t()}]
  def profile_choices, do: @profile_choices

  @spec group_choices() :: [{String.t(), String.t()}]
  def group_choices, do: @group_choices

  @spec params_from(term(), term()) :: map()
  def params_from(kind, target) do
    %{
      "choice" => choice_value(kind),
      "dashboard" => dashboard_value(kind, target),
      "query" => ""
    }
  end

  @spec attrs_from(map()) :: {:ok, map()} | :error
  def attrs_from(%{"choice" => "inherit"}), do: {:ok, %{homepage_kind: nil, homepage_target: nil}}
  def attrs_from(%{"choice" => "platform"}), do: {:ok, %{homepage_kind: :platform, homepage_target: nil}}

  def attrs_from(%{"choice" => "dashboards"}), do: {:ok, %{homepage_kind: :dashboards, homepage_target: nil}}

  def attrs_from(%{"choice" => "dashboard", "dashboard" => "authored:" <> id}) do
    if Homepage.valid_target?(id) do
      {:ok, %{homepage_kind: :authored, homepage_target: id}}
    else
      :error
    end
  end

  def attrs_from(%{"choice" => "dashboard", "dashboard" => "package:" <> slug}) do
    if Homepage.valid_target?(slug) do
      {:ok, %{homepage_kind: :package, homepage_target: slug}}
    else
      :error
    end
  end

  def attrs_from(_params), do: :error

  @doc """
  Active authored dashboards and enabled packages the actor can already open.

  Capped at 100 so the settings page can render a select without a stream.
  """
  @spec catalog(term()) :: [%{value: String.t(), label: String.t()}]
  def catalog(scope) do
    authored =
      scope
      |> Dashboards.list_authored_dashboards(%{status: [:active], limit: 100})
      |> Enum.flat_map(&authored_option/1)

    remaining = max(100 - length(authored), 0)

    packages =
      [scope: scope]
      |> Dashboards.enabled_package_instances()
      |> Enum.flat_map(&package_option/1)
      |> Enum.take(remaining)

    authored ++ packages
  rescue
    _exception -> []
  end

  @spec select_options([map()], map()) :: [{String.t(), String.t()}]
  def select_options(catalog, params) when is_list(catalog) and is_map(params) do
    selected = Map.get(params, "dashboard")
    query = params |> Map.get("query", "") |> to_string() |> String.trim() |> String.downcase()

    catalog
    |> Enum.filter(&matches_query?(&1, query, selected))
    |> ensure_selected(selected)
    |> Enum.map(fn item -> {item.label, item.value} end)
  end

  @spec summary(term(), term(), [map()]) :: String.t()
  def summary(kind, target, catalog \\ []) do
    stored = dashboard_value(kind, target)

    named =
      Enum.find_value(catalog, fn item ->
        if item.value == stored and stored != "", do: item.label
      end)

    cond do
      is_binary(named) -> named
      kind == :platform -> "Platform default"
      kind == :dashboards -> "Dashboards list"
      kind in [:authored, :package] -> "Specific dashboard"
      true -> "No group homepage"
    end
  end

  defp choice_value(:platform), do: "platform"
  defp choice_value(:dashboards), do: "dashboards"
  defp choice_value(kind) when kind in [:authored, :package], do: "dashboard"
  defp choice_value(_kind), do: "inherit"

  defp dashboard_value(:authored, target) when is_binary(target), do: "authored:" <> target
  defp dashboard_value(:package, target) when is_binary(target), do: "package:" <> target
  defp dashboard_value(_kind, _target), do: ""

  defp authored_option(%{id: id, title: title}) do
    target = to_string(id)

    if Homepage.valid_target?(target) do
      [%{value: "authored:" <> target, label: label_or(title, "Dashboard")}]
    else
      []
    end
  end

  defp authored_option(_dashboard), do: []

  defp package_option(%{route_slug: slug} = instance) when is_binary(slug) do
    if Homepage.valid_target?(slug) do
      [%{value: "package:" <> slug, label: label_or(instance.name, slug)}]
    else
      []
    end
  end

  defp package_option(_instance), do: []

  defp label_or(label, _fallback) when is_binary(label) and label != "", do: label
  defp label_or(_label, fallback), do: fallback

  defp matches_query?(_item, "", _selected), do: true

  defp matches_query?(item, query, selected) do
    item.value == selected or item.label |> String.downcase() |> String.contains?(query)
  end

  defp ensure_selected(items, "authored:" <> target = selected) do
    ensure_saved(items, selected, target)
  end

  defp ensure_selected(items, "package:" <> target = selected) do
    ensure_saved(items, selected, target)
  end

  defp ensure_selected(items, _selected), do: items

  defp ensure_saved(items, selected, target) do
    if Homepage.valid_target?(target) and not Enum.any?(items, &(&1.value == selected)) do
      items ++ [%{value: selected, label: "Saved dashboard"}]
    else
      items
    end
  end
end
