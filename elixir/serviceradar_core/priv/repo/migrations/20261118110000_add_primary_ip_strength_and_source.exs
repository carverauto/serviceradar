defmodule ServiceRadar.Repo.Migrations.AddPrimaryIpStrengthAndSource do
  @moduledoc """
  Primary address strength and the source that recorded the primary.

  `platform.sr_address_rank/1` alone let a global IPv6 (rank 50) and a private
  IPv4 (rank 40) tie in the upsert's never-downgrade guard, so on a dual-stack
  device the last writer won and the primary flipped between families on every
  passive-census pass. `platform.sr_address_strength/1` ranks the family first: a
  usable IPv4 (routable, rank 40 or 50) beats any IPv6, a routable address of
  either family beats a link-local of either family, and the rank decides only
  within a class. It mirrors `ServiceRadar.Inventory.Identity.Address.strength/1`,
  and a parity test pins the two together.

  `ip_source` and `ip_seen_at` record which source wrote the stored primary and
  when that source last sighted it. An equal-strength address replaces the stored
  primary only when the stored one is absent from its recording source's
  sightings (`DeviceWrites`), which needs both.
  """
  use Ecto.Migration

  def up do
    alter table(:ocsf_devices, prefix: "platform") do
      add_if_not_exists :ip_source, :text
      add_if_not_exists :ip_seen_at, :utc_datetime_usec
    end

    execute("""
    CREATE OR REPLACE FUNCTION platform.sr_address_strength(addr text)
    RETURNS smallint
    LANGUAGE sql
    IMMUTABLE
    STRICT
    PARALLEL SAFE
    AS $$
      WITH ranked AS (
        SELECT platform.sr_address_rank(addr) AS r,
               split_part(split_part(btrim(addr), '%', 1), '/', 1) AS t
      ),
      fam AS (
        -- The family of the address after the IPv4-mapped unwrap
        -- (::ffff:a.b.c.d is IPv4), matching sr_address_rank's own unwrap.
        SELECT r,
               CASE
                 WHEN r = 0 THEN 0
                 WHEN family(t::inet) = 4 THEN 4
                 WHEN t::inet <<= '::ffff:0:0/96'::inet THEN 4
                 ELSE 6
               END AS f
        FROM ranked
      )
      SELECT CASE
        WHEN r = 0 THEN 0::smallint
        WHEN r = 20 THEN (100 + r)::smallint
        WHEN f = 4 THEN (300 + r)::smallint
        ELSE (200 + r)::smallint
      END
      FROM fam
    $$;
    """)

    execute("""
    COMMENT ON FUNCTION platform.sr_address_strength(text) IS
      'Strength of an address as a device primary IP: usable IPv4 (300+rank) > routable IPv6 (200+rank) > link-local (120) > never (0). Mirrors ServiceRadar.Inventory.Identity.Address.strength/1; kept in step by a parity test.';
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS platform.sr_address_strength(text)")

    alter table(:ocsf_devices, prefix: "platform") do
      remove_if_exists :ip_seen_at, :utc_datetime_usec
      remove_if_exists :ip_source, :text
    end
  end
end
