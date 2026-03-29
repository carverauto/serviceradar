defmodule ServiceRadar.Identity.IdentityCacheTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Identity.IdentityCache

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

  defp record(i) do
    %{
      canonical_device_id: "device-#{i}",
      partition: "default",
      metadata_hash: nil,
      attributes: %{"index" => i},
      updated_at: DateTime.utc_now()
    }
  end
end
