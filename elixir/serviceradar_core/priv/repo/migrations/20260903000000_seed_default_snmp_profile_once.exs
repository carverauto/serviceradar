defmodule ServiceRadar.Repo.Migrations.SeedDefaultSnmpProfileOnce do
  @moduledoc """
  Seeds the starter SNMP profile exactly once, replacing `SNMPProfileSeeder`.
  GitHub #4170.

  The seeder ran on every boot and re-asserted "an instance has a default
  profile". That made the profile list impossible to empty: an operator who
  deleted every profile got one back on the next restart, with nothing in the
  UI to say why. An instance with no SNMP profile is a legitimate state -- it
  means SNMP polling is off -- so the seed has to happen once and never again.

  A migration is that "once": Ecto records it in schema_migrations and will not
  replay it. No marker table is needed.

  Guarded on the table being empty rather than on "no row has is_default", so
  an install whose profiles were all deliberately demoted to targeting profiles
  does not get a surprise default appended. Existing installs already hold the
  seeder's row and are skipped.

  The seeder also backfilled a blank `target_query` on the default profile.
  That is not carried over: `SNMPCompiler.normalize_target_query/2` already
  resolves a blank query on a default profile to `in:devices`, so the backfill
  only rewrote a value the compiler was computing anyway.
  """

  use Ecto.Migration

  # Only the columns that differ from their schema defaults are listed. id
  # (uuid_generate_v7()), poll_interval, timeout, retries, priority, version,
  # oid_template_ids, agent_ids and both timestamps all carry defaults, so
  # naming them here would only risk drifting from the schema.
  def up do
    execute """
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
    """
  end

  # Deleting the operator's SNMP profile on rollback would take their polling
  # configuration with it.
  def down, do: :ok
end
