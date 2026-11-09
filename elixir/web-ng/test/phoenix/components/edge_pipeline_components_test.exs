defmodule ServiceRadarWebNGWeb.EdgePipelineComponentsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.EdgePipelineComponents

  @moduletag :unit
  @moduletag :db_free

  test "an oversized summary names the service and its size, and does not call the build old" do
    condition = %{
      reason: :oversized_summary,
      detail: %{count: 35, summaries: %{"snmp" => %{bytes: 4_812, limit: 4_096}}, last_refused_at: nil}
    }

    explanation = EdgePipelineComponents.explanation(condition)

    assert explanation =~ "refused 35 status summaries over its size limit"
    assert explanation =~ "snmp (4812 bytes, limit 4096)"
    refute explanation =~ "cutover"
  end

  test "coverage gaps distinguish overlapping sequence numbers across generations and report the remainder" do
    detail = %{
      gap_count: 4,
      generation_gaps: [
        %{
          spool_generation_id: "01900000000070008000000000000001",
          route_profile: "durable",
          traffic_class: "bulk",
          sequence: 1
        },
        %{
          spool_generation_id: "01900000000070008000000000000002",
          route_profile: "durable",
          traffic_class: "bulk",
          sequence: 1
        }
      ]
    }

    explanation = EdgePipelineComponents.explanation(%{reason: :spool_wedged, detail: detail})
    assert explanation =~ "01900000000070008000000000000001 durable/bulk #1"
    assert explanation =~ "01900000000070008000000000000002 durable/bulk #1"
    assert explanation =~ "2 additional"
    assert EdgePipelineComponents.gap_samples(%{"gap_count" => 2, "gap_sequences" => [4, 8]}) == "4, 8"
  end

  test "unsupported old storage is distinguished from active lane health" do
    explanation =
      EdgePipelineComponents.explanation(%{reason: :unsupported_legacy_storage, detail: %{retained_legacy_bytes: 192}})

    assert explanation =~ "192 bytes of unsupported legacy edge storage are retained untouched"
    assert explanation =~ "Only bounded lanes are delivered"
  end
end
