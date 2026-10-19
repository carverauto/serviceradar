defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryFindingsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryFindings

  @moduletag :db_free

  test "uses the persisted assessment as applicability authority and raw matches only as enrichment" do
    assessment = assessment()

    raw_matches = [
      %{
        id: "raw-nvd",
        endpoint_package_ref: assessment.endpoint_package_ref,
        cve_id: assessment.cve_id,
        advisory_id: assessment.cve_id,
        provider: "nvd",
        feed_key: "nist-nvd2",
        coordinate_type: "cpe",
        coordinate_value: "cpe:2.3:a:example:starling_fetch:3.1.0:*:*:*:*:*:*:*",
        confidence: "medium",
        status: "active",
        severity: "critical",
        cvss_score: 9.8,
        fixed_version: nil,
        kev: false,
        exploit_available: false,
        advisory: %{
          description: "Raw NVD description",
          references: ["https://security.example.invalid/advisories/CVE-2099-424201"],
          metadata: %{"cwes" => ["CWE-287"]}
        },
        metadata: %{"cwes" => ["CWE-287"]}
      },
      %{
        id: "raw-kev",
        endpoint_package_ref: assessment.endpoint_package_ref,
        cve_id: assessment.cve_id,
        provider: "cisa",
        feed_key: "cisa-kev",
        coordinate_type: "vendor_product",
        coordinate_value: "starling-fetch",
        confidence: "low",
        kev: true,
        exploit_available: true,
        metadata: %{
          "priority" => %{"due_date" => "2099-02-01", "epss_score" => 0.88}
        }
      }
    ]

    assert [finding] = EndpointInventoryFindings.group([assessment], raw_matches)

    assert finding.id == assessment.id
    assert finding.assessment == "confirmed"
    assert finding.disposition == "affected"
    assert finding.authority == "fixture:SYNTH-2099-1"
    assert finding.provider == "fixture-ubuntu"
    assert finding.feed_key == "fixture-ubuntu-advisory"
    assert finding.fixed_version == "3.2.1-1ubuntu7.6"
    assert finding.package_release == "noble"
    assert finding.installed_version == "3.2.1-1ubuntu7.4"

    # Raw rows may enrich priority and descriptive fields, but do not become
    # the applicability authority or overwrite the authoritative fix boundary.
    assert finding.kev
    assert finding.exploit_available
    assert finding.cvss_score == 7.5
    assert finding.cwes == ["CWE-287"]
    assert finding.description == "Raw NVD description"
    assert finding.due_date == "2099-02-01"
    assert finding.epss_score == 0.88
    assert Enum.map(finding.sources, & &1.provider) == ["fixture-ubuntu", "cisa", "nvd"]
  end

  test "retains assessment-owned priority metadata without loaded raw matches" do
    assessment =
      assessment(%{
        metadata: %{
          "epss_score" => 0.91,
          "due_date" => "2099-03-15",
          "ransomware_use" => "Known"
        }
      })

    assert [finding] = EndpointInventoryFindings.group([assessment], [])
    assert finding.epss_score == 0.91
    assert finding.due_date == "2099-03-15"
    assert finding.ransomware_use == "Known"

    assert finding.sources == [
             %{provider: "fixture-ubuntu", feed_key: "fixture-ubuntu-advisory"}
           ]
  end

  test "does not multiply one assessment when several raw feeds support it" do
    assessment = assessment()

    raw_matches = [
      %{id: "one", endpoint_package_ref: assessment.endpoint_package_ref, cve_id: assessment.cve_id},
      %{id: "two", endpoint_package_ref: assessment.endpoint_package_ref, cve_id: assessment.cve_id},
      %{
        id: "unrelated",
        endpoint_package_ref: assessment.endpoint_package_ref,
        cve_id: "CVE-2099-424299"
      }
    ]

    assert [%{id: "assessment-1", supporting_matches: supporting}] =
             EndpointInventoryFindings.group([assessment], raw_matches)

    assert Enum.map(supporting, & &1.id) == ["one", "two"]
  end

  test "partitions rows by assessment lifecycle without treating a stale negative as current" do
    confirmed = assessment()

    candidate =
      assessment(%{
        id: "candidate-1",
        cve_id: "CVE-2099-424202",
        assessment: "candidate",
        disposition: "not_affected",
        freshness: "stale",
        applicability_reason: "stale negative assertion requires refresh"
      })

    history =
      assessment(%{
        id: "history-1",
        cve_id: "CVE-2099-424203",
        status: "resolved",
        disposition: "fixed",
        transition_reason: "package upgraded"
      })

    assert %{
             confirmed: [%{id: "assessment-1"}],
             candidates: [%{id: "candidate-1", state_label: "Unverified candidate"}],
             history: [%{id: "history-1", state_label: "Resolved · fixed"}]
           } = EndpointInventoryFindings.partition([confirmed, candidate, history])
  end

  test "projects last_seen_at as the last confirmation timestamp" do
    first_seen = ~U[2099-01-01 01:00:00Z]
    row_seen = ~U[2099-01-02 01:00:00Z]
    confirmed_eval = ~U[2099-01-05 01:00:00Z]
    unconfirmed_eval = ~U[2099-01-06 01:00:00Z]
    resolved_at = ~U[2099-01-07 01:00:00Z]

    active_confirmed =
      assessment(%{
        id: "active-confirmed",
        cve_id: "CVE-2099-424210",
        status: "active",
        first_seen_at: first_seen,
        last_seen_at: row_seen,
        evaluated_at: unconfirmed_eval
      })

    active_unconfirmed =
      assessment(%{
        id: "active-unconfirmed",
        cve_id: "CVE-2099-424211",
        status: "active",
        first_seen_at: first_seen,
        last_seen_at: row_seen,
        evaluated_at: resolved_at,
        metadata: %{
          "unconfirmed_since" => "2099-01-06T01:00:00.000000",
          "last_confirmed_at" => "2099-01-05T01:00:00.000000"
        }
      })

    resolved =
      assessment(%{
        id: "resolved-1",
        cve_id: "CVE-2099-424212",
        status: "resolved",
        disposition: "fixed",
        first_seen_at: first_seen,
        last_seen_at: row_seen,
        resolved_at: resolved_at,
        evaluated_at: resolved_at
      })

    findings =
      [active_confirmed, active_unconfirmed, resolved]
      |> EndpointInventoryFindings.group([])
      |> Map.new(&{&1.id, &1})

    assert findings["active-confirmed"].last_seen_at == unconfirmed_eval

    assert DateTime.compare(findings["active-unconfirmed"].last_seen_at, confirmed_eval) == :eq

    assert findings["resolved-1"].last_seen_at == row_seen
  end

  defp assessment(overrides \\ %{}) do
    Map.merge(
      %{
        id: "assessment-1",
        endpoint_package_ref: "package-1",
        cve_id: "CVE-2099-424201",
        advisory_id: "SYNTH-2099-1",
        status: "active",
        assessment: "confirmed",
        disposition: "affected",
        authority: "fixture:SYNTH-2099-1",
        applicability_reason: "exact Ubuntu Noble package range",
        authority_generation: 17,
        authority_as_of: ~U[2099-01-02 01:00:00Z],
        freshness: "fresh",
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
        kev: false,
        exploit_available: false,
        supporting_match_ids: [],
        evidence: %{},
        metadata: %{},
        first_seen_at: ~U[2099-01-01 01:00:00Z],
        last_seen_at: ~U[2099-01-02 01:00:00Z],
        resolved_at: nil,
        transition_reason: nil
      },
      overrides
    )
  end
end
