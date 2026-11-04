defmodule ServiceRadarAgentGateway.EdgeRecordTrustRefresh do
  @moduledoc """
  Refreshes the gateway's local edge trust, and the contract registry it carries, from core every
  five seconds. It always runs: core is the only trust source.

  Requests are serialized and bounded; ingest reads the installed snapshot directly. A snapshot
  expires thirty seconds after its request started, so a disconnected or stalled refresher
  cannot authorize indefinitely using an old fence. Failed fetches leave the last snapshot
  usable only until that deadline.

  Each refresh calls `ServiceRadar.Edge.RecordTrust.refresh/1` with this gateway's report of the
  registry it installed on the previous refresh (`EdgeRecordTrust.registry_report/1`): the epochs
  it holds and any it refused. Core's transition coordinator activates a candidate epoch only
  once every live gateway reports holding it, so the report is keyed by the id this gateway
  registers with `ServiceRadar.GatewayTracker`.
  """

  use GenServer

  alias ServiceRadar.Edge.RecordTrust
  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.CoreNodeForwarder
  alias ServiceRadarAgentGateway.EdgeRecordTrust

  require Logger

  @interval_ms 5_000
  @max_age_ms 30_000
  @rpc_timeout_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Fetches current trust immediately, for rollout readiness checks."
  def refresh_now(server \\ __MODULE__), do: GenServer.call(server, :refresh, 15_000)

  @impl true
  def init(:ok) do
    EdgeRecordTrust.clear()
    {:ok, nil, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state) do
    _ = refresh()
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state), do: {:reply, refresh(), state}

  @impl true
  def handle_info(:refresh, state) do
    _ = refresh()
    schedule()
    {:noreply, state}
  end

  defp refresh do
    expires_at = System.monotonic_time(:millisecond) + @max_age_ms

    with {:ok, document} <- fetch(EdgeRecordTrust.registry_report(Config.gateway_id())),
         :ok <- EdgeRecordTrust.install(document, expires_at) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("Edge record trust refresh failed: #{inspect(reason)}")
        error
    end
  end

  defp schedule, do: Process.send_after(self(), :refresh, @interval_ms)

  defp fetch(report) do
    core = CoreNodeForwarder.select_core_node("edge record trust")

    case :rpc.call(core, RecordTrust, :refresh, [report], @rpc_timeout_ms) do
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  rescue
    ArgumentError -> {:error, :core_unavailable}
  end
end
