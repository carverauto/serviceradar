defmodule ServiceRadar.Repo.Migrations.AddDeviceAttributeProvenance do
  @moduledoc """
  Records which source wrote each single-valued device attribute, and at what
  evidence strength (`fix-device-attribute-source-precedence`, design decisions
  1, 6 and 8).

  `ocsf_devices.attribute_provenance` maps an attribute group to the tag of the
  write that set it:

      {"name": {"source": "mapper", "strength": 4}, "vendor": {...}, ...}

  The groups are `name` (name and hostname), `vendor` (vendor_name and model),
  `type` (type, type_id and metadata device_role), `integration_type` and
  `management_device_id`. A group with a tag and an empty value is a recorded
  clear; a group with no tag has no recorded strength (every row written before
  this change). Existing rows get `{}`: nothing is backfilled, because a
  strength is assigned by the writer from the evidence it holds and cannot be
  inferred from a stored value.

  `platform.sr_attribute_write_accepted/4` is the one decision every writer
  uses (the sync upsert's ON CONFLICT update and the ranked direct writes): a
  write replaces the stored group when it is strictly stronger, or equally
  strong and from the source that recorded it. With no recorded strength it
  fills an empty group, and replaces a populated one only above the weakest
  tier (1). `ServiceRadar.Inventory.Sync.AttributeStrength.accepted?/4` is its
  Elixir mirror for in-batch merging.

  The column add is metadata-only (constant default), so the lock is brief.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:ocsf_devices, prefix: @prefix) do
      add :attribute_provenance, :map, null: false, default: fragment("'{}'::jsonb")
    end

    execute("""
    CREATE OR REPLACE FUNCTION platform.sr_attribute_write_accepted(
      stored jsonb,
      incoming jsonb,
      attr text,
      stored_populated boolean
    ) RETURNS boolean
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $$
      SELECT CASE
        WHEN jsonb_typeof(incoming -> attr) IS DISTINCT FROM 'object' THEN false
        WHEN jsonb_typeof(stored -> attr) IS DISTINCT FROM 'object' THEN
          NOT COALESCE(stored_populated, false)
          OR COALESCE((incoming -> attr ->> 'strength')::int, 0) > 1
        WHEN COALESCE((incoming -> attr ->> 'strength')::int, 0)
             > COALESCE((stored -> attr ->> 'strength')::int, 0) THEN true
        WHEN COALESCE((incoming -> attr ->> 'strength')::int, 0)
             = COALESCE((stored -> attr ->> 'strength')::int, 0)
          THEN (incoming -> attr ->> 'source') IS NOT DISTINCT FROM (stored -> attr ->> 'source')
        ELSE false
      END
    $$
    """)
  end

  def down do
    execute(
      "DROP FUNCTION IF EXISTS platform.sr_attribute_write_accepted(jsonb, jsonb, text, boolean)"
    )

    alter table(:ocsf_devices, prefix: @prefix) do
      remove :attribute_provenance
    end
  end
end
