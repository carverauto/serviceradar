defmodule ServiceRadar.Inventory.Changes.NormalizeInterfaceMetricsConfig do
  @moduledoc """
  Normalizes interface metrics settings so disablement consistently clears selections
  and composite group configuration.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    metrics_enabled = Ash.Changeset.get_attribute(changeset, :metrics_enabled)
    metrics_selected = Ash.Changeset.get_attribute(changeset, :metrics_selected)

    {normalized_selected, normalized_enabled} = normalize(metrics_selected, metrics_enabled)

    changeset
    |> Ash.Changeset.force_change_attribute(:metrics_selected, normalized_selected)
    |> Ash.Changeset.force_change_attribute(:metrics_enabled, normalized_enabled)
    |> maybe_clear_metric_groups(normalized_selected)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp normalize(metrics_selected, metrics_enabled) do
    selected = normalize_selected(metrics_selected)

    enabled =
      case metrics_enabled do
        true -> true
        false -> false
        nil -> selected != []
      end

    if enabled and selected != [] do
      {selected, true}
    else
      {[], false}
    end
  end

  defp normalize_selected(metrics) when is_list(metrics) do
    metrics
    |> Enum.map(&normalize_metric_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_selected(_), do: []

  defp normalize_metric_name(metric) when is_atom(metric), do: Atom.to_string(metric)
  defp normalize_metric_name(metric) when is_binary(metric), do: String.trim(metric)
  defp normalize_metric_name(metric), do: to_string(metric)

  defp maybe_clear_metric_groups(changeset, []),
    do: Ash.Changeset.force_change_attribute(changeset, :metric_groups, [])

  defp maybe_clear_metric_groups(changeset, _), do: changeset
end
