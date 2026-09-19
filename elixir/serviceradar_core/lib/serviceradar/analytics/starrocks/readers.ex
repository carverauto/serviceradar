defmodule ServiceRadar.Analytics.StarRocks.Readers do
  @moduledoc """
  Dataset reader routing for StarRocks cutover.

  Ordinary installations stay on CNPG until a dataset is listed in
  `cutover_datasets`.

  An entity only maps to a dataset when the warehouse actually holds its rows.
  Every spelling the SRQL parser accepts for such an entity must be listed:
  routing happens on the raw entity string, so a missing alias silently serves
  one spelling from the warehouse and another from CNPG.
  """

  @spec dataset_for_entity(String.t()) :: atom() | nil
  def dataset_for_entity(entity) when is_binary(entity) do
    case String.downcase(entity) do
      e
      when e in ~w(flows flow network_activity attributed_flows attributed_flow flow_attributions flow_attribution) ->
        :flows

      e when e in ~w(timeseries_metrics timeseries snmp_metrics snmp rperf_metrics rperf) ->
        :metrics

      "logs" ->
        :logs

      e
      when e in ~w(
             events activity
             security_findings security_finding findings finding
             scan_activity scan_activities security_scans scanner_activity
             dns_activity dns_activities dns_security_activity powerdns pdns
           ) ->
        :events

      _ ->
        nil
    end
  end

  @spec mode_for(atom() | String.t() | nil) :: String.t() | nil
  def mode_for(nil), do: nil

  def mode_for(entity) when is_binary(entity), do: mode_for(dataset_for_entity(entity))

  def mode_for(dataset) when is_atom(dataset) do
    if dataset in cutover_datasets(), do: "starrocks"
  end

  @spec backend(atom() | String.t() | nil) :: :starrocks | :cnpg
  def backend(dataset) do
    case mode_for(dataset) do
      "starrocks" -> :starrocks
      _ -> :cnpg
    end
  end

  @spec fetch(atom() | String.t() | nil, %{cnpg: (-> result), starrocks: (-> result)}) :: result
        when result: term()
  def fetch(dataset, %{cnpg: cnpg, starrocks: starrocks})
      when is_function(cnpg, 0) and is_function(starrocks, 0) do
    case backend(dataset) do
      :starrocks -> starrocks.()
      :cnpg -> cnpg.()
    end
  end

  defp cutover_datasets do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Analytics.StarRocks, [])
    |> Keyword.get(:cutover_datasets, [])
  end
end
