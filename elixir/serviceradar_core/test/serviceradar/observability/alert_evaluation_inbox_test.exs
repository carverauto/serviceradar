defmodule ServiceRadar.Observability.AlertEvaluationInboxTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ingestion.RuntimeMetrics, as: MetricPublisher
  alias Serviceradar.Metric.V1.MetricBatch
  alias ServiceRadar.Observability.AlertEvaluationLane
  alias ServiceRadar.Observability.AlertEvaluationReceipt
  alias ServiceRadar.Observability.AlertEvaluationWork
  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Observability.StatefulAlertEngine.Completion
  alias ServiceRadar.Observability.StatefulAlertEngine.EvaluationWorker
  alias ServiceRadar.Observability.StatefulAlertEngine.Inbox
  alias ServiceRadar.Observability.StatefulAlertEngine.Owner
  alias ServiceRadar.Observability.StatefulAlertEngine.RecoveryWorker
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.StatefulAlertRuleState
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration
  @time ~U[2026-01-01 00:00:00.000000Z]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup context do
    old_limits = Application.get_env(:serviceradar_core, :alert_evaluation_limits)
    old_mode = Application.get_env(:serviceradar_core, :alert_evaluation_mode)
    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :active)

    on_exit(fn ->
      if old_mode do
        Application.put_env(:serviceradar_core, :alert_evaluation_mode, old_mode)
      else
        Application.delete_env(:serviceradar_core, :alert_evaluation_mode)
      end

      if old_limits do
        Application.put_env(:serviceradar_core, :alert_evaluation_limits, old_limits)
      else
        Application.delete_env(:serviceradar_core, :alert_evaluation_limits)
      end
    end)

    # The serial sandbox rolls this back. Only the test's rule is eligible;
    # seeded rules must not make capacity assertions depend on their inventory.
    enabled_before =
      Repo.query!("SELECT id FROM platform.stateful_alert_rules WHERE enabled").rows

    cleanup_jobs_before =
      Repo.query!(
        "SELECT id FROM platform.oban_jobs WHERE worker = 'ServiceRadar.Observability.StatefulAlertCleanupWorker'"
      ).rows

    Repo.query!("UPDATE platform.stateful_alert_rules SET enabled = FALSE")
    actor = SystemActor.system(:alert_engine)

    rule =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "synthetic-inbox-#{Ash.UUID.generate()}",
          signal: :event,
          match: %{"always" => true},
          group_by: [],
          threshold: 100,
          window_seconds: 120,
          bucket_seconds: 60
        },
        actor: actor
      )
      |> Ash.create!()

    if context[:sandbox] == :unboxed do
      on_exit(fn ->
        cleanup_unboxed(rule.name)

        Repo.query!(
          "DELETE FROM platform.oban_jobs WHERE worker = 'ServiceRadar.Observability.StatefulAlertCleanupWorker' AND NOT (id = ANY($1::bigint[]))",
          [Enum.map(cleanup_jobs_before, &hd/1)]
        )

        assert Enum.sort(
                 Repo.query!(
                   "SELECT id FROM platform.oban_jobs WHERE worker = 'ServiceRadar.Observability.StatefulAlertCleanupWorker'"
                 ).rows
               ) == Enum.sort(cleanup_jobs_before)

        Repo.query!(
          "UPDATE platform.stateful_alert_rules SET enabled = TRUE WHERE id = ANY($1::uuid[])",
          [Enum.map(enabled_before, &hd/1)]
        )
      end)
    end

    {:ok, rule: rule, actor: actor}
  end

  @tag sandbox: :unboxed
  test "recovery replaces discarded, missing and abandoned wake-ups without losing accepted input",
       %{
         rule: rule,
         actor: actor
       } do
    worker = Oban.Worker.to_string(EvaluationWorker)

    for loss <- [:discarded, :missing, :executing] do
      input = event()
      assert {:ok, keys} = Inbox.admit(:event, [input])

      assert [[hint_id]] =
               Repo.query!(
                 "SELECT id FROM platform.oban_jobs WHERE worker = $1 AND args->>'rule_id' = $2 AND state = 'available'",
                 [worker, rule.id]
               ).rows

      case loss do
        :discarded ->
          Repo.query!(
            "UPDATE platform.oban_jobs SET state = 'discarded', discarded_at = timezone('utc', now()) WHERE id = $1",
            [hint_id]
          )

        :missing ->
          Repo.query!("DELETE FROM platform.oban_jobs WHERE id = $1", [hint_id])

        :executing ->
          Repo.query!(
            "UPDATE platform.oban_jobs SET state = 'executing', attempt = 1, attempted_at = timezone('utc', now()) WHERE id = $1",
            [hint_id]
          )
      end

      assert [_] = work(rule, actor)
      assert {:error, :evaluation_completion_timeout} = Completion.await(keys, 25)
      assert :ok = RecoveryWorker.perform(%Oban.Job{})

      assert [[replacement_id]] =
               Repo.query!(
                 "SELECT id FROM platform.oban_jobs WHERE worker = $1 AND args->>'rule_id' = $2 AND state = 'available'",
                 [worker, rule.id]
               ).rows

      refute replacement_id == hint_id
      assert :ok = RecoveryWorker.perform(%Oban.Job{})

      assert [[replacement_id]] ==
               Repo.query!(
                 "SELECT id FROM platform.oban_jobs WHERE worker = $1 AND args->>'rule_id' = $2 AND state = 'available'",
                 [worker, rule.id]
               ).rows

      assert %{failure: 0} = Oban.drain_queue(queue: :alerts, with_recursion: true)
      assert {:ok, [%{disposition: :completed}]} = Completion.await(keys, 1_000)
      assert [] = work(rule, actor)
      assert {:ok, ^keys} = Inbox.admit(:event, [input])
      assert [] = work(rule, actor)
    end

    assert [%{bucket_counts: %{"1767225600" => 3}}] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)
  end

  @tag sandbox: :unboxed
  test "a failed rule read rejects the batch and a repaired store accepts its redelivery", %{
    rule: rule,
    actor: actor
  } do
    input = event()

    Repo.query!(
      "ALTER TABLE platform.stateful_alert_rules RENAME COLUMN match TO synthetic_unavailable_match"
    )

    try do
      assert {:error, {:store_unavailable, _}} = StatefulAlertEngine.evaluate_events([input])
      assert [] = work(rule, actor)
    after
      Repo.query!(
        "ALTER TABLE platform.stateful_alert_rules RENAME COLUMN synthetic_unavailable_match TO match"
      )
    end

    assert :ok = StatefulAlertEngine.evaluate_events([input])
    assert [%{position: 1}] = work(rule, actor)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert [] = work(rule, actor)
  end

  @tag sandbox: :unboxed
  test "failed snapshot restoration backs off without overtaking and retries authoritative counts",
       %{
         rule: rule,
         actor: actor
       } do
    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, keys} = Inbox.admit(:event, [event(), event()])

    Repo.query!(
      "ALTER TABLE platform.stateful_alert_rule_states RENAME TO synthetic_unavailable_alert_states"
    )

    try do
      assert {:snooze, 2} = EvaluationWorker.perform(%Oban.Job{args: %{"rule_id" => rule.id}})
      assert [%{position: 2, attempts: 1}, %{position: 3, attempts: 0}] = work(rule, actor)
      assert {:ok, {:backoff, seconds}} = Owner.advance(rule.id)
      assert seconds > 0
      assert {:error, :evaluation_completion_timeout} = Completion.await(keys, 25)
    after
      Repo.query!(
        "ALTER TABLE platform.synthetic_unavailable_alert_states RENAME TO stateful_alert_rule_states"
      )
    end

    Repo.query!(
      "UPDATE platform.alert_evaluation_work SET available_at = timezone('utc', now()) - interval '1 second' WHERE rule_id = $1 AND position = 2",
      [Ecto.UUID.dump!(rule.id)]
    )

    assert :ok = EvaluationWorker.perform(%Oban.Job{args: %{"rule_id" => rule.id}})

    assert {:ok, [%{disposition: :completed}, %{disposition: :completed}]} =
             Completion.await(keys, 1_000)

    assert [] = work(rule, actor)

    assert [%{bucket_counts: %{"1767225600" => 3}}] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)
  end

  @tag sandbox: :unboxed
  test "a blocked owner neither delays another rule nor loses its input when killed", %{
    rule: rule,
    actor: actor
  } do
    rule =
      rule
      |> Ash.Changeset.for_update(
        :update,
        %{
          match: %{"body_contains" => "slow"},
          threshold: 2,
          alert: %{"title" => "Synthetic slow owner"}
        },
        actor: actor
      )
      |> Ash.update!()

    initial = %{event() | message: "slow initial"}
    assert {:ok, [_]} = Inbox.admit(:event, [initial])
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)

    assert [snapshot] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    fast =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: rule.name <> "-fast",
          signal: :event,
          match: %{"body_contains" => "fast"},
          group_by: [],
          threshold: 1,
          alert: %{"title" => "Synthetic independent owner"},
          window_seconds: 120,
          bucket_seconds: 60
        },
        actor: actor
      )
      |> Ash.create!()

    slow_input = %{event() | message: "slow pending"}
    assert {:ok, [_]} = Inbox.admit(:event, [slow_input])

    parent = self()

    {locker, lock_monitor} =
      spawn_monitor(fn ->
        Repo.transaction(fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

          Repo.query!(
            "SELECT id FROM platform.stateful_alert_rule_states WHERE id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(snapshot.id)]
          )

          send(parent, {:snapshot_locked, self(), backend})

          receive do
            :release -> :ok
          after
            15_000 -> raise "synthetic row lock was not released"
          end
        end)
      end)

    on_exit(fn -> if Process.alive?(locker), do: Process.exit(locker, :kill) end)
    assert_receive {:snapshot_locked, ^locker, backend}, 5_000

    {blocked, owner_monitor} =
      spawn_monitor(fn ->
        send(parent, {:blocked_owner_returned, Owner.advance(rule.id)})
      end)

    on_exit(fn -> if Process.alive?(blocked), do: Process.exit(blocked, :kill) end)

    assert wait_until(
             fn ->
               Repo.query!(
                 "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid)))",
                 [backend]
               ).rows == [[true]]
             end,
             5_000
           )

    # The slow owner is actually blocked in its snapshot write. Both durable
    # acceptance and another rule's committed effects finish before release.
    assert {:ok, [_]} = Inbox.admit(:event, [%{event() | message: "fast independent"}])
    assert {:ok, {:processed, :completed}} = Owner.advance(fast.id)

    assert [%{bucket_counts: %{"1767225600" => 1}}] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^fast.id)
             |> Ash.read!(actor: actor)

    assert Process.alive?(blocked)
    refute_receive {:blocked_owner_returned, _}, 0

    # A synthetic burst distinguishes durable acknowledgement from effects:
    # the blocked rule remains pending while the independent rule drains.
    burst_size = 16
    fast_burst = Enum.map(1..burst_size, fn _ -> %{event() | message: "fast synthetic burst"} end)
    slow_burst = Enum.map(1..burst_size, fn _ -> %{event() | message: "slow synthetic burst"} end)

    {admission_us, {:ok, burst_keys}} =
      :timer.tc(fn -> Inbox.admit(:event, fast_burst ++ slow_burst) end)

    assert length(burst_keys) == burst_size * 2

    %{rows: [[pending_count, pending_bytes]]} =
      Repo.query!(
        "SELECT count(*), sum(payload_bytes)::bigint FROM platform.alert_evaluation_work WHERE rule_id = ANY($1::uuid[])",
        [[Ecto.UUID.dump!(rule.id), Ecto.UUID.dump!(fast.id)]]
      )

    assert pending_count == burst_size * 2 + 1
    assert pending_bytes > 0

    {effect_us, :ok} =
      :timer.tc(fn ->
        Enum.each(fast_burst, fn _ ->
          assert {:ok, {:processed, :completed}} = Owner.advance(fast.id)
        end)
      end)

    assert [] = work(fast, actor)
    assert length(work(rule, actor)) == burst_size + 1
    assert alert_count(fast.id) == 1
    assert history_count(fast.id) == 1
    refute_receive {:blocked_owner_returned, _}, 0

    %{rows: [[blocked_connections]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
        [backend]
      )

    assert blocked_connections > 0

    IO.puts(
      "ALERT_EVALUATION_SYNTHETIC_LOAD " <>
        Jason.encode!(%{
          input_records: burst_size * 2,
          accepted_rule_occurrences: length(burst_keys),
          rejected_rule_occurrences: 0,
          admission_us: admission_us,
          independent_effect_us: effect_us,
          independent_effects_per_second: burst_size * 1_000_000 / max(effect_us, 1),
          queued_count: pending_count,
          queued_bytes: pending_bytes,
          blocked_owner_connections: blocked_connections,
          configured_repo_pool_size: Repo.config()[:pool_size],
          consumer: "real database owners driven by fixture"
        })
    )

    Process.exit(blocked, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^blocked, :killed}, 5_000
    send(locker, :release)
    assert_receive {:DOWN, ^lock_monitor, :process, ^locker, :normal}, 5_000

    assert length(work(rule, actor)) == burst_size + 1
    assert hd(work(rule, actor)).position == 2
    # The killed transaction had reached the snapshot write after creating
    # the alert and its outbox. None of those effects may survive rollback.
    assert alert_count(rule.id) == 0
    assert history_count(rule.id) == 0
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert alert_count(rule.id) == 1
    assert history_count(rule.id) == 1

    Enum.each(slow_burst, fn _ ->
      assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    end)

    assert [%{bucket_counts: %{"1767225600" => occurrence_count}}] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert occurrence_count == burst_size + 2

    assert {:ok, replay_keys} = Inbox.admit(:event, [slow_input | slow_burst])
    assert length(replay_keys) == burst_size + 1
    assert [] = work(rule, actor)
    assert {:ok, :empty} = Owner.advance(rule.id)
    assert alert_count(rule.id) == 1
    assert history_count(rule.id) == 1
  end

  @tag sandbox: :unboxed
  test "failed alert creation and recovery preserve accepted work and commit lifecycle effects once",
       %{
         rule: rule,
         actor: actor
       } do
    rule =
      rule
      |> Ash.Changeset.for_update(
        :update,
        %{
          threshold: 1,
          match: %{"body_contains" => "down", "recovery" => %{"body_contains" => "ready"}},
          alert: %{"title" => rule.name}
        },
        actor: actor
      )
      |> Ash.update!()

    opened = %{event() | message: "synthetic down"}
    assert {:ok, keys} = Inbox.admit(:event, [opened])

    Repo.query!(
      "ALTER TABLE platform.alerts ADD CONSTRAINT synthetic_alert_creation_fault CHECK (title <> '#{rule.name}')"
    )

    try do
      assert {:error, {:evaluation_failed, _, _}} = Owner.advance(rule.id)
      assert [_] = work(rule, actor)
      assert alert_count(rule.id) == 0
      assert history_count(rule.id) == 0

      assert [] =
               StatefulAlertRuleState
               |> Ash.Query.filter(rule_id == ^rule.id)
               |> Ash.read!(actor: actor)
    after
      Repo.query!("ALTER TABLE platform.alerts DROP CONSTRAINT synthetic_alert_creation_fault")
    end

    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, [%{disposition: :completed}]} = Completion.await(keys, 1_000)
    assert alert_count(rule.id) == 1
    assert history_count(rule.id) == 1

    assert [snapshot] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    cleared = %{event() | message: "synthetic ready", time: DateTime.shift(@time, second: 30)}
    assert {:ok, clear_keys} = Inbox.admit(:event, [cleared])

    Repo.query!(
      "ALTER TABLE platform.alerts ADD CONSTRAINT synthetic_alert_recovery_fault CHECK (id <> '#{snapshot.alert_id}'::uuid OR status <> 'resolved')"
    )

    try do
      assert {:error, {:evaluation_failed, _, _}} = Owner.advance(rule.id)
      assert [_] = work(rule, actor)

      assert [%{alert_id: alert_id}] =
               StatefulAlertRuleState
               |> Ash.Query.filter(rule_id == ^rule.id)
               |> Ash.read!(actor: actor)

      assert alert_id == snapshot.alert_id

      assert Repo.query!("SELECT status FROM platform.alerts WHERE id = $1", [
               Ecto.UUID.dump!(alert_id)
             ]).rows == [
               ["pending"]
             ]

      assert history_count(rule.id) == 1
    after
      Repo.query!("ALTER TABLE platform.alerts DROP CONSTRAINT synthetic_alert_recovery_fault")
    end

    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, [%{disposition: :completed}]} = Completion.await(clear_keys, 1_000)

    assert Repo.query!("SELECT status FROM platform.alerts WHERE id = $1", [
             Ecto.UUID.dump!(snapshot.alert_id)
           ]).rows == [
             ["resolved"]
           ]

    assert [%{alert_id: nil}] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert history_count(rule.id) == 2

    assert {:ok, _} = Inbox.admit(:event, [opened, cleared])
    assert [] = work(rule, actor)
    assert alert_count(rule.id) == 1
    assert history_count(rule.id) == 2
  end

  test "invalid accepted input receives an audited terminal receipt", %{rule: rule, actor: actor} do
    assert {:ok, keys} = Inbox.admit(:event, [event()])

    Repo.query!(
      "UPDATE platform.alert_evaluation_work SET payload = jsonb_set(payload, '{time}', '123') WHERE rule_id = $1",
      [Ecto.UUID.dump!(rule.id)]
    )

    assert {:ok, {:processed, :failed}} = Owner.advance(rule.id)
    assert [] = work(rule, actor)

    assert [%{disposition: :failed, details: %{"reason" => "invalid_accepted_input"}}] =
             Ash.read!(AlertEvaluationReceipt, actor: actor)

    assert {:error, :evaluation_permanently_failed} = Completion.await(keys, 1_000)
  end

  test "receipt pruning respects replay retention and never prunes pending work", %{
    rule: rule,
    actor: actor
  } do
    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    assert {:ok, :ok} = AlertEvaluationReceipt.prune(DateTime.shift(DateTime.utc_now(), day: 6))
    assert [_] = Ash.read!(AlertEvaluationReceipt, actor: actor)
    assert {:ok, :ok} = AlertEvaluationReceipt.prune(DateTime.shift(DateTime.utc_now(), day: 8))
    assert [] = Ash.read!(AlertEvaluationReceipt, actor: actor)
    assert [%{position: 2}] = work(rule, actor)
  end

  test "prepared rejects admission and draining finishes accepted work without accepting more", %{
    rule: rule,
    actor: actor
  } do
    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :prepared)
    assert {:error, :alert_evaluation_not_activated} = Inbox.admit(:event, [event()])
    assert [] = work(rule, actor)

    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :active)
    assert {:ok, [_]} = Inbox.admit(:event, [event()])

    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :draining)
    assert {:error, :alert_evaluation_draining} = Inbox.admit(:event, [event()])
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert [] = work(rule, actor)
    assert [%{disposition: :completed}] = Ash.read!(AlertEvaluationReceipt, actor: actor)
  end

  test "count overload rejects the entire batch without reserving input positions", %{
    rule: rule,
    actor: actor
  } do
    Application.put_env(:serviceradar_core, :alert_evaluation_limits, pending_count: 2)
    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    assert {:error, {:overloaded, :pending_count}} = Inbox.admit(:event, [event(), event()])

    assert [%{position: 1}] = work(rule, actor)
    assert [%{next_position: 1}] = Ash.read!(AlertEvaluationLane, actor: actor)
    assert [] = Ash.read!(AlertEvaluationReceipt, actor: actor)
  end

  test "byte overload leaves no partly accepted rule or record", %{rule: rule, actor: actor} do
    Application.put_env(:serviceradar_core, :alert_evaluation_limits, pending_bytes: 2_048)
    oversized = Map.put(event(), :message, String.duplicate("x", 4_096))
    assert {:error, {:overloaded, :pending_bytes}} = Inbox.admit(:event, [event(), oversized])
    assert [] = work(rule, actor)
    assert [] = Ash.read!(AlertEvaluationLane, actor: actor)
  end

  test "an invalid timestamp rejects every occurrence before durable admission", %{
    rule: rule,
    actor: actor
  } do
    assert {:error, {:invalid_payload, _}} =
             Inbox.admit(:event, [event(), %{event() | time: 123}])

    assert [] = work(rule, actor)
    assert [] = Ash.read!(AlertEvaluationLane, actor: actor)
  end

  test "nonmatching input consumes no capacity but recovery input retains its order", %{
    rule: rule,
    actor: actor
  } do
    rule =
      rule
      |> Ash.Changeset.for_update(
        :update,
        %{match: %{"body_contains" => "open", "recovery" => %{"body_contains" => "clear"}}},
        actor: actor
      )
      |> Ash.update!()

    Application.put_env(:serviceradar_core, :alert_evaluation_limits, pending_count: 2)
    assert {:ok, []} = Inbox.admit(:event, [event()])

    assert {:ok, [_, _]} =
             Inbox.admit(:event, [%{event() | message: "open"}, %{event() | message: "clear"}])

    assert [%{position: 1}, %{position: 2}] = work(rule, actor)
  end

  test "editing a rule does not change the revision already accepted", %{rule: rule, actor: actor} do
    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    rule |> Ash.Changeset.for_update(:update, %{threshold: 1}, actor: actor) |> Ash.update!()
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)

    assert [%{alert_id: nil, bucket_counts: %{"1767225600" => 1}}] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)
  end

  test "cleanup preserves authoritative snapshots until all accepted inputs finish", %{
    rule: rule,
    actor: actor
  } do
    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)

    assert [snapshot] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    cutoff = DateTime.shift(@time, day: 31)

    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    assert {:ok, :kept} = Owner.cleanup_snapshot(rule.id, snapshot.id, cutoff)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, :deleted} = Owner.cleanup_snapshot(rule.id, snapshot.id, cutoff)

    assert [] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert length(Ash.read!(AlertEvaluationReceipt, actor: actor)) == 2
  end

  test "cleanup never removes the identity of an open incident", %{rule: rule, actor: actor} do
    rule =
      rule |> Ash.Changeset.for_update(:update, %{threshold: 1}, actor: actor) |> Ash.update!()

    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)

    assert [snapshot] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert is_binary(snapshot.alert_id)

    assert {:ok, :kept} =
             Owner.cleanup_snapshot(rule.id, snapshot.id, DateTime.shift(@time, day: 31))

    assert %{alert_id: alert_id} = Ash.get!(StatefulAlertRuleState, snapshot.id, actor: actor)
    assert alert_id == snapshot.alert_id
  end

  test "equal occurrences remain distinct and source replay survives changed batch boundaries", %{
    rule: rule,
    actor: actor
  } do
    first = event()
    second = event()
    assert {:ok, keys} = Inbox.admit(:event, [first, second])
    assert length(keys) == 2
    assert {:ok, [_]} = Inbox.admit(:event, [second])
    assert {:ok, [_]} = Inbox.admit(:event, [first])
    assert [%{position: 1}, %{position: 2}] = work(rule, actor)

    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, [_]} = Inbox.admit(:event, [first])
    assert [] = work(rule, actor)
    assert length(Ash.read!(AlertEvaluationReceipt, actor: actor)) == 2
  end

  test "replayed admission keeps receipt keys while inserting only new work", %{
    rule: rule,
    actor: actor
  } do
    parent = self()

    request = fn "metrics.ingestion_lanes", body, _opts ->
      send(parent, {:alert_metric_frame, body})
      {:ok, %{body: Jason.encode!(%{stream: "SYNTHETIC_METRICS", seq: 1})}}
    end

    start_supervised!({MetricPublisher, interval_ms: 20, publish_opts: [request: request]})

    first = event()
    second = event()
    third = event()
    assert {:ok, keys} = Inbox.admit(:event, [first, second])
    assert [%{position: 1}, %{position: 2}] = work(rule, actor)
    assert [%{next_position: 2}] = Ash.read!(AlertEvaluationLane, actor: actor)

    assert {:ok, replay_pending} = Inbox.admit(:event, [first, second])
    assert Enum.sort(replay_pending) == Enum.sort(keys)
    assert [%{position: 1}, %{position: 2}] = work(rule, actor)
    assert [%{next_position: 2}] = Ash.read!(AlertEvaluationLane, actor: actor)

    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, receipts} = Completion.await(keys, 1_000)
    assert Enum.all?(receipts, &(&1.disposition == :completed))

    assert {:ok, replay_completed} = Inbox.admit(:event, [first, second])
    assert Enum.sort(replay_completed) == Enum.sort(keys)
    assert [] = work(rule, actor)
    assert {:ok, replay_receipts} = Completion.await(replay_completed, 1_000)
    assert Enum.all?(replay_receipts, &(&1.disposition == :completed))

    assert {:ok, mixed} = Inbox.admit(:event, [second, third])
    assert length(mixed) == 2
    assert Enum.at(keys, 1) in mixed
    assert [%{position: 3}] = work(rule, actor)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, mixed_receipts} = Completion.await(mixed, 1_000)
    assert Enum.all?(mixed_receipts, &(&1.disposition == :completed))
    assert [] = work(rule, actor)

    # Observe deltas through the real publisher, including any frames emitted
    # during the DB calls. The final gauge identifies the last observation.
    marker = 4_242
    MetricPublisher.record(:alert_event, :state, %{payload_bytes: marker})

    assert admitted_wire_total(marker, 0, System.monotonic_time(:millisecond) + 2_000) == 3.0
  end

  test "numeric source ids admit through the canonical contract and redeliver deduplicated", %{
    rule: rule,
    actor: actor
  } do
    first = event()
    numeric = %{event() | id: 71_904}
    assert {:ok, keys} = Inbox.admit(:event, [first, numeric])
    assert length(keys) == 2
    assert [%{position: 1}, %{position: 2}] = work(rule, actor)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, receipts} = Completion.await(keys, 1_000)
    assert Enum.all?(receipts, &(&1.disposition == :completed))
    assert {:ok, replay_keys} = Inbox.admit(:event, [numeric])
    assert replay_keys == [Enum.at(keys, 1)]
    assert [] = work(rule, actor)
    assert {:ok, [%{disposition: :completed}]} = Completion.await(replay_keys, 1_000)

    assert [snapshot] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert "71904" in snapshot.diagnostics["source_event_ids"]
  end

  test "fresh owners recover every count and diagnostics within one bucket", %{
    rule: rule,
    actor: actor
  } do
    first = event()
    second = %{event() | time: DateTime.shift(@time, second: 1)}
    assert {:ok, [_, _]} = Inbox.admit(:event, [first, second])
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)

    assert [snapshot] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert snapshot.bucket_counts == %{"1767225600" => 2}
    assert snapshot.first_seen_at == @time
    assert snapshot.last_seen_at == second.time
    assert Enum.sort(snapshot.diagnostics["source_event_ids"]) == Enum.sort([first.id, second.id])
    assert [] = work(rule, actor)
  end

  test "a disabled rule records cancellation rather than dropping accepted input", %{
    rule: rule,
    actor: actor
  } do
    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    rule |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: actor) |> Ash.update!()
    assert {:ok, {:processed, :cancelled}} = Owner.advance(rule.id)
    assert [] = work(rule, actor)

    assert [%{disposition: :cancelled, position: 1}] =
             Ash.read!(AlertEvaluationReceipt, actor: actor)

    assert [] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)
  end

  test "disabling and re-enabling cannot revive input accepted before disable", %{
    rule: rule,
    actor: actor
  } do
    assert {:ok, [_]} = Inbox.admit(:event, [event()])

    rule =
      rule |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: actor) |> Ash.update!()

    rule |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: actor) |> Ash.update!()
    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    assert {:ok, {:processed, :cancelled}} = Owner.advance(rule.id)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert [] = work(rule, actor)

    assert [%{bucket_counts: %{"1767225600" => 1}}] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)
  end

  test "raw replay truncation preserves accepted input until its cancellation receipt", %{
    rule: rule,
    actor: actor
  } do
    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    Repo.query!("TRUNCATE TABLE platform.stateful_alert_rules CASCADE")
    assert [%{position: 1}] = work(rule, actor)
    assert {:ok, {:processed, :cancelled}} = Owner.advance(rule.id)
    assert [%{disposition: :cancelled}] = Ash.read!(AlertEvaluationReceipt, actor: actor)
    assert [] = work(rule, actor)
  end

  test "maintenance waits behind accepted input and receipts retain the actual resolved count", %{
    rule: rule,
    actor: actor
  } do
    rule =
      rule |> Ash.Changeset.for_update(:update, %{threshold: 1}, actor: actor) |> Ash.update!()

    assert {:ok, [_]} = Inbox.admit(:event, [event()])
    now = DateTime.shift(@time, day: 2)

    assert {:ok, barrier} =
             Inbox.admit_maintenance(rule.name, DateTime.shift(@time, day: 1), now, MapSet.new())

    assert [%{position: 1, signal: :event}, %{position: 2, signal: :maintenance}] =
             work(rule, actor)

    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)

    assert [open] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert is_binary(open.alert_id)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)

    assert {:ok, [%{resolved_count: 1, disposition: :completed}]} =
             Completion.await(barrier, 1_000)

    assert [%{alert_id: nil}] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert [] = work(rule, actor)
  end

  defp admitted_wire_total(marker, total, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:alert_metric_frame, body} ->
        metrics =
          body
          |> MetricBatch.decode()
          |> Map.fetch!(:metrics)
          |> Enum.filter(fn metric ->
            Enum.any?(metric.tags, &(&1.key == "lane" and &1.value == "alert_event"))
          end)

        total =
          Enum.reduce(metrics, total, fn
            %{name: "result_ingestion_events_admitted", points: [%{value: count} | _]}, sum ->
              sum + count

            _, sum ->
              sum
          end)

        if Enum.any?(metrics, fn
             %{name: "result_ingestion_payload_bytes", points: [%{value: value} | _]}
             when value == marker ->
               true

             _ ->
               false
           end) do
          total
        else
          admitted_wire_total(marker, total, deadline)
        end
    after
      remaining -> flunk("admission metric never reached the final JetStream observation")
    end
  end

  defp work(rule, actor) do
    AlertEvaluationWork
    |> Ash.Query.filter(rule_id == ^rule.id)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(actor: actor)
  end

  defp event do
    %{
      id: Ash.UUID.generate(),
      time: @time,
      message: "synthetic input",
      severity_id: 4,
      log_name: "synthetic.check",
      log_provider: "example.collector",
      unmapped: %{}
    }
  end

  defp wait_until(predicate, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_deadline(predicate, deadline)
  end

  defp wait_until_deadline(predicate, deadline) do
    cond do
      predicate.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        wait_until_deadline(predicate, deadline)
    end
  end

  defp cleanup_unboxed(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id::text FROM platform.stateful_alert_rules WHERE name = $1 OR name = $1 || '-fast'",
        [name]
      )

    ids = Enum.map(rows, &hd/1)

    Repo.query!(
      """
      DELETE FROM platform.oban_jobs
      WHERE args->>'alert_id' IN (
        SELECT id::text FROM platform.alerts
        WHERE metadata->>'incident_rule_id' = ANY($1::text[])
      ) OR (worker = 'ServiceRadar.NATS.DurablePublishWorker' AND EXISTS (
        SELECT 1 FROM unnest($1::text[]) rule_id
        WHERE position(rule_id in coalesce(args->>'body', '')) > 0
      ))
      """,
      [ids]
    )

    Repo.query!(
      "DELETE FROM platform.oban_jobs WHERE worker = $1 AND args->>'rule_id' = ANY($2::text[])",
      ["ServiceRadar.Observability.StatefulAlertEngine.EvaluationWorker", ids]
    )

    for table <-
          ~w(alert_evaluation_work alert_evaluation_receipts alert_evaluation_lanes stateful_alert_rule_histories stateful_alert_rule_states) do
      Repo.query!("DELETE FROM platform.#{table} WHERE rule_id::text = ANY($1::text[])", [ids])
    end

    Repo.query!(
      "DELETE FROM platform.alerts WHERE metadata->>'incident_rule_id' = ANY($1::text[])",
      [ids]
    )

    Repo.query!(
      "DELETE FROM platform.ocsf_events WHERE metadata #>> '{serviceradar,rule_id}' = ANY($1::text[])",
      [ids]
    )

    Repo.query!("DELETE FROM platform.stateful_alert_rules WHERE id::text = ANY($1::text[])", [
      ids
    ])

    assert Repo.query!(
             "SELECT count(*) FROM platform.alert_evaluation_work WHERE rule_id::text = ANY($1::text[])",
             [ids]
           ).rows ==
             [[0]]
  end

  defp alert_count(rule_id) do
    Repo.query!(
      "SELECT count(*) FROM platform.alerts WHERE metadata->>'incident_rule_id' = $1",
      [rule_id]
    ).rows
    |> hd()
    |> hd()
  end

  defp history_count(rule_id) do
    Repo.query!(
      "SELECT count(*) FROM platform.stateful_alert_rule_histories WHERE rule_id = $1",
      [Ecto.UUID.dump!(rule_id)]
    ).rows
    |> hd()
    |> hd()
  end
end
