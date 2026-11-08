defmodule ServiceRadar.Edge.ContractRegistryTransition do
  @moduledoc """
  Runs the contract registry's epoch transition (`ServiceRadar.Edge.ContractRegistry`, see
  "Transition") on the cluster coordinator, every #{div(30_000, 1_000)} seconds.

  Each evaluation reads what the live components hold, fresh:

    * every connected node that runs a core node's registry process
      (`ServiceRadar.Edge.ContractRegistryNode`) reports its catalog digest
      (`ServiceRadar.Edge.ContractBundle.local/0`);
    * the live gateways are those any node's `ServiceRadar.GatewayTracker` lists as active, plus
      any gateway whose installation report arrived within the last two minutes, so a gateway
      the trackers do not list is still counted while it reports. Each must report holding the
      candidate.

  A connected node that cannot be asked blocks activation rather than being skipped: it may be a
  core node or gateway that does not hold the candidate. Activation is never forced on a timeout.

  `status/0` returns the last evaluation, which the Settings -> Cluster "Edge Pipeline" panel
  shows, naming every component that keeps a candidate from activating.
  """

  use GenServer

  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.ContractRegistryNode
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.GatewayTracker

  require Logger

  @interval_ms 30_000
  @rpc_timeout_ms 5_000
  @report_window_seconds 120

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The last evaluation on this node: `%{outcome: ..., evaluated_at: DateTime.t()}`, or nil when
  this node is not the coordinator or has not evaluated yet.
  """
  @spec status() :: map() | nil
  def status do
    case Process.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, :status, 1_000)
    end
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @interval_ms)
    {:ok, %{interval: interval, status: nil, last_outcome: nil}, {:continue, :evaluate}}
  end

  @impl true
  def handle_continue(:evaluate, state), do: {:noreply, evaluate(state)}

  @impl true
  def handle_info(:evaluate, state), do: {:noreply, evaluate(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  defp evaluate(state) do
    now = DateTime.utc_now()

    state =
      with {:ok, key} <- IssuerKey.configured(),
           {:ok, outcome} <- ContractRegistry.evaluate_transition(readiness(now), key, now) do
        log_change(state.last_outcome, outcome)
        %{state | status: %{outcome: outcome, evaluated_at: now}, last_outcome: outcome}
      else
        {:error, reason} ->
          Logger.warning("Edge contract registry transition not evaluated: #{inspect(reason)}")
          %{state | status: %{outcome: {:error, reason}, evaluated_at: now}}
      end

    Process.send_after(self(), :evaluate, state.interval)
    state
  rescue
    error ->
      Logger.warning("Edge contract registry transition failed: #{Exception.message(error)}")
      Process.send_after(self(), :evaluate, state.interval)
      state
  end

  @doc false
  # What the live components hold right now (see the moduledoc).
  @spec readiness(DateTime.t()) :: ContractRegistry.readiness()
  def readiness(now) do
    nodes = [node() | Node.list()]
    {core, core_unreachable} = core_nodes(nodes)
    {gateways, gateway_unreachable} = gateways(nodes, now)

    %{
      core_nodes: core,
      unreachable_nodes: Enum.uniq(core_unreachable ++ gateway_unreachable),
      gateways: gateways
    }
  end

  # `:erlang.whereis/1` and `ContractBundle.local/0` answer on every release that has a
  # registry, so a node on an older release is asked, not mistaken for one that cannot answer.
  defp core_nodes(nodes) do
    registry_pids =
      :erpc.multicall(nodes, :erlang, :whereis, [ContractRegistryNode], @rpc_timeout_ms)

    {cores, unreachable} =
      nodes
      |> Enum.zip(registry_pids)
      |> Enum.reduce({[], []}, fn
        {node, {:ok, pid}}, {cores, bad} when is_pid(pid) -> {[node | cores], bad}
        {_node, {:ok, :undefined}}, acc -> acc
        {node, _error}, {cores, bad} -> {cores, [to_string(node) | bad]}
      end)

    cores = Enum.reverse(cores)
    digests = :erpc.multicall(cores, ContractBundle, :local, [], @rpc_timeout_ms)

    cores
    |> Enum.zip(digests)
    |> Enum.reduce({[], Enum.reverse(unreachable)}, fn
      {node, {:ok, %{snapshot_sha256: digest}}}, {ok, bad} ->
        {ok ++ [%{node: to_string(node), snapshot_sha256: digest}], bad}

      {node, _error}, {ok, bad} ->
        {ok, bad ++ [to_string(node)]}
    end)
  end

  # A node without the tracker module runs no gateway and is skipped; any other failure blocks.
  defp gateways(nodes, now) do
    {tracked, unreachable} =
      nodes
      |> Enum.zip(:erpc.multicall(nodes, GatewayTracker, :list_gateways, [], @rpc_timeout_ms))
      |> Enum.reduce({[], []}, fn
        {_node, {:ok, list}}, {ids, bad} when is_list(list) ->
          {ids ++ for(%{gateway_id: id, active: true} <- list, do: id), bad}

        {_node, {:error, {:exception, :undef, [{GatewayTracker, _, _, _} | _]}}}, acc ->
          acc

        {node, _error}, {ids, bad} ->
          {ids, bad ++ [to_string(node)]}
      end)

    reports = Map.new(ContractRegistry.gateway_reports(), &{&1.gateway_id, &1})

    reporting =
      for {id, report} <- reports,
          DateTime.diff(now, report.received_at, :second) <= @report_window_seconds,
          do: id

    gateways =
      (tracked ++ reporting)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn id ->
        %{gateway_id: id, installed: reports |> Map.get(id) |> installed()}
      end)

    {gateways, unreachable}
  end

  defp installed(nil), do: nil
  defp installed(%{installed: installed}), do: installed

  defp log_change(same, same), do: :ok

  defp log_change(_previous, {:waiting, epoch, blockers}) do
    Logger.info(
      "Edge contract registry candidate #{epoch} is waiting: " <>
        Enum.map_join(blockers, "; ", &describe/1),
      registry_epoch: epoch
    )
  end

  defp log_change(_previous, _outcome), do: :ok

  @doc "A blocker as operators read it."
  @spec describe(ContractRegistry.blocker()) :: String.t()
  def describe({:core_node, node, :other_catalog}), do: "core node #{node} runs another catalog"
  def describe({:node_unreachable, node}), do: "node #{node} did not answer"
  def describe({:gateway, id, :no_report}), do: "gateway #{id} has not reported its registry"

  def describe({:gateway, id, :candidate_not_installed}),
    do: "gateway #{id} has not installed the candidate"

  def describe(:no_core_node), do: "no live core node reported its catalog"

  def describe({:candidate_signature_invalid, reason}),
    do: "the candidate's signature does not verify (#{reason})"
end
