defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryComponents

  @moduletag :db_free

  test "renders confirmed, candidate, and history in separate assessment sections" do
    pages = %{
      confirmed: page([assessment()], 1),
      candidates:
        page(
          [
            assessment(%{
              id: "candidate-1",
              cve_id: "CVE-2099-424202",
              assessment: "candidate",
              disposition: "unknown",
              freshness: "stale",
              authority: nil,
              applicability_reason: "unknown NVD environment terms"
            })
          ],
          1
        ),
      history:
        page(
          [
            assessment(%{
              id: "history-1",
              cve_id: "CVE-2099-424203",
              status: "resolved",
              disposition: "fixed",
              transition_reason: "package upgraded"
            })
          ],
          1
        )
    }

    html = render_inventory(pages)

    assert html =~ "Confirmed vulnerabilities"
    assert html =~ "Unverified candidates"
    assert html =~ "History"
    assert html =~ "fixture:SYNTH-2099-1"
    assert html =~ "ubuntu / noble"
    assert html =~ "3.2.1-1ubuntu7.4"
    assert html =~ "3.2.1-1ubuntu7.6"
    assert html =~ "Fresh"
    assert html =~ "unknown NVD environment terms"
    assert html =~ "Resolved · fixed"
    assert html =~ "package upgraded"
    assert html =~ ~s(data-assessment-id="assessment-1")
    assert html =~ ~s(data-assessment-id="candidate-1")
    assert html =~ ~s(data-assessment-id="history-1")
  end

  test "candidate totals remain neutral and are not included in the confirmed count" do
    pages = %{
      confirmed: page([], 0),
      candidates:
        page(
          [
            assessment(%{
              id: "candidate-1",
              assessment: "candidate",
              disposition: "unknown",
              freshness: "stale"
            })
          ],
          73
        ),
      history: page([], 0)
    }

    html = render_inventory(pages)

    assert html =~ "0 confirmed"
    assert html =~ "73 candidates"
    refute html =~ "73 actionable"
    assert html =~ ~s(data-section="candidates")
  end

  test "a stale candidate negative is not presented as currently patched or not affected" do
    pages = %{
      confirmed: page([], 0),
      candidates:
        page(
          [
            assessment(%{
              id: "candidate-negative",
              assessment: "candidate",
              disposition: "not_affected",
              freshness: "stale",
              applicability_reason: "negative assertion is stale; refresh required"
            })
          ],
          1
        ),
      history: page([], 0)
    }

    html = render_inventory(pages)

    assert html =~ "Unverified candidate"
    assert html =~ "negative assertion is stale; refresh required"
    refute html =~ "Patched"
    refute html =~ "Currently not affected"
  end

  test "vulnerability assessments show a loading row instead of confirmed-empty copy" do
    html = render_inventory(%{confirmed: page([], 0), candidates: page([], 0), history: page([], 0)}, true)

    assert html =~ "Loading vulnerability assessments"
    refute html =~ "No confirmed vulnerabilities"
  end

  test "package modal uses assessments for decisions and raw advisories for detail enrichment" do
    assessment = assessment()

    details = %{
      assessments: [assessment],
      supporting_matches: [
        %{
          id: "raw-1",
          endpoint_package_ref: assessment.endpoint_package_ref,
          cve_id: assessment.cve_id,
          provider: "nvd",
          feed_key: "nist-nvd2",
          advisory: %{
            title: "Synthetic package advisory detail",
            description: "Synthetic supporting description",
            references: ["https://security.example.invalid/advisories/CVE-2099-424201"]
          },
          metadata: %{}
        }
      ],
      supporting_matches_total: 1,
      supporting_matches_truncated?: false
    }

    html =
      render_component(&EndpointInventoryComponents.endpoint_inventory_package_modal/1,
        show: true,
        package: %{
          id: "package-1",
          name: "libstarling-fetch3",
          version: "3.2.1-1ubuntu7.4"
        },
        assessment_details: details
      )

    assert html =~ "Confirmed vulnerabilities"
    assert html =~ "fixture:SYNTH-2099-1"
    assert html =~ "Synthetic supporting description"
    assert html =~ "https://security.example.invalid/advisories/CVE-2099-424201"

    refute html =~
             "nvd / nist-nvd2</span>\n          </div>\n          <div>\n            <span class=\"text-sr-muted\">Authority"
  end

  test "hides the assessment modal when it is not shown" do
    html =
      render_component(&EndpointInventoryComponents.endpoint_inventory_match_modal/1,
        show: false,
        match: assessment()
      )

    refute html =~ "CVE-2099-424201"
    refute html =~ "endpoint-match-modal"
  end

  defp render_inventory(pages, loading \\ false) do
    render_component(&EndpointInventoryComponents.endpoint_inventory_section/1,
      query_form: to_form(%{}, as: :endpoint_inventory_query),
      cohort_form: to_form(%{}, as: :endpoint_inventory_cohort_query),
      package_filter_form: to_form(%{}, as: :endpoint_inventory_filter),
      vulnerability_assessments: pages,
      loading: loading,
      has_inventory: true,
      show_controls: false
    )
  end

  defp page(rows, total) do
    %{rows: rows, total: total, limit: 50, truncated?: total > length(rows)}
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
        authority_as_of: ~U[2099-01-02 01:00:00Z],
        freshness: "fresh",
        provider: "fixture-ubuntu",
        feed_key: "fixture-ubuntu-advisory",
        package_namespace: "ubuntu",
        package_release: "noble",
        package_name: "libstarling-fetch3",
        package_manager: "dpkg",
        installed_version: "3.2.1-1ubuntu7.4",
        fixed_version: "3.2.1-1ubuntu7.6",
        severity: "high",
        cvss_score: 7.5,
        kev: false,
        exploit_available: false,
        supporting_match_ids: [],
        first_seen_at: ~U[2099-01-01 01:00:00Z],
        last_seen_at: ~U[2099-01-02 01:00:00Z],
        resolved_at: nil,
        transition_reason: nil,
        evidence: %{},
        metadata: %{}
      },
      overrides
    )
  end
end
