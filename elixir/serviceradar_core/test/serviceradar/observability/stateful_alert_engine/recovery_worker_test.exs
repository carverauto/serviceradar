defmodule ServiceRadar.Observability.StatefulAlertEngine.RecoveryWorkerTest do
  # Mutates the process-wide :alert_evaluation_mode application env.
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.StatefulAlertEngine.RecoveryWorker

  setup do
    previous = Application.fetch_env(:serviceradar_core, :alert_evaluation_mode)

    on_exit(fn ->
      case previous do
        {:ok, mode} -> Application.put_env(:serviceradar_core, :alert_evaluation_mode, mode)
        :error -> Application.delete_env(:serviceradar_core, :alert_evaluation_mode)
      end
    end)
  end

  # Regression: with consumers disabled the scan returned {:snooze, 5}. A snoozed
  # job never completes and spends no attempt, so the every-minute cron left one
  # more permanently pending job per tick; the backlog filled the queue and starved
  # the AshOban schedulers sharing it. The tick must complete; the next one rechecks.
  test "completes instead of snoozing while consumers are disabled" do
    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :prepared)

    assert :ok = RecoveryWorker.perform(%Oban.Job{})
  end

  # The cron has no Oban uniqueness of its own. The worker's insert contract is
  # what stops a second pending scan from landing while consumers are off.
  test "inserts onto alert_recovery and stays unique over pending states" do
    job = RecoveryWorker.new(%{})

    assert job.valid?
    assert job.changes.queue == "alert_recovery"

    unique = job.changes.unique
    assert unique.period == :infinity

    states = unique.states |> Enum.map(&to_string/1) |> Enum.sort()
    assert states == ["available", "retryable", "scheduled"]
  end
end
