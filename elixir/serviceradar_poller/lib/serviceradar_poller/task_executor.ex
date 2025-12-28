defmodule ServiceRadarPoller.TaskExecutor do
  @moduledoc """
  GenServer for executing polling tasks from the core cluster.

  This module receives polling task requests from the core and executes them
  using the appropriate check executor (ICMP, TCP, HTTP, SNMP, etc.).

  ## Task Flow

  1. Core sends task via `:execute_task` call
  2. TaskExecutor spawns a supervised task to execute the check
  3. Results are sent back to the calling process or core cluster

  ## Supported Check Types

  ### Local Checks (executed directly by poller)
  - `:icmp` - ICMP ping check
  - `:tcp` - TCP port check
  - `:http` - HTTP/HTTPS health check
  - `:dns` - DNS resolution check

  ### Agent-Delegated Checks (via gRPC to Go agents)
  - `:agent_status` - Agent health check
  - `:agent_sweep` - Network sweep via agent
  - `:snmp` - SNMP polling via agent
  - `:wmi` - Windows WMI polling via agent

  Agent-delegated checks require a `tenant_id` and `agent_id` in the task config.
  The poller will connect to the agent via gRPC to execute these checks.
  """

  use GenServer

  require Logger

  @check_timeout :timer.seconds(30)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Execute a polling task asynchronously.

  Returns `{:ok, ref}` immediately, results are sent to the caller's mailbox.
  """
  @spec execute_async(map()) :: {:ok, reference()}
  def execute_async(task) do
    GenServer.call(__MODULE__, {:execute_async, task})
  end

  @doc """
  Execute a polling task synchronously.

  Returns the check result or `{:error, reason}`.
  """
  @spec execute(map()) :: {:ok, map()} | {:error, term()}
  def execute(task) do
    GenServer.call(__MODULE__, {:execute, task}, @check_timeout)
  end

  @doc """
  Get the current executor status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    state = %{
      active_tasks: %{},
      completed_count: 0,
      error_count: 0,
      started_at: DateTime.utc_now()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute_async, task}, {from_pid, _tag}, state) do
    ref = make_ref()

    task_pid =
      spawn_link(fn ->
        result = do_execute_task(task)
        send(from_pid, {:task_result, ref, result})
      end)

    new_active = Map.put(state.active_tasks, ref, %{task: task, pid: task_pid, started_at: DateTime.utc_now()})

    {:reply, {:ok, ref}, %{state | active_tasks: new_active}}
  end

  @impl true
  def handle_call({:execute, task}, _from, state) do
    result = do_execute_task(task)

    new_state =
      case result do
        {:ok, _} -> %{state | completed_count: state.completed_count + 1}
        {:error, _} -> %{state | error_count: state.error_count + 1}
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      active_tasks: map_size(state.active_tasks),
      completed_count: state.completed_count,
      error_count: state.error_count,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if Map.has_key?(state.active_tasks, ref) do
      Logger.warning("Task #{inspect(ref)} exited: #{inspect(reason)}")
      {:noreply, %{state | active_tasks: Map.delete(state.active_tasks, ref), error_count: state.error_count + 1}}
    else
      {:noreply, state}
    end
  end

  # Task execution

  defp do_execute_task(task) do
    check_type = task[:type] || task["type"]
    target = task[:target] || task["target"]
    config = task[:config] || task["config"] || %{}

    Logger.debug("Executing #{check_type} check on #{target}")

    case check_type do
      # Local checks (executed directly by poller)
      :icmp -> execute_icmp_check(target, config)
      "icmp" -> execute_icmp_check(target, config)
      :tcp -> execute_tcp_check(target, config)
      "tcp" -> execute_tcp_check(target, config)
      :http -> execute_http_check(target, config)
      "http" -> execute_http_check(target, config)
      :dns -> execute_dns_check(target, config)
      "dns" -> execute_dns_check(target, config)
      # Agent-delegated checks (via gRPC to Go agents)
      :agent_status -> execute_agent_status_check(config)
      "agent_status" -> execute_agent_status_check(config)
      :agent_sweep -> execute_agent_sweep(config)
      "agent_sweep" -> execute_agent_sweep(config)
      :snmp -> execute_agent_delegated_check(config, "snmp")
      "snmp" -> execute_agent_delegated_check(config, "snmp")
      :wmi -> execute_agent_delegated_check(config, "wmi")
      "wmi" -> execute_agent_delegated_check(config, "wmi")
      _ -> {:error, {:unsupported_check_type, check_type}}
    end
  rescue
    e ->
      Logger.error("Task execution failed: #{inspect(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  # Agent-delegated check implementations

  defp execute_agent_status_check(config) do
    tenant_id = config[:tenant_id] || config["tenant_id"]
    agent_id = config[:agent_id] || config["agent_id"]

    unless tenant_id && agent_id do
      {:error, :missing_tenant_or_agent_id}
    else
      case ServiceRadarPoller.AgentClient.get_status(tenant_id, agent_id, %{}) do
        {:ok, status} ->
          {:ok, %{
            status: if(status.available, do: :up, else: :down),
            check_type: :agent_status,
            agent_id: agent_id,
            message: status.message,
            response_time_ms: status.response_time,
            timestamp: DateTime.utc_now()
          }}

        {:error, reason} ->
          {:ok, %{
            status: :down,
            check_type: :agent_status,
            agent_id: agent_id,
            error: inspect(reason),
            timestamp: DateTime.utc_now()
          }}
      end
    end
  end

  defp execute_agent_sweep(config) do
    tenant_id = config[:tenant_id] || config["tenant_id"]
    agent_id = config[:agent_id] || config["agent_id"]
    service_type = config[:service_type] || config["service_type"] || "icmp_sweep"
    last_sequence = config[:last_sequence] || config["last_sequence"]

    unless tenant_id && agent_id do
      {:error, :missing_tenant_or_agent_id}
    else
      opts = %{
        service_type: service_type,
        last_sequence: last_sequence || ""
      }

      case ServiceRadarPoller.AgentClient.get_results(tenant_id, agent_id, opts) do
        {:ok, results} ->
          {:ok, %{
            status: if(results.available, do: :up, else: :down),
            check_type: :agent_sweep,
            agent_id: agent_id,
            service_type: results.service_type,
            data: results.data,
            has_new_data: results.has_new_data,
            current_sequence: results.current_sequence,
            response_time_ms: results.response_time,
            timestamp: DateTime.utc_now()
          }}

        {:error, reason} ->
          {:ok, %{
            status: :down,
            check_type: :agent_sweep,
            agent_id: agent_id,
            error: inspect(reason),
            timestamp: DateTime.utc_now()
          }}
      end
    end
  end

  defp execute_agent_delegated_check(config, service_type) do
    tenant_id = config[:tenant_id] || config["tenant_id"]
    agent_id = config[:agent_id] || config["agent_id"]
    service_name = config[:service_name] || config["service_name"]

    unless tenant_id && agent_id do
      {:error, :missing_tenant_or_agent_id}
    else
      opts = %{
        service_type: service_type,
        service_name: service_name || ""
      }

      case ServiceRadarPoller.AgentClient.get_status(tenant_id, agent_id, opts) do
        {:ok, status} ->
          {:ok, %{
            status: if(status.available, do: :up, else: :down),
            check_type: String.to_atom(service_type),
            agent_id: agent_id,
            service_name: status.service_name,
            message: status.message,
            response_time_ms: status.response_time,
            timestamp: DateTime.utc_now()
          }}

        {:error, reason} ->
          {:ok, %{
            status: :down,
            check_type: String.to_atom(service_type),
            agent_id: agent_id,
            error: inspect(reason),
            timestamp: DateTime.utc_now()
          }}
      end
    end
  end

  defp execute_icmp_check(target, config) do
    count = config[:count] || config["count"] || 1
    timeout = config[:timeout] || config["timeout"] || 5000

    # Use gen_icmp or shell out to ping
    case System.cmd("ping", ["-c", to_string(count), "-W", to_string(div(timeout, 1000)), target], stderr_to_stdout: true) do
      {output, 0} ->
        rtt = parse_ping_rtt(output)

        {:ok,
         %{
           status: :up,
           target: target,
           check_type: :icmp,
           response_time_ms: rtt,
           timestamp: DateTime.utc_now()
         }}

      {output, _exit_code} ->
        {:ok,
         %{
           status: :down,
           target: target,
           check_type: :icmp,
           error: String.trim(output),
           timestamp: DateTime.utc_now()
         }}
    end
  end

  defp execute_tcp_check(target, config) do
    port = config[:port] || config["port"] || 80
    timeout = config[:timeout] || config["timeout"] || 5000

    start_time = System.monotonic_time(:millisecond)

    result =
      case :gen_tcp.connect(String.to_charlist(target), port, [:binary, active: false], timeout) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          elapsed = System.monotonic_time(:millisecond) - start_time

          {:ok,
           %{
             status: :up,
             target: target,
             port: port,
             check_type: :tcp,
             response_time_ms: elapsed,
             timestamp: DateTime.utc_now()
           }}

        {:error, reason} ->
          {:ok,
           %{
             status: :down,
             target: target,
             port: port,
             check_type: :tcp,
             error: inspect(reason),
             timestamp: DateTime.utc_now()
           }}
      end

    result
  end

  defp execute_http_check(target, config) do
    url = build_url(target, config)
    timeout = config[:timeout] || config["timeout"] || 10_000
    expected_status = config[:expected_status] || config["expected_status"] || 200

    start_time = System.monotonic_time(:millisecond)

    case Req.get(url, receive_timeout: timeout, connect_options: [timeout: timeout]) do
      {:ok, %{status: status}} ->
        elapsed = System.monotonic_time(:millisecond) - start_time

        result_status = if status == expected_status, do: :up, else: :degraded

        {:ok,
         %{
           status: result_status,
           target: target,
           url: url,
           check_type: :http,
           http_status: status,
           response_time_ms: elapsed,
           timestamp: DateTime.utc_now()
         }}

      {:error, reason} ->
        {:ok,
         %{
           status: :down,
           target: target,
           url: url,
           check_type: :http,
           error: inspect(reason),
           timestamp: DateTime.utc_now()
         }}
    end
  end

  defp execute_dns_check(target, config) do
    record_type = config[:record_type] || config["record_type"] || :a
    timeout = config[:timeout] || config["timeout"] || 5000

    start_time = System.monotonic_time(:millisecond)

    case :inet_res.lookup(String.to_charlist(target), :in, record_type, timeout: timeout) do
      [] ->
        {:ok,
         %{
           status: :down,
           target: target,
           check_type: :dns,
           error: "no records found",
           timestamp: DateTime.utc_now()
         }}

      records when is_list(records) ->
        elapsed = System.monotonic_time(:millisecond) - start_time

        {:ok,
         %{
           status: :up,
           target: target,
           check_type: :dns,
           records: Enum.map(records, &:inet.ntoa/1) |> Enum.map(&to_string/1),
           response_time_ms: elapsed,
           timestamp: DateTime.utc_now()
         }}
    end
  end

  defp build_url(target, config) do
    scheme = config[:scheme] || config["scheme"] || "http"
    port = config[:port] || config["port"]
    path = config[:path] || config["path"] || "/"

    port_part = if port, do: ":#{port}", else: ""
    "#{scheme}://#{target}#{port_part}#{path}"
  end

  defp parse_ping_rtt(output) do
    # Parse "time=X.XXX ms" from ping output
    case Regex.run(~r/time[=<](\d+\.?\d*)\s*ms/, output) do
      [_, rtt] -> String.to_float(rtt)
      nil -> nil
    end
  end
end
