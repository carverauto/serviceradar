defmodule ServiceRadar.Security.RateLimiterTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Security.RateLimiter

  @moduletag :requires_app

  setup_all do
    case Process.whereis(RateLimiter) do
      nil -> start_supervised!(RateLimiter)
      _pid -> :ok
    end

    :ok
  end

  setup do
    # The Application supervisor already starts RateLimiter. Each test
    # clears the table for isolation but does not restart the GenServer
    # (restarting would invalidate the named ETS table and the :pg join).
    on_exit(fn -> :ets.delete_all_objects(RateLimiter.__table__()) end)
    :ets.delete_all_objects(RateLimiter.__table__())
    :ok
  end

  describe "check/3 and record/3" do
    test "allows requests under the limit and denies once exhausted" do
      key = "ip-#{:rand.uniform(1_000_000)}"

      for _ <- 1..3 do
        assert :ok = RateLimiter.check(:test_bucket, key, limit: 3, window_seconds: 60)
        :ok = RateLimiter.record(:test_bucket, key, limit: 3, window_seconds: 60)
      end

      assert {:error, retry_after} =
               RateLimiter.check(:test_bucket, key, limit: 3, window_seconds: 60)

      assert retry_after >= 1
      assert retry_after <= 60
    end

    test "independent buckets are tracked separately" do
      key = "shared-#{:rand.uniform(1_000_000)}"

      for _ <- 1..5 do
        :ok = RateLimiter.record(:bucket_a, key, limit: 5, window_seconds: 60)
      end

      assert {:error, _} = RateLimiter.check(:bucket_a, key, limit: 5, window_seconds: 60)
      assert :ok = RateLimiter.check(:bucket_b, key, limit: 5, window_seconds: 60)
    end

    test "different keys in the same bucket do not interfere" do
      for _ <- 1..5 do
        :ok = RateLimiter.record(:test_bucket, "key-a", limit: 5, window_seconds: 60)
      end

      assert {:error, _} = RateLimiter.check(:test_bucket, "key-a", limit: 5, window_seconds: 60)
      assert :ok = RateLimiter.check(:test_bucket, "key-b", limit: 5, window_seconds: 60)
    end

    test "subject keys may be tuples (ip, actor) for password-spray defense" do
      ip = "203.0.113.10"

      for _ <- 1..3 do
        :ok =
          RateLimiter.record(:auth_test, {ip, "alice"}, limit: 3, window_seconds: 60)
      end

      assert {:error, _} =
               RateLimiter.check(:auth_test, {ip, "alice"}, limit: 3, window_seconds: 60)

      assert :ok =
               RateLimiter.check(:auth_test, {ip, "bob"}, limit: 3, window_seconds: 60)
    end
  end

  describe "check_and_record/3" do
    test "atomically denies once exhausted without recording the extra attempt" do
      key = "atomic-#{:rand.uniform(1_000_000)}"

      Enum.each(1..3, fn _ ->
        assert :ok =
                 RateLimiter.check_and_record(:atomic_test, key, limit: 3, window_seconds: 60)
      end)

      assert {:error, retry_after} =
               RateLimiter.check_and_record(:atomic_test, key, limit: 3, window_seconds: 60)

      assert retry_after >= 1

      # A denied call must not have added an attempt, so we still have
      # exactly 3 attempts in the bucket.
      assert [{_key, attempts}] =
               :ets.lookup(RateLimiter.__table__(), {:atomic_test, key})

      assert length(attempts) == 3
    end

    test "retry_after is bounded by the window" do
      key = "retry-#{:rand.uniform(1_000_000)}"
      window = 60

      Enum.each(1..2, fn _ ->
        :ok = RateLimiter.check_and_record(:retry_test, key, limit: 2, window_seconds: window)
      end)

      {:error, retry_after} =
        RateLimiter.check_and_record(:retry_test, key, limit: 2, window_seconds: window)

      assert retry_after >= 1
      assert retry_after <= window
    end
  end

  describe "clear/2" do
    test "removes the bucket entry locally" do
      key = "clear-#{:rand.uniform(1_000_000)}"
      :ok = RateLimiter.record(:clear_test, key, limit: 5, window_seconds: 60)
      assert [_] = :ets.lookup(RateLimiter.__table__(), {:clear_test, key})

      :ok = RateLimiter.clear(:clear_test, key)
      assert [] = :ets.lookup(RateLimiter.__table__(), {:clear_test, key})
    end
  end

  describe "resolve_bucket/2" do
    test "resolves from config when present" do
      assert {5, 60} = RateLimiter.resolve_bucket(:auth_local)
    end

    test "retains security-sensitive defaults when parent release config is absent" do
      previous = Application.get_env(:serviceradar_core, RateLimiter)
      Application.delete_env(:serviceradar_core, RateLimiter)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:serviceradar_core, RateLimiter),
          else: Application.put_env(:serviceradar_core, RateLimiter, previous)
      end)

      assert {5, 60} = RateLimiter.resolve_bucket(:auth_local)
      assert {5, 300} = RateLimiter.resolve_bucket(:auth_password_reset)
      assert {60, 60} = RateLimiter.resolve_bucket(:totally_unknown_bucket)
    end

    test "falls back to default_bucket for unknown bucket names" do
      assert {60, 60} = RateLimiter.resolve_bucket(:totally_unknown_bucket)
    end

    test "opts override config" do
      assert {99, 7} = RateLimiter.resolve_bucket(:auth_local, limit: 99, window_seconds: 7)
    end
  end

  describe "concurrent writers" do
    test "many parallel records stay coherent" do
      key = "concurrent-#{:rand.uniform(1_000_000)}"
      parent = self()

      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            :ok = RateLimiter.record(:concurrent, key, limit: 1000, window_seconds: 60)
            send(parent, :recorded)
          end)
        end

      Enum.each(tasks, &Task.await(&1, 5_000))

      [{_, attempts}] = :ets.lookup(RateLimiter.__table__(), {:concurrent, key})
      # Each Task.async/await above implies a happens-before, so all
      # writes are visible by the time we read.
      assert length(attempts) == 50
    end
  end

  describe "Horde registration" do
    test "the limiter registers {:rate_limiter, node()} in ProcessRegistry" do
      entries = ServiceRadar.ProcessRegistry.select_by_type(RateLimiter.__registry_type__())

      assert Enum.any?(entries, fn
               {{:rate_limiter, _node}, pid, _meta} -> pid == Process.whereis(RateLimiter)
               _ -> false
             end)
    end

    test "the limiter restores a lost ProcessRegistry registration" do
      key = {RateLimiter.__registry_type__(), node()}
      limiter_pid = Process.whereis(RateLimiter)

      on_exit(fn ->
        if pid = Process.whereis(RateLimiter) do
          :ok = :sys.resume(pid)
          send(pid, :ensure_registry_registration)
          _ = :sys.get_state(pid)
        end
      end)

      send(RateLimiter, :ensure_registry_registration)
      _ = :sys.get_state(RateLimiter)
      assert [{^limiter_pid, _metadata}] = wait_for_registry_entry(key, limiter_pid)

      # Horde unregisters the caller's entry; suspend the owner so its timer
      # cannot recreate the entry before the test observes the loss.
      :ok = :sys.suspend(limiter_pid)

      try do
        :sys.replace_state(limiter_pid, fn state ->
          :ok = ServiceRadar.ProcessRegistry.unregister(key)
          state
        end)

        assert [] = ServiceRadar.ProcessRegistry.lookup(key)
        send(limiter_pid, :ensure_registry_registration)
      after
        :ok = :sys.resume(limiter_pid)
      end

      _ = :sys.get_state(RateLimiter)

      assert [{^limiter_pid, %{type: :rate_limiter}}] =
               wait_for_registry_entry(key, limiter_pid)
    end
  end

  describe "peer broadcast (single-node simulation)" do
    test "applying a peer_record cast updates the local ETS table" do
      bucket = :peer_test
      key = "peer-#{:rand.uniform(1_000_000)}"
      ts = System.system_time(:second)

      # Simulate a peer cast arriving from another node.
      GenServer.cast(RateLimiter, {:peer_record, bucket, key, ts, 60})

      # Allow the cast to be processed.
      _ = :sys.get_state(RateLimiter)

      assert [{_, [^ts]}] = :ets.lookup(RateLimiter.__table__(), {bucket, key})
    end

    test "peer_record casts accumulate (each broadcast represents a distinct attempt)" do
      bucket = :peer_accumulate
      key = "accumulate-#{:rand.uniform(1_000_000)}"
      ts = System.system_time(:second)

      # Three peer casts for the same (bucket, key, ts) — each represents
      # a distinct attempt observed by three different peer nodes.
      Enum.each(1..3, fn _ ->
        GenServer.cast(RateLimiter, {:peer_record, bucket, key, ts, 60})
      end)

      _ = :sys.get_state(RateLimiter)

      [{_, attempts}] = :ets.lookup(RateLimiter.__table__(), {bucket, key})
      assert length(attempts) == 3
    end

    test "snapshot_merge dedupes overlapping timestamps to avoid double-counting on cluster join" do
      bucket = :snapshot_merge
      key = "merge-#{:rand.uniform(1_000_000)}"

      # Seed local state via the GenServer.
      :ok = RateLimiter.record(bucket, key, limit: 100, window_seconds: 60)
      [{_, [seeded_ts]}] = :ets.lookup(RateLimiter.__table__(), {bucket, key})

      # Snapshot from a peer carries the same timestamp plus two more.
      other_ts1 = seeded_ts - 5
      other_ts2 = seeded_ts - 10

      GenServer.cast(
        RateLimiter,
        {:snapshot_merge, [{{bucket, key}, [seeded_ts, other_ts1, other_ts2]}]}
      )

      _ = :sys.get_state(RateLimiter)

      [{_, attempts}] = :ets.lookup(RateLimiter.__table__(), {bucket, key})
      assert Enum.sort(attempts) == Enum.sort([seeded_ts, other_ts1, other_ts2])
    end
  end

  defp wait_for_registry_entry(key, pid, attempts \\ 40)

  defp wait_for_registry_entry(key, _pid, 0), do: ServiceRadar.ProcessRegistry.lookup(key)

  defp wait_for_registry_entry(key, pid, attempts) do
    case ServiceRadar.ProcessRegistry.lookup(key) do
      [{^pid, _metadata}] = entries ->
        entries

      _entries ->
        Process.sleep(25)
        wait_for_registry_entry(key, pid, attempts - 1)
    end
  end
end
