defmodule ServiceRadar.Repo.Migrations.AttachStandardSnmpTemplatesToDefaultProfile do
  @moduledoc """
  Gives the default SNMP profile OIDs to poll.

  The starter profile (`20260903000000_seed_default_snmp_profile_once.exs`) was
  seeded with no `oid_template_ids`. `SNMPCompiler` compiles no target for a
  device its target query selects unless the profile's templates name an OID,
  so that profile selected every device and polled none of them. Nobody chose
  that: no template existed to choose.

  Two statements, in order:

  1. **A fresh install created from the schema baseline gets the starter
     profile.** The baseline is a schema-only dump, and it records the seed
     migration as applied without its row, so such an install has never had a
     default profile. It is recognised by `platform.serviceradar_schema_baselines`
     (written only when a database is created from the baseline) covering the
     seed's version, together with an empty profile table. A replayed install
     has no baseline table, so an operator there who deleted every profile -- a
     supported way to turn SNMP off (GitHub #4170) -- is not given one back.
  2. **A default profile with no templates gets the standard ones.** The ids are
     `ServiceRadar.SNMPProfiles.BuiltinTemplates.default_profile_template_ids/0`
     (System Uptime, Interface Counters), restated literally because a migration
     must not change meaning when code does. A default profile that already
     lists any template is the operator's choice and is left alone.

  The template rows themselves are written by
  `ServiceRadar.SNMPProfiles.BuiltinTemplateSeeder` on startup, after this runs.
  `oid_template_ids` has no foreign key, so referencing them first is valid;
  the seeder's inserts notify the SNMP compiler, which then recompiles.

  serviceradar:allow-startup-maintenance - the UPDATE touches at most one row
  (`snmp_profiles_unique_default_index` allows a single default profile) and the
  INSERT at most one row, so neither is a backfill and both are O(1) on first boot.
  """

  use Ecto.Migration

  @default_template_ids [
    "d0c37992-79a2-4432-81ba-3619a57a2671",
    "8d2b2e79-952f-4208-9816-aa1c600e1be1"
  ]

  def up do
    execute """
    DO $$
    BEGIN
      IF to_regclass('platform.serviceradar_schema_baselines') IS NOT NULL THEN
        EXECUTE $seed$
          INSERT INTO platform.snmp_profiles (
            name,
            description,
            is_default,
            enabled,
            target_query
          )
          SELECT
            'Default SNMP',
            'Default SNMP polling profile for discovered devices',
            true,
            true,
            'in:devices'
          WHERE NOT EXISTS (SELECT 1 FROM platform.snmp_profiles)
            AND EXISTS (
              SELECT 1
              FROM platform.serviceradar_schema_baselines
              WHERE included_through >= 20260903000000
            )
        $seed$;
      END IF;
    END
    $$;
    """

    execute """
    UPDATE platform.snmp_profiles
    SET oid_template_ids = ARRAY[#{Enum.map_join(@default_template_ids, ", ", &"'#{&1}'")}]::uuid[],
        updated_at = (now() AT TIME ZONE 'utc')
    WHERE is_default
      AND COALESCE(cardinality(oid_template_ids), 0) = 0
    """
  end

  # Removing the templates on rollback would take away the operator's polling,
  # and could not tell the attached list from one the operator chose since.
  def down, do: :ok
end
