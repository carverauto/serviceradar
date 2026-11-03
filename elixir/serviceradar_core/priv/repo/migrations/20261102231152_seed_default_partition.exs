defmodule ServiceRadar.Repo.Migrations.SeedDefaultPartition do
  @moduledoc """
  Creates the `default` partition on an installation that has none.

  An agent that reports no partition of its own reports `default`, and core resolves an
  agent's network scope from its partition row, so without this row core issues no standing
  output grant and leases no sweep slot to any such agent.

  Nothing in core created a partition, so an installation that never added one through the
  API had an empty table. The insert conflicts on the unique slug, so it never touches a
  `default` row that already exists or that an operator has since edited. `down/0` leaves
  the row in place: gateways, polling schedules and granted network scopes reference it.

  The schema baseline is schema-only, so `ServiceRadar.Repo.SchemaBootstrap` seeds the same
  row on a database it creates.
  """
  use Ecto.Migration

  def up do
    execute(seed_sql(prefix() || "platform"))
  end

  def down, do: :ok

  @doc false
  def seed_sql(schema) do
    """
    INSERT INTO #{schema}.partitions (id, name, slug, enabled, created_at, updated_at)
    VALUES (
      gen_random_uuid(),
      'Default',
      'default',
      true,
      (now() AT TIME ZONE 'utc'),
      (now() AT TIME ZONE 'utc')
    )
    ON CONFLICT (slug) DO NOTHING
    """
  end
end
