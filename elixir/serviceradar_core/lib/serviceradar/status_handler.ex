defmodule ServiceRadar.StatusHandler do
  @moduledoc "Classifies and reserves statuses; ingestion runs in bounded workers."
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

  @impl true
  def handle_call({:reserve_status, descriptor}, from, state) do
    {:reply, Admission.reserve(descriptor, elem(from, 0), 1_000), state}
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
