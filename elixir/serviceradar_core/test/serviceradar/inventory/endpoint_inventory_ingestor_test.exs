defmodule ServiceRadar.Inventory.EndpointInventoryIngestorTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.EndpointInventoryIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:endpoint_inventory_ingestor_test)}
  end

  test "promotes successful scans without clobbering current rows on failed scans", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-device-#{unique}")
    agent_id = "endpoint-inventory-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    assert {:ok, first} =
             EndpointInventoryIngestor.ingest_report(scan_payload(agent_id, "scan-#{unique}"),
               actor: actor,
               upload_object: successful_upload()
             )

    assert first.current? == true
    assert first.package_count == 1
    assert current_scan(agent_id).scan_id == "scan-#{unique}"
    assert [package] = current_packages(agent_id)
    assert package.name == "nginx"
    assert package.package_manager == "dpkg"
    assert package.purl == "pkg:deb/nginx@1.24.0-2ubuntu7"
    assert package.purl_canonical == "pkg:deb/debian/nginx@1.24.0-2ubuntu7?arch=amd64"
    assert package.device_uid == device.uid
    assert artifact_count(first.scan_ref) == 1

    assert {:ok, failed} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-failed-#{unique}", state: "scan_failed"),
               actor: actor,
               upload_object: successful_upload()
             )

    assert failed.current? == false
    assert current_scan(agent_id).scan_id == "scan-#{unique}"
    assert [%{name: "nginx"}] = current_packages(agent_id)

    assert {:ok, empty_success} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-empty-#{unique}", components: []),
               actor: actor,
               upload_object: successful_upload()
             )

    assert empty_success.current? == true
    assert current_scan(agent_id).scan_id == "scan-empty-#{unique}"
    assert current_packages(agent_id) == []
  end

  test "normalizes canonical purl and deduplicates by canonical coordinate", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-canonical-device-#{unique}")
    agent_id = "endpoint-inventory-canonical-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    components = [
      %{
        "type" => "library",
        "name" => "nginx",
        "version" => "1.24.0-2ubuntu7",
        "purl" => "pkg:DEB/nginx@1.24.0-2ubuntu7?arch=amd64",
        "properties" => [
          %{"name" => "serviceradar:package_manager", "value" => "dpkg"},
          %{"name" => "serviceradar:architecture", "value" => "amd64"}
        ]
      },
      %{
        "type" => "library",
        "name" => "nginx",
        "version" => "1.24.0-2ubuntu7",
        "properties" => [
          %{"name" => "serviceradar:package_manager", "value" => "dpkg"},
          %{"name" => "serviceradar:architecture", "value" => "amd64"}
        ]
      }
    ]

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-canonical-#{unique}", components: components),
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.package_count == 1
    assert [package] = current_packages(agent_id)
    assert package.purl_canonical == "pkg:deb/debian/nginx@1.24.0-2ubuntu7?arch=amd64"
  end

  test "normalizes package-summary ecosystem to package-manager namespace", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-package-summary-device-#{unique}")
    agent_id = "endpoint-inventory-package-summary-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    payload =
      agent_id
      |> scan_payload("scan-package-summary-#{unique}", components: [])
      |> Map.put("packages", [
        %{
          "name" => "nginx",
          "version" => "1.24.0-2ubuntu7",
          "architecture" => "amd64",
          "package_manager" => "dpkg",
          "ecosystem" => "deb",
          "purl" => "pkg:deb/nginx@1.24.0-2ubuntu7"
        }
      ])

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.package_count == 1
    assert [package] = current_packages(agent_id)
    assert package.purl_canonical == "pkg:deb/debian/nginx@1.24.0-2ubuntu7?arch=amd64"
  end

  test "unchanged package_set_hash updates scan freshness without replacing current packages", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-unchanged-device-#{unique}")
    agent_id = "endpoint-inventory-unchanged-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    assert {:ok, first} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-full-#{unique}"),
               actor: actor,
               upload_object: successful_upload()
             )

    first_scan = current_scan(agent_id)
    assert first_scan.package_set_hash
    assert first.package_count == 1
    assert package_row_count(agent_id) == 1
    assert [%{scan_ref: package_scan_ref}] = current_packages(agent_id)

    unchanged_payload =
      agent_id
      |> scan_payload("scan-unchanged-#{unique}", components: [])
      |> Map.delete("sbom")
      |> Map.merge(%{
        "state" => "unchanged",
        "coverage_state" => "complete",
        "package_count" => first_scan.package_count,
        "package_set_hash" => first_scan.package_set_hash,
        "artifact_hash" => "artifact-hash-#{unique}",
        "hash_algorithm" => "sha256-v1",
        "upload_reason" => "unchanged"
      })

    assert {:ok, unchanged} =
             EndpointInventoryIngestor.ingest_report(unchanged_payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert unchanged.current? == true
    assert unchanged.package_rows_replaced? == false
    assert unchanged.package_set_hash_mismatch? == false
    assert unchanged.reconcile_floor? == false
    assert unchanged.package_count == 1
    assert package_row_count(agent_id) == 1

    refreshed_scan = current_scan(agent_id)
    assert refreshed_scan.scan_id == "scan-unchanged-#{unique}"
    assert refreshed_scan.state == "unchanged"
    assert refreshed_scan.package_set_hash == first_scan.package_set_hash
    assert refreshed_scan.unchanged_scan_count == 1
    assert refreshed_scan.last_changed_scan_at == first_scan.last_changed_scan_at
    assert refreshed_scan.reconcile_floor_due == false

    assert [%{name: "nginx", scan_ref: ^package_scan_ref}] = current_packages(agent_id)
  end

  test "changed uploads recompute package_set_hash server-side and flag mismatches", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-mismatch-device-#{unique}")
    agent_id = "endpoint-inventory-mismatch-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    payload =
      agent_id
      |> scan_payload("scan-mismatch-#{unique}")
      |> Map.merge(%{
        "package_set_hash" => "reported-bad-hash-#{unique}",
        "hash_algorithm" => "sha256-v1",
        "upload_reason" => "changed"
      })

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.package_rows_replaced? == true
    assert result.package_set_hash_mismatch? == true

    scan = current_scan(agent_id)
    assert scan.package_set_hash == scan.server_package_set_hash
    assert scan.package_set_hash != "reported-bad-hash-#{unique}"
    assert scan.package_set_hash_mismatch == true
  end

  test "records changed scan history and server-computed package diff events", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-history-device-#{unique}")
    agent_id = "endpoint-inventory-history-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)
    nginx = "nginx-history-#{unique}"
    openssl = "openssl-history-#{unique}"
    curl = "curl-history-#{unique}"

    first_components = [
      package_component(nginx, "1.24.0-2ubuntu7"),
      package_component(openssl, "3.0.13-0ubuntu3")
    ]

    assert {:ok, first} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-history-first-#{unique}",
                 components: first_components
               ),
               actor: actor,
               upload_object: successful_upload()
             )

    assert first.scan_history_recorded? == true
    assert first.package_event_count == 2
    assert scan_history_count(agent_id) == 1

    assert [
             %{event_type: "added", name: ^nginx, new_version: "1.24.0-2ubuntu7"},
             %{event_type: "added", name: ^openssl, new_version: "3.0.13-0ubuntu3"}
           ] = package_event_rows(agent_id, "scan-history-first-#{unique}")

    second_components = [
      package_component(curl, "8.5.0-2ubuntu10"),
      package_component(nginx, "1.24.1-2ubuntu7")
    ]

    assert {:ok, second} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-history-second-#{unique}",
                 components: second_components
               ),
               actor: actor,
               upload_object: successful_upload()
             )

    assert second.scan_history_recorded? == true
    assert second.package_event_count == 3
    assert scan_history_count(agent_id) == 2

    assert [
             %{event_type: "added", name: ^curl, new_version: "8.5.0-2ubuntu10"},
             %{event_type: "removed", name: ^openssl, previous_version: "3.0.13-0ubuntu3"},
             %{
               event_type: "version_changed",
               name: ^nginx,
               previous_version: "1.24.0-2ubuntu7",
               new_version: "1.24.1-2ubuntu7"
             }
           ] = package_event_rows(agent_id, "scan-history-second-#{unique}")

    assert current_package_host_count(nginx, "1.24.0-2ubuntu7") == 0
    assert current_package_host_count(nginx, "1.24.1-2ubuntu7") == 1
    assert current_package_host_count(openssl, "3.0.13-0ubuntu3") == 0
    assert current_package_host_count(curl, "8.5.0-2ubuntu10") == 1
    assert current_cpe_host_count(package_cpe(nginx, "1.24.1-2ubuntu7")) == 1
    assert current_cpe_host_count(package_cpe(openssl, "3.0.13-0ubuntu3")) == 0
    assert package_count_history_count(agent_id) == 6
    assert cpe_count_history_count(agent_id) == 6

    latest_scan = current_scan(agent_id)
    package_event_total = package_event_count(agent_id)

    unchanged_payload =
      agent_id
      |> scan_payload("scan-history-unchanged-#{unique}", components: [])
      |> Map.delete("sbom")
      |> Map.merge(%{
        "state" => "unchanged",
        "coverage_state" => "complete",
        "package_count" => latest_scan.package_count,
        "package_set_hash" => latest_scan.package_set_hash,
        "hash_algorithm" => "sha256-v1",
        "upload_reason" => "unchanged"
      })

    assert {:ok, unchanged} =
             EndpointInventoryIngestor.ingest_report(unchanged_payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert unchanged.scan_history_recorded? == false
    assert unchanged.package_event_count == 0
    assert scan_history_count(agent_id) == 2
    assert package_event_count(agent_id) == package_event_total

    if timescale_installed?() do
      assert "endpoint_inventory_scan_history" in endpoint_inventory_hypertables()
      assert "endpoint_inventory_package_events" in endpoint_inventory_hypertables()
      assert "endpoint_inventory_package_count_history" in endpoint_inventory_hypertables()
      assert "endpoint_inventory_cpe_count_history" in endpoint_inventory_hypertables()

      assert "endpoint_inventory_package_counts_hourly" in endpoint_inventory_continuous_aggregates()

      assert "endpoint_inventory_cpe_counts_hourly" in endpoint_inventory_continuous_aggregates()
    end
  end

  test "deduplicates content-addressed SBOM payloads across scan provenance rows", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device_one = create_device!(actor, "endpoint-inventory-dedupe-device-one-#{unique}")
    device_two = create_device!(actor, "endpoint-inventory-dedupe-device-two-#{unique}")
    agent_one = "endpoint-inventory-dedupe-agent-one-#{unique}"
    agent_two = "endpoint-inventory-dedupe-agent-two-#{unique}"
    artifact_hash = String.duplicate("b", 64)
    create_agent!(actor, agent_one, device_one.uid)
    create_agent!(actor, agent_two, device_two.uid)

    test = self()

    upload_object = fn metadata, _data, _opts ->
      send(test, {:upload_object, metadata.key})
      {:ok, %{ok?: true}}
    end

    assert {:ok, first} =
             agent_one
             |> scan_payload("scan-dedupe-one-#{unique}")
             |> Map.put("artifact_hash", artifact_hash)
             |> EndpointInventoryIngestor.ingest_report(
               actor: actor,
               upload_object: upload_object
             )

    assert {:ok, second} =
             agent_two
             |> scan_payload("scan-dedupe-two-#{unique}")
             |> Map.put("artifact_hash", artifact_hash)
             |> EndpointInventoryIngestor.ingest_report(
               actor: actor,
               upload_object: upload_object
             )

    expected_object_key = "endpoint-inventory/by-hash/#{artifact_hash}.cdx.json"
    assert_receive {:upload_object, ^expected_object_key}
    refute_receive {:upload_object, _}, 50

    assert artifact_content_count(artifact_hash) == 1
    assert artifact_content_reference_count(artifact_hash) == 2

    assert [
             %{scan_ref: first_scan_ref, reused_content: false},
             %{scan_ref: second_scan_ref, reused_content: true}
           ] = artifact_provenance_rows(artifact_hash)

    assert first_scan_ref == first.scan_ref
    assert second_scan_ref == second.scan_ref
  end

  test "unchanged scans past reconcile floor return full-upload directive", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-reconcile-device-#{unique}")
    agent_id = "endpoint-inventory-reconcile-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    assert {:ok, _first} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-floor-full-#{unique}"),
               actor: actor,
               upload_object: successful_upload()
             )

    first_scan = current_scan(agent_id)

    unchanged_payload =
      agent_id
      |> scan_payload("scan-floor-unchanged-#{unique}", components: [])
      |> Map.delete("sbom")
      |> Map.merge(%{
        "state" => "unchanged",
        "coverage_state" => "complete",
        "package_count" => first_scan.package_count,
        "package_set_hash" => first_scan.package_set_hash,
        "hash_algorithm" => "sha256-v1",
        "upload_reason" => "unchanged"
      })

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(unchanged_payload,
               actor: actor,
               upload_object: successful_upload(),
               reconcile_floor_scan_count: 1,
               reconcile_floor_max_age_days: 0
             )

    assert result.reconcile_floor? == true
    assert result.directives["endpoint_inventory"]["reconcile_floor"] == true
    assert result.directives["endpoint_inventory"]["upload_reason"] == "changed"

    scan = current_scan(agent_id)
    assert scan.reconcile_floor_due == true
    assert scan.unchanged_scan_count == 1
  end

  defp scan_payload(agent_id, scan_id, opts \\ []) do
    components =
      Keyword.get(opts, :components, [
        %{
          "type" => "library",
          "name" => "nginx",
          "version" => "1.24.0-2ubuntu7",
          "purl" => "pkg:deb/nginx@1.24.0-2ubuntu7",
          "cpe" => "cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*",
          "properties" => [
            %{"name" => "serviceradar:package_manager", "value" => "dpkg"},
            %{"name" => "serviceradar:architecture", "value" => "amd64"}
          ]
        }
      ])

    %{
      "schema_version" => "serviceradar.endpoint_inventory.scan.v1",
      "agent_id" => agent_id,
      "scan_id" => scan_id,
      "collector_version" => "endpoint-inventory-test",
      "state" => Keyword.get(opts, :state, "scanned"),
      "coverage_state" => "complete",
      "last_scan_at" => DateTime.utc_now(),
      "last_successful_scan_at" => DateTime.utc_now(),
      "sources" => [
        %{"source" => "dpkg", "state" => "scanned", "package_count" => length(components)}
      ],
      "package_count" => length(components),
      "sbom" => %{
        "bomFormat" => "CycloneDX",
        "specVersion" => "1.6",
        "version" => 1,
        "components" => components
      },
      "metadata" => %{"test_scan_id" => scan_id}
    }
  end

  defp package_component(name, version, package_manager \\ "dpkg", architecture \\ "amd64") do
    %{
      "type" => "library",
      "name" => name,
      "version" => version,
      "purl" => "pkg:deb/#{name}@#{version}",
      "cpe" => package_cpe(name, version),
      "properties" => [
        %{"name" => "serviceradar:package_manager", "value" => package_manager},
        %{"name" => "serviceradar:architecture", "value" => architecture}
      ]
    }
  end

  defp package_cpe(name, version), do: "cpe:2.3:a:#{name}:#{name}:#{version}:*:*:*:*:*:*:*"

  defp successful_upload do
    fn _metadata, _data, _opts -> {:ok, %{ok?: true}} end
  end

  defp current_scan(agent_id) do
    Repo.one!(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id and s.current == true,
        select: %{
          id: s.id,
          scan_id: s.scan_id,
          state: s.state,
          package_count: s.package_count,
          package_set_hash: s.package_set_hash,
          server_package_set_hash: s.server_package_set_hash,
          package_set_hash_mismatch: s.package_set_hash_mismatch,
          unchanged_scan_count: s.unchanged_scan_count,
          last_changed_scan_at: s.last_changed_scan_at,
          reconcile_floor_due: s.reconcile_floor_due
        }
      ),
      prefix: "platform"
    )
  end

  defp current_packages(agent_id) do
    Repo.all(
      from(p in "endpoint_inventory_packages",
        where: p.agent_id == ^agent_id and p.current == true,
        order_by: [asc: p.name],
        select: %{
          scan_ref: p.scan_ref,
          name: p.name,
          package_manager: p.package_manager,
          purl: p.purl,
          purl_canonical: p.purl_canonical,
          device_uid: p.device_uid
        }
      ),
      prefix: "platform"
    )
  end

  defp package_row_count(agent_id) do
    Repo.one!(
      from(p in "endpoint_inventory_packages",
        where: p.agent_id == ^agent_id,
        select: count(p.id)
      ),
      prefix: "platform"
    )
  end

  defp scan_history_count(agent_id) do
    Repo.one!(
      from(s in "endpoint_inventory_scan_history",
        where: s.agent_id == ^agent_id,
        select: count(s.id)
      ),
      prefix: "platform"
    )
  end

  defp package_event_count(agent_id) do
    Repo.one!(
      from(e in "endpoint_inventory_package_events",
        where: e.agent_id == ^agent_id,
        select: count(e.id)
      ),
      prefix: "platform"
    )
  end

  defp current_package_host_count(name, version) do
    Repo.one!(
      from(c in "endpoint_inventory_current_package_counts",
        where: c.name == ^name and c.version == ^version,
        select: c.host_count
      ),
      prefix: "platform"
    )
  end

  defp current_cpe_host_count(cpe) do
    Repo.one!(
      from(c in "endpoint_inventory_current_cpe_counts",
        where: c.cpe == ^cpe,
        select: c.host_count
      ),
      prefix: "platform"
    )
  end

  defp package_count_history_count(agent_id) do
    Repo.one!(
      from(c in "endpoint_inventory_package_count_history",
        where: c.agent_id == ^agent_id,
        select: count(c.id)
      ),
      prefix: "platform"
    )
  end

  defp cpe_count_history_count(agent_id) do
    Repo.one!(
      from(c in "endpoint_inventory_cpe_count_history",
        where: c.agent_id == ^agent_id,
        select: count(c.id)
      ),
      prefix: "platform"
    )
  end

  defp package_event_rows(agent_id, scan_id) do
    Repo.all(
      from(e in "endpoint_inventory_package_events",
        where: e.agent_id == ^agent_id and e.scan_id == ^scan_id,
        order_by: [asc: e.event_type, asc: e.name],
        select: %{
          event_type: e.event_type,
          name: e.name,
          previous_version: e.previous_version,
          new_version: e.new_version,
          purl_canonical: e.purl_canonical
        }
      ),
      prefix: "platform"
    )
  end

  defp timescale_installed? do
    %{rows: [[installed?]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb')")

    installed?
  end

  defp endpoint_inventory_hypertables do
    %{rows: rows} =
      Repo.query!("""
      SELECT hypertable_name
      FROM timescaledb_information.hypertables
      WHERE hypertable_schema = 'platform'
        AND hypertable_name IN (
          'endpoint_inventory_scan_history',
          'endpoint_inventory_package_events',
          'endpoint_inventory_package_count_history',
          'endpoint_inventory_cpe_count_history'
        )
      """)

    Enum.map(rows, fn [name] -> name end)
  end

  defp endpoint_inventory_continuous_aggregates do
    %{rows: rows} =
      Repo.query!("""
      SELECT view_name
      FROM timescaledb_information.continuous_aggregates
      WHERE view_schema = 'platform'
        AND view_name IN (
          'endpoint_inventory_package_counts_hourly',
          'endpoint_inventory_cpe_counts_hourly'
        )
      """)

    Enum.map(rows, fn [name] -> name end)
  end

  defp artifact_count(scan_ref) do
    Repo.one!(
      from(a in "endpoint_inventory_artifacts",
        where: a.scan_ref == ^scan_ref,
        select: count(a.id)
      ),
      prefix: "platform"
    )
  end

  defp artifact_content_count(artifact_hash) do
    Repo.one!(
      from(c in "endpoint_inventory_artifact_contents",
        where: c.artifact_hash == ^artifact_hash,
        select: count(c.id)
      ),
      prefix: "platform"
    )
  end

  defp artifact_content_reference_count(artifact_hash) do
    Repo.one!(
      from(c in "endpoint_inventory_artifact_contents",
        where: c.artifact_hash == ^artifact_hash,
        select: c.reference_count
      ),
      prefix: "platform"
    )
  end

  defp artifact_provenance_rows(artifact_hash) do
    Repo.all(
      from(a in "endpoint_inventory_artifacts",
        where: a.artifact_hash == ^artifact_hash,
        order_by: [asc: a.agent_id],
        select: %{
          scan_ref: a.scan_ref,
          reused_content: a.reused_content,
          metadata: a.metadata
        }
      ),
      prefix: "platform"
    )
  end

  defp create_device!(actor, uid) do
    now = DateTime.utc_now()

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        hostname: "#{uid}.local",
        type_id: 0,
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_agent!(actor, agent_id, device_uid) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_id,
        name: agent_id,
        type_id: 0,
        device_uid: device_uid,
        capabilities: ["endpoint-inventory"]
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
