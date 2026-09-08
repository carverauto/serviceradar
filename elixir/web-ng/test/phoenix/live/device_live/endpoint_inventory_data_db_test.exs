defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryDataDbTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Inventory.EndpointPackage
  alias ServiceRadar.Inventory.EndpointVulnerabilityAssessment
  alias ServiceRadar.Inventory.EndpointVulnerabilityMatch
  alias ServiceRadar.Inventory.VulnerabilityAdvisory
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryData

  @moduletag :web_ng_shared_fixture_db

  setup do
    user = AshTestHelpers.admin_user_fixture()
    %{scope: ServiceRadarWebNG.Accounts.Scope.for_user(user)}
  end

  test "counts and limits assessment partitions independently and keeps modal evidence separate", %{
    scope: scope
  } do
    unique = System.unique_integer([:positive])
    device_uid = "sr:assessment-ui-#{unique}"
    now = DateTime.utc_now()

    endpoint_package =
      EndpointPackage
      |> Ash.Changeset.for_create(:create, %{
        coordinate_key: "pkg:deb/ubuntu/libstarling-fetch3@3.2.1-1ubuntu7.#{unique}?distro=noble",
        purl_canonical: "pkg:deb/ubuntu/libstarling-fetch3@3.2.1-1ubuntu7.#{unique}?distro=noble",
        package_manager: "dpkg",
        name: "libstarling-fetch3",
        version: "3.2.1-1ubuntu7.#{unique}",
        architecture: "amd64",
        ecosystem: "deb",
        source_scope: "host",
        metadata: %{}
      })
      |> Ash.create!(scope: scope)

    advisory =
      VulnerabilityAdvisory
      |> Ash.Changeset.for_create(:upsert, %{
        provider: "fixture-nvd",
        feed_key: "fixture-nvd-feed",
        source_object_id: "CVE-2099-1001-#{unique}",
        advisory_id: "CVE-2099-1001",
        cve_id: "CVE-2099-1001",
        title: "Supporting raw advisory",
        description: "Raw detail enrichment only",
        references: ["https://security.example.invalid/advisories/CVE-2099-1001"],
        severity: "high",
        cvss_score: 7.5,
        metadata: %{}
      })
      |> Ash.create!(scope: scope)

    raw_match =
      EndpointVulnerabilityMatch
      |> Ash.Changeset.for_create(:upsert, %{
        device_uid: device_uid,
        endpoint_package_ref: endpoint_package.id,
        advisory_ref: advisory.id,
        provider: "fixture-nvd",
        feed_key: "fixture-nvd-feed",
        advisory_id: "CVE-2099-1001",
        cve_id: "CVE-2099-1001",
        coordinate_type: "cpe",
        coordinate_value: "cpe:2.3:a:example:starling_fetch:*:*:*:*:*:*:*:*",
        confidence: "medium",
        status: "active",
        severity: "high",
        cvss_score: 7.5,
        evidence: %{},
        first_seen_at: now,
        last_seen_at: now,
        metadata: %{}
      })
      |> Ash.create!(scope: scope)

    Enum.each(1..55, fn index ->
      create_assessment!(scope, endpoint_package.id, device_uid, now,
        id_suffix: "candidate-#{index}",
        cve_id: "CVE-2099-#{2000 + index}",
        assessment: "candidate",
        disposition: "unknown",
        freshness: "stale",
        applicability_reason: "candidate #{index}"
      )
    end)

    Enum.each(1..3, fn index ->
      create_assessment!(scope, endpoint_package.id, device_uid, now,
        id_suffix: "confirmed-#{index}",
        cve_id: "CVE-2099-#{1000 + index}",
        assessment: "confirmed",
        disposition: "affected",
        freshness: "fresh",
        authority: "fixture:SYNTH-2099-#{index}",
        applicability_reason: "exact Ubuntu range",
        supporting_match_ids: if(index == 1, do: [raw_match.id], else: [])
      )
    end)

    Enum.each(1..2, fn index ->
      create_assessment!(scope, endpoint_package.id, device_uid, now,
        id_suffix: "history-#{index}",
        cve_id: "CVE-2099-#{3000 + index}",
        status: "resolved",
        assessment: "confirmed",
        disposition: "fixed",
        freshness: "fresh",
        authority: "fixture:SYNTH-2099-history-#{index}",
        applicability_reason: "fixed Ubuntu range",
        transition_reason: "package upgraded",
        resolved_at: now
      )
    end)

    inventory = EndpointInventoryData.load(scope, device_uid)
    pages = inventory.vulnerability_assessments

    assert pages.candidates.total == 55
    assert length(pages.candidates.rows) == 50
    assert pages.candidates.truncated?
    assert pages.confirmed.total == 3
    assert length(pages.confirmed.rows) == 3
    refute pages.confirmed.truncated?
    assert pages.history.total == 2
    assert length(pages.history.rows) == 2

    assert Enum.all?(pages.confirmed.rows, fn row ->
             row.status == "active" and row.assessment == "confirmed" and
               row.disposition == "affected"
           end)

    details =
      EndpointInventoryData.load_package_vulnerabilities(
        scope,
        device_uid,
        to_string(endpoint_package.id)
      )

    assert length(details.assessments) == 60
    assert Enum.count(details.assessments, &(&1.assessment == "candidate")) == 55
    assert Enum.count(details.assessments, &(&1.status == "resolved")) == 2
    assert details.supporting_matches_total == 1
    assert [support] = details.supporting_matches
    assert support.id == raw_match.id
    assert support.advisory.description == "Raw detail enrichment only"
  end

  defp create_assessment!(scope, endpoint_package_ref, device_uid, now, opts) do
    attrs = %{
      device_uid: device_uid,
      package_identity_key: "pkgid:v1:#{Keyword.fetch!(opts, :id_suffix)}",
      endpoint_package_ref: endpoint_package_ref,
      cve_id: Keyword.fetch!(opts, :cve_id),
      status: Keyword.get(opts, :status, "active"),
      assessment: Keyword.fetch!(opts, :assessment),
      disposition: Keyword.fetch!(opts, :disposition),
      authority: Keyword.get(opts, :authority),
      applicability_reason: Keyword.fetch!(opts, :applicability_reason),
      freshness: Keyword.fetch!(opts, :freshness),
      provider: "fixture-ubuntu",
      feed_key: "fixture-ubuntu-advisory",
      package_type: "deb",
      package_manager: "dpkg",
      package_namespace: "ubuntu",
      package_release: "noble",
      package_name: "libstarling-fetch3",
      package_purl:
        "pkg:deb/ubuntu/libstarling-fetch3@3.2.1-1ubuntu7.4?distro=noble&source=starling-fetch&sourceversion=3.2.1-1ubuntu7.4",
      installed_version: "3.2.1-1ubuntu7.4",
      fixed_version: "3.2.1-1ubuntu7.6",
      severity: "high",
      cvss_score: 7.5,
      supporting_match_ids: Keyword.get(opts, :supporting_match_ids, []),
      evidence: %{},
      metadata: %{},
      transition_reason: Keyword.get(opts, :transition_reason),
      first_seen_at: now,
      last_seen_at: now,
      resolved_at: Keyword.get(opts, :resolved_at)
    }

    EndpointVulnerabilityAssessment
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create!(scope: scope)
  end
end
