defmodule ServiceRadarWebNG.CameraRecordingRuntime do
  @moduledoc """
  Inspects camera recording installation, `core-elx` reachability, and the
  local deployment recovery gate without touching NVR media or bearer secrets.

  `web-ng` never contacts an NVR directly and never modifies the deployment
  recovery gate. An unreachable or refusing `core-elx` node is reported as
  `:unknown`, never as `:not_installed` or empty.
  """

  alias ServiceRadarRecordingControl.RecoveryGate

  @rpc_timeout_ms 5_000
  @default_remote_supervisor Module.concat([ServiceRadarCoreElx, CameraRecording, Supervisor])

  @type gate_state :: :not_configured | :closed | :open
  @type gate_status :: %{
          state: gate_state(),
          generation: String.t() | nil
        }

  @type supervisor_state :: :enabled | :disabled | :unknown
  @type nvr_installation_state :: :installed | :not_installed | :invalid_config | :unknown

  @type core_elx_status :: %{
          reachability: :reachable | :unreachable,
          node: node() | nil,
          supervisor: supervisor_state(),
          nvr_installation: nvr_installation_state()
        }

  @type status :: %{
          recovery_gate: gate_status(),
          core_elx: core_elx_status()
        }

  @doc """
  Returns the current local Core recovery gate status and `core-elx` recording
  runtime inspection state.
  """
  @spec status() :: status()
  def status do
    %{
      recovery_gate: recovery_gate_status(),
      core_elx: core_elx_status()
    }
  end

  @doc """
  Evaluates the local Core deployment recovery gate configured on
  `:serviceradar_core`, `:nvr_recovery_gate`.

  Distinguishes `nil` (`:not_configured`) from a configured gate whose ready
  state file check fails (`:closed`).
  """
  @spec recovery_gate_status() :: gate_status()
  def recovery_gate_status do
    case Application.get_env(:serviceradar_core, :nvr_recovery_gate) do
      nil ->
        %{state: :not_configured, generation: nil}

      %{generation: generation} = gate when is_binary(generation) ->
        case RecoveryGate.check(gate) do
          :ok -> %{state: :open, generation: generation}
          {:error, _reason} -> %{state: :closed, generation: generation}
        end

      _invalid ->
        %{state: :closed, generation: nil}
    end
  end

  @doc """
  Inspects `core-elx` camera recording supervisor and NVR client installation
  over bounded `:rpc.call/5`.
  """
  @spec core_elx_status() :: core_elx_status()
  def core_elx_status do
    supervisor_module = remote_supervisor()
    timeout = rpc_timeout_ms()

    case find_supervisor_node(supervisor_module, timeout) do
      {:ok, node} ->
        %{
          reachability: :reachable,
          node: node,
          supervisor: inspect_supervisor_enabled(node, supervisor_module, timeout),
          nvr_installation: inspect_nvr_installation(node, timeout)
        }

      {:error, :unreachable} ->
        %{
          reachability: :unreachable,
          node: nil,
          supervisor: :unknown,
          nvr_installation: :unknown
        }
    end
  end

  defp find_supervisor_node(supervisor_module, timeout) do
    Enum.find_value(rpc_nodes(), {:error, :unreachable}, fn node ->
      case :rpc.call(node, Process, :whereis, [supervisor_module], timeout) do
        pid when is_pid(pid) -> {:ok, node}
        _ -> nil
      end
    end)
  end

  defp inspect_supervisor_enabled(node, supervisor_module, timeout) do
    case :rpc.call(node, supervisor_module, :enabled?, [], timeout) do
      true -> :enabled
      false -> :disabled
      _ -> :unknown
    end
  end

  defp inspect_nvr_installation(node, timeout) do
    config_file =
      :rpc.call(
        node,
        Application,
        :get_env,
        [:serviceradar_core_elx, :camera_nvr_client_config_file],
        timeout
      )

    token_file =
      :rpc.call(
        node,
        Application,
        :get_env,
        [:serviceradar_core_elx, :camera_nvr_client_token_file],
        timeout
      )

    classify_nvr_installation(config_file, token_file)
  end

  defp classify_nvr_installation({:badrpc, _}, _token_file), do: :unknown
  defp classify_nvr_installation(_config_file, {:badrpc, _}), do: :unknown

  defp classify_nvr_installation(cfg, tok) when cfg in [nil, ""] and tok in [nil, ""] do
    :not_installed
  end

  defp classify_nvr_installation(cfg, tok) when is_binary(cfg) and is_binary(tok) do
    if cfg != "" and tok != "" and Path.type(cfg) == :absolute and Path.type(tok) == :absolute do
      :installed
    else
      :invalid_config
    end
  end

  defp classify_nvr_installation(_cfg, _tok), do: :invalid_config

  defp remote_supervisor do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_recording_remote_supervisor,
      @default_remote_supervisor
    )
  end

  defp rpc_nodes do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_recording_rpc_nodes,
      [Node.self() | Node.list()]
    )
  end

  defp rpc_timeout_ms do
    Application.get_env(:serviceradar_web_ng, :camera_recording_rpc_timeout_ms, @rpc_timeout_ms)
  end
end
