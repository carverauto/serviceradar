defmodule ServiceRadar.FlowAttribution.PersistenceTest do
  use ExUnit.Case, async: true

  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias ServiceRadar.FlowAttribution
  alias ServiceRadar.FlowAttribution.Persistence

  test "prepare_current_rows prefers container-scoped owner for the same socket key" do
    now = ~U[2026-07-11 05:48:00Z]
    later = DateTime.add(now, 5, :second)

    host = %{
      observed_at: later,
      partition: "default",
      attribution_key: "socket-key",
      agent_id: "agent-a",
      proto: 6,
      local_ip: "10.42.0.1",
      local_port: 4000,
      remote_ip: "0.0.0.0",
      remote_port: 0,
      pid: 1787,
      comm: "k3s-agent",
      cmdline: "/usr/local/bin/k3s agent",
      uid: 0,
      container_id: nil,
      workload_identity: nil
    }

    container = %{
      observed_at: now,
      partition: "default",
      attribution_key: "socket-key",
      agent_id: "agent-a",
      proto: 6,
      local_ip: "10.42.0.1",
      local_port: 4000,
      remote_ip: "0.0.0.0",
      remote_port: 0,
      pid: 99,
      comm: "beam.smp",
      cmdline: nil,
      uid: 1000,
      container_id: "abc123",
      workload_identity: nil
    }

    prepared = Persistence.prepare_current_rows([host, container])
    assert length(prepared) == 1
    assert hd(prepared).comm == "beam.smp"
    assert hd(prepared).container_id == "abc123"
    assert hd(prepared).pid == 99

    # Order of arrival should not matter.
    prepared_rev = Persistence.prepare_current_rows([container, host])
    assert hd(prepared_rev).comm == "beam.smp"
  end

  test "upsert SQL prefers container_id over host-only dual emit" do
    query = fn sql, [_payload] ->
      send(self(), {:sql, sql})
      {:ok, %Postgrex.Result{num_rows: 0}}
    end

    assert {:ok, _} =
             Persistence.insert_current_rows([row("default", "key-a")], query: query)

    assert_receive {:sql, sql}
    assert sql =~ "container_id IS NULL"
    assert sql =~ "EXCLUDED.container_id IS NOT NULL AND"
    assert sql =~ "pid = CASE"
  end

  test "concurrent callers submit conflict keys in the same deterministic order" do
    now = ~U[2026-07-11 05:48:00Z]

    rows = [
      row("z", "key-b", now),
      row("a", "key-c", now),
      row("a", "key-a", now),
      row("a", "key-a", DateTime.add(now, 1, :second))
    ]

    expected = [{"a", "key-a"}, {"a", "key-c"}, {"z", "key-b"}]
    test_pid = self()

    tasks =
      for permutation <- [rows, Enum.reverse(rows), Enum.shuffle(rows)] do
        Task.async(fn ->
          query = fn sql, [payload] ->
            send(test_pid, {:submitted, sql, Jason.decode!(payload)})
            {:ok, %Postgrex.Result{num_rows: 3}}
          end

          Persistence.insert_current_rows(permutation, query: query)
        end)
      end

    assert Enum.map(Task.await_many(tasks), fn {:ok, result} -> result.num_rows end) == [3, 3, 3]

    for _caller <- tasks do
      assert_receive {:submitted, sql, payload}
      assert sql =~ "ORDER BY r.partition, r.attribution_key\nON CONFLICT"

      assert Enum.map(payload, &{&1["partition"], &1["attribution_key"]}) == expected

      assert Enum.find(payload, &(&1["attribution_key"] == "key-a"))["observed_at"] ==
               DateTime.to_iso8601(DateTime.add(now, 1, :second))
    end
  end

  test "retries PostgreSQL deadlocks with bounded backoff and succeeds" do
    test_pid = self()
    Process.put(:query_attempt, 0)

    query = fn _sql, [_payload] ->
      attempt = Process.get(:query_attempt) + 1
      Process.put(:query_attempt, attempt)

      if attempt <= 3 do
        {:error, deadlock_error()}
      else
        {:ok, %Postgrex.Result{num_rows: 1}}
      end
    end

    sleep = fn delay_ms -> send(test_pid, {:retry_delay, delay_ms}) end

    assert {:ok, %Postgrex.Result{num_rows: 1}} =
             Persistence.insert_current_rows([row("default", "key-a")],
               query: query,
               sleep: sleep
             )

    assert Process.get(:query_attempt) == 4
    assert_receive {:retry_delay, first}
    assert_receive {:retry_delay, second}
    assert_receive {:retry_delay, third}
    assert first in 8..12
    assert second in 16..24
    assert third in 32..48
    refute_receive {:retry_delay, _delay}
  end

  test "returns an exhausted deadlock without acknowledging persistence" do
    test_pid = self()
    Process.put(:query_attempt, 0)
    error = deadlock_error()

    query = fn _sql, [_payload] ->
      Process.put(:query_attempt, Process.get(:query_attempt) + 1)
      {:error, error}
    end

    sleep = fn delay_ms -> send(test_pid, {:retry_delay, delay_ms}) end

    assert {:error, ^error} =
             Persistence.insert_current_rows([row("default", "key-a")],
               query: query,
               sleep: sleep
             )

    assert Process.get(:query_attempt) == 4
    assert_receive {:retry_delay, _first}
    assert_receive {:retry_delay, _second}
    assert_receive {:retry_delay, _third}
    refute_receive {:retry_delay, _delay}
  end

  test "does not retry a non-deadlock database error" do
    Process.put(:query_attempt, 0)
    error = %Postgrex.Error{message: "connection unavailable"}

    query = fn _sql, [_payload] ->
      Process.put(:query_attempt, Process.get(:query_attempt) + 1)
      {:error, error}
    end

    assert {:error, ^error} =
             Persistence.insert_current_rows([row("default", "key-a")],
               query: query,
               sleep: fn _delay -> flunk("non-deadlock errors must not be retried") end
             )

    assert Process.get(:query_attempt) == 1
  end

  test "propagates exhausted persistence failure to the status caller" do
    event = %FlowAttributionEvent{
      transport_protocol: "tcp",
      local_ip: "10.0.2.11",
      local_port: 48_872,
      remote_ip: "104.18.43.187",
      remote_port: 443,
      pid: 1234,
      comm: "test-process"
    }

    error = deadlock_error()

    assert {:error, {:flow_attribution_persist_failed, ^error}} =
             FlowAttribution.persist([event], "default", "agent-a",
               persistence: fn [_row] -> {:error, error} end
             )
  end

  defp row(partition, attribution_key, observed_at \\ ~U[2026-07-11 05:48:00Z]) do
    %{
      observed_at: observed_at,
      partition: partition,
      attribution_key: attribution_key,
      agent_id: "agent-a",
      proto: 6,
      local_ip: "10.0.2.11",
      local_port: 48_872,
      remote_ip: "104.18.43.187",
      remote_port: 443,
      pid: 1234,
      comm: "test-process",
      cmdline: "test-process --flag",
      uid: 1000,
      container_id: nil,
      workload_identity: nil
    }
  end

  defp deadlock_error do
    %Postgrex.Error{postgres: %{code: :deadlock_detected, pg_code: "40P01"}}
  end
end
