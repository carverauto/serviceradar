defmodule ServiceRadar.Repo.Migrations.AddAddressRankFunction do
  @moduledoc """
  Ranks an IP address by its fitness to be a device's PRIMARY address.

  `platform.ocsf_devices.ip` is overwritten by whatever update arrives last. An
  NDP census sighting carries a `fe80::` link-local, so a device with a perfectly
  good routable address can be rewritten to one that is not routable, is not
  unique beyond a link, and cannot reach the host. Measured on one deployment:
  25 of 126 live devices presented a link-local or ULA primary (GitHub #3905),
  and 10 of them already held the better address as an alias.

  The comparison has to happen against the CURRENT row at write time, which only
  SQL sees -- the bulk upsert deliberately never reads the row it is updating.
  Hence a function rather than logic in Elixir.

  It mirrors `ServiceRadar.Inventory.Identity.Address.rank/1`, and the two are
  pinned together by a parity test rather than by hope.

  IMMUTABLE and STRICT so it can be used in index expressions later and costs
  nothing on NULL. `pg_input_is_valid/2` (PG16+) is what makes it total: casting
  arbitrary text to `inet` raises, and `ip` is a text column that legitimately
  holds blanks.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION platform.sr_address_rank(addr text)
    RETURNS smallint
    LANGUAGE sql
    IMMUTABLE
    STRICT
    PARALLEL SAFE
    AS $$
      WITH trimmed AS (
        -- Strip a %zone and a /cidr before parsing, matching
        -- Identity.Address.normalize/1. Both reach inventory from real
        -- collectors: SNMP reports link-locals as `fe80::1%eth0`, and interface
        -- addresses arrive as `192.168.1.1/24`. Without this, pg_input_is_valid
        -- rejects them and they rank 0 while Elixir ranks them correctly -- a
        -- divergence the parity test catches.
        SELECT split_part(split_part(btrim(addr), '%', 1), '/', 1) AS t
      ),
      raw AS (
        SELECT CASE
          WHEN t = '' THEN NULL
          WHEN NOT pg_input_is_valid(t, 'inet') THEN NULL
          ELSE t::inet
        END AS a
        FROM trimmed
      ),
      norm AS (
        -- An IPv4-mapped address (::ffff:a.b.c.d) is an IPv4 address wearing an
        -- IPv6 shape. Postgres compares it as IPv6, so a mapped RFC1918 address
        -- is not contained in 192.168.0.0/16 and reads as global. Unwrap it to
        -- the address it actually is. A parity test against the Elixir ranking
        -- caught exactly this.
        SELECT CASE
          WHEN a IS NULL THEN NULL
          WHEN a <<= '::ffff:0:0/96'::inet
            THEN '0.0.0.0'::inet + (a - '::ffff:0.0.0.0'::inet)
          ELSE a
        END AS a
        FROM raw
      )
      SELECT CASE
        WHEN a IS NULL THEN 0::smallint
        -- Never a primary address.
        WHEN a <<= '127.0.0.0/8'::inet
          OR a <<= '::1/128'::inet
          OR a <<= '0.0.0.0/32'::inet
          OR a <<= '::/128'::inet THEN 0::smallint
        -- Valid on one link only.
        WHEN a <<= '169.254.0.0/16'::inet
          OR a <<= 'fe80::/10'::inet THEN 20::smallint
        -- Stable, not globally routable.
        WHEN a <<= 'fc00::/7'::inet THEN 30::smallint
        -- Reachable within the deployment.
        WHEN a <<= '10.0.0.0/8'::inet
          OR a <<= '172.16.0.0/12'::inet
          OR a <<= '192.168.0.0/16'::inet
          OR a <<= '100.64.0.0/10'::inet THEN 40::smallint
        ELSE 50::smallint
      END
      FROM norm
    $$;
    """)

    execute("""
    COMMENT ON FUNCTION platform.sr_address_rank(text) IS
      'Fitness of an address as a device primary IP: 50 global, 40 private, 30 ULA, 20 link-local, 0 never. Mirrors ServiceRadar.Inventory.Identity.Address.rank/1; kept in step by a parity test.';
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS platform.sr_address_rank(text)")
  end
end
