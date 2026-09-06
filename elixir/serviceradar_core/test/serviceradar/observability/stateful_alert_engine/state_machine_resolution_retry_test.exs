defmodule ServiceRadar.Observability.StatefulAlertEngine.StateMachineResolutionRetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Observability.StatefulAlertEngine.Bucketing
  alias ServiceRadar.Observability.StatefulAlertEngine.Diagnostics
  alias ServiceRadar.Observability.StatefulAlertEngine.StateMachine

  @alert_id "alert-awaiting-durable-resolution"

  setup do
    table = :ets.new(:state_machine_resolution_retry, [:set, :private])
    {:ok, table: table}
  end

  test "a failed stale recovery keeps the alert attached for the next sweep", %{table: table} do
    now = ~U[2026-08-11 12:00:00Z]
    rule = rule()
    key = {rule.id, "global"}
    snapshot = snapshot(rule, now, last_seen_at: DateTime.add(now, -120, :second))
    :ets.insert(table, {key, snapshot})

    calls = :counters.new(1, [])
    state = state(table, failing_resolver(calls))
    cutoff = DateTime.add(now, -60, :second)

    log =
      capture_log(fn ->
        assert StateMachine.sweep_stale_anomalies(rule, cutoff, now, state) == 0
        assert StateMachine.sweep_stale_anomalies(rule, cutoff, now, state) == 0
      end)

    assert log =~ "Keeping alert #{@alert_id} open after recovery failed"
    assert :counters.get(calls, 1) == 2
    assert [{^key, retained}] = :ets.lookup(table, key)
    assert retained.alert_id == @alert_id
    assert retained.last_notification_at == snapshot.last_notification_at
  end

  test "a failed incident rollover keeps the existing alert instead of opening a new one", %{
    table: table
  } do
    now = ~U[2026-08-11 12:00:00Z]
    rule = rule()
    key = {rule.id, "global"}

    # Keep the current bucket aligned with the new event. The old last-seen
    # timestamp still crosses the rollover gap, while avoiding an unrelated
    # persistence flush in this pure state-machine regression.
    snapshot =
      snapshot(rule, now,
        last_seen_at: DateTime.add(now, -61, :second),
        current_bucket_start: Bucketing.to_bucket_start(now, rule.bucket_seconds)
      )

    :ets.insert(table, {key, snapshot})

    calls = :counters.new(1, [])
    state = state(table, failing_resolver(calls))

    log =
      capture_log(fn ->
        assert {:error, {:routing_enqueue_failed, :queue_down}} =
                 StateMachine.process_event_rules(event(now), [rule], state)
      end)

    assert log =~ "Keeping alert #{@alert_id} open after rollover resolution failed"
    assert :counters.get(calls, 1) == 1
    assert [{^key, retained}] = :ets.lookup(table, key)
    assert retained.alert_id == @alert_id
    assert retained.last_notification_at == snapshot.last_notification_at
  end

  test "the record after a failed rollover retries and opens the replacement incident", %{
    table: table
  } do
    now = ~U[2026-08-11 12:00:00Z]
    next_seen_at = DateTime.add(now, 1, :second)
    rule = rule()
    key = {rule.id, "global"}

    snapshot =
      snapshot(rule, now,
        last_seen_at: DateTime.add(now, -61, :second),
        current_bucket_start: Bucketing.to_bucket_start(now, rule.bucket_seconds)
      )

    :ets.insert(table, {key, snapshot})

    resolve_calls = :counters.new(1, [])
    create_calls = :counters.new(1, [])

    resolver = fn @alert_id, _rule, _snapshot, _now ->
      :counters.add(resolve_calls, 1, 1)

      if :counters.get(resolve_calls, 1) == 1,
        do: {:error, {:routing_enqueue_failed, :queue_down}},
        else: :ok
    end

    creator = fn _rule, _snapshot, _record, _now ->
      :counters.add(create_calls, 1, 1)
      {:ok, "replacement-alert"}
    end

    state =
      table
      |> state(resolver)
      |> Map.put(:create_event_and_alert, creator)
      |> Map.put(:persist_snapshot, fn _snapshot, _rule, _state -> :ok end)

    capture_log(fn ->
      assert {:error, {:routing_enqueue_failed, :queue_down}} =
               StateMachine.process_event_rules(event(now), [rule], state)

      assert :ok = StateMachine.process_event_rules(event(next_seen_at), [rule], state)
    end)

    assert :counters.get(resolve_calls, 1) == 2
    assert :counters.get(create_calls, 1) == 1
    assert [{^key, replacement}] = :ets.lookup(table, key)
    assert replacement.alert_id == "replacement-alert"
    assert replacement.last_fired_at == next_seen_at
  end

  test "engine replies with alert creation failure without consuming the record", %{table: table} do
    now = ~U[2026-08-11 12:00:00Z]
    rule = rule()

    state = %{
      table: table,
      rules: [rule],
      snapshots_loaded?: true,
      rules_loaded_at: System.monotonic_time(:millisecond),
      create_event_and_alert: fn _, _, _, _ -> {:error, :alert_insert_failed} end
    }

    capture_log(fn ->
      assert {:reply, {:error, :alert_insert_failed}, ^state} =
               StatefulAlertEngine.handle_call(
                 {:evaluate_events, [event(now)]},
                 {self(), make_ref()},
                 state
               )
    end)

    assert [] = :ets.tab2list(table)
  end

  test "engine replies with recovery failure and retains the original snapshot", %{table: table} do
    now = ~U[2026-08-11 12:00:00Z]

    rule = %{
      rule()
      | match: %{
          "subject_prefix" => "test.down",
          "recovery" => %{"subject_prefix" => "test.rollover"}
        }
    }

    key = {rule.id, "global"}
    snapshot = snapshot(rule, now, [])
    :ets.insert(table, {key, snapshot})
    calls = :counters.new(1, [])

    state =
      Map.merge(state(table, failing_resolver(calls)), %{
        rules: [rule],
        snapshots_loaded?: true,
        rules_loaded_at: System.monotonic_time(:millisecond)
      })

    capture_log(fn ->
      assert {:reply, {:error, {:routing_enqueue_failed, :queue_down}}, ^state} =
               StatefulAlertEngine.handle_call(
                 {:evaluate_events, [event(now)]},
                 {self(), make_ref()},
                 state
               )
    end)

    assert [{^key, ^snapshot}] = :ets.lookup(table, key)
    assert :counters.get(calls, 1) == 1
  end

  test "failed rules and records do not prevent independent evaluations", %{table: table} do
    now = ~U[2026-08-11 12:00:00Z]
    failing_rule = rule()
    healthy_rule = %{rule() | id: "healthy-rule", threshold: 100}
    test_pid = self()

    state = %{
      table: table,
      rules: [failing_rule, healthy_rule],
      snapshots_loaded?: true,
      rules_loaded_at: System.monotonic_time(:millisecond),
      create_event_and_alert: fn _, _, record, _ ->
        send(test_pid, {:attempted, record.id})
        {:error, record.id}
      end,
      persist_snapshot: fn _, _, _ -> :ok end
    }

    first = %{event(now) | id: "first"}
    second = %{event(DateTime.add(now, 1, :second)) | id: "second"}

    capture_log(fn ->
      assert {:reply, {:error, "first"}, ^state} =
               StatefulAlertEngine.handle_call(
                 {:evaluate_events, [first, second]},
                 {self(), make_ref()},
                 state
               )
    end)

    assert_received {:attempted, "first"}
    assert_received {:attempted, "second"}
    assert [{_, %{window_count: 2}}] = :ets.lookup(table, {healthy_rule.id, "global"})
    assert [] = :ets.lookup(table, {failing_rule.id, "global"})
  end

  test "engine rejects failed snapshot persistence and retries the pending state", %{table: table} do
    now = ~U[2026-08-11 12:00:00Z]
    rule = %{rule() | threshold: 100}
    key = {rule.id, "global"}
    pending = snapshot(rule, now, alert_id: nil, flush_required: true)
    :ets.insert(table, {key, pending})
    calls = :counters.new(1, [])
    test_pid = self()

    state = %{
      table: table,
      rules: [rule],
      snapshots_loaded?: true,
      rules_loaded_at: System.monotonic_time(:millisecond),
      persist_snapshot: fn snapshot, _, _ ->
        :counters.add(calls, 1, 1)
        send(test_pid, {:persisted, snapshot})
        if :counters.get(calls, 1) == 1, do: :error, else: :ok
      end
    }

    assert {:reply, {:error, :snapshot_persistence_failed}, ^state} =
             StatefulAlertEngine.handle_call(
               {:evaluate_events, [event(now)]},
               {self(), make_ref()},
               state
             )

    assert [{^key, %{flush_required: true, window_count: 1}}] = :ets.lookup(table, key)
    assert_received {:persisted, %{flush_required: true, window_count: 1}}

    assert {:reply, :ok, ^state} =
             StatefulAlertEngine.handle_call(
               {:evaluate_events, [event(now)]},
               {self(), make_ref()},
               state
             )

    assert_received {:persisted, %{flush_required: true, window_count: 2}}
    assert [{^key, %{flush_required: false, bucket_changed: false}}] = :ets.lookup(table, key)
    assert :counters.get(calls, 1) == 2
  end

  test "redelivery persists the newly opened incident without creating a duplicate", %{
    table: table
  } do
    now = ~U[2026-08-11 12:00:00Z]
    rule = rule()
    key = {rule.id, "global"}
    calls = :counters.new(2, [])

    state = %{
      table: table,
      create_event_and_alert: fn _, _, _, _ ->
        :counters.add(calls, 1, 1)
        {:ok, "synthetic-pending-incident"}
      end,
      persist_snapshot: fn snapshot, _, _ ->
        assert snapshot.alert_id == "synthetic-pending-incident"
        :counters.add(calls, 2, 1)
        if :counters.get(calls, 2) == 1, do: :error, else: :ok
      end
    }

    assert {:error, :snapshot_persistence_failed} =
             StateMachine.process_event_rules(event(now), [rule], state)

    assert [{^key, %{alert_id: "synthetic-pending-incident", flush_required: true}}] =
             :ets.lookup(table, key)

    assert :ok = StateMachine.process_event_rules(event(now), [rule], state)

    assert [{^key, %{alert_id: "synthetic-pending-incident", flush_required: false}}] =
             :ets.lookup(table, key)

    assert :counters.get(calls, 1) == 1
    assert :counters.get(calls, 2) == 2
  end

  test "failed recovery persistence retains the resolved snapshot for redelivery", %{table: table} do
    now = ~U[2026-08-11 12:00:00Z]
    rule = rule()
    key = {rule.id, "global"}
    :ets.insert(table, {key, snapshot(rule, now, [])})
    test_pid = self()

    state = %{
      table: table,
      resolve_alert: fn alert_id, _, _, _ ->
        send(test_pid, {:resolved, alert_id})
        :ok
      end,
      persist_snapshot: fn _, _, _ -> :error end
    }

    assert {:error, :snapshot_persistence_failed} =
             StateMachine.recover_event(rule, event(now), state)

    assert_received {:resolved, @alert_id}
    assert [{^key, %{alert_id: nil, flush_required: true}}] = :ets.lookup(table, key)

    retry_state = Map.put(state, :persist_snapshot, fn _, _, _ -> :ok end)
    assert :ok = StateMachine.recover_event(rule, event(now), retry_state)
    assert [{^key, %{alert_id: nil, flush_required: false}}] = :ets.lookup(table, key)
    refute_received {:resolved, @alert_id}
  end

  defp state(table, resolver) do
    %{
      table: table,
      resolve_alert: resolver
    }
  end

  defp failing_resolver(calls) do
    fn @alert_id, _rule, _snapshot, _now ->
      :counters.add(calls, 1, 1)
      {:error, {:routing_enqueue_failed, :queue_down}}
    end
  end

  defp rule do
    %{
      id: "resolution-retry-rule",
      name: "resolution retry rule",
      signal: :event,
      enabled: true,
      match: %{"always" => true},
      group_by: [],
      threshold: 1,
      window_seconds: 120,
      bucket_seconds: 60,
      cooldown_seconds: 60,
      renotify_seconds: 0
    }
  end

  defp snapshot(rule, now, overrides) do
    bucket_start = Bucketing.to_bucket_start(now, rule.bucket_seconds)

    Map.merge(
      %{
        rule_id: rule.id,
        group_key: "global",
        group_values: %{},
        window_seconds: rule.window_seconds,
        bucket_seconds: rule.bucket_seconds,
        current_bucket_start: bucket_start,
        bucket_counts: %{bucket_start => 0},
        window_count: 0,
        last_seen_at: DateTime.add(now, -30, :second),
        last_fired_at: DateTime.add(now, -300, :second),
        last_notification_at: DateTime.add(now, -300, :second),
        cooldown_until: nil,
        alert_id: @alert_id,
        first_seen_at: DateTime.add(now, -300, :second),
        diagnostics: Diagnostics.empty_diagnostics(),
        bucket_changed: false,
        flush_required: false
      },
      Map.new(overrides)
    )
  end

  defp event(now) do
    %{
      id: "rollover-event",
      time: now,
      log_name: "test.rollover",
      log_provider: "test",
      metadata: %{},
      unmapped: %{}
    }
  end
end
