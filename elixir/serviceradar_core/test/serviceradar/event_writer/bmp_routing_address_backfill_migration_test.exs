defmodule ServiceRadar.EventWriter.BmpRoutingAddressBackfillMigrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.BackfillCanonicalBmpRoutingAddresses, as: Migration

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260715130000_backfill_canonical_bmp_routing_addresses.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  Code.require_file(@migration_path)

  test "backfill canonicalizes mapped IPv4 projections without rewriting raw payloads" do
    table = "migration_bmp_routing_events"

    Repo.query!("""
    CREATE TEMP TABLE #{table} (
      id uuid PRIMARY KEY,
      time timestamptz NOT NULL,
      router_id text,
      router_ip text,
      peer_ip text,
      prefix text,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      raw_data text
    ) ON COMMIT DROP
    """)

    mapped_id = Ecto.UUID.generate()
    second_mapped_id = Ecto.UUID.generate()
    third_mapped_id = Ecto.UUID.generate()
    ipv6_id = Ecto.UUID.generate()

    raw_payload =
      ~s({"router_addr":"::ffff:10.42.57.39","peer_addr":"::ffff:169.254.0.179","prefix_addr":"::ffff:10.43.73.194"})

    Repo.query!(
      """
      INSERT INTO #{table} (id, time, router_id, router_ip, peer_ip, prefix, metadata, raw_data)
      VALUES ($1::text::uuid, now(), $2, $3, $4, $5, $6::jsonb, $7)
      """,
      [
        mapped_id,
        "::ffff:10.42.57.39",
        "::ffff:10.42.57.39",
        "::ffff:169.254.0.179",
        "::ffff:10.43.73.194/32",
        mapped_metadata(),
        raw_payload
      ]
    )

    Enum.each(
      [
        {
          second_mapped_id,
          "::ffff:198.51.100.2",
          "::ffff:198.51.100.3",
          "legacy BMP metadata"
        },
        {
          third_mapped_id,
          "::ffff:203.0.113.4",
          "::ffff:203.0.113.5",
          %{
            "source_identity" => "legacy scalar",
            "routing_correlation" => "legacy scalar",
            "explainability" => "legacy scalar"
          }
        }
      ],
      fn {id, router_ip, peer_ip, metadata} ->
        Repo.query!(
          """
          INSERT INTO #{table} (id, time, router_id, router_ip, peer_ip, prefix, metadata, raw_data)
          VALUES ($1::text::uuid, now(), $2, $2, $3, $4, $5::jsonb, $6)
          """,
          [
            id,
            router_ip,
            peer_ip,
            "#{router_ip}/32",
            metadata,
            ~s({"router_addr":"#{router_ip}"})
          ]
        )
      end
    )

    Repo.query!(
      """
      INSERT INTO #{table} (id, time, router_id, router_ip, peer_ip, prefix, metadata, raw_data)
      VALUES ($1::text::uuid, now(), $2, $3, $4, $5, $6::jsonb, $7)
      """,
      [
        ipv6_id,
        "2001:db8:1::39",
        "2001:db8:1::39",
        "2001:db8:2::179",
        "2001:db8:3::/64",
        ipv6_metadata(),
        ~s({"router_addr":"2001:db8:1::39"})
      ]
    )

    Enum.each(Migration.helper_statements("pg_temp"), &Repo.query!/1)

    try do
      skip_locked_sql = Migration.backfill_batch_sql("pg_temp", table, 2, :skip_locked)
      strict_sql = Migration.backfill_batch_sql("pg_temp", table, 2, :wait)

      assert skip_locked_sql =~ "FOR UPDATE SKIP LOCKED"
      assert strict_sql =~ "FOR UPDATE\n"
      refute strict_sql =~ "FOR UPDATE SKIP LOCKED"

      # The production migration uses 10,000 rows per transaction. A small
      # fixture limit proves it continues through multiple bounded batches and
      # finishes with a strict pass that cannot silently skip a locked legacy row.
      assert {:ok, %{rows: 3, batches: 2}} =
               Migration.backfill_batches(
                 Repo,
                 skip_locked_sql,
                 strict_sql,
                 2
               )

      assert %Postgrex.Result{
               rows: [
                 [
                   "10.42.57.39",
                   "10.42.57.39",
                   "169.254.0.179",
                   "10.43.73.194/32",
                   metadata,
                   ^raw_payload
                 ]
               ]
             } =
               Repo.query!(
                 """
                 SELECT router_id, router_ip, peer_ip, prefix, metadata, raw_data
                 FROM #{table}
                 WHERE id = $1::text::uuid
                 """,
                 [mapped_id]
               )

      assert get_in(metadata, ["source_identity", "router_ip"]) == "10.42.57.39"
      assert get_in(metadata, ["source_identity", "peer_ip"]) == "169.254.0.179"
      assert get_in(metadata, ["routing_correlation", "router_id"]) == "10.42.57.39"
      assert get_in(metadata, ["routing_correlation", "router_ip"]) == "10.42.57.39"
      assert get_in(metadata, ["routing_correlation", "peer_ip"]) == "169.254.0.179"
      assert get_in(metadata, ["routing_correlation", "prefix"]) == "10.43.73.194/32"

      assert get_in(metadata, ["routing_correlation", "topology_keys"]) == [
               "10.42.57.39",
               "169.254.0.179",
               "10.43.73.194/32",
               "router-name"
             ]

      assert get_in(metadata, ["explainability", "routing_topology_keys"]) == [
               "10.42.57.39",
               "169.254.0.179",
               "10.43.73.194/32"
             ]

      assert %Postgrex.Result{
               rows: [
                 [
                   "2001:db8:1::39",
                   "2001:db8:1::39",
                   "2001:db8:2::179",
                   "2001:db8:3::/64",
                   ipv6_metadata
                 ]
               ]
             } =
               Repo.query!(
                 """
                 SELECT router_id, router_ip, peer_ip, prefix, metadata
                 FROM #{table}
                 WHERE id = $1::text::uuid
                 """,
                 [ipv6_id]
               )

      assert get_in(ipv6_metadata, ["source_identity", "router_ip"]) == "2001:db8:1::39"
      assert get_in(ipv6_metadata, ["routing_correlation", "prefix"]) == "2001:db8:3::/64"

      assert %Postgrex.Result{rows: [[0]]} =
               Repo.query!("""
               SELECT count(*)
               FROM #{table}
               WHERE router_ip LIKE '::ffff:%'
                  OR peer_ip LIKE '::ffff:%'
                  OR prefix LIKE '::ffff:%'
               """)

      assert %{num_rows: 0} = Repo.query!(Migration.backfill_batch_sql("pg_temp", table, 2))
    after
      Enum.each(Migration.drop_helper_statements("pg_temp"), &Repo.query!/1)
    end
  end

  defp mapped_metadata do
    %{
      "source_identity" => %{
        "router_ip" => "::ffff:10.42.57.39",
        "peer_ip" => "::ffff:169.254.0.179"
      },
      "routing_correlation" => %{
        "router_id" => "::ffff:10.42.57.39",
        "router_ip" => "::ffff:10.42.57.39",
        "peer_ip" => "::ffff:169.254.0.179",
        "prefix" => "::ffff:10.43.73.194/32",
        "topology_keys" => [
          "::ffff:10.42.57.39",
          "::ffff:169.254.0.179",
          "::ffff:10.43.73.194/32",
          "router-name"
        ]
      },
      "explainability" => %{
        "routing_topology_keys" => [
          "::ffff:10.42.57.39",
          "::ffff:169.254.0.179",
          "::ffff:10.43.73.194/32"
        ]
      }
    }
  end

  defp ipv6_metadata do
    %{
      "source_identity" => %{
        "router_ip" => "2001:db8:1::39",
        "peer_ip" => "2001:db8:2::179"
      },
      "routing_correlation" => %{
        "router_id" => "2001:db8:1::39",
        "router_ip" => "2001:db8:1::39",
        "peer_ip" => "2001:db8:2::179",
        "prefix" => "2001:db8:3::/64",
        "topology_keys" => ["2001:db8:1::39", "2001:db8:2::179", "2001:db8:3::/64"]
      },
      "explainability" => %{
        "routing_topology_keys" => [
          "2001:db8:1::39",
          "2001:db8:2::179",
          "2001:db8:3::/64"
        ]
      }
    }
  end
end
