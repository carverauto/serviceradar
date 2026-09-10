defmodule ServiceRadarAgentGateway.EdgeRecordCapabilityTest do
  # Registers real named processes under PublisherPool.via/1 and
  # PublisherLane.connection_name/1, so this must not run concurrently with anything else
  # touching those names.
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadarAgentGateway.EdgeRecordCapability

  setup do
    previous = Application.get_env(:serviceradar_agent_gateway, :edge_records_publisher)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:serviceradar_agent_gateway, :edge_records_publisher)
        value -> Application.put_env(:serviceradar_agent_gateway, :edge_records_publisher, value)
      end
    end)

    :ok
  end

  test "id/0 returns the frozen capability identifier" do
    assert EdgeRecordCapability.id() == "edge-records:v1"
  end

  test "not ready when the publisher flag is disabled, even if every lane is alive" do
    Application.put_env(:serviceradar_agent_gateway, :edge_records_publisher, enabled: false)
    start_every_lane!()

    refute EdgeRecordCapability.enabled?()
    refute EdgeRecordCapability.ready?()
  end

  test "not ready when enabled but no lane is alive" do
    Application.put_env(:serviceradar_agent_gateway, :edge_records_publisher, enabled: true)

    assert EdgeRecordCapability.enabled?()
    refute EdgeRecordCapability.ready?()
  end

  test "not ready when enabled but only some lanes are alive" do
    Application.put_env(:serviceradar_agent_gateway, :edge_records_publisher, enabled: true)
    [first | _rest] = PublisherLane.lanes()
    start_lane!(first)

    refute EdgeRecordCapability.ready?()
  end

  test "ready when enabled and every lane's accountant and transport are alive" do
    Application.put_env(:serviceradar_agent_gateway, :edge_records_publisher, enabled: true)
    start_every_lane!()

    assert EdgeRecordCapability.ready?()
  end

  defp start_every_lane! do
    Enum.each(PublisherLane.lanes(), &start_lane!/1)
  end

  defp start_lane!(lane) do
    # Defensive: force a clean slate under these registered names first. A leaked process from a
    # prior test (or a killed :DOWN not yet processed) must not turn this into an unrelated
    # {:already_started, _} failure -- a fresh registration is the thing under test.
    clear_registered!(PublisherPool.via(lane))
    clear_registered!(PublisherLane.connection_name(lane))

    {:ok, pool} =
      PublisherPool.start_link(
        class: lane,
        frame_credits: 64,
        byte_credits: 64 * 1024 * 1024,
        name: PublisherPool.via(lane)
      )

    on_exit(fn -> stop_if_alive(pool) end)

    transport = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(transport, :kill) end)
    {:ok, _generation} = PublisherPool.register_transport(pool, transport)

    connection_name = PublisherLane.connection_name(lane)
    connection = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(connection, connection_name)
    on_exit(fn -> Process.exit(connection, :kill) end)
  end

  defp clear_registered!(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          200 -> :ok
        end
    end
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 100)
  catch
    :exit, _ -> :ok
  end
end
