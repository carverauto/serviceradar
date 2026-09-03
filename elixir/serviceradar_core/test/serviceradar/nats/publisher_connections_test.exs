defmodule ServiceRadar.NATS.PublisherConnectionsTest do
  @moduledoc """
  Where the lane connections live, and where they must NOT.

  They were briefly started by `ServiceRadar.NATS.Supervisor`, which meant every process enabling
  NATS -- core and web-ng, and core's Helm chart enables it -- opened three lane sockets it had no
  pool for and never published on, while only the gateway started pools. They now live inside each
  lane's restart unit, with that lane's window.

  `async: false`: the settings-failure test mutates application config.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.LaneSupervisor
  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherSupervisor
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.Supervisor, as: NATSSupervisor

  describe "the shared supervisor owns ONLY the shared connection" do
    test "connection_names/0 is exactly the shared connection" do
      assert NATSSupervisor.connection_names() === [NATSSupervisor.connection_name()]
    end

    test "no lane connection is started by a plain NATS process" do
      # The regression: a core or web-ng process starts NATS and no pools, so a lane connection
      # here would be an idle socket per lane in every such process.
      for lane <- PublisherLane.lanes() do
        refute PublisherLane.connection_name(lane) in NATSSupervisor.connection_names()
      end
    end

    test "init/1 supervises exactly that one connection, by name" do
      {:ok, {_flags, children}} = NATSSupervisor.init([])

      assert length(children) === 1
      [child] = children
      {Gnat.ConnectionSupervisor, :start_link, [settings | _]} = child.start

      # id AND registered name: an id-only assertion passes while the child registers something
      # else entirely.
      assert child.id === NATSSupervisor.connection_name()
      assert settings.name === NATSSupervisor.connection_name()
    end
  end

  describe "the lane connections live inside their lane's restart unit" do
    test "one lane unit per lane, and nothing else" do
      {:ok, {_flags, children}} = PublisherSupervisor.init([])

      assert Enum.map(children, & &1.id) ===
               Enum.map(PublisherLane.lanes(), &LaneSupervisor.via/1)
    end

    test "each unit holds that lane's connection AND that lane's window" do
      # The pairing is the point: neither can exist without the other, because one list builds
      # both. Their order and restart strategy are asserted in LaneSupervisorTest.
      for lane <- PublisherLane.lanes() do
        ids =
          [
            lane: lane,
            connection_settings: %{host: "127.0.0.1", port: 4222},
            backoff_period: 1_000,
            credits: [frame_credits: 1, byte_credits: 1]
          ]
          |> LaneSupervisor.child_specs()
          |> Enum.map(& &1.id)

        assert PublisherLane.connection_name(lane) in ids
        assert ServiceRadar.Edge.PublisherPool.via(lane) in ids
      end
    end

    test "lane connection names are distinct, and none is the shared one" do
      names = PublisherSupervisor.lane_connection_names()

      assert length(names) === length(PublisherLane.lanes())
      assert length(Enum.uniq(names)) === length(names)
      refute NATSSupervisor.connection_name() in names
    end
  end

  describe "when NATS settings cannot be built" do
    setup do
      previous = Application.get_env(:serviceradar_core, Connection)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:serviceradar_core, Connection)
          value -> Application.put_env(:serviceradar_core, Connection, value)
        end
      end)

      # A JWT with no nkey seed is the documented settings failure.
      Application.put_env(:serviceradar_core, Connection, jwt: "a-jwt")
      :ok
    end

    test "NO lanes start -- not pools without connections" do
      # The earlier version turned a settings error into an empty CONNECTION list but still
      # appended all three pools, so init/1 succeeded with windows whose named connections could
      # not exist: frames admitted against transport that was never going to be there.
      assert PublisherSupervisor.child_specs() === []

      {:ok, {_flags, children}} = PublisherSupervisor.init([])
      assert children === []
    end

    test "NOT VACUOUS: with working settings the lanes DO start" do
      Application.delete_env(:serviceradar_core, Connection)

      assert length(PublisherSupervisor.child_specs()) === length(PublisherLane.lanes())
    end
  end

  describe "the count does not grow with anything except lanes" do
    test "neither inventory function takes an argument that could add one" do
      # The spec forbids a connection per network scope, agent, producer assignment, run, output
      # contract, package, or logical partition. Both take no arguments, so there is nothing a
      # caller could vary.
      assert :erlang.fun_info(&NATSSupervisor.connection_names/0, :arity) === {:arity, 0}

      assert :erlang.fun_info(&PublisherSupervisor.lane_connection_names/0, :arity) ===
               {:arity, 0}
    end
  end
end
