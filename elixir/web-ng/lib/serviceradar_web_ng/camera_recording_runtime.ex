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
  @member_status_timeout_ms 2_500
  @member_status_rpc_timeout_ms 3_500
  @max_client_config_bytes 32_768
  @member_name_pattern ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @default_remote_supervisor Module.concat([ServiceRadarCoreElx, CameraRecording, Supervisor])
  @default_remote_member_status Module.concat([ServiceRadarCoreElx, CameraRecording, MemberStatus])

  @type gate_state :: :not_configured | :closed | :open
  @type gate_status :: %{
          state: gate_state(),
          generation: String.t() | nil
        }

  @type supervisor_state :: :enabled | :disabled | :unknown
  @type nvr_installation_state :: :installed | :not_installed | :invalid_config | :unknown

  @type nvr_member :: %{
          member: String.t(),
          storage_id: String.t()
        }

  @type core_elx_status :: %{
          reachability: :reachable | :unreachable,
          node: node() | nil,
          supervisor: supervisor_state(),
          nvr_installation: nvr_installation_state(),
          members: [nvr_member()]
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
        {nvr_installation, members} = inspect_nvr_installation_and_members(node, timeout)

        %{
          reachability: :reachable,
          node: node,
          supervisor: inspect_supervisor_enabled(node, supervisor_module, timeout),
          nvr_installation: nvr_installation,
          members: members
        }

      {:error, :unreachable} ->
        %{
          reachability: :unreachable,
          node: nil,
          supervisor: :unknown,
          nvr_installation: :unknown,
          members: []
        }
    end
  end

  @doc """
  Fetches live `GET /v1/status` reports for configured NVR members via bounded
  RPC to `core-elx` (which holds the ingest listener credentials).

  Never raises and never blocks longer than the bounded status RPC timeout;
  returns `%{}` when `core-elx` is unreachable, NVR is not installed, or no
  member answers.
  """
  @spec member_statuses(status() | map() | nil) :: %{optional(String.t()) => map()}
  def member_statuses(runtime \\ nil)

  def member_statuses(%{core_elx: %{reachability: :reachable, nvr_installation: :installed, node: node}})
      when is_atom(node) and not is_nil(node) do
    fetch_remote_member_statuses(node)
  end

  def member_statuses(nil) do
    case find_supervisor_node(remote_supervisor(), rpc_timeout_ms()) do
      {:ok, node} -> fetch_remote_member_statuses(node)
      {:error, :unreachable} -> %{}
    end
  end

  def member_statuses(_runtime), do: %{}

  defp fetch_remote_member_statuses(node) do
    if node == Node.self() or node in Node.list() do
      status_timeout = member_status_timeout_ms()
      rpc_timeout = member_status_rpc_timeout_ms()

      case :rpc.call(
             node,
             remote_member_status_module(),
             :fetch_all,
             [[timeout_ms: status_timeout]],
             rpc_timeout
           ) do
        %{} = statuses -> statuses
        _ -> %{}
      end
    else
      %{}
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

  defp inspect_nvr_installation_and_members(node, timeout) do
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

    installation = classify_nvr_installation(config_file, token_file)

    members =
      if installation == :installed do
        read_configured_members(node, config_file, timeout)
      else
        []
      end

    {installation, members}
  end

  defp read_configured_members(node, config_file, timeout) when is_binary(config_file) do
    with {:ok, %File.Stat{type: :regular, size: size}}
         when is_integer(size) and size >= 0 and size <= @max_client_config_bytes <-
           :rpc.call(node, File, :stat, [config_file], timeout),
         {:ok, bytes}
         when is_binary(bytes) and byte_size(bytes) <= @max_client_config_bytes <-
           :rpc.call(node, File, :read, [config_file], timeout),
         {:ok, %{"members" => raw_members}} when is_map(raw_members) <- Jason.decode(bytes) do
      raw_members
      |> Enum.flat_map(&parse_member_entry/1)
      |> Enum.sort_by(& &1.member)
    else
      _ -> []
    end
  end

  defp parse_member_entry({name, %{"storage_id" => raw_storage_id}}) when is_binary(name) and is_binary(raw_storage_id) do
    trimmed_sid = String.trim(raw_storage_id)

    with true <- Regex.match?(@member_name_pattern, name),
         36 <- byte_size(trimmed_sid),
         {:ok, normalized_sid} <- Ecto.UUID.cast(trimmed_sid) do
      [%{member: name, storage_id: normalized_sid}]
    else
      _ -> []
    end
  end

  defp parse_member_entry(_entry), do: []

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

  defp remote_member_status_module do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_recording_remote_member_status,
      @default_remote_member_status
    )
  end

  defp member_status_timeout_ms do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_recording_member_status_timeout_ms,
      @member_status_timeout_ms
    )
  end

  defp member_status_rpc_timeout_ms do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_recording_member_status_rpc_timeout_ms,
      @member_status_rpc_timeout_ms
    )
  end

  defp rpc_timeout_ms do
    Application.get_env(:serviceradar_web_ng, :camera_recording_rpc_timeout_ms, @rpc_timeout_ms)
  end
end
