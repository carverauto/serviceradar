defmodule ServiceRadar.Jobs.SelfSchedulingWorkerUniquenessTest do
  @moduledoc """
  The uniqueness contract for workers that reschedule themselves.

  Two opposite requirements, and getting either wrong fails silently:

    * the SEED insert must be unique across every incomplete state, so scheduling a worker
      that is already pending is a no-op rather than a duplicate;
    * the SUCCESSOR insert must be unique only against `scheduled` jobs. The successor is
      inserted from inside `perform/1`, while the current job is `executing`, so Oban's
      default would deduplicate the successor against the very job creating it. The insert is
      dropped, nothing raises, and the worker just never runs again.

  Both assertions are now behavioural: they build the changeset each worker would actually
  insert and inspect its `:unique` change.

  The previous version read each worker's `.ex` file through
  `module_info(:compile)[:source]` and grepped for the option literal. That was a proxy for
  the behaviour rather than the behaviour, it silently omitted three self-scheduling workers
  that were missing from its list, and it could not run under Bazel at all -- a compiled
  module's `:source` points into a sandboxed build tree that no longer exists, so the read
  failed with `File.Error: could not read file ""`.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Jobs.SelfScheduling

  @moduletag :requires_app

  # Every worker that reschedules itself, i.e. every caller of
  # SelfScheduling.successor_changeset/3. Keep in step with that call site list; the three
  # at the end were self-scheduling all along and simply never covered.
  @workers [
    ServiceRadar.Automation.Ansible.AwxCatalogSyncWorker,
    ServiceRadar.Automation.Ansible.ControllerHealthWorker,
    ServiceRadar.Automation.Ansible.GitCatalogSyncWorker,
    ServiceRadar.Automation.Ansible.RetentionWorker,
    ServiceRadar.Automation.Ansible.RunPulseWorker,
    ServiceRadar.Automation.Ansible.RunWatchdog,
    ServiceRadar.Automation.Ansible.ScheduleEvaluatorWorker,
    ServiceRadar.Credentials.PluginCredentialRuleReconcileWorker,
    ServiceRadar.Credentials.PluginIntegrationReconcileWorker,
    ServiceRadar.Edge.AgentCommandCleanupWorker,
    ServiceRadar.Identity.CliAuthCleanupWorker,
    ServiceRadar.Integrations.ArmisNorthboundScheduleWorker,
    ServiceRadar.Inventory.BumblebeeCatalogRefreshWorker,
    ServiceRadar.Inventory.DeviceCleanupWorker,
    ServiceRadar.Inventory.DeviceRiskAssessmentWorker,
    ServiceRadar.Inventory.EndpointVulnerabilityMatchWorker,
    ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker,
    ServiceRadar.Inventory.AdvisoryFeeds.StagingCleanupWorker,
    ServiceRadar.Inventory.InterfaceThresholdWorker,
    ServiceRadar.Observability.IpinfoMmdbDownloadWorker,
    ServiceRadar.Observability.StatefulAlertCleanupWorker,
    ServiceRadar.Plugins.AddonProfileReconcileWorker,
    ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryDispatchWorker,
    ServiceRadar.Plugins.PluginTargetPolicyReconcileWorker,
    ServiceRadar.SweepJobs.SweepCoverageRollupWorker,
    ServiceRadar.SweepJobs.SweepDataCleanupWorker,
    ServiceRadar.SweepJobs.SweepMonitorWorker,
    # Never covered by the old source-grep test, which carried a hardcoded 23-module list.
    ServiceRadar.Integrations.ArmisNorthboundConflictAuditWorker,
    ServiceRadar.Plugins.AddonRolloutWorker,
    ServiceRadar.Plugins.PluginLegacyAssignmentRecoveryWorker
  ]

  # Any positive value; the assertion is about :unique, not :schedule_in.
  @schedule_in 60

  test "seed insertion is guarded across incomplete states" do
    for worker <- @workers do
      unique = %{} |> worker.new() |> Ecto.Changeset.get_change(:unique)

      assert unique.states == Oban.Job.unique_states(:incomplete),
             "#{inspect(worker)} must guard seed insertion across incomplete states, " <>
               "or scheduling an already-pending job inserts a duplicate"
    end
  end

  test "successor insertion is scoped to scheduled jobs" do
    for worker <- @workers do
      unique =
        worker
        |> SelfScheduling.successor_changeset(%{}, @schedule_in)
        |> Ecto.Changeset.get_change(:unique)

      assert unique.states == [:scheduled],
             "#{inspect(worker)} must scope successor uniqueness to scheduled jobs, or the " <>
               "successor is deduplicated against the executing job that inserts it and the " <>
               "worker stops rescheduling itself"
    end
  end

  test "the successor changeset carries the requested delay" do
    # Guards the helper itself: a successor with no delay would busy-loop the queue.
    changeset = SelfScheduling.successor_changeset(hd(@workers), %{}, @schedule_in)

    assert Ecto.Changeset.get_change(changeset, :scheduled_at)
    assert SelfScheduling.successor_unique() == [states: :scheduled]
  end

  test "every listed worker is a real Oban worker" do
    # Cheap guard against a typo in the list above silently reducing coverage: a misspelled
    # module would make both assertions above vacuous rather than failing.
    for worker <- @workers do
      assert Code.ensure_loaded?(worker), "#{inspect(worker)} does not exist"

      assert function_exported?(worker, :new, 2),
             "#{inspect(worker)} is not an Oban.Worker"
    end
  end
end
