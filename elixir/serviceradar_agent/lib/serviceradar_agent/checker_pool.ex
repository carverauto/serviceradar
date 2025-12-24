defmodule ServiceRadarAgent.CheckerPool do
  @moduledoc """
  Manages connections to external checker processes via gRPC.

  External checkers are Go/Rust processes that handle specific check types
  that require native system access or specialized libraries (SNMP, WMI, etc.).

  ## Configuration

  Checkers are configured via environment variables:

  - `CHECKER_SNMP_ADDR` - Address of SNMP checker (default: localhost:50052)
  - `CHECKER_WMI_ADDR` - Address of WMI checker (default: localhost:50053)
  - `CHECKER_SWEEP_ADDR` - Address of sweep checker (default: localhost:50054)

  ## Usage

      # Execute a check via gRPC
      {:ok, result} = ServiceRadarAgent.CheckerPool.execute(:snmp, "192.168.1.1", %{oid: ".1.3.6.1.2.1.1.1.0"})
  """

  use GenServer

  require Logger

  @default_timeout :timer.seconds(30)

  @checker_defaults %{
    snmp: "localhost:50052",
    wmi: "localhost:50053",
    sweep: "localhost:50054"
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Execute a check via the specified checker.
  """
  @spec execute(atom(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def execute(checker_type, target, config) do
    GenServer.call(__MODULE__, {:execute, checker_type, target, config}, @default_timeout)
  end

  @doc """
  Get the status of all checker connections.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Get the address for a checker type.
  """
  @spec checker_address(atom()) :: String.t()
  def checker_address(checker_type) do
    GenServer.call(__MODULE__, {:address, checker_type})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Load checker addresses from environment
    checkers = %{
      snmp: System.get_env("CHECKER_SNMP_ADDR", @checker_defaults.snmp),
      wmi: System.get_env("CHECKER_WMI_ADDR", @checker_defaults.wmi),
      sweep: System.get_env("CHECKER_SWEEP_ADDR", @checker_defaults.sweep)
    }

    state = %{
      checkers: checkers,
      channels: %{},
      stats: %{
        requests: 0,
        errors: 0,
        last_request: nil
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, checker_type, target, config}, _from, state) do
    addr = Map.get(state.checkers, checker_type)

    if addr do
      result = do_grpc_call(checker_type, addr, target, config)

      new_stats = %{
        state.stats
        | requests: state.stats.requests + 1,
          errors:
            case result do
              {:error, _} -> state.stats.errors + 1
              _ -> state.stats.errors
            end,
          last_request: DateTime.utc_now()
      }

      {:reply, result, %{state | stats: new_stats}}
    else
      {:reply, {:error, {:unknown_checker, checker_type}}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      checkers: state.checkers,
      stats: state.stats
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:address, checker_type}, _from, state) do
    {:reply, Map.get(state.checkers, checker_type), state}
  end

  # gRPC call implementation
  # Note: This is a simplified implementation. In production, you would use
  # generated protobuf modules from monitoring.proto

  defp do_grpc_call(checker_type, addr, target, config) do
    Logger.debug("Calling #{checker_type} checker at #{addr} for target #{target}")

    # Parse address
    [host, port_str] = String.split(addr, ":")
    port = String.to_integer(port_str)

    # For now, we'll use a simple TCP connection to check if the checker is available
    # In production, you would use GRPC.Stub.connect/2 and generated client modules
    case check_checker_available(host, port) do
      :ok ->
        # Placeholder for actual gRPC call
        # In production:
        # {:ok, channel} = GRPC.Stub.connect(addr)
        # Monitoring.AgentService.Stub.get_status(channel, request)

        {:ok,
         %{
           status: :up,
           target: target,
           check_type: checker_type,
           message: "gRPC call placeholder - checker at #{addr} is available",
           timestamp: DateTime.utc_now()
         }}

      {:error, reason} ->
        {:error, {:checker_unavailable, checker_type, reason}}
    end
  end

  defp check_checker_available(host, port) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
