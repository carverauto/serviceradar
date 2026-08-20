defmodule ServiceRadarWebNGWeb.DeviceLive.IndexData.Composite do
  @moduledoc """
  Per-device composite verdicts for the device list's optional verdict column.

  The column is optional in a specific sense: it appears only when the current
  query already filters on one composite check. That is what makes it
  well-defined — a device can hold a verdict for several checks at once, so
  "the" verdict column is only meaningful once the list is narrowed to one.

  Costs nothing on an unfiltered list: no composite filter means no query.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadarWebNGWeb.CompositeChecks.Catalog, as: CompositeCatalog

  require Ash.Query

  @doc """
  `%{device_uid => %{verdict:, status:}}` for the check the query filters on.

  Returns `%{}` when the query names no composite check, when the slug does not
  resolve, or on any read failure — the column simply does not render, rather
  than the list failing to load over a supplementary detail.
  """
  @spec verdicts_by_device(term(), String.t() | nil, [map()]) :: map()
  def verdicts_by_device(scope, query, devices) do
    with slug when is_binary(slug) <- CompositeCatalog.filtered_slug(query),
         uids when uids != [] <- device_uids(devices),
         {:ok, check} <- CompositeCheck.get_by_slug(slug, scope: scope) do
      load(check, uids, scope)
    else
      _other -> %{}
    end
  rescue
    _exception -> %{}
  end

  defp load(check, uids, scope) do
    DeviceCompositeCheckResult
    |> Ash.Query.filter(check_id == ^check.id and device_uid in ^uids)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, results} ->
        Map.new(results, &{&1.device_uid, %{verdict: &1.verdict, status: &1.status}})

      {:error, _reason} ->
        %{}
    end
  end

  defp device_uids(devices) when is_list(devices) do
    devices
    |> Enum.filter(&is_map/1)
    |> Enum.map(&(Map.get(&1, "uid") || Map.get(&1, "id")))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp device_uids(_devices), do: []
end
