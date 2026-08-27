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

  test "the count does not grow with anything except lanes" do
    # The spec forbids a connection per network scope, agent, producer assignment, run, output
    # contract, package, or logical partition. connection_names/0 takes NO arguments, so there is
    # nothing a caller could vary to allocate another one -- the bound is structural, and this
    # test fails if the function ever grows a parameter.
    assert :erlang.fun_info(&NATSSupervisor.connection_names/0, :arity) === {:arity, 0}
    assert NATSSupervisor.connection_names() === NATSSupervisor.connection_names()
  end
end
