defmodule ServiceRadar.Ash.AtomicHookChangesTest do
  @moduledoc """
  An atomic update does not call `change/3`; Ash applies what `atomic/3`
  returns. A change whose whole job is to register a hook therefore has to
  return, from `atomic/3`, a changeset that carries the same hooks `change/3`
  registers. A bare `:ok` registers none, and the side effect is skipped.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.Changes.SeedControllerLifecycle
  alias ServiceRadar.Observability.ZenRule

  # {module, opts the resource passes it}
  @changes [
    {ServiceRadar.Automation.Ansible.Changes.ScheduleGitCatalogSync, []},
    {SeedControllerLifecycle, []},
    {SeedControllerLifecycle, [mode: :teardown]},
    {ServiceRadar.Edge.Changes.PublishOnboardingEvent, []},
    {ServiceRadar.Infrastructure.Changes.EnsureStateMonitor, []},
    {ServiceRadar.Integrations.Changes.PublishSyncLog, [stage: :started]},
    {ServiceRadar.Inventory.Changes.InvalidateSnmpConfigs, []},
    {ServiceRadar.Inventory.Changes.ScheduleThresholdEvaluator, []},
    {ServiceRadar.Inventory.Changes.SyncMetricEventRules, []},
    {ServiceRadar.Inventory.Changes.SyncSnmpInterfaceConfig, []},
    {ServiceRadar.NetworkDiscovery.Changes.TriggerMapperRun, []},
    {ServiceRadar.Observability.Changes.ScheduleAlertCleanup, []},
    {ServiceRadar.PrefixTags.Changes.BroadcastManualInvalidation, []},
    {ServiceRadar.SweepJobs.Changes.ScheduleSweepMonitor, []}
  ]

  defp hooks(%Ash.Changeset{} = changeset) do
    %{
      after_action: length(changeset.after_action),
      after_transaction: length(changeset.after_transaction)
    }
  end

  for {module, opts} <- @changes do
    test "#{inspect(module)} #{inspect(opts)} registers its hook on an atomic update" do
      module = unquote(module)
      opts = unquote(Macro.escape(opts))
      # Any resource will do: these changes only register a hook.
      changeset = %ZenRule{} |> Ash.Changeset.new() |> Map.put(:action_type, :update)

      registered = hooks(module.change(changeset, opts, %{}))
      assert registered.after_action + registered.after_transaction > 0

      assert {:ok, %Ash.Changeset{} = atomic} = module.atomic(changeset, opts, %{})
      assert hooks(atomic) == registered
    end
  end
end
