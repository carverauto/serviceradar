defmodule ServiceRadar.Ash.AtomicHookChangesTest do
  @moduledoc """
  An atomic update does not call `change/3`; Ash applies what `atomic/3`
  returns. A change whose whole job is to register a hook therefore has to
  return, from `atomic/3`, a changeset that carries the same hooks `change/3`
  registers. A bare `:ok` registers none, and the side effect is skipped.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Automation.Ansible.Changes.SeedControllerLifecycle
  alias ServiceRadar.Infrastructure.Changes.EnsureStateMonitor
  alias ServiceRadar.Integrations.Changes.PublishSyncLog
  alias ServiceRadar.Integrations.IntegrationSource
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

  # Ash runs an atomic update's after_action hooks inside the write's
  # transaction and requires each to return {:ok, record}; a raise rolls the
  # write back. These hooks need no database, so run them as Ash would.
  defp run_after_action(%Ash.Changeset{} = changeset, record) do
    Enum.reduce_while(changeset.after_action, {:ok, record}, fn hook, {:ok, record} ->
      case hook.(changeset, record) do
        {:ok, record} -> {:cont, {:ok, record}}
        other -> {:halt, other}
      end
    end)
  end

  for stage <- [:started, :finished] do
    test "PublishSyncLog's atomic hook returns the record for stage #{inspect(stage)}" do
      {:ok, opts} = PublishSyncLog.init(stage: unquote(stage))

      source = %IntegrationSource{
        id: Ash.UUID.generate(),
        name: "source01",
        source_type: :armis,
        agent_id: "agent-1",
        gateway_id: "gateway-1",
        partition: "default"
      }

      changeset =
        source
        |> Ash.Changeset.new()
        |> Map.put(:action_type, :update)
        |> Ash.Changeset.set_argument(:device_count, 3)
        |> Ash.Changeset.set_argument(:result, :failed)
        |> Ash.Changeset.set_argument(:error_message, "boom")

      {:ok, atomic} = PublishSyncLog.atomic(changeset, opts, %{})

      capture_log(fn ->
        assert {:ok, ^source} = run_after_action(atomic, source)
      end)
    end
  end

  test "EnsureStateMonitor's atomic hook returns the record" do
    record = %ZenRule{id: Ash.UUID.generate()}
    changeset = record |> Ash.Changeset.new() |> Map.put(:action_type, :update)
    {:ok, atomic} = EnsureStateMonitor.atomic(changeset, [], %{})

    capture_log(fn ->
      assert {:ok, ^record} = run_after_action(atomic, record)
    end)
  end
end
