defmodule ServiceRadar.Inventory.EndpointInventoryPackageSetDeltaTest do
  @moduledoc """
  Pure (DB-free) unit tests for the endpoint inventory package-set delta
  application path. These verify reconstruction and hash agreement without
  touching the database, so they run in any environment.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Inventory.EndpointInventoryIngestor, as: Ingestor
  alias ServiceRadar.Inventory.EndpointInventoryPackageSet, as: PackageSet

  defp pkg(name, version, opts \\ []) do
    %{
      "name" => name,
      "version" => version,
      "architecture" => Keyword.get(opts, :arch, "amd64"),
      "manager" => Keyword.get(opts, :manager, "dpkg"),
      "ecosystem" => Keyword.get(opts, :ecosystem)
    }
  end

  defp normalized(name, version, opts \\ []) do
    [pkg(name, version, opts)]
    |> PackageSet.normalize_delta_packages()
    |> hd()
  end

  test "normalize_delta_packages drops invalid entries" do
    entries = [pkg("bash", "5.1"), %{"version" => "x"}, "garbage"]
    assert [package] = PackageSet.normalize_delta_packages(entries)
    assert package.name == "bash"
  end

  test "apply_delta adds, removes, and replaces by coordinate" do
    current = [
      normalized("bash", "5.1"),
      normalized("curl", "7.80"),
      normalized("openssl", "3.0")
    ]

    delta = %{
      added: [normalized("nginx", "1.24")],
      removed: [normalized("openssl", "3.0")],
      changed: [normalized("curl", "7.81")]
    }

    reconstructed = PackageSet.apply_delta(current, delta)
    names_versions = reconstructed |> Enum.map(&{&1.name, &1.version}) |> Enum.sort()

    assert names_versions == [{"bash", "5.1"}, {"curl", "7.81"}, {"nginx", "1.24"}]
  end

  test "apply_delta then server_package_set_hash equals hash of the equivalent full set" do
    current = [normalized("bash", "5.1"), normalized("curl", "7.80")]

    delta = %{
      added: [normalized("nginx", "1.24")],
      removed: [],
      changed: [normalized("curl", "7.81")]
    }

    reconstructed = PackageSet.apply_delta(current, delta)

    full_equivalent = [
      normalized("bash", "5.1"),
      normalized("curl", "7.81"),
      normalized("nginx", "1.24")
    ]

    assert PackageSet.server_package_set_hash(reconstructed) ==
             PackageSet.server_package_set_hash(full_equivalent)
  end

  test "apply_delta is idempotent for an added coordinate that already exists" do
    current = [normalized("bash", "5.1")]
    delta = %{added: [normalized("bash", "5.2")], removed: [], changed: []}

    reconstructed = PackageSet.apply_delta(current, delta)
    assert [%{name: "bash", version: "5.2"}] = reconstructed
  end

  # Core's current rows come from the CycloneDX anchor, which carries no
  # ecosystem, while the producer's delta entries do. The delta must still line
  # up with those rows, or it can never reach its target hash.
  test "a delta with ecosystems applies to rows stored from a CycloneDX anchor" do
    anchor = fn packages ->
      components =
        Enum.map(packages, fn {name, version} ->
          %{
            "type" => "library",
            "name" => name,
            "version" => version,
            "purl" => "pkg:deb/debian/#{name}@#{version}?arch=amd64",
            "properties" => [
              %{"name" => "serviceradar:package_manager", "value" => "dpkg"},
              %{"name" => "serviceradar:architecture", "value" => "amd64"}
            ]
          }
        end)

      PackageSet.normalize_packages(%{"sbom" => %{"components" => components}})
    end

    entry = fn name, version ->
      [package] =
        PackageSet.normalize_delta_packages([
          %{
            "name" => name,
            "version" => version,
            "architecture" => "amd64",
            "manager" => "dpkg",
            "ecosystem" => "deb",
            "purl" => "pkg:deb/debian/#{name}@#{version}?arch=amd64"
          }
        ])

      package
    end

    current = anchor.([{"bash", "5.1"}, {"curl", "7.80"}, {"openssl", "3.0"}])

    delta = %{
      added: [entry.("nginx", "1.24")],
      removed: [entry.("openssl", "3.0")],
      changed: [entry.("curl", "7.81")]
    }

    target = anchor.([{"bash", "5.1"}, {"curl", "7.81"}, {"nginx", "1.24"}])

    assert current |> PackageSet.apply_delta(delta) |> PackageSet.server_package_set_hash() ==
             PackageSet.server_package_set_hash(target)
  end

  # BuildCycloneDX (go/pkg/endpointinventory/cyclonedx.go) is the anchor a full
  # upload stores. It drops ecosystem, keeps manager and architecture only as
  # serviceradar properties, and copies only the first CPE. An applied delta of
  # the same producer package has to land on that row, or fleet package counts
  # keyed by coordinate_hash split across two coordinates.
  test "an applied delta package matches the CycloneDX anchor row and coordinate hash" do
    version = "7.81.0-1ubuntu1"

    producer = %{
      "name" => "curl",
      "version" => version,
      "architecture" => "amd64",
      "manager" => "dpkg",
      "ecosystem" => "deb",
      "purl" => "pkg:deb/debian/curl@#{version}?arch=amd64",
      "cpes" => [
        "cpe:2.3:a:haxx:curl:#{version}:*:*:*:*:*:*:*",
        "cpe:2.3:a:haxx:libcurl:#{version}:*:*:*:*:*:*:*"
      ]
    }

    anchor_component = %{
      "type" => "library",
      "name" => "curl",
      "version" => version,
      "purl" => "pkg:deb/debian/curl@#{version}?arch=amd64",
      "cpe" => "cpe:2.3:a:haxx:curl:#{version}:*:*:*:*:*:*:*",
      "properties" => [
        %{"name" => "serviceradar:package_manager", "value" => "dpkg"},
        %{"name" => "serviceradar:architecture", "value" => "amd64"}
      ]
    }

    [changed] = PackageSet.normalize_delta_packages([producer])

    [written] =
      PackageSet.apply_delta([normalized("curl", "7.80.0-1")], %{
        added: [],
        removed: [],
        changed: [changed]
      })

    [anchor] =
      PackageSet.normalize_packages(%{"sbom" => %{"components" => [anchor_component]}})

    assert written == anchor
    assert written.ecosystem == nil

    assert written.metadata == %{
             "properties" => %{
               "serviceradar:package_manager" => "dpkg",
               "serviceradar:architecture" => "amd64"
             }
           }

    assert PackageSet.coordinate_hash(written) == PackageSet.coordinate_hash(anchor)
  end

  test "empty delta reproduces the current set" do
    current = [normalized("bash", "5.1"), normalized("curl", "7.80")]
    delta = %{added: [], removed: [], changed: []}

    reconstructed = PackageSet.apply_delta(current, delta)

    assert PackageSet.server_package_set_hash(reconstructed) ==
             PackageSet.server_package_set_hash(current)
  end

  test "canonical persistence decodes encoded PURL components once" do
    version = "7:42.0~test1-0ubuntu99.7+fixture1"

    [package] =
      PackageSet.normalize_delta_packages([
        %{
          "name" => "libexample42",
          "version" => version,
          "architecture" => "amd64",
          "manager" => "dpkg",
          "purl" =>
            "pkg:deb/ubuntu/libexample42@7:42.0~test1-0ubuntu99.7%2Bfixture1?arch=amd64&source=example-source&sourceversion=7:42.0~test1-0ubuntu99.7%2Bfixture1"
        }
      ])

    assert package.purl_canonical ==
             "pkg:deb/ubuntu/libexample42@7:42.0~test1-0ubuntu99.7%2Bfixture1?arch=amd64&source=example-source&sourceversion=7:42.0~test1-0ubuntu99.7%2Bfixture1"

    refute package.purl_canonical =~ "%252B"
  end

  test "canonical persistence retains a parsed PURL subpath" do
    [package] =
      PackageSet.normalize_delta_packages([
        %{
          "name" => "example-agent",
          "version" => "42.0~test1-0ubuntu99.7",
          "architecture" => "amd64",
          "manager" => "dpkg",
          "purl" =>
            "pkg:deb/ubuntu/example-agent@42.0~test1-0ubuntu99.7?arch=amd64#licenses/Example%20License"
        }
      ])

    assert package.purl_canonical ==
             "pkg:deb/ubuntu/example-agent@42.0~test1-0ubuntu99.7?arch=amd64#licenses/Example%20License"
  end

  test "unchanged upload after a mismatched full upload does not force reconcile unless artifact_hash changes" do
    artifact_hash = String.duplicate("a", 64)
    stale_reported_hash = "stale-producer-hash-v0"

    full_payload = %{
      "agent_id" => "example-agent-stale-producer",
      "scan_id" => "scan-full-1",
      "device_uid" => "sr:example-device-stale-producer",
      "collector_version" => "0.1.5",
      "state" => "scanned",
      "coverage_state" => "complete",
      "package_count" => 1,
      "package_set_hash" => stale_reported_hash,
      "artifact_hash" => artifact_hash,
      "hash_algorithm" => "sha256-v1",
      "upload_reason" => "changed",
      "sbom" => %{
        "components" => [
          %{
            "type" => "library",
            "name" => "curl",
            "version" => "1:7.81.0-1ubuntu1",
            "purl" => "pkg:deb/debian/curl@1%3A7.81.0-1ubuntu1?arch=amd64",
            "properties" => [
              %{"name" => "serviceradar:package_manager", "value" => "dpkg"},
              %{"name" => "serviceradar:architecture", "value" => "amd64"}
            ]
          }
        ]
      },
      "metadata" => %{"scanner_producer_version" => "0.1.5"}
    }

    assert {:ok, raw_full_ctx} = Ingestor.build_scan_context(full_payload)
    full_ctx = Ingestor.apply_hash_freshness(raw_full_ctx, nil, 0)

    assert full_ctx.package_set_hash_mismatch? == true
    assert full_ctx.package_set_hash == full_ctx.server_package_set_hash
    refute full_ctx.package_set_hash == stale_reported_hash

    current = %{
      id: 1,
      device_uid: full_ctx.device_uid,
      package_count: full_ctx.package_count,
      scan_id: full_ctx.scan_id,
      state: full_ctx.state,
      coverage_state: full_ctx.coverage_state,
      package_set_hash: full_ctx.package_set_hash,
      artifact_hash: full_ctx.artifact_hash,
      upload_reason: full_ctx.upload_reason,
      server_package_set_hash: full_ctx.server_package_set_hash,
      package_set_hash_mismatch: full_ctx.package_set_hash_mismatch?,
      last_successful_scan_at: full_ctx.last_successful_scan_at,
      last_scan_at: full_ctx.last_scan_at,
      last_changed_scan_at: full_ctx.last_changed_scan_at,
      unchanged_scan_count: full_ctx.unchanged_scan_count,
      reconcile_floor_due: full_ctx.reconcile_floor_due?,
      metadata: %{
        "reported_package_set_hash" => full_ctx.reported_package_set_hash,
        "server_package_set_hash" => full_ctx.server_package_set_hash,
        "package_set_hash_mismatch" => full_ctx.package_set_hash_mismatch?
      },
      current: true
    }

    unchanged_payload = %{
      "agent_id" => "example-agent-stale-producer",
      "scan_id" => "scan-unchanged-2",
      "device_uid" => "sr:example-device-stale-producer",
      "collector_version" => "0.1.5",
      "state" => "unchanged",
      "coverage_state" => "unchanged",
      "package_count" => 1,
      "package_set_hash" => stale_reported_hash,
      "artifact_hash" => artifact_hash,
      "hash_algorithm" => "sha256-v1",
      "upload_reason" => "unchanged",
      "metadata" => %{"scanner_producer_version" => "0.1.5"}
    }

    assert {:ok, unchanged_ctx} = Ingestor.build_scan_context(unchanged_payload)

    assert {:short_circuit, noop_ctx} = Ingestor.evaluate_hash_noop(unchanged_ctx, current, 1)
    assert noop_ctx.reconcile_floor_due? == false
    assert noop_ctx.package_set_hash_mismatch? == true
    assert noop_ctx.package_set_hash == full_ctx.server_package_set_hash
    assert noop_ctx.unchanged_scan_count == 1

    changed_artifact_payload =
      Map.put(unchanged_payload, "artifact_hash", String.duplicate("b", 64))

    assert {:ok, changed_artifact_ctx} = Ingestor.build_scan_context(changed_artifact_payload)

    assert {:short_circuit, forced_ctx} =
             Ingestor.evaluate_hash_noop(changed_artifact_ctx, current, 1)

    assert forced_ctx.reconcile_floor_due? == true
  end

  test "package_set_hash mismatch warning logs once per (reported, server) pair change and includes scanner_producer_version" do
    artifact_hash = String.duplicate("c", 64)

    base_payload = %{
      "agent_id" => "example-agent-mismatch-log",
      "scan_id" => "scan-log-1",
      "device_uid" => "sr:example-device-mismatch-log",
      "collector_version" => "0.1.4",
      "state" => "scanned",
      "coverage_state" => "complete",
      "package_count" => 1,
      "package_set_hash" => "stale-reported-hash-1",
      "artifact_hash" => artifact_hash,
      "hash_algorithm" => "sha256-v1",
      "upload_reason" => "changed",
      "sbom" => %{
        "components" => [
          %{
            "type" => "library",
            "name" => "openssl",
            "version" => "3.0.13-0ubuntu3",
            "purl" => "pkg:deb/debian/openssl@3.0.13-0ubuntu3?arch=amd64",
            "properties" => [
              %{"name" => "serviceradar:package_manager", "value" => "dpkg"},
              %{"name" => "serviceradar:architecture", "value" => "amd64"}
            ]
          }
        ]
      },
      "metadata" => %{"scanner_producer_version" => "0.1.4"}
    }

    assert {:ok, first_raw_ctx} = Ingestor.build_scan_context(base_payload)

    {first_ctx, first_log} =
      with_log(fn ->
        Ingestor.apply_hash_freshness(first_raw_ctx, nil, 0)
      end)

    assert first_ctx.package_set_hash_mismatch? == true
    assert first_log =~ "Endpoint inventory package_set_hash mismatch:"
    assert first_log =~ "scanner_producer_version=0.1.4"
    assert first_log =~ "reported=stale-reported-hash-1"

    current = %{
      package_set_hash: first_ctx.package_set_hash,
      server_package_set_hash: first_ctx.server_package_set_hash,
      package_set_hash_mismatch: true,
      artifact_hash: artifact_hash,
      unchanged_scan_count: 0,
      last_changed_scan_at: first_ctx.last_changed_scan_at,
      reconcile_floor_due: false,
      metadata: %{
        "reported_package_set_hash" => first_ctx.reported_package_set_hash,
        "server_package_set_hash" => first_ctx.server_package_set_hash,
        "package_set_hash_mismatch" => true
      }
    }

    assert {:ok, second_raw_ctx} =
             base_payload
             |> Map.put("scan_id", "scan-log-2")
             |> Ingestor.build_scan_context()

    {second_ctx, second_log} =
      with_log(fn ->
        Ingestor.apply_hash_freshness(second_raw_ctx, current, 1)
      end)

    assert second_ctx.package_set_hash_mismatch? == true
    refute second_log =~ "Endpoint inventory package_set_hash mismatch:"

    assert {:ok, third_raw_ctx} =
             base_payload
             |> Map.put("scan_id", "scan-log-3")
             |> Map.put("package_set_hash", "stale-reported-hash-2")
             |> Ingestor.build_scan_context()

    {third_ctx, third_log} =
      with_log(fn ->
        Ingestor.apply_hash_freshness(third_raw_ctx, current, 1)
      end)

    assert third_ctx.package_set_hash_mismatch? == true
    assert third_log =~ "Endpoint inventory package_set_hash mismatch:"
    assert third_log =~ "scanner_producer_version=0.1.4"
    assert third_log =~ "reported=stale-reported-hash-2"
  end
end
