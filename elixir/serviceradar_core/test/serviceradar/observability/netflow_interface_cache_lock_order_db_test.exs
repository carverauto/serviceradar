defmodule ServiceRadar.Observability.NetflowInterfaceCacheLockOrderDbTest do
  @moduledoc """
  Flow batches and the refresh worker upsert overlapping `netflow_interface_cache` keys
  concurrently. A writer that upserts keys in arrival order can hold a higher key while it
  waits for a lower one that a flow batch holds. When the batch then writes the higher key,
  Postgres aborts one side with `deadlock_detected` and that write is lost.

  Each case lets a flow batch hold the lower key, runs the writer under test into it with its
  keys arriving highest first, then has the batch write the higher key. Both must commit.
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Observability.NetflowInterfaceCacheRefreshWorker, as: Worker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag sandbox: :unboxed

  @wait_ms 15_000
  @if_index 7
  @low_sampler "198.51.100.10"
  @high_sampler "198.51.100.20"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    on_exit(&delete_cache_rows!/0)

    # Both keys exist, so every upsert below takes a row lock on an existing row.
    assert {:ok, 2} =
             Worker.record_observed_interface_pairs([
               flow_row(@low_sampler),
               flow_row(@high_sampler)
             ])

    :ok
  end

  test "a flow batch whose keys arrive highest first commits beside a concurrent batch" do
    ref = make_ref()
    holder = start_flow_batch_holding(@low_sampler, ref)
    assert_receive {:holding, ^ref, holder_backend, {:ok, 1}}, @wait_ms

    writer =
      Task.async(fn ->
        Worker.record_observed_interface_pairs([flow_row(@high_sampler), flow_row(@low_sampler)])
      end)

    await_blocked_by(writer, holder_backend)
    send(holder.pid, {:write, ref, flow_row(@high_sampler)})

    assert {:ok, {:ok, 1}} = Task.await(holder, @wait_ms * 2)
    assert {:ok, 2} = Task.await(writer, @wait_ms * 2)
  end

  describe "refresh" do
    setup do
      unique = System.unique_integer([:positive])
      # The refresh worker groups keys by device uid, so the higher sampler's device sorts
      # first and the refresh reaches the higher key before the lower one.
      high_uid = "sr:lock-order-#{unique}-a"
      low_uid = "sr:lock-order-#{unique}-b"
      uids = [high_uid, low_uid]

      on_exit(fn -> delete_refresh_fixtures!(uids) end)

      insert_device_with_interface!(high_uid, @high_sampler, "uplink-high")
      insert_device_with_interface!(low_uid, @low_sampler, "uplink-low")
      :ok
    end

    test "a refresh whose devices reach the higher key first commits beside a flow batch" do
      ref = make_ref()
      holder = start_flow_batch_holding(@low_sampler, ref)
      assert_receive {:holding, ^ref, holder_backend, {:ok, 1}}, @wait_ms

      writer = Task.async(fn -> Worker.perform(%Oban.Job{attempt: 1, max_attempts: 3}) end)

      await_blocked_by(writer, holder_backend)
      send(holder.pid, {:write, ref, flow_row(@high_sampler)})

      assert {:ok, {:ok, 1}} = Task.await(holder, @wait_ms * 2)
      assert :ok = Task.await(writer, @wait_ms * 2)

      assert %{rows: [[@low_sampler, "uplink-low"], [@high_sampler, "uplink-high"]]} =
               Repo.query!(
                 """
                 SELECT sampler_address, if_name
                 FROM platform.netflow_interface_cache
                 WHERE sampler_address = ANY($1) AND if_index = $2
                 ORDER BY sampler_address
                 """,
                 [[@low_sampler, @high_sampler], @if_index]
               )
    end
  end

  # A flow batch's transaction that has written `sampler_address` and keeps its row lock until
  # told which row to write next, then commits.
  defp start_flow_batch_holding(sampler_address, ref) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(
        fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          first = Worker.record_observed_interface_pairs([flow_row(sampler_address)])
          send(parent, {:holding, ref, backend, first})

          receive do
            {:write, ^ref, row} -> Worker.record_observed_interface_pairs([row])
          after
            @wait_ms -> {:error, :never_told_to_write}
          end
        end,
        timeout: @wait_ms * 2
      )
    end)
  end

  # Returns once the writer waits on the holder's row lock. A writer that finishes first never
  # reached the held row, so the case proves nothing and fails.
  defp await_blocked_by(writer, holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    do_await_blocked_by(writer, holder_backend, deadline)
  end

  defp do_await_blocked_by(writer, holder_backend, deadline) do
    %{rows: [[blocked?]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_stat_activity
          WHERE wait_event_type = 'Lock'
            AND query ILIKE '%netflow_interface_cache%'
            AND $1 = ANY(pg_blocking_pids(pid))
        )
        """,
        [holder_backend]
      )

    cond do
      blocked? ->
        :ok

      not Process.alive?(writer.pid) ->
        flunk(
          "the writer finished without waiting on the held row: #{inspect(Task.await(writer))}"
        )

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the writer never waited on the held row within #{@wait_ms}ms")

      true ->
        Process.sleep(25)
        do_await_blocked_by(writer, holder_backend, deadline)
    end
  end

  defp flow_row(sampler_address) do
    %{
      sampler_address: sampler_address,
      ocsf_payload: %{"connection_info" => %{"input_snmp" => @if_index}}
    }
  end

  defp insert_device_with_interface!(uid, ip, if_name) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "ocsf_devices",
      [%{uid: uid, ip: ip, type_id: 0, first_seen_time: now, last_seen_time: now}],
      prefix: "platform"
    )

    Repo.insert_all(
      "discovered_interfaces",
      [
        %{
          device_id: uid,
          interface_uid: "name:#{if_name}",
          timestamp: now,
          if_index: @if_index,
          if_name: if_name
        }
      ],
      prefix: "platform"
    )
  end

  defp delete_cache_rows! do
    Repo.query!("DELETE FROM platform.netflow_interface_cache WHERE sampler_address = ANY($1)", [
      [@low_sampler, @high_sampler]
    ])
  end

  defp delete_refresh_fixtures!(uids) do
    # A successful refresh schedules its next cycle.
    Repo.query!("DELETE FROM platform.oban_jobs WHERE worker = $1", [
      Oban.Worker.to_string(Worker)
    ])

    Repo.query!("DELETE FROM platform.discovered_interfaces WHERE device_id = ANY($1)", [uids])
    TestSupport.delete_device_fixtures!(uids)
  end
end
