defmodule ServiceRadar.Repo.Migrations.FlipAddonProfilesTargetQueryToAgents do
  @moduledoc """
  Flips seeded add-on profiles whose SRQL target is the bare `in:devices`
  default onto `in:agents`.

  Context
  -------
  Add-on profile reconciliation materializes one assignment per enrolled agent
  and keys targets off a usable `uid`. The `agents` projection exposes a `uid`
  for every enrolled agent, whereas the `devices` projection only carries a
  denormalized `agent_id` on the subset of device rows that happen to have one.
  A bare `in:devices` default therefore silently drops every device without an
  `agent_id` as `no_enrolled_agent` (on demo, only ~13/100 device rows carry an
  `agent_id`), starving the reconciler of eligible targets.

  The seeder default has been corrected to `in:agents`; this one-time backfill
  brings long-lived deployments (e.g. demo) whose profiles were seeded with the
  old bare `in:devices` value into line.

  Idempotency
  -----------
  Only rows whose `target_query` is exactly the bare `in:devices` default are
  rewritten. Profiles an operator has narrowed with additional predicates
  (e.g. `in:devices tags.role:database`) are left untouched, and a re-run or a
  fresh-seeded deployment (already `in:agents`) is a no-op.

  Down
  ----
  `down/0` reverts the bare value back to `in:devices` so the migration is
  reversible for the exact rows it touched.
  """

  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - bounded, schema-critical one-time backfill.
    # platform.addon_profiles is a small control-plane table (seeded add-on profiles, not a
    # hypertable), so this single UPDATE rewrites only the few profiles still on the bare
    # `in:devices` default in the first-boot Job with no large-table lock/timeout risk. It is
    # required for correctness (a bare `in:devices` target starves add-on reconciliation of
    # eligible agents) and idempotent: the WHERE clause matches only the exact bare default,
    # so a re-run or a fresh-seeded deployment (already `in:agents`) is a no-op.
    execute("""
    UPDATE platform.addon_profiles
    SET target_query = 'in:agents',
        updated_at = now()
    WHERE target_query = 'in:devices'
    """)
  end

  def down do
    execute("""
    UPDATE platform.addon_profiles
    SET target_query = 'in:devices',
        updated_at = now()
    WHERE target_query = 'in:agents'
    """)
  end
end
