defmodule ServiceRadar.Inventory.VirtualizationV3IdentityDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor
  alias ServiceRadar.Inventory.VirtualizationCluster
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:virtualization_v3_identity_db_test)}
  end

  test "database denies new legacy identities and ordinary legacy provenance promotion" do
    suffix = System.unique_integer([:positive])
    legacy_ref = "proxmox:cluster:legacy-#{suffix}"

    assert_check_violation(fn ->
      Repo.query(
        """
        INSERT INTO platform.virtualization_clusters (id, provider, provider_ref, name)
        VALUES (gen_random_uuid(), 'proxmox', $1, $2)
        """,
        [legacy_ref, "legacy-#{suffix}"]
      )
    end)

    Repo.query!(
      "ALTER TABLE platform.virtualization_clusters DISABLE TRIGGER virtualization_clusters_identity_immutable_guard"
    )

    legacy_id =
      try do
        [[legacy_id]] =
          Repo.query!(
            """
            INSERT INTO platform.virtualization_clusters (id, provider, provider_ref, name)
            VALUES (gen_random_uuid(), 'proxmox', $1, $2)
            RETURNING id
            """,
            [legacy_ref, "legacy-#{suffix}"]
          ).rows

        legacy_id
      after
        Repo.query!(
          "ALTER TABLE platform.virtualization_clusters ENABLE TRIGGER virtualization_clusters_identity_immutable_guard"
        )
      end

    integration_id = Ecto.UUID.generate()
    controller_id = Ecto.UUID.generate()
    instance_ref = "proxmox:v3:#{integration_id}:#{controller_id}:legacy-#{suffix}"

    assert_check_violation(fn ->
      Repo.query(
        """
        UPDATE platform.virtualization_clusters
        SET provider_ref = $1,
            identity_version = 3,
            identity_state = 'authoritative',
            integration_id = ($2::text)::uuid,
            controller_id = ($3::text)::uuid,
            native_cluster_id = $4,
            object_kind = 'cluster',
            native_object_id = $4,
            provider_instance_ref = $5
        WHERE id = $6
        """,
        [
          instance_ref <> ":cluster:legacy-#{suffix}",
          integration_id,
          controller_id,
          "legacy-#{suffix}",
          instance_ref,
          legacy_id
        ]
      )
    end)
  end

  test "same native Proxmox inventory remains distinct and legacy aliases quarantine", %{
    actor: actor
  } do
    suffix = System.unique_integer([:positive])
    cluster = "shared-#{suffix}"
    node = "pve-shared-#{suffix}"
    vmid = rem(suffix, 900_000) + 100

    farm = %{
      integration_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      partition_id: "farm01"
    }

    tonka = %{
      integration_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      partition_id: "tonka01"
    }

    farm_payload = payload(cluster, node, vmid, "10.210.1.11", "10.210.1.21")
    tonka_payload = payload(cluster, node, vmid, "10.220.1.11", "10.220.1.21")

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(farm_payload, %{},
               actor: actor,
               source_scope: farm
             )

    # Replaying one controller is idempotent.
    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(farm_payload, %{},
               actor: actor,
               source_scope: farm
             )

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(tonka_payload, %{},
               actor: actor,
               source_scope: tonka
             )

    rows =
      Repo.query!(
        """
        SELECT
          g.id,
          g.integration_id::text,
          g.controller_id::text,
          g.native_cluster_id,
          g.object_kind,
          g.native_object_id,
          g.provider_ref,
          h.id,
          h.integration_id::text,
          h.controller_id::text,
          h.native_cluster_id,
          h.object_kind,
          h.provider_ref,
          h.device_uid
        FROM platform.virtualization_guests g
        JOIN platform.virtualization_hosts h ON h.id = g.host_id
        WHERE g.provider = 'proxmox'
          AND g.native_cluster_id = $1
          AND g.native_object_id = $2
        ORDER BY g.integration_id
        """,
        [cluster, Integer.to_string(vmid)]
      ).rows

    assert length(rows) == 2

    assert MapSet.new(Enum.map(rows, &Enum.at(&1, 1))) ==
             MapSet.new([farm.integration_id, tonka.integration_id])

    assert MapSet.size(MapSet.new(Enum.map(rows, &Enum.at(&1, 6)))) == 2
    assert MapSet.size(MapSet.new(Enum.map(rows, &Enum.at(&1, 12)))) == 2
    assert MapSet.size(MapSet.new(Enum.map(rows, &Enum.at(&1, 13)))) == 2

    for [
          _guest_id,
          integration_id,
          controller_id,
          ^cluster,
          "qemu",
          native_vmid,
          _guest_ref,
          _host_id,
          owner_integration_id,
          owner_controller_id,
          ^cluster,
          "node",
          _host_ref,
          _device_uid
        ] <- rows do
      assert native_vmid == Integer.to_string(vmid)
      assert owner_integration_id == integration_id
      assert owner_controller_id == controller_id
    end

    legacy_refs = [
      {"cluster", "proxmox:cluster:#{cluster}"},
      {"host", "proxmox:node:#{node}"},
      {"guest", "proxmox:guest:#{node}:qemu:#{vmid}"}
    ]

    for {resource_kind, legacy_ref} <- legacy_refs do
      assert [["ambiguous", nil, candidates]] =
               Repo.query!(
                 """
                 SELECT status, target_provider_ref, candidate_provider_refs
                 FROM platform.virtualization_identity_aliases
                 WHERE provider = 'proxmox'
                   AND resource_kind = $1
                   AND legacy_provider_ref = $2
                 """,
                 [resource_kind, legacy_ref]
               ).rows

      assert length(candidates) == 2
      assert Enum.all?(candidates, &String.starts_with?(&1, "proxmox:v3:"))
    end

    [farm_row, tonka_row] = Enum.sort_by(rows, &Enum.at(&1, 1))
    farm_guest_id = Enum.at(farm_row, 0)
    farm_guest_ref = Enum.at(farm_row, 6)
    tonka_host_id = Enum.at(tonka_row, 7)

    assert_check_violation(fn ->
      Repo.query(
        "UPDATE platform.virtualization_guests SET host_id = $1 WHERE id = $2",
        [tonka_host_id, farm_guest_id]
      )
    end)

    assert_check_violation(fn ->
      Repo.query(
        "UPDATE platform.virtualization_guests SET provider_ref = $1 WHERE id = $2",
        [farm_guest_ref <> ":mutated", farm_guest_id]
      )
    end)
  end

  test "superseded legacy rows stay stored but are not read as current inventory", %{
    actor: actor
  } do
    suffix = System.unique_integer([:positive])
    cluster = "lab-#{suffix}"
    node_a = "pve-a-#{suffix}"
    node_shared = "pve-s-#{suffix}"
    [resolved_vmid, shared_vmid, unresolved_vmid, dangling_vmid] = Enum.map(1..4, &(&1 + 200))

    scope_a = %{
      integration_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      partition_id: "site-a"
    }

    scope_b = %{
      integration_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      partition_id: "site-b"
    }

    # node_a and its guest are reported once (resolved aliases); node_shared,
    # its guest, and the cluster are reported by both scopes (ambiguous).
    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(
               inventory_payload(cluster, [
                 {node_a, "192.0.2.11", [{resolved_vmid, "192.0.2.21"}]},
                 {node_shared, "192.0.2.12", [{shared_vmid, "192.0.2.22"}]}
               ]),
               %{},
               actor: actor,
               source_scope: scope_a
             )

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(
               inventory_payload(cluster, [
                 {node_shared, "198.51.100.12", [{shared_vmid, "198.51.100.22"}]}
               ]),
               %{},
               actor: actor,
               source_scope: scope_b
             )

    legacy_device_uid = "sr:" <> Ecto.UUID.generate()
    Repo.query!("INSERT INTO platform.ocsf_devices (uid) VALUES ($1)", [legacy_device_uid])

    legacy_cluster_ref = "proxmox:cluster:#{cluster}"
    legacy_host_a_ref = "proxmox:node:#{node_a}"
    legacy_host_shared_ref = "proxmox:node:#{node_shared}"
    legacy_resolved_ref = "proxmox:guest:#{node_a}:qemu:#{resolved_vmid}"
    legacy_shared_ref = "proxmox:guest:#{node_shared}:qemu:#{shared_vmid}"
    legacy_unresolved_ref = "proxmox:guest:#{node_a}:qemu:#{unresolved_vmid}"
    legacy_dangling_ref = "proxmox:guest:#{node_a}:qemu:#{dangling_vmid}"

    insert_legacy_row(:virtualization_clusters, [legacy_cluster_ref, cluster])
    host_a_id = insert_legacy_row(:virtualization_hosts, [legacy_host_a_ref, node_a])
    insert_legacy_row(:virtualization_hosts, [legacy_host_shared_ref, node_shared])

    legacy_guest_refs = [
      legacy_resolved_ref,
      legacy_shared_ref,
      legacy_unresolved_ref,
      legacy_dangling_ref
    ]

    for ref <- legacy_guest_refs do
      insert_legacy_row(:virtualization_guests, [ref, host_a_id, legacy_device_uid])
    end

    # Migration-seeded unresolved alias, and a resolved alias whose v3 target
    # row no longer exists: neither has current v3 data to replace the row.
    insert_alias(legacy_unresolved_ref, "unresolved", nil, [])
    dangling_target = "proxmox:v3:#{Ecto.UUID.generate()}:missing:qemu:#{dangling_vmid}"
    insert_alias(legacy_dangling_ref, "resolved", dangling_target, [dangling_target])

    expected_aliases = %{
      {"cluster", legacy_cluster_ref} => "ambiguous",
      {"host", legacy_host_a_ref} => "resolved",
      {"host", legacy_host_shared_ref} => "ambiguous",
      {"guest", legacy_resolved_ref} => "resolved",
      {"guest", legacy_shared_ref} => "ambiguous",
      {"guest", legacy_unresolved_ref} => "unresolved",
      {"guest", legacy_dangling_ref} => "resolved"
    }

    assert Map.take(alias_statuses(), Map.keys(expected_aliases)) == expected_aliases

    # The device page reads the guest bound to the legacy device.
    assert {:ok, device_guests} =
             VirtualizationGuest
             |> Ash.Query.for_read(:by_device, %{device_uid: legacy_device_uid})
             |> Ash.read(actor: actor)

    assert device_guests |> Enum.map(& &1.provider_ref) |> Enum.sort() ==
             Enum.sort([legacy_unresolved_ref, legacy_dangling_ref])

    v3_guest_refs = v3_refs("virtualization_guests", cluster)
    v3_host_refs = v3_refs("virtualization_hosts", cluster)
    v3_cluster_refs = v3_refs("virtualization_clusters", cluster)

    # Scope A's guests and the shared guest from both scopes.
    assert length(v3_guest_refs) == 3
    assert length(v3_host_refs) == 3
    assert length(v3_cluster_refs) == 2

    assert current_refs(VirtualizationGuest, legacy_guest_refs ++ v3_guest_refs, actor) ==
             MapSet.new([legacy_unresolved_ref, legacy_dangling_ref | v3_guest_refs])

    assert current_refs(
             VirtualizationHost,
             [legacy_host_a_ref, legacy_host_shared_ref | v3_host_refs],
             actor
           ) == MapSet.new(v3_host_refs)

    assert current_refs(VirtualizationCluster, [legacy_cluster_ref | v3_cluster_refs], actor) ==
             MapSet.new(v3_cluster_refs)

    # Legacy rows are kept, and an exact provider-ref lookup still reaches them.
    assert [[4]] =
             Repo.query!(
               "SELECT count(*) FROM platform.virtualization_guests WHERE device_uid = $1",
               [legacy_device_uid]
             ).rows

    assert {:ok, %VirtualizationGuest{provider_ref: ^legacy_resolved_ref}} =
             VirtualizationGuest
             |> Ash.Query.for_read(:by_provider_ref, %{
               provider: "proxmox",
               provider_ref: legacy_resolved_ref
             })
             |> Ash.read_one(actor: actor)
  end

  defp inventory_payload(cluster, nodes) do
    %{
      "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "details" => %{
        "schema" => "serviceradar.proxmox_enrichment.v1",
        "targets" => [
          %{
            "cluster" => [%{"type" => "cluster", "id" => cluster, "name" => cluster}],
            "nodes" =>
              Enum.map(nodes, fn {node, node_ip, _guests} ->
                %{"node" => node, "status" => "online", "ip" => node_ip, "network" => []}
              end),
            "guests" =>
              Enum.flat_map(nodes, fn {node, _node_ip, guests} ->
                Enum.map(guests, fn {vmid, guest_ip} ->
                  %{
                    "node" => node,
                    "type" => "qemu",
                    "vmid" => vmid,
                    "name" => "guest-#{vmid}",
                    "status" => "running",
                    "interfaces" => [
                      %{"name" => "eth0", "ip_addresses" => [guest_ip <> "/24"]}
                    ]
                  }
                end)
              end)
          }
        ]
      }
    }
  end

  # New Proxmox rows must be v3, so a pre-migration row needs the guard off.
  defp insert_legacy_row(table, params) do
    guard = "#{table}_identity_immutable_guard"
    Repo.query!("ALTER TABLE platform.#{table} DISABLE TRIGGER #{guard}")

    try do
      [[id]] = Repo.query!(legacy_insert_sql(table), params).rows
      id
    after
      Repo.query!("ALTER TABLE platform.#{table} ENABLE TRIGGER #{guard}")
    end
  end

  defp legacy_insert_sql(:virtualization_clusters) do
    """
    INSERT INTO platform.virtualization_clusters (id, provider, provider_ref, name, status)
    VALUES (gen_random_uuid(), 'proxmox', $1, $2, 'stale')
    RETURNING id::text
    """
  end

  defp legacy_insert_sql(:virtualization_hosts) do
    """
    INSERT INTO platform.virtualization_hosts (id, provider, provider_ref, name, status)
    VALUES (gen_random_uuid(), 'proxmox', $1, $2, 'stale')
    RETURNING id::text
    """
  end

  defp legacy_insert_sql(:virtualization_guests) do
    """
    INSERT INTO platform.virtualization_guests (
      id, provider, provider_ref, host_id, device_uid, name, guest_type, status
    )
    VALUES (gen_random_uuid(), 'proxmox', $1, ($2::text)::uuid, $3, 'stale guest', 'vm', 'stopped')
    RETURNING id::text
    """
  end

  defp insert_alias(legacy_ref, status, target_ref, candidates) do
    Repo.query!(
      """
      INSERT INTO platform.virtualization_identity_aliases (
        id, provider, resource_kind, legacy_provider_ref, target_provider_ref,
        status, candidate_provider_refs
      )
      VALUES (gen_random_uuid(), 'proxmox', 'guest', $1, $2, $3, $4)
      """,
      [legacy_ref, target_ref, status, candidates]
    )
  end

  defp alias_statuses do
    "SELECT resource_kind, legacy_provider_ref, status FROM platform.virtualization_identity_aliases"
    |> Repo.query!()
    |> Map.fetch!(:rows)
    |> Map.new(fn [kind, ref, status] -> {{kind, ref}, status} end)
  end

  defp current_refs(resource, provider_refs, actor) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(provider == "proxmox" and provider_ref in ^provider_refs)
    |> Ash.read!(actor: actor)
    |> MapSet.new(& &1.provider_ref)
  end

  defp v3_refs(table, cluster) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT provider_ref
        FROM platform.#{table}
        WHERE native_cluster_id = $1 AND identity_version = 3
        """,
        [cluster]
      )

    List.flatten(rows)
  end

  defp payload(cluster, node, vmid, node_ip, guest_ip) do
    %{
      "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "details" => %{
        "schema" => "serviceradar.proxmox_enrichment.v1",
        "targets" => [
          %{
            "cluster" => [
              %{"type" => "cluster", "id" => cluster, "name" => cluster}
            ],
            "nodes" => [
              %{
                "node" => node,
                "status" => "online",
                "ip" => node_ip,
                "network" => []
              }
            ],
            "guests" => [
              %{
                "node" => node,
                "type" => "qemu",
                "vmid" => vmid,
                "name" => "guest-#{vmid}",
                "status" => "running",
                "interfaces" => [
                  %{
                    "name" => "eth0",
                    "ip_addresses" => [guest_ip <> "/24"],
                    "source" => "guest-agent"
                  }
                ]
              }
            ]
          }
        ]
      }
    }
  end

  defp assert_check_violation(fun) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            case fun.() do
              {:error, %Postgrex.Error{} = error} -> raise error
              other -> flunk("expected a PostgreSQL check violation, got: #{inspect(other)}")
            end
          end,
          mode: :savepoint
        )
      end

    assert error.postgres.code == :check_violation
  end
end
