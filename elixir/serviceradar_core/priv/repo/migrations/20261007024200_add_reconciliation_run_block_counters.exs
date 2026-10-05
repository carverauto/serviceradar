defmodule ServiceRadar.Repo.Migrations.AddReconciliationRunBlockCounters do
  @moduledoc """
  Run-record counters for blocked merges and source succession (change
  `add-source-id-succession`, design D9).

  `identity_reconciliation_runs` gains:

  * `blocked_merges`: the merges a guard refused. The run counted them as errors.
  * `blocked_unchanged`: the blocked components and pairs the run skipped because their
    evidence fingerprint was unchanged since they were last blocked.
  * `succession_merges`, `succession_reviews`, `successions_skipped` and
    `successions_deferred`: the counters of the source succession pass, which the run only
    logged.
  * `max_successions_configured`: the per-run succession cap the run was given.

  Schema only: no existing row is rewritten. A run recorded earlier reads zero for each counter,
  and its `errors` still include the merges a guard refused.
  """
  use Ecto.Migration

  def up do
    alter table(:identity_reconciliation_runs, prefix: "platform") do
      add :blocked_merges, :integer, null: false, default: 0
      add :blocked_unchanged, :integer, null: false, default: 0
      add :succession_merges, :integer, null: false, default: 0
      add :succession_reviews, :integer, null: false, default: 0
      add :successions_skipped, :integer, null: false, default: 0
      add :successions_deferred, :integer, null: false, default: 0
      add :max_successions_configured, :integer
    end
  end

  def down do
    alter table(:identity_reconciliation_runs, prefix: "platform") do
      remove :max_successions_configured
      remove :successions_deferred
      remove :successions_skipped
      remove :succession_reviews
      remove :succession_merges
      remove :blocked_unchanged
      remove :blocked_merges
    end
  end
end
