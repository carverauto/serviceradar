defmodule ServiceRadar.Repo.Migrations.HoldMetadataSourceIdsFromExpiry do
  @moduledoc """
  `platform.device_holds_strong_identifier(uid)` also holds a device whose metadata carries a
  source id (change `add-source-id-succession`, design D13).

  Ephemeral expiry applies the function in its candidate read and again in the soft delete's
  `UPDATE ... WHERE`. It read only `device_identifiers` and `device_interface_macs`, so a device
  whose source id survived only in its metadata, because its identifier row was
  garbage-collected or never written, was held by the in-memory check alone, and nothing in the
  delete statement held it. A numeric JSON value, which the in-memory check does not read, was
  held by nothing.

  The function now also holds a device whose metadata carries an `agent_id`, `armis_device_id`,
  `integration_id` or `netbox_device_id` that is a JSON number or a string with a
  non-whitespace character. It deliberately skips the in-memory check's admission rules, such as
  the rejection of a purely numeric `integration_id`: a hold that keeps too much is safe, and
  the in-memory check remains the second stage.

  Redefines a function only: no row is read or rewritten.
  """
  use Ecto.Migration

  # The identifier-table rule, as 20260925090000 defined it.
  @identifier_tables """
  EXISTS (
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
  """

  @metadata_source_ids """
  OR EXISTS (
    SELECT 1
    FROM platform.ocsf_devices d
    CROSS JOIN (VALUES ('agent_id'), ('armis_device_id'), ('integration_id'),
                       ('netbox_device_id')) AS k(key)
    WHERE d.uid = device_uid
      AND CASE jsonb_typeof(d.metadata -> k.key)
            WHEN 'number' THEN true
            WHEN 'string' THEN (d.metadata ->> k.key) ~ '[^[:space:]]'
            ELSE false
          END
  )
  """

  def up, do: define(@identifier_tables <> @metadata_source_ids)

  def down, do: define(@identifier_tables)

  defp define(body) do
    execute("""
    CREATE OR REPLACE FUNCTION platform.device_holds_strong_identifier(device_uid text)
    RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
      SELECT #{body}
    $$
    """)
  end
end
