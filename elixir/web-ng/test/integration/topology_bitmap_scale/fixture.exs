defmodule ServiceRadarWebNG.Topology.Scale.Fixture do
  @moduledoc false
  alias ServiceRadar.Repo
  alias ServiceRadar.TopologyAtlas

  @population 1_100_000
  @batch 500
  def population, do: @population
  def uid(n), do: "sr:atlas-scale-#{n}"

  def query,
    do: %{
      "all" => [
        %{"facet" => "availability", "value" => "unavailable"},
        %{"facet" => "tag:scale", "value" => "fixture"},
        %{"ip_cidr" => "2001:db8::/32"},
        %{"facet" => "region", "prefix" => "region-"}
      ]
    }

  # Bootstrap invented identities before creating devices or starting any index.
  # Existing dictionary rows and tombstones are never reassigned or removed.
  def seed(distribution) do
    [[max_ordinal]] = Repo.query!("SELECT coalesce(max(ordinal), 0) FROM platform.device_fleet_ordinals").rows
    base = if distribution == :sparse, do: max(2_147_483_648, max_ordinal + 1), else: max_ordinal + 1
    stride = if distribution == :sparse, do: 7, else: 1
    true = base + (@population - 1) * stride <= 4_294_967_295

    for first <- 0..(@population - 1)//@batch do
      last = min(first + @batch - 1, @population - 1)

      {:ok, :ok} =
        Repo.transaction(
          fn ->
            Repo.query!("SET LOCAL platform.skip_inventory_rollup = 'on'")

            Repo.query!(
              """
              INSERT INTO platform.device_fleet_ordinals(uid, ordinal, tombstoned)
              SELECT 'sr:atlas-scale-' || n, $3::bigint + n * $4::bigint, false
              FROM generate_series($1::bigint, $2::bigint) n
              """,
              [first, last, base, stride]
            )

            Repo.query!(
              """
              INSERT INTO platform.ocsf_devices
                (uid, hostname, type_id, ip, vendor_name, region, vlan_uid, is_available, tags)
              SELECT 'sr:atlas-scale-' || n, 'node.example.com', CASE WHEN n < 100000 THEN 12 ELSE 2 END,
                '192.0.2.' || (n % 254 + 1), 'vendor-' || (n % 8), 'region-' || (n % 10),
                (20 + n % 8)::text, true, jsonb_build_object('cohort', 'cohort-' || (n % 50), 'scale', 'fixture')
              FROM generate_series($1::bigint, $2::bigint) n
              """,
              [first, last]
            )

            # The second assignment lives on a real interface source. Multiplication
            # permutes ownership, avoiding the monotonic-address native benchmark.
            Repo.query!(
              """
              INSERT INTO platform.discovered_interfaces(device_id, interface_uid, timestamp, ip_addresses)
              SELECT 'sr:atlas-scale-' || n, 'example-port', now(),
                ARRAY['2001:db8::' || to_hex(((n * 7919) % 1100000) / 65536) || ':' ||
                  to_hex(((n * 7919) % 1100000) % 65536)]
              FROM generate_series($1::bigint, $2::bigint) n
              """,
              [first, last]
            )

            :ok
          end,
          timeout: 30_000
        )
    end

    Repo.query!(
      "SELECT setval('platform.device_fleet_ordinals_ordinal_seq', (SELECT max(ordinal) FROM platform.device_fleet_ordinals), true)"
    )

    Repo.query!("SELECT platform.refresh_device_inventory_rollups()", [], timeout: 60_000)
    %{distribution: distribution, base: base, stride: stride, devices: @population, addresses: @population * 2}
  end

  def churn(tick, notify) do
    # Exactly one percent each tick; every device participates in the 100-tick cycle.
    first = rem(tick, 100) * div(@population, 100)
    last = first + div(@population, 100) - 1

    for start <- first..last//@batch do
      ids = Enum.map(start..min(start + @batch - 1, last), &uid/1)

      result =
        Repo.query!(
          """
          UPDATE platform.ocsf_devices SET is_available = NOT is_available,
            ip = CASE WHEN is_available THEN '198.51.100.7' ELSE '192.0.2.7' END
          WHERE uid = ANY($1::text[])
          """,
          [ids],
          timeout: 30_000
        )

      true = result.num_rows == length(ids)
      notify.(ids)
    end

    # The final SQL oracle checks persisted values. Avoid an extra fleet-wide
    # count every tick while measuring the real reconciliation reader load.
    (tick + 1) * div(@population, 100)
  end

  def expected_total do
    [[total]] =
      Repo.query!("SELECT count(*) FROM platform.ocsf_devices WHERE uid LIKE 'sr:atlas-scale-%' AND is_available = false").rows

    total
  end

  def cap_facet do
    Repo.query!("""
    UPDATE platform.ocsf_devices SET tags = tags || jsonb_build_object('cohort', uid)
    WHERE uid IN (SELECT 'sr:atlas-scale-' || n FROM generate_series(0, 1024) n)
    """)
  end

  def world(version, count \\ @population) do
    {:ok, builder} = TopologyAtlas.new_builder(version, 24)

    for first <- 0..(count - 1)//500 do
      :ok = TopologyAtlas.add_positions(builder, Enum.map(first..min(first + 499, count - 1), &position/1))
    end

    {:ok, world} = TopologyAtlas.finish_world(builder)
    world
  end

  def position(n) do
    tile = rem(n, 64)
    leaf = div(n, 64)
    promoted = leaf < 127

    %{
      device_id: uid(n),
      label: "Synthetic device",
      parent_id: nil,
      x: rem(tile, 8) * 2_097_152 + if(promoted, do: 100_000 + rem(leaf, 16) * 100_000, else: 100 + rem(leaf, 10_000)),
      y: div(tile, 8) * 2_097_152 + if(promoted, do: 100_000 + div(leaf, 16) * 100_000, else: 100 + div(leaf, 10_000)),
      min_zoom: if(promoted, do: 0, else: 24),
      placement_depth: 24,
      component_id: "synthetic-component",
      component_z: 0,
      component_x: 0,
      component_y: 0,
      active: true
    }
  end
end
