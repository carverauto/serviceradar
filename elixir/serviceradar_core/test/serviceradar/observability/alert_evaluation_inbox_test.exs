defmodule ServiceRadar.Observability.AlertEvaluationInboxTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.AlertEvaluationLane
  alias ServiceRadar.Observability.AlertEvaluationReceipt
  alias ServiceRadar.Observability.AlertEvaluationWork
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

  setup do
    old_limits = Application.get_env(:serviceradar_core, :alert_evaluation_limits)

    on_exit(fn ->
      if old_limits do
        Application.put_env(:serviceradar_core, :alert_evaluation_limits, old_limits)
      else
        Application.delete_env(:serviceradar_core, :alert_evaluation_limits)
      end
    end)

    # The serial sandbox rolls this back. Only the test's rule is eligible;
    # seeded rules must not make capacity assertions depend on their inventory.
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

    {:ok, rule: rule, actor: actor}
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
end
