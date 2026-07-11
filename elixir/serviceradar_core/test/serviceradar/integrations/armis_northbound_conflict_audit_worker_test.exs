defmodule ServiceRadar.Integrations.ArmisNorthboundConflictAuditWorkerTest.SupportStub do
  @moduledoc false

  def available?, do: Process.get(:support_available, false)
  def prefix, do: "platform"

  def safe_insert(job) do
    send(Process.get(:test_pid), {:safe_insert, job})
    {:ok, job}
  end
end

defmodule ServiceRadar.Integrations.ArmisNorthboundConflictAuditWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Integrations.ArmisNorthboundConflictAuditWorker
  alias ServiceRadar.Integrations.ArmisNorthboundConflictAuditWorkerTest.SupportStub

  setup do
    prev = %{
      support: Application.get_env(:serviceradar_core, :armis_northbound_oban_support_module),
      fun: Application.get_env(:serviceradar_core, :armis_northbound_conflict_audit_fun),
      interval:
        Application.get_env(
          :serviceradar_core,
          :armis_northbound_conflict_audit_interval_seconds
        )
    }

    Process.put(:test_pid, self())
    Process.put(:support_available, true)

    Application.put_env(:serviceradar_core, :armis_northbound_oban_support_module, SupportStub)

    Application.put_env(
      :serviceradar_core,
      :armis_northbound_conflict_audit_interval_seconds,
      1800
    )

    on_exit(fn ->
      restore(:armis_northbound_oban_support_module, prev.support)
      restore(:armis_northbound_conflict_audit_fun, prev.fun)
      restore(:armis_northbound_conflict_audit_interval_seconds, prev.interval)
    end)

    :ok
  end

  test "perform runs the audit and schedules the next run" do
    parent = self()

    Application.put_env(:serviceradar_core, :armis_northbound_conflict_audit_fun, fn ->
      send(parent, :audit_ran)
      %{audited_count: 3, cleared_count: 1, summary: %{}}
    end)

    assert :ok = ArmisNorthboundConflictAuditWorker.perform(%Oban.Job{})
    assert_received :audit_ran
    assert_received {:safe_insert, follow_up}

    assert %{states: states} = Ecto.Changeset.get_change(follow_up, :unique)
    assert states == Oban.Job.unique_states(:scheduled)
    assert %DateTime{} = Ecto.Changeset.get_change(follow_up, :scheduled_at)
  end

  test "seed jobs remain unique across every incomplete state" do
    seed = ArmisNorthboundConflictAuditWorker.new(%{})

    assert %{states: states} = Ecto.Changeset.get_change(seed, :unique)
    assert states == Oban.Job.unique_states(:incomplete)
  end

  test "perform stays :ok and still reschedules when the audit returns an error" do
    parent = self()

    Application.put_env(:serviceradar_core, :armis_northbound_conflict_audit_fun, fn ->
      send(parent, :audit_ran)
      {:error, :boom}
    end)

    assert :ok = ArmisNorthboundConflictAuditWorker.perform(%Oban.Job{})
    assert_received :audit_ran
    assert_received {:safe_insert, _job}
  end

  test "perform stays :ok and still reschedules when the audit raises" do
    parent = self()

    Application.put_env(:serviceradar_core, :armis_northbound_conflict_audit_fun, fn ->
      send(parent, :audit_ran)
      raise "kaboom"
    end)

    assert :ok = ArmisNorthboundConflictAuditWorker.perform(%Oban.Job{})
    assert_received :audit_ran
    assert_received {:safe_insert, _job}
  end

  test "ensure_scheduled returns oban_unavailable when Oban is unavailable" do
    Process.put(:support_available, false)
    assert {:error, :oban_unavailable} = ArmisNorthboundConflictAuditWorker.ensure_scheduled()
  end

  test "ensure_scheduled enqueues when Oban is available" do
    assert {:ok, _job} = ArmisNorthboundConflictAuditWorker.ensure_scheduled()
    assert_received {:safe_insert, _job}
  end

  defp restore(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
