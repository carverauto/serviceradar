defmodule ServiceRadar.Repo.Migrations.IndexCurrentKevAdvisories do
  @moduledoc """
  Serves `CvePriority`'s read of the current KEV advisories of enabled feeds,
  `WHERE current AND kev` joined to `vulnerability_feed_definitions` on
  `(provider, feed_key)`.

  KEV advisories are a small fraction of `vulnerability_advisories`, but no index
  covered `kev`, so every read sequentially scanned the whole advisory table,
  `raw` documents included. The partial index holds only the current KEV rows.

  Advisory feeds rewrite the table while they load, so the index is built
  `CONCURRENTLY`. That cannot run inside a transaction, hence a migration of its
  own with the DDL transaction and migration lock disabled.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:vulnerability_advisories, [:provider, :feed_key],
        prefix: "platform",
        name: "vulnerability_advisories_current_kev_idx",
        where: "current AND kev",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:vulnerability_advisories, [:provider, :feed_key],
        prefix: "platform",
        name: "vulnerability_advisories_current_kev_idx",
        concurrently: true
      )
    )
  end
end
