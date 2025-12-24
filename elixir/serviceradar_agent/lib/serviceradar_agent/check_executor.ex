defmodule ServiceRadarAgent.CheckExecutor do
  @moduledoc """
  Executes monitoring checks locally or via gRPC to external checkers.

  This module handles running checks assigned to this agent and
  reporting results back to the poller via ERTS messaging.

  ## Check Types

  - **Local checks**: Run directly by the agent (ping, process, port)
  - **gRPC checks**: Delegated to external checkers (SNMP, WMI, disk)

  ## Usage

      # Execute a check synchronously
      {:ok, result} = ServiceRadarAgent.CheckExecutor.execute(check)

      # Execute a check asynchronously (result sent to caller)
      {:ok, ref} = ServiceRadarAgent.CheckExecutor.execute_async(check)
  """

  use GenServer

  require Logger

  @check_timeout :timer.seconds(30)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Execute a check synchronously.
  """
  @spec execute(map()) :: {:ok, map()} | {:error, term()}
  def execute(check) do
    GenServer.call(__MODULE__, {:execute, check}, @check_timeout)
  end

  @doc """
  Execute a check asynchronously.

  Returns `{:ok, ref}` immediately, results are sent to the caller's mailbox.
  """
  @spec execute_async(map()) :: {:ok, reference()}
  def execute_async(check) do
    GenServer.call(__MODULE__, {:execute_async, check})
  end

  @doc """
  Get executor status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    state = %{
      active_checks: %{},
      completed_count: 0,
      error_count: 0,
      started_at: DateTime.utc_now()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, check}, _from, state) do
    result = do_execute(check)

    new_state =
      case result do
        {:ok, _} -> %{state | completed_count: state.completed_count + 1}
        {:error, _} -> %{state | error_count: state.error_count + 1}
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:execute_async, check}, {from_pid, _tag}, state) do
    ref = make_ref()

    _task_pid =
      spawn_link(fn ->
        result = do_execute(check)
        send(from_pid, {:check_result, ref, result})
      end)

    {:reply, {:ok, ref}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      active_checks: map_size(state.active_checks),
      completed_count: state.completed_count,
      error_count: state.error_count,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at)
    }

    {:reply, status, state}
  end

  # Check execution

  defp do_execute(check) do
    check_type = check[:type] || check["type"]
    target = check[:target] || check["target"]
    config = check[:config] || check["config"] || %{}

    Logger.debug("Executing #{check_type} check on #{target}")

    case check_type do
      # Local checks
      t when t in [:ping, "ping"] -> execute_ping(target, config)
      t when t in [:process, "process"] -> execute_process_check(target, config)
      t when t in [:port, "port"] -> execute_port_check(target, config)
      t when t in [:disk, "disk"] -> execute_disk_check(target, config)

      # gRPC checks (delegated to external checkers)
      t when t in [:snmp, "snmp"] -> execute_grpc_check(:snmp, target, config)
      t when t in [:wmi, "wmi"] -> execute_grpc_check(:wmi, target, config)
      t when t in [:sweep, "sweep"] -> execute_grpc_check(:sweep, target, config)

      _ ->
        {:error, {:unsupported_check_type, check_type}}
    end
  rescue
    e ->
      Logger.error("Check execution failed: #{inspect(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  # Local check implementations

  defp execute_ping(target, config) do
    count = config[:count] || config["count"] || 1
    timeout = config[:timeout] || config["timeout"] || 5000

    case System.cmd("ping", ["-c", to_string(count), "-W", to_string(div(timeout, 1000)), target],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        rtt = parse_ping_rtt(output)

        {:ok,
         %{
           status: :up,
           target: target,
           check_type: :ping,
           response_time_ms: rtt,
           timestamp: DateTime.utc_now()
         }}

      {output, _exit_code} ->
        {:ok,
         %{
           status: :down,
           target: target,
           check_type: :ping,
           error: String.trim(output),
           timestamp: DateTime.utc_now()
         }}
    end
  end

  defp execute_process_check(process_name, config) do
    timeout = config[:timeout] || config["timeout"] || 5000

    case System.cmd("pgrep", ["-x", process_name], stderr_to_stdout: true) do
      {output, 0} ->
        pids = output |> String.split("\n", trim: true) |> length()

        {:ok,
         %{
           status: :up,
           target: process_name,
           check_type: :process,
           process_count: pids,
           timestamp: DateTime.utc_now()
         }}

      {_, _} ->
        {:ok,
         %{
           status: :down,
           target: process_name,
           check_type: :process,
           error: "process not found",
           timestamp: DateTime.utc_now()
         }}
    end
  end

  defp execute_port_check(target, config) do
    port = config[:port] || config["port"] || 80
    timeout = config[:timeout] || config["timeout"] || 5000

    start_time = System.monotonic_time(:millisecond)

    case :gen_tcp.connect(String.to_charlist(target), port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        elapsed = System.monotonic_time(:millisecond) - start_time

        {:ok,
         %{
           status: :up,
           target: target,
           port: port,
           check_type: :port,
           response_time_ms: elapsed,
           timestamp: DateTime.utc_now()
         }}

      {:error, reason} ->
        {:ok,
         %{
           status: :down,
           target: target,
           port: port,
           check_type: :port,
           error: inspect(reason),
           timestamp: DateTime.utc_now()
         }}
    end
  end

  defp execute_disk_check(mount_point, config) do
    warning_threshold = config[:warning_threshold] || config["warning_threshold"] || 80
    critical_threshold = config[:critical_threshold] || config["critical_threshold"] || 90

    case System.cmd("df", ["-P", mount_point], stderr_to_stdout: true) do
      {output, 0} ->
        # Parse df output: Filesystem 1024-blocks Used Available Capacity Mounted
        lines = String.split(output, "\n", trim: true)

        if length(lines) >= 2 do
          [_fs, _blocks, _used, _avail, capacity_str, _mounted] =
            lines |> Enum.at(1) |> String.split(~r/\s+/, trim: true)

          capacity = String.trim_trailing(capacity_str, "%") |> String.to_integer()

          status =
            cond do
              capacity >= critical_threshold -> :critical
              capacity >= warning_threshold -> :warning
              true -> :up
            end

          {:ok,
           %{
             status: status,
             target: mount_point,
             check_type: :disk,
             usage_percent: capacity,
             timestamp: DateTime.utc_now()
           }}
        else
          {:error, :parse_error}
        end

      {output, _} ->
        {:ok,
         %{
           status: :unknown,
           target: mount_point,
           check_type: :disk,
           error: String.trim(output),
           timestamp: DateTime.utc_now()
         }}
    end
  end

  # gRPC check (delegated to external checkers via CheckerPool)
  defp execute_grpc_check(checker_type, target, config) do
    case ServiceRadarAgent.CheckerPool.execute(checker_type, target, config) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:grpc_error, reason}}
    end
  end

  defp parse_ping_rtt(output) do
    case Regex.run(~r/time[=<](\d+\.?\d*)\s*ms/, output) do
      [_, rtt] -> String.to_float(rtt)
      nil -> nil
    end
  end
end
