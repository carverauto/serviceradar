defmodule ServiceRadar.Repo.Migrations.AddEphemeralDeviceExpirySettings do
  @moduledoc """
  Settings for expiring ephemeral devices on last-seen (#4603): whether the expiry pass runs
  (off by default: an estate that never expired anything can hold a large stale population),
  the last-seen window in days, an SRQL device query whose matches are never expired, and the
  mass-expiry guard (maximum fraction of live devices one pass may expire, and its override).

  Also `platform.device_holds_strong_identifier(uid)`, the one definition of "this device holds
  a strong identifier" that both the candidate read and the soft delete's WHERE clause use.
  A MAC counts as evidence only when it normalizes to twelve hex digits AND its
  locally-administered bit (0x02 of the first octet) is set; anything else counts as globally
  unique, so an unreadable value keeps the device. The CASE keeps decode() from ever seeing a
  non-hex value.
  """
  use Ecto.Migration

  def up do
    alter table(:device_cleanup_settings, prefix: "platform") do
      add :ephemeral_expiry_enabled, :boolean, null: false, default: false
      add :ephemeral_expiry_days, :integer, null: false, default: 30
      add :ephemeral_expiry_exclusion_query, :text
      add :ephemeral_expiry_max_fraction, :float, null: false, default: 0.5
      add :ephemeral_expiry_guard_override, :boolean, null: false, default: false
    end

    execute("""
    CREATE OR REPLACE FUNCTION platform.mac_is_locally_administered(mac text)
    RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
      SELECT CASE
        WHEN upper(regexp_replace(coalesce(mac, ''), '[^0-9A-Fa-f]', '', 'g')) ~ '^[0-9A-F]{12}$'
        THEN (get_byte(decode(substr(upper(regexp_replace(mac, '[^0-9A-Fa-f]', '', 'g')), 1, 2), 'hex'), 0) & 2) <> 0
        ELSE false
      END
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.device_holds_strong_identifier(device_uid text)
    RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
      SELECT EXISTS (
               SELECT 1 FROM platform.device_identifiers di
               WHERE di.device_id = device_uid
                 AND (di.identifier_type IN ('agent_id', 'armis_device_id', 'integration_id',
                                             'netbox_device_id', 'hardware_serial')
                      OR (di.identifier_type = 'mac'
                          AND NOT platform.mac_is_locally_administered(di.identifier_value)))
             )
          OR EXISTS (
               SELECT 1 FROM platform.device_interface_macs dim
               WHERE dim.device_id = device_uid
                 AND NOT platform.mac_is_locally_administered(dim.mac)
             )
    $$
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS platform.device_holds_strong_identifier(text)")
    execute("DROP FUNCTION IF EXISTS platform.mac_is_locally_administered(text)")

    alter table(:device_cleanup_settings, prefix: "platform") do
      remove :ephemeral_expiry_guard_override
      remove :ephemeral_expiry_max_fraction
      remove :ephemeral_expiry_exclusion_query
      remove :ephemeral_expiry_days
      remove :ephemeral_expiry_enabled
    end
  end
end
