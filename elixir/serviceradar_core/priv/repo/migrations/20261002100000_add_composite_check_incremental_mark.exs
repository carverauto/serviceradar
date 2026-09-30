defmodule ServiceRadar.Repo.Migrations.AddCompositeCheckIncrementalMark do
  @moduledoc """
  Adds the incremental-evaluation mark to composite checks.

  `last_incremental_at` is the database `now()` taken before the last
  successful dirty read. The minute tick selects devices whose input rows were
  written after that mark (less a fixed slack) and re-evaluates only those.
  The full-pass clock, `last_evaluated_at`, already exists. A nil mark means
  "run the full pass", so no backfill is needed.
  """

  use Ecto.Migration

  def change do
    alter table(:composite_checks, prefix: "platform") do
      add :last_incremental_at, :utc_datetime_usec
    end
  end
end
