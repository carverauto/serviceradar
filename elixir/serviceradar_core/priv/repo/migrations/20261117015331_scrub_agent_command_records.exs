defmodule ServiceRadar.Repo.Migrations.ScrubAgentCommandRecords do
  @moduledoc """
  Enqueues the one-time cleanup of `platform.agent_commands` rows written
  before `ServiceRadar.Edge.AgentCommandRecordPolicy` existed.

  Those rows can hold a camera stream URL (with its username and password, or
  a UniFi Protect alias token) in `payload` and `context`, and an agent's raw
  error quoting that URL in `message`. The prevention ships in the same change:
  the command bus and the result persister now apply the policy on every
  write. `ServiceRadar.Edge.AgentCommandRecordScrubWorker` rewrites the existing
  rows with the same Elixir rules, in primary-key batches, after boot.

  serviceradar:allow-startup-maintenance - `up` only inserts one Oban job and
  changes no existing row; the worker does the cleanup after boot. The one
  DELETE, in `down`, removes only this migration's own pending job.
  """

  use Ecto.Migration

  @prefix "platform"
  @scrub_worker "ServiceRadar.Edge.AgentCommandRecordScrubWorker"

  def up do
    execute("""
    INSERT INTO #{@prefix}.oban_jobs (state, queue, worker, args, max_attempts)
    VALUES ('available', 'maintenance', '#{@scrub_worker}',
            '{"trigger": "migration"}'::jsonb, 20)
    """)
  end

  def down do
    execute("""
    DELETE FROM #{@prefix}.oban_jobs
    WHERE worker = '#{@scrub_worker}' AND state IN ('available', 'scheduled', 'retryable')
    """)
  end
end
