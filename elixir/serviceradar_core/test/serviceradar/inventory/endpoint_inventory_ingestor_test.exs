defmodule ServiceRadar.Inventory.EndpointInventoryIngestorTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceRiskReducer
  alias ServiceRadar.Inventory.EndpointInventoryFleetOrdinal
  alias ServiceRadar.Inventory.EndpointInventoryIngestor
  alias ServiceRadar.Inventory.EndpointInventoryTelemetry
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

    assert String.starts_with?(device.uid, "sr:")

    assert {:ok, first} =
             EndpointInventoryIngestor.ingest_report(scan_payload(agent_id, "scan-#{unique}"),
               actor: actor,
               upload_object: successful_upload()
             )

    assert first.current? == true
    assert first.package_count == 1
    assert current_scan(agent_id).scan_id == "scan-#{unique}"
    assert scan_activity = endpoint_inventory_scan_activity("scan-#{unique}")
    assert scan_activity.class_uid == 6007
    assert scan_activity.category_uid == 6
    assert scan_activity.activity_name == "Completed"
    assert scan_activity.status == "Success"
    assert scan_activity.metadata["service_radar"]["source_type"] == "endpoint_inventory"
    assert scan_activity.metadata["service_radar"]["agent_id"] == agent_id
    assert scan_activity.metadata["service_radar"]["device_uid"] == device.uid
    assert [package] = current_packages(agent_id)
    assert package.name == "nginx"
    assert package.package_manager == "dpkg"
    assert package.purl == "pkg:deb/nginx@1.24.0-2ubuntu7"
    assert package.purl_canonical == "pkg:deb/debian/nginx@1.24.0-2ubuntu7?arch=amd64"
    assert package.endpoint_package_ref
    assert package.device_uid == device.uid
    assert is_integer(EndpointInventoryFleetOrdinal.ordinal_for(device.uid))

    assert endpoint_package(package.endpoint_package_ref).coordinate_key ==
             "purl:#{package.purl_canonical}"

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

    # An empty/SBOM-less scan must NOT wipe a non-empty current inventory. It is
    # promoted as the current scan but preserves and re-stamps the prior rows.
    assert {:ok, empty_success} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-empty-#{unique}", components: []),
               actor: actor,
               upload_object: successful_upload()
             )

    assert empty_success.current? == true
    assert empty_success.package_rows_replaced? == false
    assert empty_success.package_count == 1
    empty_scan = current_scan(agent_id)
    assert empty_scan.scan_id == "scan-empty-#{unique}"
    assert empty_scan.package_count == 1
    assert [%{name: "nginx", scan_ref: nginx_scan_ref}] = current_packages(agent_id)
    assert nginx_scan_ref == empty_scan.id
  end

  test "nulls non-canonical endpoint inventory device uid payloads", %{actor: actor} do
    unique = System.unique_integer([:positive])
    agent_id = "endpoint-inventory-noncanonical-agent-#{unique}"

    payload =
      agent_id
      |> scan_payload("scan-noncanonical-#{unique}")
      |> Map.put("device_uid", "endpoint-inventory-device-#{unique}")

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.device_uid == nil
    assert current_scan(agent_id).device_uid == nil
    assert [%{device_uid: nil}] = current_packages(agent_id)
    assert artifact_device_uids(result.scan_ref) == [nil]
  end

  test "preserves scanner-style diagnostics through endpoint inventory ingest", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-diagnostics-device-#{unique}")
    agent_id = "endpoint-inventory-diagnostics-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    payload =
      agent_id
      |> scan_payload("scan-diagnostics-#{unique}")
      |> Map.merge(%{
        "collector_name" => "generic-endpoint-scanner",
        "config_hash" => String.duplicate("a", 64),
        "duration_ms" => 128,
        "truncated" => true,
        "enabled_plugins" => ["os-packages", "language-packages"],
        "detected_plugins" => ["os-packages"],
        "diagnostics" => [
          %{
            "name" => "os-packages",
            "type" => "extractor",
            "state" => "partial",
            "detected" => true,
            "package_count" => 1,
            "finding_count" => 0,
            "reason" => "output_truncated",
            "duration_ms" => 127,
            "truncated" => true,
            "metadata" => %{"scope" => "host"}
          },
          %{
            "name" => "language-packages",
            "type" => "extractor",
            "state" => "unavailable",
            "detected" => false,
            "package_count" => 0,
            "reason" => "not_found"
          }
        ]
      })

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.current? == true

    scan = current_scan(agent_id)
    assert scan.enabled_sources == ["os-packages", "language-packages"]

    assert scan.source_summaries == [
             %{
               "name" => "os-packages",
               "type" => "extractor",
               "state" => "partial",
               "detected" => true,
               "package_count" => 1,
               "finding_count" => 0,
               "reason" => "output_truncated",
               "duration_ms" => 127,
               "truncated" => true,
               "metadata" => %{"scope" => "host"}
             },
             %{
               "name" => "language-packages",
               "type" => "extractor",
               "state" => "unavailable",
               "detected" => false,
               "package_count" => 0,
               "reason" => "not_found"
             }
           ]

    assert scan.metadata["config_hash"] == String.duplicate("a", 64)
    assert scan.metadata["duration_ms"] == 128
    assert scan.metadata["truncated"] == true
    assert scan.metadata["enabled_plugins"] == ["os-packages", "language-packages"]
    assert scan.metadata["detected_plugins"] == ["os-packages"]
  end

  test "does not infer scan coverage from legacy source summaries", %{actor: actor} do
    unique = System.unique_integer([:positive])
    agent_id = "endpoint-inventory-legacy-source-agent-#{unique}"

    payload =
      agent_id
      |> scan_payload("scan-legacy-source-#{unique}")
      |> Map.delete("coverage_state")
      |> Map.delete("diagnostics")
      |> Map.delete("enabled_plugins")
      |> Map.delete("detected_plugins")
      |> Map.put("sources", [
        %{"source" => "dpkg", "state" => "scanned", "package_count" => 1}
      ])

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.current? == false
    scan = scan_by_id(agent_id, "scan-legacy-source-#{unique}")
    assert scan.coverage_state == "unknown"
    assert scan.source_summaries == []
    assert scan.enabled_sources == []
  end

  test "normalizes scanner diagnostic aliases without legacy source fallback", %{actor: actor} do
    unique = System.unique_integer([:positive])
    agent_id = "endpoint-inventory-diagnostic-alias-agent-#{unique}"

    payload =
      agent_id
      |> scan_payload("scan-diagnostic-alias-#{unique}")
      |> Map.delete("coverage_state")
      |> Map.delete("enabled_plugins")
      |> Map.delete("detected_plugins")
      |> Map.put("sources", [
        %{"source" => "legacy-dpkg", "state" => "scanned", "package_count" => 99}
      ])
      |> Map.put("diagnostics", [
        %{
          "plugin_id" => "os-packages",
          "kind" => "extractor",
          "status" => "succeeded",
          "count" => 1,
          "findings_count" => 2,
          "reason_code" => "matched",
          "scan_root" => "/",
          "elapsed_ms" => 42,
          "supported" => true,
          "metadata" => %{"scanner_family" => "endpoint_inventory"}
        },
        %{
          "id" => "language-packages",
          "category" => "extractor",
          "status" => "failure",
          "packages" => 0,
          "message" => "permission denied",
          "partial" => true,
          "applicable" => false
        }
      ])

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.current? == false
    scan = scan_by_id(agent_id, "scan-diagnostic-alias-#{unique}")
    assert scan.coverage_state == "partial"
    assert scan.enabled_sources == ["os-packages", "language-packages"]

    assert scan.source_summaries == [
             %{
               "name" => "os-packages",
               "type" => "extractor",
               "state" => "success",
               "detected" => true,
               "package_count" => 1,
               "finding_count" => 2,
               "reason" => "matched",
               "path" => "/",
               "duration_ms" => 42,
               "metadata" => %{"scanner_family" => "endpoint_inventory"}
             },
             %{
               "name" => "language-packages",
               "type" => "extractor",
               "state" => "failed",
               "detected" => false,
               "package_count" => 0,
               "error" => "permission denied",
               "truncated" => true
             }
           ]
  end

  test "infers complete coverage for zero packages only from complete diagnostics", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    agent_id = "endpoint-inventory-empty-complete-agent-#{unique}"

    payload =
      agent_id
      |> scan_payload("scan-empty-complete-#{unique}", components: [])
      |> Map.delete("coverage_state")

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.current? == true
    scan = current_scan(agent_id)
    assert scan.package_count == 0
    assert scan.coverage_state == "complete"

    assert [%{"name" => "dpkg", "state" => "scanned", "package_count" => 0}] =
             scan.source_summaries
  end

  test "marks diagnostic-less generic scans as unknown coverage", %{actor: actor} do
    unique = System.unique_integer([:positive])
    agent_id = "endpoint-inventory-no-diagnostics-agent-#{unique}"

    payload =
      agent_id
      |> scan_payload("scan-no-diagnostics-#{unique}")
      |> Map.delete("coverage_state")
      |> Map.delete("diagnostics")
      |> Map.delete("enabled_plugins")
      |> Map.delete("detected_plugins")

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.current? == false
    scan = scan_by_id(agent_id, "scan-no-diagnostics-#{unique}")
    assert scan.coverage_state == "unknown"
    assert scan.source_summaries == []
    assert scan.enabled_sources == []
  end

  test "infers failed coverage from generic diagnostic failures", %{actor: actor} do
    unique = System.unique_integer([:positive])
    agent_id = "endpoint-inventory-diagnostic-failed-agent-#{unique}"

    payload =
      agent_id
      |> scan_payload("scan-diagnostic-failed-#{unique}", components: [])
      |> Map.delete("coverage_state")
      |> Map.put("diagnostics", [
        %{
          "name" => "dpkg",
          "type" => "package_source",
          "state" => "error",
          "detected" => true,
          "package_count" => 0,
          "reason" => "permission_denied",
          "error" => "permission denied"
        }
      ])

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.current? == false
    scan = scan_by_id(agent_id, "scan-diagnostic-failed-#{unique}")
    assert scan.package_count == 0
    assert scan.coverage_state == "failed"
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

  test "derives endpoint-side CPE match input and host-scoped fallback tuple", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-coordinate-device-#{unique}")
    agent_id = "endpoint-inventory-coordinate-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    payload =
      agent_id
      |> scan_payload("scan-coordinate-#{unique}", components: [])
      |> Map.put("packages", [
        %{
          "name" => "libssl3",
          "version" => "3.0.13-0ubuntu3",
          "architecture" => "amd64",
          "package_manager" => "dpkg",
          "ecosystem" => "deb",
          "purl" => "pkg:deb/libssl3@3.0.13-0ubuntu3"
        }
      ])

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.package_count == 1
    assert [package] = current_packages(agent_id)

    assert package.cpes == [
             "cpe:2.3:a:openssl:openssl:3.0.13-0ubuntu3:*:*:*:*:*:*:*"
           ]

    normalized_package = endpoint_package(package.endpoint_package_ref)

    assert normalized_package.source_scope == "host"

    assert normalized_package.primary_cpe ==
             "cpe:2.3:a:openssl:openssl:3.0.13-0ubuntu3:*:*:*:*:*:*:*"

    assert normalized_package.cpes == package.cpes

    assert normalized_package.metadata["match_input"] == %{
             "scope" => "host",
             "canonical_purl" => package.purl_canonical,
             "candidate_cpes" => package.cpes,
             "fallback_tuple" => %{
               "package_manager" => "dpkg",
               "name" => "libssl3",
               "version" => "3.0.13-0ubuntu3",
               "architecture" => "amd64"
             }
           }
  end

  test "upserts endpoint vulnerability risk contribution from vuln-match payload", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-risk-device-#{unique}")

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_vulnerability_match(
               %{
                 "event_id" => "inventory-vuln-#{unique}",
                 "agent_id" => "endpoint-inventory-risk-agent-#{unique}",
                 "scan_id" => "scan-risk-#{unique}",
                 "device_uid" => device.uid,
                 "cve" => "CVE-2026-#{unique}",
                 "status" => "active",
                 "assessment" => "confirmed",
                 "disposition" => "affected",
                 "freshness" => "fresh",
                 "cvss_score" => 9.8,
                 "observed_at" => "2026-06-02T12:00:00Z",
                 "package_set_hash" => "package-set-risk-#{unique}",
                 "advisory" => %{
                   "kev_count" => 1,
                   "has_unpatched_rce" => true
                 },
                 "package" => %{
                   "name" => "nginx",
                   "version" => "1.24.0-2ubuntu7",
                   "purl_canonical" => "pkg:deb/debian/nginx@1.24.0-2ubuntu7?arch=amd64"
                 }
               },
               age_risk_summary_projector: test_age_risk_summary_projector(self())
             )

    assert result == %{
             active?: true,
             device_uid: device.uid,
             risk_contribution_upserted?: true,
             score: 98,
             source: "endpoint_inventory",
             source_ref: device.uid
           }

    assert contribution = endpoint_inventory_risk_contribution(device.uid)
    assert contribution.active == true
    assert contribution.score == 98
    assert contribution.risk_level == "Critical"
    assert contribution.metadata["cve"] == "CVE-2026-#{unique}"
    assert contribution.metadata["package"]["name"] == "nginx"

    assert device_risk(device.uid) == %{risk_score: 98, risk_level_id: 4, risk_level: "Critical"}

    device_uid = device.uid

    assert_receive {:age_risk_summary, ^device_uid,
                    %{
                      pkg_worst_severity: "critical",
                      pkg_critical_count: 1,
                      pkg_kev_count: 1,
                      pkg_has_unpatched_rce: true,
                      pkg_risk_summary_at: "2026-06-02T12:00:00Z"
                    }}
  end

  test "resolved endpoint vuln-match deactivates risk contribution and recomputes device risk", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-risk-resolved-device-#{unique}")

    :ok =
      DeviceRiskReducer.upsert_contribution(%{
        device_uid: device.uid,
        source: "endpoint_inventory",
        source_ref: device.uid,
        score: 82,
        reason: "initial endpoint vulnerability",
        metadata: %{"test" => "risk-resolved-#{unique}"}
      })

    assert device_risk(device.uid).risk_score == 82

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_vulnerability_match(
               %{
                 "device_uid" => device.uid,
                 "status" => "resolved",
                 "assessment" => "confirmed",
                 "disposition" => "fixed",
                 "freshness" => "fresh",
                 "cvss_score" => 0,
                 "observed_at" => "2026-06-02T13:00:00Z",
                 "package" => %{"name" => "nginx"}
               },
               age_risk_summary_projector: test_age_risk_summary_projector(self())
             )

    assert result.active? == false
    assert result.score == 0

    assert contribution = endpoint_inventory_risk_contribution(device.uid)
    assert contribution.active == false
    assert contribution.resolved_at

    assert device_risk(device.uid) == %{risk_score: nil, risk_level_id: nil, risk_level: nil}

    device_uid = device.uid

    assert_receive {:age_risk_summary, ^device_uid,
                    %{
                      pkg_worst_severity: "none",
                      pkg_critical_count: 0,
                      pkg_kev_count: 0,
                      pkg_has_unpatched_rce: false,
                      pkg_risk_summary_at: "2026-06-02T13:00:00Z"
                    }}
  end

  test "same-hash completed full scan advances freshness without replacing packages", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-unchanged-device-#{unique}")
    agent_id = "endpoint-inventory-unchanged-agent-#{unique}"
    artifact_hash = unique |> Integer.to_string(16) |> String.pad_leading(64, "0")
    create_agent!(actor, agent_id, device.uid)

    assert {:ok, first} =
             agent_id
             |> scan_payload("scan-full-#{unique}")
             |> Map.put("artifact_hash", artifact_hash)
             |> EndpointInventoryIngestor.ingest_report(
               actor: actor,
               upload_object: successful_upload()
             )

    first_scan = current_scan(agent_id)
    assert first_scan.package_set_hash
    assert first.package_count == 1
    assert package_row_count(agent_id) == 1
    assert [%{scan_ref: package_scan_ref}] = current_packages(agent_id)
    freshness_at = NaiveDateTime.add(first_scan.last_scan_at, 1, :hour)
    test_pid = self()

    unchanged_payload =
      agent_id
      |> scan_payload("scan-unchanged-#{unique}", components: [])
      |> Map.delete("sbom")
      |> Map.merge(%{
        "state" => "unchanged",
        "coverage_state" => "complete",
        "package_count" => first_scan.package_count,
        "package_set_hash" => first_scan.package_set_hash,
        "artifact_hash" => artifact_hash,
        "hash_algorithm" => "sha256-v1",
        "upload_reason" => "unchanged",
        "last_scan_at" => freshness_at,
        "last_successful_scan_at" => freshness_at,
        "metadata" => %{"reason" => "full_scan_hash_unchanged"}
      })

    upload_object = fn _metadata, _data, _opts ->
      send(test_pid, :unexpected_unchanged_upload)
      {:ok, %{ok?: true}}
    end

    assert {:ok, unchanged} =
             EndpointInventoryIngestor.ingest_report(unchanged_payload,
               actor: actor,
               upload_object: upload_object
             )

    assert unchanged.scan_ref == first.scan_ref
    assert unchanged.current? == true
    assert unchanged.package_rows_replaced? == false
    assert unchanged.artifact_uploaded? == false
    assert unchanged.package_set_hash_mismatch? == false
    assert unchanged.reconcile_floor? == false
    assert unchanged.package_count == 1
    assert package_row_count(agent_id) == 1

    current = current_scan(agent_id)
    assert current.id == first_scan.id
    assert current.scan_id == first_scan.scan_id
    assert NaiveDateTime.compare(current.last_scan_at, freshness_at) == :eq
    assert current.package_set_hash == first_scan.package_set_hash
    assert current.artifact_hash == artifact_hash
    assert current.unchanged_scan_count == 1
    assert current.last_changed_scan_at == first_scan.last_changed_scan_at
    assert current.reconcile_floor_due == false
    assert current.metadata["test_scan_id"] == first_scan.metadata["test_scan_id"]

    assert current.metadata["latest_freshness_observation"]["scan_id"] ==
             "scan-unchanged-#{unique}"

    assert scan_row_count(agent_id) == 1
    assert endpoint_inventory_scan_activity("scan-unchanged-#{unique}")
    assert artifact_count(first.scan_ref) == 1

    assert [%{name: "nginx", scan_ref: scan_ref}] = current_packages(agent_id)
    assert scan_ref == package_scan_ref

    duplicate_payload =
      Map.put(unchanged_payload, "scan_id", "scan-unchanged-duplicate-#{unique}")

    assert {:ok, duplicate} =
             EndpointInventoryIngestor.ingest_report(duplicate_payload,
               actor: actor,
               upload_object: upload_object
             )

    assert duplicate.scan_id == first_scan.scan_id
    assert current_scan(agent_id).unchanged_scan_count == 1

    delayed_payload =
      unchanged_payload
      |> Map.put("scan_id", "scan-unchanged-delayed-#{unique}")
      |> Map.put("last_scan_at", NaiveDateTime.add(first_scan.last_scan_at, 30, :minute))
      |> Map.put(
        "last_successful_scan_at",
        NaiveDateTime.add(first_scan.last_scan_at, 30, :minute)
      )

    assert {:ok, delayed} =
             EndpointInventoryIngestor.ingest_report(delayed_payload,
               actor: actor,
               upload_object: upload_object
             )

    assert delayed.scan_id == first_scan.scan_id
    after_delayed = current_scan(agent_id)
    assert after_delayed.unchanged_scan_count == 1
    assert NaiveDateTime.compare(after_delayed.last_scan_at, freshness_at) == :eq

    Repo.delete_all(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id and s.current == false
      ),
      prefix: "platform"
    )

    assert [%{name: "nginx", scan_ref: scan_ref_after_retention}] = current_packages(agent_id)
    assert scan_ref_after_retention == first_scan.id
    refute_receive :unexpected_unchanged_upload, 100
  end

  test "scanned partial payload cannot replace the current inventory graph", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-partial-device-#{unique}")
    agent_id = "endpoint-inventory-partial-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    assert {:ok, first} =
             agent_id
             |> scan_payload("scan-partial-anchor-#{unique}")
             |> Map.put("artifact_hash", String.duplicate("a", 64))
             |> EndpointInventoryIngestor.ingest_report(
               actor: actor,
               upload_object: successful_upload()
             )

    anchor = current_scan(agent_id)
    anchor_packages = current_packages(agent_id)

    partial_payload =
      agent_id
      |> scan_payload("scan-partial-#{unique}",
        components: [package_component("partial-only", "9.9.9")]
      )
      |> Map.merge(%{
        "state" => "scanned",
        "coverage_state" => "partial",
        "artifact_hash" => String.duplicate("b", 64)
      })

    assert {:ok, partial} =
             EndpointInventoryIngestor.ingest_report(partial_payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert partial.current? == false
    assert partial.scan_ref != first.scan_ref

    current = current_scan(agent_id)
    assert current.id == anchor.id
    assert current.scan_id == anchor.scan_id
    assert current.artifact_hash == anchor.artifact_hash
    assert current.artifact_count == anchor.artifact_count
    assert current.manager_counts == anchor.manager_counts
    assert current_packages(agent_id) == anchor_packages
    assert artifact_count(anchor.id) == 1

    assert %{status: "Failure"} = endpoint_inventory_scan_activity("scan-partial-#{unique}")

    inferred_partial_payload =
      partial_payload
      |> Map.put("scan_id", "scan-partial-inferred-#{unique}")
      |> Map.delete("coverage_state")
      |> Map.put("diagnostics", [
        %{
          "name" => "os/dpkg",
          "state" => "partial",
          "detected" => true,
          "package_count" => 1,
          "error" => "one path was unreadable"
        }
      ])

    assert {:ok, inferred_partial} =
             EndpointInventoryIngestor.ingest_report(inferred_partial_payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert inferred_partial.current? == false
    assert current_scan(agent_id).id == anchor.id
    assert current_packages(agent_id) == anchor_packages
  end

  test "duplicate scan id short-circuits before upload and transaction work", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-duplicate-device-#{unique}")
    agent_id = "endpoint-inventory-duplicate-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    payload = scan_payload(agent_id, "scan-duplicate-#{unique}")

    assert {:ok, first} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert scan_row_count(agent_id) == 1
    test_pid = self()

    upload_object = fn _metadata, _data, _opts ->
      send(test_pid, :unexpected_duplicate_upload)
      {:ok, %{ok?: true}}
    end

    assert {:ok, duplicate} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: upload_object
             )

    assert duplicate.scan_ref == first.scan_ref
    assert duplicate.package_rows_replaced? == false
    assert duplicate.scan_history_recorded? == false
    assert duplicate.package_event_count == 0
    assert scan_row_count(agent_id) == 1
    refute_receive :unexpected_duplicate_upload, 100
  end

  test "already-acknowledged unchanged uploads short-circuit against current hash", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-acked-device-#{unique}")
    agent_id = "endpoint-inventory-acked-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    assert {:ok, first} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-acked-full-#{unique}"),
               actor: actor,
               upload_object: successful_upload()
             )

    first_scan = current_scan(agent_id)
    assert scan_row_count(agent_id) == 1
    test_pid = self()

    acknowledged_payload =
      agent_id
      |> scan_payload("scan-acked-unchanged-#{unique}", components: [])
      |> Map.delete("sbom")
      |> Map.merge(%{
        "state" => "unchanged",
        "coverage_state" => "complete",
        "package_count" => first_scan.package_count,
        "package_set_hash" => first_scan.package_set_hash,
        "upload_reason" => "unchanged",
        "metadata" => %{"reason" => "upload_already_acknowledged"}
      })

    upload_object = fn _metadata, _data, _opts ->
      send(test_pid, :unexpected_acknowledged_upload)
      {:ok, %{ok?: true}}
    end

    assert {:ok, acknowledged} =
             EndpointInventoryIngestor.ingest_report(acknowledged_payload,
               actor: actor,
               upload_object: upload_object
             )

    assert acknowledged.scan_ref == first.scan_ref
    assert acknowledged.current? == true
    assert acknowledged.package_rows_replaced? == false
    assert acknowledged.scan_history_recorded? == false
    assert acknowledged.package_event_count == 0
    assert acknowledged.package_change_signal_publish_count == 0
    assert scan_row_count(agent_id) == 1
    assert current_scan(agent_id).unchanged_scan_count == 0
    refute_receive :unexpected_acknowledged_upload, 100
  end

  test "repeated empty not-scanned reports short-circuit after first status row", %{actor: actor} do
    unique = System.unique_integer([:positive])
    agent_id = "endpoint-inventory-not-scanned-agent-#{unique}"

    first_payload =
      agent_id
      |> scan_payload("scan-not-scanned-first-#{unique}", components: [])
      |> Map.delete("sbom")
      |> Map.merge(%{
        "state" => "not_scanned",
        "coverage_state" => "not_scanned",
        "package_count" => 0,
        "upload_reason" => "unchanged"
      })

    assert {:ok, first} =
             EndpointInventoryIngestor.ingest_report(first_payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert first.current? == false
    assert scan_row_count(agent_id) == 1

    second_payload = Map.put(first_payload, "scan_id", "scan-not-scanned-second-#{unique}")

    assert {:ok, second} =
             EndpointInventoryIngestor.ingest_report(second_payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert second.current? == false
    assert second.package_rows_replaced? == false
    assert second.scan_history_recorded? == false
    assert second.package_event_count == 0
    assert scan_row_count(agent_id) == 1
  end

  test "SBOM-less unchanged upload without a matching prior hash preserves current packages",
       %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-degraded-device-#{unique}")
    agent_id = "endpoint-inventory-degraded-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    assert {:ok, first} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-full-#{unique}",
                 components: [
                   package_component("nginx", "1.24.0-2ubuntu7"),
                   package_component("curl", "8.5.0-2ubuntu1")
                 ]
               ),
               actor: actor,
               upload_object: successful_upload()
             )

    assert first.package_count == 2
    assert package_row_count(agent_id) == 2
    anchor = current_scan(agent_id)

    # An `unchanged` upload that carries NO SBOM/packages and whose hash does not
    # match the stored current scan (hash drift) must NOT fall through to a 0-row
    # wipe, and must NOT stamp a package_count it cannot back.
    degraded_payload =
      agent_id
      |> scan_payload("scan-degraded-#{unique}", components: [])
      |> Map.delete("sbom")
      |> Map.merge(%{
        "state" => "unchanged",
        "coverage_state" => "complete",
        "package_count" => 487,
        "package_set_hash" => "deadbeef-drifted-hash",
        "upload_reason" => "unchanged"
      })

    assert {:ok, degraded} =
             EndpointInventoryIngestor.ingest_report(degraded_payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert degraded.current? == true
    assert degraded.package_rows_replaced? == false
    assert degraded.reconcile_floor? == true
    assert degraded.directives["endpoint_inventory"]["reconcile_floor"] == true
    # package_count is reconciled to the actually-loaded current rows, not 487.
    assert degraded.package_count == 2

    degraded_scan = current_scan(agent_id)
    assert degraded_scan.id == anchor.id
    assert degraded_scan.scan_id == anchor.scan_id
    assert degraded_scan.package_count == 2
    assert degraded_scan.artifact_hash == anchor.artifact_hash
    assert degraded_scan.metadata == anchor.metadata
    assert scan_row_count(agent_id) == 1

    assert names = agent_id |> current_packages() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["curl", "nginx"]
    assert package_row_count(agent_id) == 2
  end

  test "failed empty upload does not wipe a prior full current inventory", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-partial-device-#{unique}")
    agent_id = "endpoint-inventory-partial-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    assert {:ok, first} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-full-#{unique}",
                 components: [
                   package_component("nginx", "1.24.0-2ubuntu7"),
                   package_component("curl", "8.5.0-2ubuntu1")
                 ]
               ),
               actor: actor,
               upload_object: successful_upload()
             )

    assert first.current? == true
    assert package_row_count(agent_id) == 2

    # A failed/partial scan that carries no packages must leave the prior current
    # inventory intact (current scan unchanged, rows preserved).
    failed_payload =
      agent_id
      |> scan_payload("scan-partial-#{unique}", components: [])
      |> Map.delete("sbom")
      |> Map.merge(%{
        "state" => "scan_failed",
        "coverage_state" => "failed",
        "package_count" => 0,
        "upload_reason" => "changed"
      })

    assert {:ok, failed} =
             EndpointInventoryIngestor.ingest_report(failed_payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert failed.current? == false
    assert failed.package_rows_replaced? == false

    current = current_scan(agent_id)
    assert current.scan_id == "scan-full-#{unique}"
    names = agent_id |> current_packages() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["curl", "nginx"]
    assert package_row_count(agent_id) == 2
  end

  test "changed scan reconciles package_count to actual loaded rows when reported count lies",
       %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-count-device-#{unique}")
    agent_id = "endpoint-inventory-count-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    # Reported package_count (487) intentionally diverges from the two SBOM
    # components that actually explode into current rows.
    payload =
      agent_id
      |> scan_payload("scan-count-#{unique}",
        components: [
          package_component("nginx", "1.24.0-2ubuntu7"),
          package_component("curl", "8.5.0-2ubuntu1")
        ]
      )
      |> Map.put("package_count", 487)

    assert {:ok, result} =
             EndpointInventoryIngestor.ingest_report(payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert result.current? == true
    assert result.package_count == 2

    scan = current_scan(agent_id)
    assert scan.package_count == 2
    assert scan.metadata["reported_package_count"] == 487
    assert scan.metadata["loaded_package_count"] == 2
    assert package_row_count(agent_id) == 2
  end

  test "emits endpoint inventory cost and volume telemetry", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-inventory-telemetry-device-#{unique}")
    agent_id = "endpoint-inventory-telemetry-agent-#{unique}"
    handler_id = "endpoint-inventory-telemetry-#{unique}"
    test_pid = self()
    ingest_event = EndpointInventoryTelemetry.ingest_event()
    storage_event = EndpointInventoryTelemetry.storage_event()
    table_event = EndpointInventoryTelemetry.table_event()

    create_agent!(actor, agent_id, device.uid)
    attach_endpoint_inventory_telemetry(handler_id, test_pid)

    assert {:ok, first} =
             EndpointInventoryIngestor.ingest_report(
               scan_payload(agent_id, "scan-telemetry-full-#{unique}"),
               actor: actor,
               upload_object: successful_upload()
             )

    assert_receive {:endpoint_inventory_telemetry, event,
                    %{
                      count: 1,
                      changed_upload_count: 1,
                      unchanged_upload_count: 0,
                      package_rows_replaced_count: 1,
                      artifact_uploaded_count: 1
                    }, %{agent_id: ^agent_id, upload_reason: "changed"}}
                   when event == ingest_event

    first_scan = current_scan(agent_id)

    unchanged_payload =
      agent_id
      |> scan_payload("scan-telemetry-unchanged-#{unique}", components: [])
      |> Map.delete("sbom")
      |> Map.merge(%{
        "state" => "unchanged",
        "coverage_state" => "complete",
        "package_count" => first.package_count,
        "package_set_hash" => first_scan.package_set_hash,
        "hash_algorithm" => "sha256-v1",
        "upload_reason" => "unchanged"
      })

    assert {:ok, _unchanged} =
             EndpointInventoryIngestor.ingest_report(unchanged_payload,
               actor: actor,
               upload_object: successful_upload()
             )

    assert_receive {:endpoint_inventory_telemetry, event,
                    %{
                      count: 1,
                      changed_upload_count: 0,
                      unchanged_upload_count: 1,
                      package_rows_replaced_count: 0
                    }, %{agent_id: ^agent_id, upload_reason: "unchanged"}}
                   when event == ingest_event

    assert :ok = EndpointInventoryTelemetry.measure_cost_volume()

    assert_receive {:endpoint_inventory_telemetry, event, storage, %{}}
                   when event == storage_event

    assert storage.artifact_object_bytes > 0
    assert storage.current_package_row_count >= 1
    assert storage.recent_changed_scan_count >= 1
    assert storage.recent_unchanged_scan_count >= 0
    assert storage.recent_changed_ratio > 0.0
    assert storage.recent_unchanged_ratio >= 0.0

    assert_receive {:endpoint_inventory_telemetry, event,
                    %{
                      live_rows: live_rows,
                      dead_rows: dead_rows,
                      autovacuum_lag_seconds: autovacuum_lag_seconds,
                      compression_lag_seconds: compression_lag_seconds
                    }, %{table: "endpoint_inventory_packages", table_kind: :current}}
                   when event == table_event and live_rows >= 0 and
                          dead_rows >= 0 and autovacuum_lag_seconds >= 0 and
                          compression_lag_seconds >= 0
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
    causal_signal_publisher = capture_causal_signals(self())

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
               upload_object: successful_upload(),
               causal_signal_publisher: causal_signal_publisher
             )

    assert first.scan_history_recorded? == true
    assert first.package_event_count == 2
    assert first.package_change_signal_publish_count == 2
    assert scan_history_count(agent_id) == 1

    assert [
             %{event_type: "added", name: ^nginx, new_version: "1.24.0-2ubuntu7"},
             %{event_type: "added", name: ^openssl, new_version: "3.0.13-0ubuntu3"}
           ] = package_event_rows(agent_id, "scan-history-first-#{unique}")

    first_scan = current_scan(agent_id)
    first_signals = collect_causal_signals(2)

    assert Enum.map(first_signals, & &1.subject) == [
             "signals.analytics.inventory.added",
             "signals.analytics.inventory.added"
           ]

    assert Enum.all?(first_signals, fn signal ->
             signal.payload["schema_version"] ==
               "serviceradar.endpoint_inventory.package_change.v1" and
               signal.payload["signal_type"] == "inventory" and
               signal.payload["signal_domain"] == "inventory" and
               signal.payload["event_type"] == "added" and
               signal.payload["agent_id"] == agent_id and
               signal.payload["device_uid"] == device.uid and
               signal.payload["device_id"] == device.uid and
               signal.payload["package_set_hash"] == first_scan.package_set_hash and
               String.starts_with?(signal.payload["event_id"], "inventory:#{agent_id}:")
           end)

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
               upload_object: successful_upload(),
               causal_signal_publisher: causal_signal_publisher
             )

    assert second.scan_history_recorded? == true
    assert second.package_event_count == 3
    assert second.package_change_signal_publish_count == 3
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

    second_signals = collect_causal_signals(3)

    assert Enum.map(second_signals, & &1.subject) == [
             "signals.analytics.inventory.added",
             "signals.analytics.inventory.removed",
             "signals.analytics.inventory.version_changed"
           ]

    assert version_changed_signal =
             Enum.find(second_signals, &(&1.payload["event_type"] == "version_changed"))

    assert version_changed_signal.payload["package"]["name"] == nginx
    assert version_changed_signal.payload["package"]["previous_version"] == "1.24.0-2ubuntu7"
    assert version_changed_signal.payload["package"]["new_version"] == "1.24.1-2ubuntu7"
    assert version_changed_signal.payload["previous_package"]["version"] == "1.24.0-2ubuntu7"

    assert version_changed_signal.payload["package"]["cpes"] == [
             package_cpe(nginx, "1.24.1-2ubuntu7")
           ]

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
               upload_object: successful_upload(),
               causal_signal_publisher: causal_signal_publisher
             )

    assert unchanged.scan_history_recorded? == false
    assert unchanged.package_event_count == 0
    assert unchanged.package_change_signal_publish_count == 0
    assert scan_history_count(agent_id) == 2
    assert package_event_count(agent_id) == package_event_total
    refute_receive {:causal_signal_published, _subject, _payload}, 200

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
        "coverage_state" => "unchanged",
        "package_count" => first_scan.package_count,
        "package_set_hash" => first_scan.package_set_hash,
        "artifact_hash" => first_scan.artifact_hash,
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
    assert scan.id == first_scan.id
    assert scan.scan_id == first_scan.scan_id
    assert scan.reconcile_floor_due == true
    assert scan.unchanged_scan_count == 1
    assert scan.artifact_hash == first_scan.artifact_hash
    assert scan_row_count(agent_id) == 1
    assert artifact_count(first_scan.id) == 1
    assert Enum.all?(current_packages(agent_id), &(&1.scan_ref == first_scan.id))
  end

  @tag sandbox: :unboxed
  test "concurrent freshness observations cross the reconcile floor atomically", %{actor: actor} do
    unique = System.unique_integer([:positive])
    agent_id = "endpoint-inventory-concurrent-floor-agent-#{unique}"
    artifact_hash = unique |> Integer.to_string(16) |> String.pad_leading(64, "c")
    on_exit(fn -> cleanup_unboxed_inventory(agent_id, artifact_hash) end)

    assert {:ok, _first} =
             agent_id
             |> scan_payload("scan-concurrent-floor-anchor-#{unique}")
             |> Map.put("artifact_hash", artifact_hash)
             |> EndpointInventoryIngestor.ingest_report(
               actor: actor,
               upload_object: successful_upload()
             )

    anchor = current_scan(agent_id)

    {1, _} =
      Repo.update_all(
        from(s in "endpoint_inventory_scans", where: s.id == ^anchor.id),
        [set: [unchanged_scan_count: 22, reconcile_floor_due: false]],
        prefix: "platform"
      )

    parent = self()

    hook = fn context ->
      send(parent, {:freshness_ready, context.scan_id, self()})

      receive do
        {:release_freshness, scan_id} when scan_id == context.scan_id -> :ok
      after
        5_000 -> raise "timed out waiting to release freshness observation"
      end
    end

    payload = fn scan_id, seconds ->
      agent_id
      |> scan_payload(scan_id, components: [])
      |> Map.delete("sbom")
      |> Map.merge(%{
        "state" => "unchanged",
        "coverage_state" => "complete",
        "package_count" => anchor.package_count,
        "package_set_hash" => anchor.package_set_hash,
        "artifact_hash" => anchor.artifact_hash,
        "hash_algorithm" => "sha256-v1",
        "upload_reason" => "unchanged",
        "last_scan_at" => NaiveDateTime.add(anchor.last_scan_at, seconds, :second),
        "last_successful_scan_at" => NaiveDateTime.add(anchor.last_scan_at, seconds, :second),
        "metadata" => %{"reason" => "full_scan_hash_unchanged"}
      })
    end

    older_id = "scan-concurrent-floor-older-#{unique}"
    newer_id = "scan-concurrent-floor-newer-#{unique}"

    older_task =
      Task.async(fn ->
        EndpointInventoryIngestor.ingest_report(payload.(older_id, 1),
          actor: actor,
          upload_object: successful_upload(),
          reconcile_floor_scan_count: 24,
          reconcile_floor_max_age_days: 0,
          before_hash_freshness_touch: hook
        )
      end)

    newer_task =
      Task.async(fn ->
        EndpointInventoryIngestor.ingest_report(payload.(newer_id, 2),
          actor: actor,
          upload_object: successful_upload(),
          reconcile_floor_scan_count: 24,
          reconcile_floor_max_age_days: 0,
          before_hash_freshness_touch: hook
        )
      end)

    assert_receive {:freshness_ready, ^older_id, older_pid}, 5_000
    assert_receive {:freshness_ready, ^newer_id, newer_pid}, 5_000

    send(older_pid, {:release_freshness, older_id})
    assert {:ok, older_result} = Task.await(older_task, 5_000)
    assert older_result.reconcile_floor? == false

    send(newer_pid, {:release_freshness, newer_id})
    assert {:ok, newer_result} = Task.await(newer_task, 5_000)
    assert newer_result.reconcile_floor? == true
    assert newer_result.directives["endpoint_inventory"]["reconcile_floor"] == true
    assert newer_result.scan_id == anchor.scan_id

    current = current_scan(agent_id)
    assert current.id == anchor.id
    assert current.scan_id == anchor.scan_id
    assert current.unchanged_scan_count == 24
    assert current.reconcile_floor_due == true
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
      "enabled_plugins" => ["dpkg"],
      "detected_plugins" => ["dpkg"],
      "diagnostics" => [
        %{
          "name" => "dpkg",
          "type" => "package_source",
          "state" => "scanned",
          "package_count" => length(components),
          "detected" => true
        }
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

  defp attach_endpoint_inventory_telemetry(handler_id, test_pid) do
    :telemetry.attach_many(
      handler_id,
      [
        EndpointInventoryTelemetry.ingest_event(),
        EndpointInventoryTelemetry.storage_event(),
        EndpointInventoryTelemetry.table_event()
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:endpoint_inventory_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> _ = :telemetry.detach(handler_id) end)
  end

  defp current_scan(agent_id) do
    Repo.one!(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id and s.current == true,
        select: %{
          id: s.id,
          device_uid: s.device_uid,
          scan_id: s.scan_id,
          state: s.state,
          coverage_state: s.coverage_state,
          enabled_sources: s.enabled_sources,
          source_summaries: s.source_summaries,
          package_count: s.package_count,
          package_set_hash: s.package_set_hash,
          artifact_hash: s.artifact_hash,
          artifact_count: s.artifact_count,
          manager_counts: s.manager_counts,
          server_package_set_hash: s.server_package_set_hash,
          package_set_hash_mismatch: s.package_set_hash_mismatch,
          unchanged_scan_count: s.unchanged_scan_count,
          last_scan_at: s.last_scan_at,
          last_changed_scan_at: s.last_changed_scan_at,
          reconcile_floor_due: s.reconcile_floor_due,
          metadata: s.metadata
        }
      ),
      prefix: "platform"
    )
  end

  defp scan_by_id(agent_id, scan_id) do
    Repo.one!(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id and s.scan_id == ^scan_id,
        select: %{
          id: s.id,
          current: s.current,
          package_count: s.package_count,
          coverage_state: s.coverage_state,
          source_summaries: s.source_summaries,
          enabled_sources: s.enabled_sources
        }
      ),
      prefix: "platform"
    )
  end

  defp cleanup_unboxed_inventory(agent_id, artifact_hash) do
    Repo.delete_all(
      from(e in "ocsf_events",
        where: fragment("?->>'agent_id' = ?", e.unmapped, ^agent_id)
      ),
      prefix: "platform"
    )

    Repo.delete_all(
      from(s in "endpoint_inventory_scans", where: s.agent_id == ^agent_id),
      prefix: "platform"
    )

    Repo.delete_all(
      from(c in "endpoint_inventory_artifact_contents",
        where: c.artifact_hash == ^artifact_hash
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
          cpes: p.cpes,
          endpoint_package_ref: p.endpoint_package_ref,
          device_uid: p.device_uid
        }
      ),
      prefix: "platform"
    )
  end

  defp endpoint_inventory_scan_activity(scan_id) do
    Repo.one(
      from(e in "ocsf_events",
        where:
          e.class_uid == 6007 and e.category_uid == 6 and
            fragment("?->'service_radar'->>'scan_id' = ?", e.metadata, ^scan_id),
        select: %{
          class_uid: e.class_uid,
          category_uid: e.category_uid,
          activity_name: e.activity_name,
          status: e.status,
          metadata: e.metadata
        },
        limit: 1
      ),
      prefix: "platform"
    )
  end

  defp endpoint_package(package_ref) do
    Repo.one!(
      from(p in "endpoint_packages",
        where: p.id == ^package_ref,
        select: %{
          id: p.id,
          coordinate_key: p.coordinate_key,
          purl_canonical: p.purl_canonical,
          primary_cpe: p.primary_cpe,
          cpes: p.cpes,
          package_manager: p.package_manager,
          name: p.name,
          source_scope: p.source_scope,
          metadata: p.metadata
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

  defp scan_row_count(agent_id) do
    Repo.one!(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id,
        select: count(s.id)
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

  defp endpoint_inventory_risk_contribution(device_uid) do
    Repo.one(
      from(c in "device_risk_contributions",
        where: c.device_uid == ^device_uid and c.source == "endpoint_inventory",
        select: %{
          active: c.active,
          score: c.score,
          risk_level: c.risk_level,
          resolved_at: c.resolved_at,
          metadata: c.metadata
        },
        limit: 1
      ),
      prefix: "platform"
    )
  end

  defp device_risk(device_uid) do
    Repo.one!(
      from(d in "ocsf_devices",
        where: d.uid == ^device_uid,
        select: %{
          risk_score: d.risk_score,
          risk_level_id: d.risk_level_id,
          risk_level: d.risk_level
        }
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

  defp capture_causal_signals(parent_pid) do
    fn subject, payload ->
      send(parent_pid, {:causal_signal_published, subject, Jason.decode!(payload)})
      :ok
    end
  end

  defp collect_causal_signals(count) do
    1..count
    |> Enum.map(fn _ ->
      assert_receive {:causal_signal_published, subject, payload}, 1_000
      %{subject: subject, payload: payload}
    end)
    |> Enum.sort_by(&{&1.subject, &1.payload["package"]["name"] || ""})
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

  defp artifact_device_uids(scan_ref) do
    Repo.all(
      from(a in "endpoint_inventory_artifacts",
        where: a.scan_ref == ^scan_ref,
        order_by: [asc: a.id],
        select: a.device_uid
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
    uid = canonical_test_device_uid(uid)

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        hostname: "#{String.replace(uid, ":", "-")}.local",
        type_id: 0,
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp canonical_test_device_uid("sr:" <> _ = uid), do: uid
  defp canonical_test_device_uid(uid), do: "sr:#{uid}"

  defp test_age_risk_summary_projector(test_pid) do
    fn device_uid, summary ->
      send(test_pid, {:age_risk_summary, device_uid, summary})
      :ok
    end
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
