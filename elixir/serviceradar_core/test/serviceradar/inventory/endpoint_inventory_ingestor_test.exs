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

  defp successful_upload do
    fn _metadata, _data, _opts -> {:ok, %{ok?: true}} end
  end

  defp current_scan(agent_id) do
    Repo.one!(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id and s.current == true,
        select: %{scan_id: s.scan_id, package_count: s.package_count}
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

  defp artifact_count(scan_ref) do
    Repo.one!(
      from(a in "endpoint_inventory_artifacts",
        where: a.scan_ref == ^scan_ref,
        select: count(a.id)
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
