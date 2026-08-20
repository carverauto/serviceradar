defmodule ServiceRadar.CompositeChecks.EvaluationWorkerTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.EvaluationWorker

  defp actor, do: SystemActor.system(:composite_check_test)

  defp build_check(state) do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Worker #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    if state == :enabled do
      {:ok, enabled} =
        check
        |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true}, actor: actor())
        |> Ash.update()

      enabled
    else
      check
    end
  end

  test "perform evaluates an enabled check and returns a summary" do
    check = build_check(:enabled)

    assert {:ok, summary} = EvaluationWorker.perform(%Oban.Job{args: %{"check_id" => check.id}})

    assert is_integer(summary.evaluated)
    assert is_list(summary.transitions)
  end

  test "perform is a no-op for a draft check" do
    check = build_check(:draft)

    assert {:ok, :skipped} = EvaluationWorker.perform(%Oban.Job{args: %{"check_id" => check.id}})
  end

  test "perform is a no-op for a disabled check" do
    check = build_check(:enabled)

    {:ok, disabled} =
      check
      |> Ash.Changeset.for_update(:set_state, %{state: :disabled}, actor: actor())
      |> Ash.update()

    assert {:ok, :skipped} =
             EvaluationWorker.perform(%Oban.Job{args: %{"check_id" => disabled.id}})
  end

  test "perform cancels cleanly when the check no longer exists" do
    # Discard rather than retry: a deleted check will never come back, and
    # retrying would burn attempts until the job finally dies as a failure.
    assert {:cancel, reason} =
             EvaluationWorker.perform(%Oban.Job{args: %{"check_id" => Ash.UUID.generate()}})

    assert reason =~ "no longer exists"
  end

  test "ensure_scheduled does not raise when Oban is unavailable" do
    # A check must stay saveable when the scheduler is down, the same contract
    # sweep groups have.
    check = build_check(:draft)
    assert {:ok, :not_enabled} = EvaluationWorker.ensure_scheduled(check)
  end

  test "state changes do not fail the save when scheduling cannot happen" do
    check = build_check(:draft)

    assert {:ok, enabled} =
             check
             |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true},
               actor: actor()
             )
             |> Ash.update()

    assert enabled.state == :enabled

    assert {:ok, disabled} =
             enabled
             |> Ash.Changeset.for_update(:set_state, %{state: :disabled}, actor: actor())
             |> Ash.update()

    assert disabled.state == :disabled
  end
end
