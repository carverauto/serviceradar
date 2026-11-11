defmodule ServiceRadar.AgentConfig.ConfigCacheTest do
  @moduledoc """
  An invalidation reaches the cache on every node: the node that invalidates
  broadcasts it, and each other node drops its own entries on receipt.

  These tests drive one node's cache process with the messages another node
  would cause. Delivery between real nodes is Phoenix.PubSub's and is not
  exercised here.
  """

  # Sync: the cache is a named process with a named table.
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentConfig.ConfigCache

  @other_node :"core@other.example.com"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    if !Process.whereis(ConfigCache), do: start_supervised!(ConfigCache)

    partition = "partition-#{System.unique_integer([:positive])}"
    ConfigCache.put(:snmp, partition, "agent-01", %{hash: "snmp-hash"})
    ConfigCache.put(:mapper, partition, "agent-01", %{hash: "mapper-hash"})

    on_exit(fn ->
      ConfigCache.invalidate_key(:snmp, partition, "agent-01")
      ConfigCache.invalidate_key(:mapper, partition, "agent-01")
    end)

    {:ok, partition: partition}
  end

  test "invalidating a config type tells the other nodes which type", %{partition: partition} do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, ConfigCache.invalidation_topic())

    assert ConfigCache.invalidate(:snmp) == :ok

    assert_receive {:config_cache_invalidate, :snmp, origin}
    assert origin == node()
    assert ConfigCache.get(:snmp, partition, "agent-01") == :miss
    assert {:ok, %{hash: "mapper-hash"}} = ConfigCache.get(:mapper, partition, "agent-01")
  end

  test "an invalidation from another node drops this node's entries of that type", %{
    partition: partition
  } do
    deliver({:config_cache_invalidate, :snmp, @other_node})

    assert ConfigCache.get(:snmp, partition, "agent-01") == :miss
    assert {:ok, %{hash: "mapper-hash"}} = ConfigCache.get(:mapper, partition, "agent-01")
  end

  test "a key invalidation is broadcast and applied on another node", %{partition: partition} do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, ConfigCache.invalidation_topic())

    assert ConfigCache.invalidate_key(:mapper, partition, "agent-01") == :ok
    assert_receive {:config_cache_invalidate_key, key, _origin}

    ConfigCache.put(:mapper, partition, "agent-01", %{hash: "recompiled"})
    deliver({:config_cache_invalidate_key, key, @other_node})

    assert ConfigCache.get(:mapper, partition, "agent-01") == :miss
    assert {:ok, %{hash: "snmp-hash"}} = ConfigCache.get(:snmp, partition, "agent-01")
  end

  test "a node connecting empties the table, since its invalidations may have been missed", %{
    partition: partition
  } do
    deliver({:nodeup, @other_node})

    assert ConfigCache.get(:snmp, partition, "agent-01") == :miss
    assert ConfigCache.get(:mapper, partition, "agent-01") == :miss
  end

  test "a message from a release that says something else is ignored", %{partition: partition} do
    deliver({:config_cache_unknown, :snmp})

    assert {:ok, %{hash: "snmp-hash"}} = ConfigCache.get(:snmp, partition, "agent-01")
  end

  # Hands the cache process a message and waits until it has handled it.
  defp deliver(message) do
    cache = Process.whereis(ConfigCache)
    send(cache, message)
    _state = :sys.get_state(cache)
    :ok
  end
end
