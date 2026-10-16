defmodule ServiceRadar.Repo.Migrations.WidenFleetOrdinals do
  @moduledoc """
  Widen the permanent dictionary before acquiring inventory lifecycle locks.

  Integer-to-bigint conversion rewrites the dictionary and its indexes. This
  migration needs a maintenance window, but its transaction does not retain an
  ACCESS EXCLUSIVE lock on the canonical inventory table during that rewrite.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '5min'")
    execute("ALTER TABLE platform.device_fleet_ordinals ALTER COLUMN ordinal TYPE bigint")
    execute("ALTER SEQUENCE platform.device_fleet_ordinals_ordinal_seq AS bigint MAXVALUE 4294967295 NO CYCLE")
    execute("ALTER TABLE platform.device_fleet_ordinals DROP CONSTRAINT IF EXISTS device_fleet_ordinals_u32")
    execute("ALTER TABLE platform.device_fleet_ordinals ADD CONSTRAINT device_fleet_ordinals_u32 CHECK (ordinal BETWEEN 1 AND 4294967295)")
  end

  # Narrowing or cycling could destroy an assignment made after this migration.
  def down, do: :ok
end
