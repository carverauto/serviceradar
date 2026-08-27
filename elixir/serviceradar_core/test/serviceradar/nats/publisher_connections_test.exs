defmodule ServiceRadar.NATS.PublisherConnectionsTest do
  @moduledoc """
  The supervisor's connection inventory, asserted without starting NATS.

  `connection_names/0` is pure, and it is the thing that decides how many sockets exist. Testing
  it directly means the bound can be checked in the database-free tier, where it will actually be
  run, rather than only in an environment that has a NATS server.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.NATS.Supervisor, as: NATSSupervisor

  test "one shared connection plus exactly one per publisher lane" do
    names = NATSSupervisor.connection_names()

    assert NATSSupervisor.connection_name() in names
    assert length(names) === 1 + length(PublisherLane.lanes())

    for lane <- PublisherLane.lanes() do
      assert PublisherLane.connection_name(lane) in names
    end
  end

  test "every connection name is DISTINCT" do
    names = NATSSupervisor.connection_names()

    # Duplicates would not merely be untidy: Gnat registers by name, so two child specs sharing a
    # name means the second never starts and one lane silently has no connection at all.
    assert length(Enum.uniq(names)) === length(names)
  end

  test "no publisher reuses the SHARED connection" do
    shared = NATSSupervisor.connection_name()
    publishers = Enum.map(PublisherLane.lanes(), &PublisherLane.connection_name/1)

    # The shared connection carries unrelated platform traffic. A publisher on it would put edge
    # frames behind that traffic in the same Gnat mailbox, which is the head-of-line coupling the
    # per-lane windows are meant to bound.
    refute shared in publishers
  end

  test "every child spec has a DISTINCT id, so all of them actually start" do
    specs = NATSSupervisor.child_specs(%{host: "localhost", port: 4222}, 5_000)
    ids = Enum.map(specs, & &1.id)

    assert length(specs) === length(NATSSupervisor.connection_names())

    # Gnat.ConnectionSupervisor's default id is the MODULE. Without an explicit id these four
    # collide and Supervisor.init/2 starts only the first -- the shared connection comes up, the
    # app boots, and three lanes have no connection until something tries to publish. Nothing in
    # the connection-NAME assertions above can see that, because the names are fine either way.
    assert length(Enum.uniq(ids)) === length(ids)

    # NOT VACUOUS: the ids are the connection names, not merely unique-by-construction values
    # such as an index, so a spec built for the wrong connection is also caught.
    assert Enum.sort(ids) === Enum.sort(NATSSupervisor.connection_names())
  end

  describe "init/1 is what actually supervises them" do
    # Everything above tests the DECLARED inventory. Two mutations survived that: setting every
    # child's inner Gnat name to :serviceradar_nats while keeping four unique child ids, and
    # supervising only the first spec. Both are invisible to child_specs/2 assertions about ids,
    # and both are catastrophic at runtime -- the first collides on one registered name, the
    # second leaves three lanes with no connection. These bind init/1 itself.

    test "supervises exactly the declared inventory" do
      {:ok, {_flags, children}} = NATSSupervisor.init([])

      assert length(children) === length(NATSSupervisor.connection_names())

      assert children |> Enum.map(& &1.id) |> Enum.sort() ===
               Enum.sort(NATSSupervisor.connection_names())
    end

    test "every supervised child registers the Gnat name its id claims" do
      {:ok, {_flags, children}} = NATSSupervisor.init([])

      registered =
        Enum.map(children, fn child ->
          {Gnat.ConnectionSupervisor, :start_link, [settings | _]} = child.start
          {child.id, settings.name}
        end)

      # The id and the REGISTERED name must be the same connection. An id-only assertion passes
      # while every child registers :serviceradar_nats, which is the collision that leaves the
      # lanes sharing one socket.
      for {id, name} <- registered do
        assert id === name, "child #{inspect(id)} registers #{inspect(name)}"
      end

      assert registered |> Enum.map(&elem(&1, 1)) |> Enum.sort() ===
               Enum.sort(NATSSupervisor.connection_names())

      # NOT VACUOUS: the names are distinct, so this cannot pass with one name repeated four times
      # even if id and name happened to agree.
      assert registered |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() === 4
    end

    test "each lane's connection is supervised, by name" do
      {:ok, {_flags, children}} = NATSSupervisor.init([])
      names = Enum.map(children, fn c -> c.start |> elem(2) |> hd() |> Map.fetch!(:name) end)

      for lane <- PublisherLane.lanes() do
        assert PublisherLane.connection_name(lane) in names,
               "lane #{inspect(lane)} has no supervised connection"
      end

      assert NATSSupervisor.connection_name() in names
    end
  end

  test "the count does not grow with anything except lanes" do
    # The spec forbids a connection per network scope, agent, producer assignment, run, output
    # contract, package, or logical partition. connection_names/0 takes NO arguments, so there is
    # nothing a caller could vary to allocate another one -- the bound is structural, and this
    # test fails if the function ever grows a parameter.
    assert :erlang.fun_info(&NATSSupervisor.connection_names/0, :arity) === {:arity, 0}
    assert NATSSupervisor.connection_names() === NATSSupervisor.connection_names()
  end
end
