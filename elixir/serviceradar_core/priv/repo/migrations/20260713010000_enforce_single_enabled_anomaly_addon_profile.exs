defmodule ServiceRadar.Repo.Migrations.EnforceSingleEnabledAnomalyAddonProfile do
  @moduledoc """
  Backs the single-enabled-anomaly-profile invariant with a partial unique
  index so it holds under concurrency.

  `ServiceRadar.Plugins.Validations.SingleEnabledAddonProfile` checks for an
  existing enabled anomaly profile with a read before the write, which is
  raceable: two concurrent enables can both pass validation and commit. The
  anomaly add-on requires exactly one enabled profile because the config
  projector and seasonal edge-baseline producer fan settings into every
  enabled profile, and each agent receives one effective assignment per
  add-on — two enabled profiles with different params make the delivered edge
  config ambiguous.

  Two steps, in order:

  1. Resolve pre-existing duplicates: keep the profile config delivery
     already prefers (lowest `priority`, then most recently updated, then id
     — the same total order `AgentConfigGenerator.select_effective_addon_assignments`
     uses) and disable the rest. This codifies the delivery winner; operators
     who prefer a shadowed profile can disable the winner and re-enable their
     choice afterwards (the invariant allows exactly one at a time).
  2. Create the partial unique index. The predicate (`enabled AND
     addon_id = 'anomaly'`) must stay in sync with `@exclusive_addon_ids` in
     the validation module.

  Idempotent: the UPDATE only touches rows beyond the first-ranked enabled
  profile, and the index is created IF NOT EXISTS.
  """

  use Ecto.Migration

  def up do
    execute("""
    WITH ranked AS (
      SELECT id,
             row_number() OVER (
               ORDER BY priority ASC, updated_at DESC, id ASC
             ) AS rn
      FROM #{schema()}.addon_profiles
      WHERE addon_id = 'anomaly' AND enabled
    )
    UPDATE #{schema()}.addon_profiles AS p
    SET enabled = false
    FROM ranked r
    WHERE p.id = r.id AND r.rn > 1
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS addon_profiles_single_enabled_anomaly_index
    ON #{schema()}.addon_profiles (addon_id)
    WHERE enabled AND addon_id = 'anomaly'
    """)
  end

  def down do
    # Data cleanup (step 1) is not reversible; only the index is dropped.
    execute("DROP INDEX IF EXISTS #{schema()}.addon_profiles_single_enabled_anomaly_index")
  end

  defp schema do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Repo, [])
    |> Keyword.get(:migration_default_prefix, "platform")
  end
end
