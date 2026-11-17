defmodule ServiceRadar.Repo.Migrations.ScrubCameraStreamSecrets do
  @moduledoc """
  Enqueues the stage 1 cleanup of camera stream addresses that Core stored from
  plugin results: path aliases and URL userinfo in camera profile, source and
  device metadata and in stored plugin status and state rows.

  The prevention ships in the same change: every plugin result is now reduced on
  entry (`ServiceRadar.Camera.StreamAddressReduction`).
  `ServiceRadar.Camera.StreamSecretScrubWorker` rewrites the existing rows with
  the same Elixir rule, in primary-key batches, after boot, and completes only
  once every connected Core node runs that rule.

  serviceradar:allow-startup-maintenance - `up` only inserts one Oban job and
  changes no existing row; the worker does the cleanup after boot. The one
  DELETE, in `down`, removes only this migration's own pending job.
  """

  use Ecto.Migration

  @prefix "platform"
  @scrub_worker "ServiceRadar.Camera.StreamSecretScrubWorker"

  def up do
    execute("""
    INSERT INTO #{@prefix}.oban_jobs (state, queue, worker, args, max_attempts)
    VALUES ('available', 'maintenance', '#{@scrub_worker}', '{"stage": 1}'::jsonb, 20)
    """)
  end

  def down do
    execute("""
    DELETE FROM #{@prefix}.oban_jobs
    WHERE worker = '#{@scrub_worker}'
      AND args = '{"stage": 1}'::jsonb
      AND state IN ('available', 'scheduled', 'retryable')
    """)
  end
end
