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

  # Bootstrap invented identities while their new devices are inactive, before
  # starting any index. Existing identities and tombstones are never reassigned.
  def seed(distribution) do
    assert_disposable_clone!()
    [[max_ordinal]] = Repo.query!("SELECT coalesce(max(ordinal), 0) FROM platform.device_fleet_ordinals").rows
    base = if distribution == :sparse, do: max(2_147_483_648, max_ordinal + 1), else: max_ordinal + 1
    stride = if distribution == :sparse, do: 7, else: 1
    true = base + (@population - 1) * stride <= 4_294_967_295
    Process.put(:atlas_scale_seeded, true)

    for first <- 0..(@population - 1)//@batch do
      last = min(first + @batch - 1, @population - 1)

      {:ok, :ok} =
        Repo.transaction(
          fn ->
            Repo.query!("SET LOCAL platform.skip_inventory_rollup = 'on'")

            Repo.query!(
              """
              INSERT INTO platform.ocsf_devices
                (uid, hostname, type_id, ip, vendor_name, region, vlan_uid, is_available, is_active, tags)
              SELECT 'sr:atlas-scale-' || n, 'node.example.com', CASE WHEN n < 100000 THEN 12 ELSE 2 END,
                '2001:db8:1::' || to_hex(((n * 7919) % 1100000) / 65536) || ':' ||
                  to_hex(((n * 7919) % 1100000) % 65536),
                'vendor-' || (n % 8), 'region-' || (n % 10),
                (20 + n % 8)::text, true, false,
                jsonb_build_object('cohort', 'cohort-' || (n % 50), 'scale', 'fixture')
              FROM generate_series($1::bigint, $2::bigint) n
              """,
              [first, last]
            )

            # The immediate FK requires devices first. Inactive insertion avoids
            # automatic assignment; normal activation then adopts these new IDs.
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
              UPDATE platform.ocsf_devices SET is_active = true
              FROM generate_series($1::bigint, $2::bigint) n
              WHERE uid = 'sr:atlas-scale-' || n
              """,
              [first, last]
            )

            # Primary addresses above are unique and permute ownership. Shared
            # addresses belong on interfaces, outside the primary-IP unique index.
            Repo.query!(
              """
              INSERT INTO platform.discovered_interfaces(device_id, interface_uid, timestamp, ip_addresses)
              SELECT 'sr:atlas-scale-' || n, 'example-port', now(),
                ARRAY['198.51.100.7']
              FROM generate_series($1::bigint, $2::bigint) n
              """,
              [first, last]
            )

            :ok
          end,
          timeout: 30_000
        )
    end

    %{rows: [[previous, called]]} =
      Repo.query!("SELECT last_value, is_called FROM platform.device_fleet_ordinals_ordinal_seq")

    Process.put(:atlas_scale_ordinal_seq, {previous, called})

    Repo.query!(
      "SELECT setval('platform.device_fleet_ordinals_ordinal_seq', (SELECT max(ordinal) FROM platform.device_fleet_ordinals), true)"
    )

    Repo.query!("SELECT platform.refresh_device_inventory_rollups()", [], timeout: 60_000)
    %{distribution: distribution, base: base, stride: stride, devices: @population, addresses: @population * 2}
  end

  def cleanup! do
    if Process.get(:atlas_scale_seeded) do
      Enum.each(0..(@population - 1)//200, fn first ->
        last = min(first + 199, @population - 1)
        ids = Enum.map(first..last, &uid/1)

        Repo.query!(
          "DELETE FROM platform.discovered_interfaces WHERE device_id = ANY($1::text[])",
          [ids]
        )

        ServiceRadar.TestSupport.delete_device_fixtures!(ids)
      end)

      Repo.query!("DELETE FROM platform.ng_users WHERE email = 'atlas-scale@example.com'")

      case Process.get(:atlas_scale_ordinal_seq) do
        {previous, called} ->
          Repo.query!(
            "SELECT setval('platform.device_fleet_ordinals_ordinal_seq', $1::bigint, $2::boolean)",
            [previous, called]
          )

        _ ->
          :ok
      end
    end

    :ok
  end

  defp assert_disposable_clone! do
    run_id_path = Path.join(System.fetch_env!("TEST_TMPDIR"), "build/run_id_file.txt")
    base_name = run_id_path |> File.read!() |> String.trim()

    expected =
      ServiceRadar.DB.IntegrationEnvConfig.database_name!(
        base_name,
        System.get_env("SERVICERADAR_TEST_DB_SHARD")
      )

    %{rows: [[current]]} = Repo.query!("SELECT current_database()")

    if current != expected do
      raise "scale seed refused: connected to #{current}, disposable clone is #{expected}"
    end

    %{rows: [[existing]]} =
      Repo.query!("SELECT count(*) FROM platform.ocsf_devices WHERE uid LIKE 'sr:atlas-scale-%'")

    if existing != 0 do
      raise "scale seed refused: #{existing} atlas-scale rows already exist"
    end

    :ok
  end

  def churn(tick, notify) do
    # Exactly one percent each tick; every device participates in the 100-tick cycle.
    first = rem(tick, 100) * div(@population, 100)
    last = first + div(@population, 100) - 1

    for start <- first..last//@batch do
      finish = min(start + @batch - 1, last)
      ids = Enum.map(start..finish, &uid/1)

      result =
        Repo.query!(
          """
          UPDATE platform.ocsf_devices SET is_available = NOT is_available,
            ip = '2001:db8:2::' || to_hex(((n * 7919) % 1100000) / 65536) || ':' ||
              to_hex(((n * 7919) % 1100000) % 65536)
          FROM generate_series($1::bigint, $2::bigint) n
          WHERE uid = 'sr:atlas-scale-' || n
          """,
          [start, finish],
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
