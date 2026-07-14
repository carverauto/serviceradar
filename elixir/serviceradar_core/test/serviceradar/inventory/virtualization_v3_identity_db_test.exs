defmodule ServiceRadar.Inventory.VirtualizationV3IdentityDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor
  alias ServiceRadar.Repo

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
