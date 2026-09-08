defmodule ServiceRadar.Edge.RemoteAccessBrokerRegistryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.RemoteAccessBrokerRegistry

  defmodule FakeRegistry do
    @moduledoc false

    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def register(key, metadata) do
      caller_pid = self()

      Agent.get_and_update(__MODULE__, fn entries ->
        case Map.get(entries, key) do
          nil ->
            {{:ok, caller_pid}, Map.put(entries, key, {caller_pid, metadata})}

          {pid, _metadata} ->
            {{:error, {:already_registered, pid}}, entries}
        end
      end)
    end

    def lookup(key) do
      Agent.get(__MODULE__, fn entries ->
        case Map.get(entries, key) do
          nil -> []
          {pid, metadata} -> [{pid, metadata}]
        end
      end)
    end

    def unregister(key) do
      Agent.update(__MODULE__, &Map.delete(&1, key))
    end
  end

  setup do
    start_supervised!(FakeRegistry)
    :ok
  end

  test "register is idempotent for the owning broker process" do
    assert :ok =
             RemoteAccessBrokerRegistry.register("session-1", %{agent_id: "agent-1"},
               registry: FakeRegistry
             )

    assert :ok =
             RemoteAccessBrokerRegistry.register("session-1", %{agent_id: "agent-1"},
               registry: FakeRegistry
             )

    assert {:ok, pid, metadata} =
             RemoteAccessBrokerRegistry.lookup("session-1", registry: FakeRegistry)

    assert pid == self()
    assert metadata[:type] == :remote_access_broker
    assert metadata[:broker_pid] == self()
    assert metadata[:agent_id] == "agent-1"
  end

  test "register rejects a different live process for the same session" do
    assert :ok =
             RemoteAccessBrokerRegistry.register("session-2", %{agent_id: "agent-1"},
               registry: FakeRegistry
             )

    owner = self()

    assert {:error, {:already_registered, ^owner}} =
             fn ->
               RemoteAccessBrokerRegistry.register("session-2", %{agent_id: "agent-2"},
                 registry: FakeRegistry
               )
             end
             |> Task.async()
             |> Task.await()

    assert {:ok, ^owner, metadata} =
             RemoteAccessBrokerRegistry.lookup("session-2", registry: FakeRegistry)

    assert metadata[:agent_id] == "agent-1"
  end

  test "unregister ignores non-owner processes" do
    assert :ok =
             RemoteAccessBrokerRegistry.register("session-3", %{agent_id: "agent-1"},
               registry: FakeRegistry
             )

    owner = self()

    assert :ok =
             fn ->
               RemoteAccessBrokerRegistry.unregister("session-3", registry: FakeRegistry)
             end
             |> Task.async()
             |> Task.await()

    assert {:ok, ^owner, _metadata} =
             RemoteAccessBrokerRegistry.lookup("session-3", registry: FakeRegistry)

    assert :ok = RemoteAccessBrokerRegistry.unregister("session-3", registry: FakeRegistry)

    assert {:error, :broker_not_found} =
             RemoteAccessBrokerRegistry.lookup("session-3", registry: FakeRegistry)
  end
end
