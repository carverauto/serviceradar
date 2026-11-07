defmodule ServiceRadar.Edge.SweepServiceState do
  @moduledoc """
  The `sweep`/`network_sweep` service state an agent's sweep edge records report, shared by the
  unleased (`ServiceRadar.Edge.Projectors.UnleasedSweepResults`) and leased
  (`ServiceRadar.Edge.Projectors.SweepObservation`) sweep projectors.

  Before the edge-record cutover the agent's `results` status kept this service state current.
  Each projected sweep batch is now the agent's report that its sweep service ran, so both
  projectors build the status here and record it through
  `ServiceRadar.Ingestion.ResultIngestor.publish_service_state/2`, the writer the legacy results
  path used. The gateway id is the publishing gateway's `Sr-Edge-Gateway-Id` header, else the
  agent's gateway; neither is taken from the record body.
  """

  alias ServiceRadar.Infrastructure.Agent

  @service_name "network_sweep"
  @service_type "sweep"

  @doc """
  The gateway a sweep record's service state belongs to: the publishing gateway's header, else
  the agent's gateway column, else `{:error, {:refused, :gateway_unknown}}`.
  """
  @spec gateway(module(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, {:refused, :gateway_unknown}}
  def gateway(_repo, _agent_id, header) when is_binary(header) and header != "", do: {:ok, header}

  def gateway(repo, agent_id, _header) do
    case repo.get(Agent, agent_id) do
      %Agent{gateway_id: gateway_id} when is_binary(gateway_id) and gateway_id != "" ->
        {:ok, gateway_id}

      _ ->
        {:error, {:refused, :gateway_unknown}}
    end
  end

  @doc """
  The `results` status of the agent's sweep service, carrying `message` and observed at
  `observed_at` (unix seconds or a `DateTime`), as the gateway built it from the agent's results.
  """
  @spec status(String.t(), String.t(), String.t(), String.t(), integer() | DateTime.t()) :: map()
  def status(agent_id, gateway_id, partition, message, observed_at) do
    %{
      service_name: @service_name,
      service_type: @service_type,
      available: true,
      message: message,
      response_time: 0,
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: partition,
      authenticated_partition: partition,
      source: "results",
      kv_store_id: "",
      timestamp: System.os_time(:second),
      agent_timestamp: observed_at
    }
  end
end
