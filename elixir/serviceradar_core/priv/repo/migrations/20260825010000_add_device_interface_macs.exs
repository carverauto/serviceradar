defmodule ServiceRadar.Repo.Migrations.AddDeviceInterfaceMacs do
  @moduledoc """
  Per-device record of the MACs a device reports on its OWN interfaces.

  Replaces an `:interface_mac` row in `device_identifiers`, which could not work:
  that table is unique on `(identifier_type, identifier_value, partition)` and its
  upsert deliberately never moves `device_id`. Two device rows that are the SAME
  chassis report the SAME interface MACs, so the first to register owned all of
  them and the second got none -- observed on farm01, where one device held 11
  chassis MACs and its twin held 0 despite reporting 16.

  Two consequences that only appear at scale, both fixed by keying per device:

    * the loser's change gate never engaged -- its own set always read back empty,
      so it re-attempted every MAC on every poll, forever, and each attempt
      updated the OTHER device's row;
    * the write was reported as successful, because the upsert did succeed -- just
      against a row belonging to a different device.

  Keyed `(device_id, mac)`. That primary key serves both access patterns:
  "which MACs does this device claim" is a prefix scan, and "does this device
  claim any of these MACs" is a prefix scan with `mac = ANY(...)`. The secondary
  index on `mac` alone answers the reverse question -- which devices claim a given
  MAC -- used for diagnostics and duplicate detection. No GIN index: these are
  scalar equality lookups, not containment over arrays or jsonb.
  """
  use Ecto.Migration

  def up do
    create table(:device_interface_macs, primary_key: false, prefix: "platform") do
      add :device_id, :text, null: false, primary_key: true
      add :mac, :text, null: false, primary_key: true
      add :partition, :text
      add :first_seen, :utc_datetime_usec, null: false, default: fragment("now()")
      add :last_seen, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:device_interface_macs, [:mac], prefix: "platform")

    execute("""
    COMMENT ON TABLE platform.device_interface_macs IS
      'MACs a device reports on its own interfaces. Corroboration for identity only -- never an identifier, never resolves an update. Keyed per device so two rows of one chassis can each claim the same MAC.';
    """)

    # NO cleanup of the :interface_mac identifier rows this replaces.
    #
    # A DELETE here is a synchronous cleanup on the first-boot path, which
    # scripts/db/check-baseline-metadata.sh forbids for migrations newer than the
    # baseline -- correctly, because startup work that scans a table is unbounded
    # on a large deployment.
    #
    # It is also unnecessary. `:interface_mac` was never released: it existed only
    # between two commits on a feature branch, so on every real deployment this
    # DELETE would match zero rows and still pay for the scan. The one cluster
    # that has such rows is a lab cluster running an unreleased build, and it is
    # cleaned up as an operator task.
    #
    # The rows are inert regardless -- nothing reads `identifier_type =
    # 'interface_mac'` once this migration lands, and the type is no longer in
    # DeviceIdentifier's allowed list, so no new ones can be written.
  end

  def down do
    drop table(:device_interface_macs, prefix: "platform")
  end
end
