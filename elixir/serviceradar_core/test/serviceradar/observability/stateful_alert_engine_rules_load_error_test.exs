defmodule ServiceRadar.Observability.StatefulAlertEngineRulesLoadErrorTest do
  @moduledoc """
  DB-free tests for the rule-load ERROR contract: a returned query error
  (e.g. schema drift when code selects a column an unapplied migration adds)
  must not be mistaken for "zero rules". The shard keeps its previously
  loaded rules, logs once until recovery, emits telemetry, and retries.

  Regression: `Ash.read` errors were silently converted to `[]` by
  `unwrap_page(_)` and `rules_loaded_at` was stamped, so every shard quietly
  evaluated against zero rules with no log line (observed live on demo when
  v1.4.14 ran against a pre-migration schema).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.StatefulAlertEngine

  @rules_load_failed_event [:serviceradar, :stateful_alert_engine, :rules_load_failed]
  @rules_loaded_event [:serviceradar, :stateful_alert_engine, :rules_loaded]

  setup do
    previous = Application.get_env(:serviceradar_core, :repo_enabled)

    handler_id = {__MODULE__, self()}
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [@rules_load_failed_event, @rules_loaded_event],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    {:ok, mode} = Agent.start_link(fn -> {:ok, []} end)

    reader = fn -> Agent.get(mode, & &1) end

    # Start with the repo flagged unavailable so init's snapshot load takes the
    # repo-less branch (no real Repo runs in this suite), then flip to
    # available with a stand-in registered process so load_rules reaches the
    # injected reader.
    Application.put_env(:serviceradar_core, :repo_enabled, false)

    {:ok, pid} =
      GenServer.start(StatefulAlertEngine, %{
        shard: 3,
        rules_reader: reader,
        snapshots_reader: fn -> {:ok, []} end
      })

    fake_repo =
      if is_nil(Process.whereis(ServiceRadar.Repo)) do
        {:ok, agent} = Agent.start(fn -> :fake_repo end, name: ServiceRadar.Repo)
        agent
      end

    Application.put_env(:serviceradar_core, :repo_enabled, true)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      if Process.alive?(pid), do: GenServer.stop(pid)
      if is_pid(fake_repo) and Process.alive?(fake_repo), do: Agent.stop(fake_repo)

      case previous do
        nil -> Application.delete_env(:serviceradar_core, :repo_enabled)
        value -> Application.put_env(:serviceradar_core, :repo_enabled, value)
      end
    end)

    {:ok, pid: pid, mode: mode}
  end

  test "query errors keep previous rules, log once, emit telemetry, and recover", %{
    pid: pid,
    mode: mode
  } do
    rule = %{id: rule_id_for_shard(3)}
    Agent.update(mode, fn _ -> {:ok, [rule]} end)

    capture_log(fn -> assert :ok = GenServer.call(pid, {:evaluate_events, []}) end)
    assert_receive {:telemetry, @rules_loaded_event, %{count: 1}, %{shard: 3}}
    assert length(:sys.get_state(pid).rules) == 1

    Agent.update(mode, fn _ -> {:error, :undefined_column} end)
    expire_rules_cache(pid)

    first_log =
      capture_log(fn ->
        assert :ok = GenServer.call(pid, {:evaluate_events, []})
      end)

    assert first_log =~ "failed to load alert rules"
    assert first_log =~ "keeping 1 previously loaded rules"
    assert_receive {:telemetry, @rules_load_failed_event, %{count: 1}, %{shard: 3}}
    assert length(:sys.get_state(pid).rules) == 1

    second_log =
      capture_log(fn ->
        assert :ok = GenServer.call(pid, {:evaluate_events, []})
      end)

    refute second_log =~ "failed to load alert rules"
    assert_receive {:telemetry, @rules_load_failed_event, %{count: 1}, %{shard: 3}}

    Agent.update(mode, fn _ -> {:ok, [rule]} end)

    recovery_log =
      capture_log(fn -> assert :ok = GenServer.call(pid, {:evaluate_events, []}) end)

    assert recovery_log =~ "recovered"
    assert_receive {:telemetry, @rules_loaded_event, %{count: 1}, %{shard: 3}}
    refute :sys.get_state(pid).rules_load_error_logged
  end

  test "cold query failure is an error, but a successful empty load is acknowledged", %{
    pid: pid,
    mode: mode
  } do
    Agent.update(mode, fn _ -> {:error, :query_unavailable} end)

    capture_log(fn ->
      assert {:error, {:rules_load_failed, :query_unavailable}} =
               GenServer.call(pid, {:evaluate_events, [%{log_name: "node.not_ready"}]})
    end)

    assert :sys.get_state(pid).rules_loaded_at == nil

    Agent.update(mode, fn _ -> {:ok, []} end)

    capture_log(fn ->
      assert :ok = GenServer.call(pid, {:evaluate_events, [%{log_name: "node.not_ready"}]})
    end)

    assert is_integer(:sys.get_state(pid).rules_loaded_at)
    assert_receive {:telemetry, @rules_loaded_event, %{count: 0}, %{shard: 3}}
  end

  test "a successful empty rule cache remains usable across repeated refresh failures", %{
    pid: pid,
    mode: mode
  } do
    assert :ok = GenServer.call(pid, {:evaluate_events, []})
    Agent.update(mode, fn _ -> {:error, :query_unavailable} end)
    expire_rules_cache(pid)

    capture_log(fn ->
      assert :ok = GenServer.call(pid, {:evaluate_events, [%{log_name: "node.not_ready"}]})
      assert :ok = GenServer.call(pid, {:evaluate_events, [%{log_name: "node.not_ready"}]})
    end)

    assert_receive {:telemetry, @rules_load_failed_event, _, _}
    assert_receive {:telemetry, @rules_load_failed_event, _, _}
  end

  test "warm refresh failure still evaluates records with cached rules", %{pid: pid, mode: mode} do
    rule = %{
      id: rule_id_for_shard(3),
      name: "cached-rule",
      signal: :event,
      match: %{"always" => true},
      group_by: [],
      threshold: 1,
      window_seconds: 120,
      bucket_seconds: 60,
      cooldown_seconds: 0,
      renotify_seconds: 0
    }

    Agent.update(mode, fn _ -> {:ok, [rule]} end)
    assert :ok = GenServer.call(pid, {:evaluate_events, []})

    :sys.replace_state(pid, fn state ->
      Map.put(state, :create_event_and_alert, fn _, _, _, _ ->
        {:error, :cached_rule_evaluated}
      end)
    end)

    expire_rules_cache(pid)
    Agent.update(mode, fn _ -> {:error, :query_unavailable} end)
    event = %{time: ~U[2026-09-05 12:00:00Z], log_name: "test.node", metadata: %{}, unmapped: %{}}

    capture_log(fn ->
      assert {:error, :cached_rule_evaluated} = GenServer.call(pid, {:evaluate_events, [event]})
      assert {:error, :cached_rule_evaluated} = GenServer.call(pid, {:evaluate_events, [event]})
    end)
  end

  test "failed restoration rejects recovery and retries before resolving", %{pid: pid} do
    rule_id = rule_id_for_shard(3)
    now = ~U[2026-09-05 12:00:00Z]
    {:ok, snapshots} = Agent.start_link(fn -> {:error, :read_unavailable} end)
    test_pid = self()

    rule = %{
      id: rule_id,
      name: "restored-node",
      signal: :event,
      group_by: [],
      match: %{"subject_prefix" => "test.down", "recovery" => %{"subject_prefix" => "test.ready"}},
      bucket_seconds: 60
    }

    :sys.replace_state(pid, fn state ->
      state
      |> Map.merge(%{rules: [rule], rules_loaded_at: System.monotonic_time(:millisecond)})
      |> Map.put(:snapshots_reader, fn -> Agent.get(snapshots, & &1) end)
      |> Map.put(:resolve_alert, fn id, _, _, _ ->
        send(test_pid, {:resolved, id})
        :ok
      end)
      |> Map.put(:persist_snapshot, fn _, _, _ -> :ok end)
    end)

    event = %{time: now, log_name: "test.ready", metadata: %{}, unmapped: %{}}

    assert {:error, {:snapshot_restore_failed, :read_unavailable}} =
             GenServer.call(pid, {:evaluate_events, [event]})

    refute_received {:resolved, _}

    snapshot = %{
      rule_id: rule_id,
      group_key: "global",
      group_values: %{},
      window_seconds: 120,
      bucket_seconds: 60,
      current_bucket_start: now,
      bucket_counts: %{},
      last_seen_at: now,
      last_fired_at: now,
      last_notification_at: now,
      cooldown_until: nil,
      alert_id: "restored-alert"
    }

    Agent.update(snapshots, fn _ -> {:ok, [snapshot]} end)
    assert :ok = GenServer.call(pid, {:evaluate_events, [event]})
    assert_received {:resolved, "restored-alert"}
    assert :sys.get_state(pid).snapshots_loaded?

    Agent.update(snapshots, fn _ -> {:error, :must_not_reload} end)
    assert :ok = GenServer.call(pid, {:evaluate_events, []})
  end

  defp expire_rules_cache(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | rules_loaded_at: System.monotonic_time(:millisecond) - 120_000}
    end)
  end

  defp rule_id_for_shard(shard) do
    (&Ash.UUID.generate/0)
    |> Stream.repeatedly()
    |> Enum.find(fn id -> :erlang.phash2(id, 8) == shard end)
  end
end
