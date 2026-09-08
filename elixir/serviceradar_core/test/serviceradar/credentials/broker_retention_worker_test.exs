defmodule ServiceRadar.Credentials.BrokerRetentionWorkerTest do
  @moduledoc """
  Pins the pure retention arithmetic for `BrokerRetentionWorker`.

  The value of these tests is the disable path. Grants and secret resolution
  audits are the record of what credential authority was handed out, so a config
  mistake that silently widened the window into "delete everything" would destroy
  exactly the rows an incident review needs. Every shape that is not a positive
  integer must therefore mean "prune nothing", never "prune from the epoch".
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.BrokerRetentionWorker, as: Worker

  defp now, do: ~U[2026-08-03 12:00:00Z]

  describe "cutoff_for/2" do
    test "nil and :disabled produce no cutoff" do
      assert Worker.cutoff_for(nil, now()) == nil
      assert Worker.cutoff_for(:disabled, now()) == nil
    end

    test "zero and negative day counts produce no cutoff" do
      assert Worker.cutoff_for(0, now()) == nil
      assert Worker.cutoff_for(-1, now()) == nil
      assert Worker.cutoff_for(-3650, now()) == nil
    end

    test "non-integer values produce no cutoff rather than a garbage one" do
      assert Worker.cutoff_for("14", now()) == nil
      assert Worker.cutoff_for(1.5, now()) == nil
      assert Worker.cutoff_for(:forever, now()) == nil
    end

    test "positive integer subtracts days x 86400 seconds" do
      assert Worker.cutoff_for(1, now()) == ~U[2026-08-02 12:00:00Z]
      assert Worker.cutoff_for(14, now()) == ~U[2026-07-20 12:00:00Z]
      assert Worker.cutoff_for(30, now()) == ~U[2026-07-04 12:00:00Z]
    end
  end

  describe "pruning_plan/2" do
    test "carries each window independently" do
      plan = Worker.pruning_plan(%{grant_days: 14, audit_days: 30}, now())

      assert plan.grant_cutoff == ~U[2026-07-20 12:00:00Z]
      assert plan.audit_cutoff == ~U[2026-07-04 12:00:00Z]
    end

    test "one window disabled does not disable the other" do
      plan = Worker.pruning_plan(%{grant_days: 14, audit_days: :disabled}, now())

      assert plan.grant_cutoff == ~U[2026-07-20 12:00:00Z]
      assert plan.audit_cutoff == nil
    end

    test "both disabled yields no cutoffs at all" do
      plan = Worker.pruning_plan(%{grant_days: :disabled, audit_days: :disabled}, now())

      assert plan == %{grant_cutoff: nil, audit_cutoff: nil}
    end
  end

  describe "read_config/0" do
    setup do
      previous = {
        Application.get_env(:serviceradar_core, :credential_broker_grant_retention_days),
        Application.get_env(
          :serviceradar_core,
          :credential_secret_resolution_audit_retention_days
        )
      }

      on_exit(fn ->
        {grant, audit} = previous
        restore(:credential_broker_grant_retention_days, grant)
        restore(:credential_secret_resolution_audit_retention_days, audit)
      end)

      :ok
    end

    test "defaults keep audits longer than grants" do
      Application.delete_env(:serviceradar_core, :credential_broker_grant_retention_days)

      Application.delete_env(
        :serviceradar_core,
        :credential_secret_resolution_audit_retention_days
      )

      assert %{grant_days: 14, audit_days: 30} = Worker.read_config()
    end

    test "zero disables a window instead of pruning everything" do
      Application.put_env(:serviceradar_core, :credential_broker_grant_retention_days, 0)

      assert %{grant_days: :disabled} = Worker.read_config()
    end

    test "a string from the environment is parsed" do
      Application.put_env(:serviceradar_core, :credential_broker_grant_retention_days, "21")

      assert %{grant_days: 21} = Worker.read_config()
    end

    test "an unparseable value disables rather than falling back to a default window" do
      Application.put_env(:serviceradar_core, :credential_broker_grant_retention_days, "soon")

      assert %{grant_days: :disabled} = Worker.read_config()
    end
  end

  defp restore(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
