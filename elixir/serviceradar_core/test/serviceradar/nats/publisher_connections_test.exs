defmodule ServiceRadar.NATS.PublisherConnectionsTest do
  @moduledoc """
  Where the lane connections live, and where they must NOT.

  They were briefly started by `ServiceRadar.NATS.Supervisor`, which meant every process enabling
  NATS -- core and web-ng, and core's Helm chart enables it -- opened three lane sockets it had no
  pool for and never published on, while only the gateway started pools. These bind the corrected
  split: the shared connection here, the lane connections with their windows in
  `PublisherSupervisor`.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.Edge.PublisherSupervisor
  alias ServiceRadar.NATS.Supervisor, as: NATSSupervisor

  describe "the shared supervisor owns ONLY the shared connection" do
    test "connection_names/0 is exactly the shared connection" do
      assert NATSSupervisor.connection_names() === [NATSSupervisor.connection_name()]
    end

    test "no lane connection is started by a plain NATS process" do
      # This is the regression. A core or web-ng process starts NATS and no pools; if a lane
      # connection appeared here it would be an idle socket per lane in every such process.
      for lane <- PublisherLane.lanes() do
        refute PublisherLane.connection_name(lane) in NATSSupervisor.connection_names()
      end
    end

    test "init/1 supervises exactly that one connection, by name" do
      {:ok, {_flags, children}} = NATSSupervisor.init([])

      assert length(children) === 1
      [child] = children
      {Gnat.ConnectionSupervisor, :start_link, [settings | _]} = child.start

      # id AND registered name, not just the id: an id-only assertion passes while the child
      # registers something else entirely.
      assert child.id === NATSSupervisor.connection_name()
      assert settings.name === NATSSupervisor.connection_name()
    end
  end

  describe "the lane connections live with their pools" do
    test "one connection per lane, all distinct, none the shared one" do
      names = PublisherSupervisor.lane_connection_names()

      assert length(names) === length(PublisherLane.lanes())
      assert length(Enum.uniq(names)) === length(names)
      refute NATSSupervisor.connection_name() in names
    end

    test "every lane connection child registers the Gnat name its id claims" do
      specs = PublisherSupervisor.connection_child_specs()

      registered =
        Enum.map(specs, fn spec ->
          {Gnat.ConnectionSupervisor, :start_link, [settings | _]} = spec.start
          {spec.id, settings.name}
        end)

      for {id, name} <- registered do
        assert id === name, "child #{inspect(id)} registers #{inspect(name)}"
      end

      assert registered |> Enum.map(&elem(&1, 1)) |> Enum.sort() ===
               Enum.sort(PublisherSupervisor.lane_connection_names())
    end

    test "the supervised inventory pairs each connection with a pool" do
      {:ok, {_flags, children}} = PublisherSupervisor.init([])

      # The pairing is the point: a lane cannot have a socket without a window, or a window
      # without a socket, because one list builds both.
      assert length(children) === 2 * length(PublisherLane.lanes())

      ids = Enum.map(children, & &1.id)

      for lane <- PublisherLane.lanes() do
        assert PublisherLane.connection_name(lane) in ids
        assert PublisherPool.via(lane) in ids
      end
    end

    test "connections are started BEFORE pools" do
      {:ok, {_flags, children}} = PublisherSupervisor.init([])
      ids = Enum.map(children, & &1.id)

      last_connection = Enum.find_index(ids, &(&1 === PublisherLane.connection_name(:recovery)))

      first_pool = Enum.find_index(ids, &(&1 === PublisherPool.via(:bulk)))

      # A lane's transport must exist before anything admits against its window. one_for_one
      # starts children in order, so the order in the list is the guarantee.
      assert last_connection < first_pool
    end
  end

  describe "the count does not grow with anything except lanes" do
    test "neither inventory function takes an argument that could add one" do
      # The spec forbids a connection per network scope, agent, producer assignment, run, output
      # contract, package, or logical partition. Both take no arguments, so there is nothing a
      # caller could vary; these fail if either ever grows a parameter.
      assert :erlang.fun_info(&NATSSupervisor.connection_names/0, :arity) === {:arity, 0}

      assert :erlang.fun_info(&PublisherSupervisor.lane_connection_names/0, :arity) ===
               {:arity, 0}
    end
  end
end
