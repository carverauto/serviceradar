defmodule ServiceRadar.Jobs.SelfSchedulingWorkerUniquenessTest do
  use ExUnit.Case, async: true

  @workers [
    ServiceRadar.Automation.Ansible.AwxCatalogSyncWorker,
    ServiceRadar.Automation.Ansible.ControllerHealthWorker,
    ServiceRadar.Automation.Ansible.GitCatalogSyncWorker,
    ServiceRadar.Automation.Ansible.RetentionWorker,
    ServiceRadar.Automation.Ansible.RunPulseWorker,
    ServiceRadar.Automation.Ansible.RunWatchdog,
    ServiceRadar.Automation.Ansible.ScheduleEvaluatorWorker,
    ServiceRadar.Credentials.CameraCredentialRuleReconcileWorker,
    ServiceRadar.Credentials.PluginIntegrationReconcileWorker,
    ServiceRadar.Credentials.ProxmoxCredentialRuleReconcileWorker,
    ServiceRadar.Edge.AgentCommandCleanupWorker,
    ServiceRadar.Identity.CliAuthCleanupWorker,
    ServiceRadar.Integrations.ArmisNorthboundScheduleWorker,
    ServiceRadar.Inventory.BumblebeeCatalogRefreshWorker,
    ServiceRadar.Inventory.DeviceCleanupWorker,
    ServiceRadar.Inventory.EndpointVulnerabilityMatchWorker,
    ServiceRadar.Inventory.InterfaceThresholdWorker,
    ServiceRadar.Observability.IpinfoMmdbDownloadWorker,
    ServiceRadar.Observability.StatefulAlertCleanupWorker,
    ServiceRadar.Plugins.AddonProfileReconcileWorker,
    ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryDispatchWorker,
    ServiceRadar.Plugins.PluginTargetPolicyReconcileWorker,
    ServiceRadar.SweepJobs.SweepDataCleanupWorker,
    ServiceRadar.SweepJobs.SweepMonitorWorker
  ]

  test "self-scheduling workers protect seeds and allow successors" do
    Enum.each(@workers, fn worker ->
      unique = %{} |> worker.new() |> Ecto.Changeset.get_change(:unique)

      assert unique.states == Oban.Job.unique_states(:incomplete),
             "#{inspect(worker)} must guard seed insertion across incomplete states"

      source = worker.module_info(:compile)[:source] |> to_string() |> File.read!()

      assert source =~ "unique: [states: :scheduled]",
             "#{inspect(worker)} must scope successor uniqueness to scheduled jobs"
    end)
  end
end
