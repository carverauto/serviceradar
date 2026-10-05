defmodule ServiceRadar.Ingestion.Admission do
  @moduledoc """
  Bounded status routing; payloads move only after a metadata reservation.

  Sweep group metadata is extracted producer-side before reservation. Core
  admission never decodes message payloads in coordinator callbacks, so sweep
  statuses arriving without prepared group metadata keep the conservative
  per-agent ordering key.
  """

  alias ServiceRadar.Admission.FlowLane
  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.Admission.RetainedPluginLane
  alias ServiceRadar.Ingestion.ResultIngestor
  alias ServiceRadar.Ingestion.StatusIngestor

  @core_budget_ms 15_000
  @retained_capability "plugin-result-retained:v1"

  def budget_ms, do: @core_budget_ms

  # Producer-side extraction keeps decoding out of dispatch callbacks. Unknown
  # or malformed group metadata retains the conservative per-agent ordering key.
  def prepare(%{source: source, service_type: type, message: message} = status)
      when source in ["results", :results] and type in ["sweep", :sweep] and is_binary(message) and
             byte_size(message) <= 16 * 1_024 * 1_024 do
    case Jason.decode(message) do
      {:ok, %{"sweep_group_id" => group}} when is_binary(group) and byte_size(group) in 1..255 ->
        Map.put(status, :sweep_group_id, group)

      _ ->
        Map.delete(status, :sweep_group_id)
    end
  end

  def prepare(status), do: status

  def reserve(%{headers: headers} = descriptor, owner, timeout) when is_map(headers) do
    case classify(headers) do
      :flow -> FlowLane.reserve(descriptor, owner, timeout)
      :retained_plugin -> RetainedPluginLane.reserve(descriptor, owner, timeout)
      type -> Lane.reserve(server(type), descriptor, owner, timeout)
    end
  end

  def reserve(_descriptor, _owner, _timeout), do: {:error, :invalid_admission_descriptor}

  def admit(status, reply_to) do
    descriptor = Lane.descriptor(status, @core_budget_ms)

    owner =
      case reply_to do
        {pid, _} -> pid
        _ -> self()
      end

    with {:ok, {lane, id}} <- reserve(descriptor, owner, 1_000) do
      Lane.submit(lane, id, status, reply_to)
    end
  end

  def ingest(status) do
    if retained?(status) do
      ResultIngestor.process_retained_plugin(status)
    else
      StatusIngestor.ingest(status, best_effort?: status[:ingestion_best_effort] == true)
    end
  end

  def classify(%{source: source}) when source in ["flow-attribution", :flow_attribution],
    do: :flow

  def classify(%{source: source} = headers) when source in ["plugin-result", :plugin_result] do
    if retained?(headers) and retained_enabled?(), do: :retained_plugin, else: :legacy_plugin
  end

  def classify(%{source: source, service_type: type}) when source in ["results", :results] do
    case type do
      type when type in ["sweep", :sweep] ->
        :sweep

      type
      when type in ["mapper_interfaces", :mapper_interfaces, "mapper_topology", :mapper_topology] ->
        :mapper

      type when type in ["bumblebee", :bumblebee] ->
        :bumblebee

      type when type in ["endpoint_inventory", :endpoint_inventory] ->
        :endpoint

      _ ->
        :other_results
    end
  end

  def classify(_), do: :status

  def server(type), do: {:via, Registry, {ServiceRadar.Ingestion.Registry, {:lane, type}}}

  defp retained?(%{source: source} = status) when source in ["plugin-result", :plugin_result],
    do: @retained_capability in (status[:delivery_capabilities] || [])

  defp retained?(_), do: false

  defp retained_enabled? do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.StatusHandler, [])
    |> Keyword.get(:retained_plugin_admission_enabled, true)
  end
end
