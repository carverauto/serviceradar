defmodule ServiceRadar.Observability.ServiceHealthDistinctTest do
  # Guards #5394: the dashboard Network Health card and `/services` share one
  # distinct service summary computed from `platform.service_state` instead of
  # summing time-windowed `services_availability_5m` buckets (which counted one
  # row per service per 5-minute bucket, inflating the total with the window).
  #
  # These tests drive the shared in-memory path
  # (`ServiceHealth.summary_from_states/1`) through its public interface with
  # both structs and plain maps. The plain-map shape is what the integration
  # suite reads back from `service_state`; it previously crashed
  # `state_sort_key/1`, which only accepted `%ServiceState{}` structs.
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ServiceHealth
  alias ServiceRadar.Observability.ServiceState

  @newer ~U[2026-10-06 02:00:00Z]
  @older ~U[2026-10-06 01:55:00Z]

  describe "distinct service summary from structs" do
    test "counts each logical identity once with availability parity" do
      states = [
        %ServiceState{
          agent_id: "agent-1",
          gateway_id: "gw-1",
          partition: "default",
          service_type: "plugin",
          service_name: "Service A",
          available: true,
          state: "active",
          last_observed_at: @newer
        },
        %ServiceState{
          agent_id: "agent-1",
          gateway_id: "gw-2",
          partition: "default",
          service_type: "plugin",
          service_name: "Service A",
          available: true,
          state: "active",
          last_observed_at: @older
        },
        %ServiceState{
          agent_id: "agent-1",
          gateway_id: "gw-1",
          partition: "default",
          service_type: "plugin",
          service_name: "Service B",
          available: false,
          state: "active",
          last_observed_at: @newer
        }
      ]

      summary = ServiceHealth.summary_from_states(states)

      # Three report rows, but only two distinct services: no bucket-style
      # inflation.
      assert summary.total == 2
      assert summary.available == 1
      assert summary.unavailable == 1
      assert summary.available + summary.unavailable == summary.total
      assert summary.availability_pct == 50.0
      assert summary.check_count == 2
      # The newer observation wins deduplication, so the latest timestamp survives.
      assert summary.last_updated == @newer
    end
  end

  describe "distinct service summary from plain maps" do
    test "accepts database row maps and dedupes by identity" do
      rows = [
        %{
          agent_id: "agent-test",
          gateway_id: "gw-1",
          partition: "default",
          service_type: "plugin",
          service_name: "svc-x",
          available: true,
          state: "active",
          last_observed_at: @newer
        },
        %{
          agent_id: "agent-test",
          gateway_id: "gw-2",
          partition: "default",
          service_type: "plugin",
          service_name: "svc-x",
          available: true,
          state: "inactive",
          last_observed_at: @older
        },
        %{
          agent_id: "agent-test",
          gateway_id: "gw-1",
          partition: "default",
          service_type: "plugin",
          service_name: "svc-y",
          available: false,
          state: "active",
          last_observed_at: @newer
        }
      ]

      summary = ServiceHealth.summary_from_states(rows)

      assert summary.total == 2
      assert summary.available == 1
      assert summary.unavailable == 1
      assert summary.available + summary.unavailable == summary.total
      assert summary.availability_pct == 50.0
      assert summary.last_updated == @newer
    end

    test "accepts string-keyed maps" do
      rows = [
        %{
          "agent_id" => "agent-1",
          "partition" => "default",
          "service_type" => "plugin",
          "service_name" => "Svc 1",
          "available" => true,
          "last_observed_at" => "2026-10-06T02:00:00Z"
        },
        %{
          "agent_id" => "agent-1",
          "partition" => "default",
          "service_type" => "plugin",
          "service_name" => "Svc 1",
          "available" => false,
          "last_observed_at" => "2026-10-06T01:55:00Z"
        }
      ]

      summary = ServiceHealth.summary_from_states(rows)

      assert summary.total == 1
      assert summary.available + summary.unavailable == 1
      assert summary.last_updated == ~U[2026-10-06 02:00:00Z]
    end
  end

  describe "summary dispatch" do
    test "every in-memory entry point agrees on one result" do
      states = [
        %ServiceState{
          agent_id: "agent-1",
          gateway_id: "gw-1",
          partition: "default",
          service_type: "plugin",
          service_name: "Service A",
          available: true,
          state: "active",
          last_observed_at: @newer
        }
      ]

      expected = ServiceHealth.summary_from_states(states)

      assert ServiceHealth.summary(states) == expected
      assert ServiceHealth.summary(states, services: []) == expected
      assert ServiceHealth.summary(states: states) == expected
    end

    test "empty input yields the empty summary" do
      assert ServiceHealth.summary([]) == ServiceHealth.empty_summary()
      assert ServiceHealth.summary_from_states([]) == ServiceHealth.empty_summary()

      assert ServiceHealth.empty_summary() == %{
               total: 0,
               available: 0,
               unavailable: 0,
               availability_pct: 0.0,
               last_updated: nil,
               check_count: 0
             }
    end
  end
end
