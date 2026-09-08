defmodule Mix.Tasks.Serviceradar.AnomalyAlertLiveness do
  @shortdoc "Verify anomaly alert open/clear liveness"

  @moduledoc """
  Runs the anomaly alert pipeline liveness check.

      mix serviceradar.anomaly_alert_liveness

  The task injects a synthetic confirmed anomaly open event into the stateful
  alert engine, verifies that the seeded anomaly rule creates a persisted alert,
  injects a clear event, and verifies that the alert resolves.
  """

  use Mix.Task

  alias ServiceRadar.Observability.AnomalyAlertLivenessCheck

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case AnomalyAlertLivenessCheck.run() do
      {:ok, result} ->
        result
        |> Jason.encode!(pretty: true)
        |> Mix.shell().info()

      {:error, reason} ->
        Mix.raise("anomaly alert liveness check failed: #{inspect(reason)}")
    end
  end
end
