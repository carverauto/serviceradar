defmodule ServiceRadar.Analytics.StarRocks.Readers do
  @moduledoc """
  Dataset reader routing for StarRocks cutover.

  Ordinary installations stay on CNPG until a dataset is listed in
  `cutover_datasets`. Unknown consumers remain in the coverage inventory.
  """

  @flow_switched [
    "srql in:flows",
    "dashboard NetFlow map",
    "device flow tab",
    "observability netflow loaders",
    "exporter cache",
    "topology",
    "attribution",
    "threat queries"
  ]

  @flow_remaining []

  @metric_switched [
    "srql timeseries/cpu/memory/disk/process/snmp",
    "device charts",
    "ICMP sparklines",
    "thresholds",
    "anomaly/capacity",
    "topology nonnumeric facts"
  ]

  @metric_readers []

  @log_switched [
    "srql in:logs",
    "dashboard logs severity (SRQL)",
    "logs rollup status"
  ]

  @log_remaining []

  @event_switched [
    "srql in:events / security_findings / scan / dns activity",
    "dashboard event window",
    "dns-policy prefix tags",
    "anomaly ingest silence (2004 rows)"
  ]

  @event_remaining []

  @spec dataset_for_entity(String.t()) :: atom() | nil
  def dataset_for_entity(entity) when is_binary(entity) do
    case String.downcase(entity) do
      e
      when e in ~w(flows flow network_activity attributed_flows attributed_flow flow_attributions flow_attribution) ->
        :flows

      e
      when e in ~w(
             timeseries_metrics timeseries snmp_metrics snmp rperf_metrics rperf
             cpu_metrics cpu memory_metrics memory disk_metrics disk process_metrics processes
           ) ->
        :metrics

      "logs" ->
        :logs

      e when e in ~w(events activity security_findings scan_activity dns_activity) ->
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

  @spec switched_readers(atom()) :: [String.t()]
  def switched_readers(:flows), do: @flow_switched
  def switched_readers(:metrics), do: @metric_switched
  def switched_readers(:logs), do: @log_switched
  def switched_readers(:events), do: @event_switched
  def switched_readers(_dataset), do: []

  @spec remaining_readers(atom()) :: [String.t()]
  def remaining_readers(:flows), do: @flow_remaining
  def remaining_readers(:metrics), do: @metric_readers
  def remaining_readers(:logs), do: @log_remaining
  def remaining_readers(:events), do: @event_remaining
  def remaining_readers(_dataset), do: []

  defp cutover_datasets do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Analytics.StarRocks, [])
    |> Keyword.get(:cutover_datasets, [])
  end
end
