defmodule ServiceRadar.Observability.AlertEvaluationInboxTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.AlertEvaluationLane
  alias ServiceRadar.Observability.AlertEvaluationReceipt
  alias ServiceRadar.Observability.AlertEvaluationWork
  alias ServiceRadar.Observability.StatefulAlertEngine.Completion
  alias ServiceRadar.Observability.StatefulAlertEngine.Inbox
  alias ServiceRadar.Observability.StatefulAlertEngine.Owner
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
          "UPDATE platform.stateful_alert_rules SET enabled = TRUE WHERE id = ANY($1::uuid[])",
          [Enum.map(enabled_before, &hd/1)]
        )
      end)
    end

    {:ok, rule: rule, actor: actor}
  end

  @tag sandbox: :unboxed
  test "a blocked owner neither delays another rule nor loses its input when killed", %{
    rule: rule,
    actor: actor
  } do
    rule =
      rule
      |> Ash.Changeset.for_update(:update, %{match: %{"body_contains" => "slow"}}, actor: actor)
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
          threshold: 100,
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

    Process.exit(blocked, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^blocked, :killed}, 5_000
    send(locker, :release)
    assert_receive {:DOWN, ^lock_monitor, :process, ^locker, :normal}, 5_000

    assert [%{position: 2}] = work(rule, actor)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)

    assert [%{bucket_counts: %{"1767225600" => 2}}] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert {:ok, [_]} = Inbox.admit(:event, [slow_input])
    assert [] = work(rule, actor)
    assert {:ok, :empty} = Owner.advance(rule.id)
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
      "DELETE FROM platform.oban_jobs WHERE worker = $1 AND args->>'rule_id' = ANY($2::text[])",
      ["ServiceRadar.Observability.StatefulAlertEngine.EvaluationWorker", ids]
    )

    for table <-
          ~w(alert_evaluation_work alert_evaluation_receipts alert_evaluation_lanes stateful_alert_rule_histories stateful_alert_rule_states) do
      Repo.query!("DELETE FROM platform.#{table} WHERE rule_id::text = ANY($1::text[])", [ids])
    end

    Repo.query!("DELETE FROM platform.stateful_alert_rules WHERE id::text = ANY($1::text[])", [
      ids
    ])

    assert Repo.query!(
             "SELECT count(*) FROM platform.alert_evaluation_work WHERE rule_id::text = ANY($1::text[])",
             [ids]
           ).rows ==
             [[0]]
  end
end
