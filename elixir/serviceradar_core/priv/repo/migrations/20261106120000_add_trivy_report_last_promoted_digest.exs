defmodule ServiceRadar.Repo.Migrations.AddTrivyReportLastPromotedDigest do
  @moduledoc """
  Records, per Trivy report, the promoted state the event log last recorded.

  EventWriter used to keep one event per report and rewrite it on every
  rescan, deleting the previous row first. Events are now appended only when a
  report's promoted state changes, so the current state it is compared with
  lives here, beside the rest of the report's current state.

  Reports already promoted when this runs have their event in the log, so they
  are seeded with the digest of their current state (the same `s<severity>:n<count>`
  form `TrivyReports` writes; promotion starts at severity 4, High). Without the
  seed the first rescan after the upgrade would append a second "new" event for
  every one of them.
  """
  use Ecto.Migration

  def up do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.trivy_reports
      ADD COLUMN IF NOT EXISTS last_promoted_digest TEXT
    """)

    execute("""
    UPDATE #{schema}.trivy_reports
    SET last_promoted_digest = 's' || severity_id || ':n' || findings_count
    WHERE severity_id >= 4 AND last_promoted_digest IS NULL
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.trivy_reports
      DROP COLUMN IF EXISTS last_promoted_digest
    """)
  end
end
