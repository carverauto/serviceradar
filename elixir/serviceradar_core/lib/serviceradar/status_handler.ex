defmodule ServiceRadar.StatusHandler do
  @moduledoc "Routes status reservations to their lanes; ingestion runs in bounded workers."
  use GenServer

  alias ServiceRadar.Ingestion.Admission
  alias ServiceRadar.Ingestion.StatusIngestor

  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  defdelegate process_flow_attribution(status), to: StatusIngestor
  defdelegate emit_flow_attribution_committed(metadata), to: StatusIngestor

  def admission_protocol, do: :reserved_v1

  @impl true
  def init(state), do: {:ok, state}

  # Every gateway reservation passes through this one process, so it only
  # routes: the lane answers the gateway directly. Waiting here for a lane's
  # reply would make each reservation queue behind the slowest lane's answer.
  @impl true
  def handle_call({:reserve_status, descriptor}, from, state) do
    case Admission.forward_reserve(descriptor, from) do
      :ok -> {:noreply, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:status_update, status}, from, state) do
    case Admission.admit(status, from) do
      :ok -> {:noreply, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_cast({:status_update, status}, state) do
    case Admission.admit(status, nil) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Status admission rejected: #{inspect(reason)}")
    end

    {:noreply, state}
  end
end
