defmodule ServiceRadar.Inventory.Identity.ReconciliationRunTest do
  @moduledoc """
  Integration coverage for the reconciliation run record (GitHub #4229).

  The stats map existed before this record did; it was logged and dropped. What
  these tests hold in place is the part that made the drop expensive:

  - a run that completes is recorded, with the configured cap and whether it was
    reached -- neither of which is derivable afterwards from anything else
  - a run that RAISES is recorded too. The rescue clause used to leave one
    `Logger.warning` and a `{:error, reason}` return, which in a restarted pod is
    no trace at all
  - a failure to write the record never fails the sweep. An audit that can reject
    the operation it observes gives somebody a motive to switch it off
  - retention prunes only what is outside the window
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Identity.DuplicateSweep
  alias ServiceRadar.Inventory.Identity.ReconciliationRun
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  defp actor, do: SystemActor.system(:identity_reconciliation)

  defp runs do
    ReconciliationRun
    |> Ash.Query.for_read(:recent, %{}, actor: actor())
    |> Ash.read!()
  end

  defp insert_run(attrs) do
    ReconciliationRun.record!(
      Map.merge(
        %{
          run_id: Ash.UUID.generate(),
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now(),
          duration_ms: 10,
          status: :completed,
          max_merges_configured: 200
        },
        attrs
      ),
      actor: actor()
    )
  end

  describe "a completed run" do
    test "is recorded with the counters the run computed" do
      before = length(runs())

      assert {:ok, stats} = DuplicateSweep.reconcile_duplicates(actor: actor())

      recorded = runs()
      assert length(recorded) == before + 1

      [run | _] = recorded
      assert run.status == :completed
      assert run.merges == stats.merges
      assert run.errors == stats.errors
      assert run.duplicate_identifier_count == stats.duplicate_identifier_count
      assert run.blocked_components == stats.blocked_components
      assert run.largest_blocked_component == stats.largest_blocked_component
      assert is_integer(run.duration_ms)
      assert run.trigger == :scheduled
    end

    test "records the configured cap and that the run stayed under it" do
      assert {:ok, stats} = DuplicateSweep.reconcile_duplicates(actor: actor(), max_merges: 5)

      [run | _] = runs()
      assert run.max_merges_configured == 5
      assert stats.max_merges_configured == 5
      # An empty fixture performs no merges, so the cap cannot have been hit.
      refute run.merge_cap_reached
      refute stats.merge_cap_reached
    end

    test "carries the trigger and job schedule the caller supplied" do
      assert {:ok, _stats} =
               DuplicateSweep.reconcile_duplicates(
                 actor: actor(),
                 trigger: :manual,
                 job_schedule_id: 99
               )

      [run | _] = runs()
      assert run.trigger == :manual
      assert run.job_schedule_id == 99
    end
  end

  describe "a run that raises" do
    test "is recorded as failed with an error summary, not silently absent" do
      before = length(runs())

      # Force the collection stage to raise the way a database error would.
      assert {:error, _reason} =
               with_failing_collection(fn ->
                 DuplicateSweep.reconcile_duplicates(actor: actor())
               end)

      recorded = runs()
      assert length(recorded) == before + 1

      [run | _] = recorded
      assert run.status == :failed
      assert is_binary(run.error_summary)
      assert run.error_summary != ""
    end
  end

  describe "recording never fails the sweep" do
    test "a run still returns its stats when the record cannot be written" do
      # Drop the table out from under the writer. The sweep must still succeed;
      # a missing diagnostic beats a blocked reconciliation.
      # try/after, not on_exit: the sandbox transaction rolls back before
      # on_exit runs, so the rename would already be undone and the restore
      # would fail against a table that is no longer renamed.
      Repo.query!("ALTER TABLE platform.identity_reconciliation_runs RENAME TO _runs_hidden")

      try do
        assert {:ok, stats} = DuplicateSweep.reconcile_duplicates(actor: actor())
        assert is_integer(stats.merges)
      after
        Repo.query!("ALTER TABLE platform._runs_hidden RENAME TO identity_reconciliation_runs")
      end
    end
  end

  describe "retention" do
    test "prunes runs outside the window and keeps the ones inside it" do
      old_id = Ash.UUID.generate()
      recent_id = Ash.UUID.generate()

      insert_run(%{run_id: old_id, started_at: DateTime.add(DateTime.utc_now(), -90, :day)})
      insert_run(%{run_id: recent_id, started_at: DateTime.add(DateTime.utc_now(), -1, :day)})

      assert {:ok, _stats} = DuplicateSweep.reconcile_duplicates(actor: actor())

      remaining =
        Repo.all(
          from(r in "identity_reconciliation_runs",
            prefix: "platform",
            select: type(r.run_id, :binary_id)
          )
        )

      refute old_id in remaining, "a run older than the retention window survived"
      assert recent_id in remaining, "a run inside the retention window was pruned"
    end
  end

  # The sweep's first stage reads `device_identifiers`; renaming it makes that
  # read raise, which is the closest honest stand-in for the database errors the
  # rescue clause exists to catch.
  defp with_failing_collection(fun) do
    Repo.query!("ALTER TABLE platform.device_identifiers RENAME TO _identifiers_hidden")

    try do
      fun.()
    after
      Repo.query!("ALTER TABLE platform._identifiers_hidden RENAME TO device_identifiers")
    end
  end
end
