defmodule ServiceRadarWebNGWeb.EdgePipelineComponentsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.EdgePipelineComponents

  @moduletag :unit
  @moduletag :db_free

  test "a gateway that has not installed the active epoch names the gateway and epoch" do
    condition = %{reason: :no_live_gateway_on_active_epoch, detail: %{epoch: 1_000_007, gateway_id: "gw-1"}}

    explanation = EdgePipelineComponents.explanation(condition)

    assert explanation =~ "gw-1"
    assert explanation =~ "1000007"
    assert explanation =~ "cannot be admitted"
  end

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
    assert explanation =~ "not handed off"
  end

  test "legacy storage pending handoff is reported as pending delivery with its reason" do
    explanation =
      EdgePipelineComponents.explanation(%{
        reason: :unsupported_legacy_storage,
        detail: %{
          retained_legacy_bytes: 4096,
          legacy_handoff_pending_records: 3,
          legacy_handoff_reason: "insufficient_capacity"
        }
      })

    assert explanation =~ "3 records in legacy edge storage are pending handoff to late admission"
    assert explanation =~ "insufficient_capacity"
    assert explanation =~ "delivered once the handoff completes"
    refute explanation =~ "untouched"
    refute explanation =~ "not handed off"
  end

  test "late records waiting for gateway support are reported as pending delivery" do
    explanation =
      EdgePipelineComponents.explanation(%{
        reason: :late_pending_gateway_support,
        detail: %{late_pending_records: 7, late_pending_reason: "late_pending_gateway_support"}
      })

    assert explanation =~ "7 late-admitted records wait for a gateway that supports late admission"
    assert explanation =~ "delivered once it does"
  end

  test "a stuck spool explains the unresolved age and byte budget" do
    detail = %{
      unresolved_count: 5,
      oldest_unresolved_age_known: true,
      oldest_unresolved_age_seconds: 905,
      bytes_used: 4096,
      budget_bytes: 8192
    }

    explanation = EdgePipelineComponents.explanation(%{reason: :spool_stuck, detail: detail})

    assert explanation =~ "15 minutes"
    assert explanation =~ "5 unresolved slots; oldest age 905s; 4096 / 8192 bytes charged."
  end

  test "backpressure names a paused gate only when admission is actually paused" do
    detail = %{
      admission_paused: false,
      unresolved_bytes: 1_073_741_825,
      unresolved_count: 9,
      oldest_unresolved_age_known: true,
      oldest_unresolved_age_seconds: 30,
      bytes_used: 1_100_000_000,
      budget_bytes: 2_147_483_648
    }

    full = EdgePipelineComponents.explanation(%{reason: :spool_backpressure, detail: detail})

    refute full =~ "paused"
    assert full =~ "exceed 1 GiB"
    assert full =~ "1073741825 unresolved bytes"

    paused =
      EdgePipelineComponents.explanation(%{
        reason: :spool_backpressure,
        detail: %{detail | admission_paused: true}
      })

    assert paused =~ "Spool admission is paused."
  end
end
