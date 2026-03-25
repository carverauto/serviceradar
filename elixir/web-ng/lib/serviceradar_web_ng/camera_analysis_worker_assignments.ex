defmodule ServiceRadarWebNG.CameraAnalysisWorkerAssignments do
  @moduledoc """
  ERTS client for runtime-derived camera analysis worker assignment visibility
  owned by `core-elx`.
  """

  @default_rpc_timeout 3_000

  def assignment_snapshot(opts \\ []) do
    module = remote_manager_module()
    timeout = Keyword.get(opts, :rpc_timeout, @default_rpc_timeout)

    case core_elx_node(module, timeout) do
      nil ->
        %{}

      node ->
        case :rpc.call(node, module, :worker_assignment_snapshot, [], timeout) do
          snapshot when is_map(snapshot) -> snapshot
          _other -> %{}
        end
    end
  end

  defp core_elx_node(module, timeout) do
    Enum.find(rpc_nodes(), fn node ->
      case :rpc.call(node, Process, :whereis, [module], timeout) do
        pid when is_pid(pid) -> true
        _other -> false
      end
    end)
  end

  defp remote_manager_module do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_analysis_worker_assignment_remote_manager,
      Module.concat([ServiceRadarCoreElx, CameraRelay, AnalysisDispatchManager])
    )
  end

  defp rpc_nodes do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_analysis_worker_assignment_rpc_nodes,
      [Node.self() | Node.list()]
    )
  end
end
