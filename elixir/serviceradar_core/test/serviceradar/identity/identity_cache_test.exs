defmodule ServiceRadar.Identity.IdentityCacheTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Identity.IdentityCache

  @moduletag :requires_app

  setup do
    pid =
      case Process.whereis(IdentityCache) do
        nil ->
          {:ok, pid} =
            IdentityCache.start_link(ttl_ms: 60_000, max_size: 10, eviction_scan_chunk: 3)

          pid

        pid ->
          pid
      end

    original_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:ttl_ms, 60_000)
      |> Map.put(:max_size, 10)
      |> Map.put(:eviction_scan_chunk, 3)
    end)

    IdentityCache.clear()

    on_exit(fn ->
      IdentityCache.clear()
      :sys.replace_state(pid, fn _state -> original_state end)
    end)

    :ok
  end

  test "cleanup evicts the oldest entries when the cache exceeds its soft limit" do
    records =
      Map.new(1..20, fn i ->
        record = record(i)
        IdentityCache.put("device-#{i}", record, ttl_ms: 60_000 + i)
        {i, record}
      end)

    send(Process.whereis(IdentityCache), :cleanup)
    Process.sleep(50)

    stats = IdentityCache.stats()

    assert stats.size == 18
    assert IdentityCache.get("device-1") == nil
    assert IdentityCache.get("device-2") == nil
    assert IdentityCache.get("device-3") == records[3]
    assert IdentityCache.get("device-20") == records[20]
  end

  test "delete and clear emit invalidation telemetry" do
    attach_telemetry([[:serviceradar, :identity, :cache, :invalidation]])

    IdentityCache.put("device-1", record(1))
    IdentityCache.put("device-2", record(2))

    assert :ok = IdentityCache.delete("device-1")

    assert_receive {:telemetry, [:serviceradar, :identity, :cache, :invalidation], %{count: 1},
                    %{reason: :delete}}

    assert :ok = IdentityCache.clear()

    assert_receive {:telemetry, [:serviceradar, :identity, :cache, :invalidation], %{count: 1},
                    %{reason: :clear}}
  end

  test "expired entries emit stale reject telemetry" do
    attach_telemetry([[:serviceradar, :identity, :cache]])

    IdentityCache.put("expired-device", record(1), ttl_ms: -1)

    assert IdentityCache.get("expired-device") == nil

    assert_receive {:telemetry, [:serviceradar, :identity, :cache], %{count: 1},
                    %{result: :stale_reject, reason: :expired}}
  end

  defp record(i) do
    %{
      canonical_device_id: "device-#{i}",
      partition: "default",
      metadata_hash: nil,
      attributes: %{"index" => i},
      updated_at: DateTime.utc_now()
    }
  end

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = "identity-cache-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
