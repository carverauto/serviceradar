defmodule ServiceRadar.Repo.Migrations.CreateAdvisoryFeedGenerationSequence do
  @moduledoc """
  Adds the Task 5 generation allocator without changing the Task 4 table migration.

  A PostgreSQL sequence is globally monotonic, which also guarantees monotonicity
  for each provider/feed pair. Initialization advances beyond generations already
  persisted in either advisory content or the source-presence ledger.
  """

  use Ecto.Migration

  def up do
    execute("CREATE SEQUENCE platform.advisory_feed_generation_seq AS bigint")

    execute("""
    SELECT setval(
      'platform.advisory_feed_generation_seq',
      GREATEST(
        COALESCE((SELECT MAX(generation) FROM platform.vulnerability_advisories), 0),
        COALESCE((SELECT MAX(generation) FROM platform.advisory_feed_source_presence), 0)
      ) + 1,
      false
    )
    """)
  end

  def down do
    execute("DROP SEQUENCE IF EXISTS platform.advisory_feed_generation_seq")
  end
end
