defmodule ServiceRadar.Repo.Migrations.ScrubCameraStreamRelayColumns do
  @moduledoc """
  Enqueues the stage 3 cleanup of camera stream addresses: the job that empties
  `camera_stream_profiles.source_url_override` (keeping its origin in
  `source_origin`) and `camera_sources.source_url`, reduces `source_origin`,
  and repeats every stage 1 target.

  The prevention ships in the same change: Core no longer maps or writes the two
  columns, and a relay sends the agent the discovering plugin assignment instead
  of an address. `ServiceRadar.Camera.StreamSecretScrubWorker` runs this job only
  while every connected Core node runs stage 3 code, so a node that still opens
  relays from the two columns never finds them emptied. This is a new job, not a
  re-enqueue of the stage 1 job.

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
    VALUES ('available', 'maintenance', '#{@scrub_worker}', '{"stage": 3}'::jsonb, 20)
    """)
  end

  def down do
    execute("""
    DELETE FROM #{@prefix}.oban_jobs
    WHERE worker = '#{@scrub_worker}'
      AND args = '{"stage": 3}'::jsonb
      AND state IN ('available', 'scheduled', 'retryable')
    """)
  end
end
