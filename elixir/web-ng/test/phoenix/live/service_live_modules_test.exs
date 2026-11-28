defmodule ServiceRadarWebNGWeb.ServiceLiveModulesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStatus
  alias ServiceRadarWebNGWeb.ServiceLive.Index.Data
  alias ServiceRadarWebNGWeb.ServiceLive.Service
  alias ServiceRadarWebNGWeb.ServiceLive.Show.History
  alias ServiceRadarWebNGWeb.ServiceLive.Show.Query

  @moduletag :db_free

  describe "shared service presentation" do
    test "normalizes identity and preserves detail route parameters" do
      service = %{
        "uid" => "service-1",
        "check_name" => "Inventory Sync",
        "check_type" => "plugin",
        "gateway_id" => "gateway-a",
        "agent_id" => "agent-a",
        "partition" => "default",
        "timestamp" => "2026-07-11T05:23:49.123456Z"
      }

      assert Service.name(service) == "Inventory Sync"
      assert Service.type(service) == "plugin"

      assert Service.details_params(service) == %{
               "service_id" => "service-1",
               "service_name" => "Inventory Sync",
               "service_type" => "plugin",
               "gateway_id" => "gateway-a",
               "agent_id" => "agent-a",
               "partition" => "default",
               "timestamp" => "2026-07-11T05:23:49.123456Z"
             }
    end

    test "parses result details and enforces a widget contract" do
      details = %{
        "summary" => "20 hosts imported",
        "schema_version" => 1,
        "labels" => %{"plugin_id" => "awx-inventory"},
        "display" => [
          %{"widget" => "stat_card", "value" => 20},
          %{"widget" => "table", "rows" => []}
        ]
      }

      service = %{"message" => "fallback", "details" => Jason.encode!(details)}
      parsed = Service.parse_details(service)

      assert Service.summary(service, parsed) == "20 hosts imported"
      assert Service.plugin_id(parsed) == "awx-inventory"
      assert Service.schema_version(parsed, %{}) == 1

      assert Service.filter_display(Service.display_instructions(parsed), %{
               "widgets" => ["stat_card"]
             }) == [%{"widget" => "stat_card", "value" => 20}]
    end

    test "normalizes availability values without coercing unknown text" do
      assert Service.normalize_available(" T ")
      refute Service.normalize_available("0")
      assert Service.normalize_available("healthy") == nil
    end
  end

  describe "index query defaults" do
    test "only replaces missing, empty, or non-string queries" do
      default = "in:services time:last_1h"

      assert Data.ensure_default_query(%{}, default) == %{"q" => default}
      assert Data.ensure_default_query(%{"q" => ""}, default) == %{"q" => default}
      assert Data.ensure_default_query(%{"q" => 42}, default) == %{"q" => default}

      assert Data.ensure_default_query(%{"q" => "in:services limit:10"}, default) == %{
               "q" => "in:services limit:10"
             }
    end
  end

  describe "show query identity" do
    test "prefers a service id and escapes SRQL values" do
      query = Query.build(%{"service_id" => "id\"quoted", "agent_id" => "ignored"}, 200)

      assert query ==
               "in:services service_id:\"id\\\"quoted\" sort:timestamp:desc limit:200"
    end

    test "falls back to agent identity and omits gateway identity" do
      query =
        Query.fallback(
          %{
            "service_name" => "AWX Inventory Sync",
            "service_type" => "plugin",
            "gateway_id" => "gateway-old",
            "agent_id" => "agent-a",
            "partition" => "default"
          },
          200
        )

      assert query =~ "service_name:\"AWX Inventory Sync\""
      assert query =~ "agent_id:\"agent-a\""
      refute query =~ "gateway_id:"
    end

    test "selects the exact requested observation before falling back to latest" do
      services = [
        %{"service_id" => "latest", "timestamp" => "2026-07-11T05:23:50Z"},
        %{"service_id" => "target", "timestamp" => "2026-07-11T05:23:49.123456Z"}
      ]

      assert %{"service_id" => "target"} =
               Query.pick_service(services, %{"timestamp" => "2026-07-11T05:23:49.123456Z"})

      assert %{"service_id" => "latest"} =
               Query.pick_service(services, %{"timestamp" => "not-a-timestamp"})
    end
  end

  describe "distinct service health summaries" do
    test "deduplicates service instances by logical identity and computes availability parity" do
      now = ~U[2026-10-06 02:00:00Z]
      older = ~U[2026-10-06 01:55:00Z]

      # 3 rows representing 2 distinct services:
      # - Service A on agent-1: two gateway variants (older unavailable, newer available)
      # - Service B on agent-1: unavailable
      states = [
        %ServiceState{
          agent_id: "agent-1",
          gateway_id: "gw-1",
          partition: "default",
          service_type: "plugin",
          service_name: "Service A",
          available: true,
          state: "active",
          last_observed_at: now
        },
        %ServiceState{
          agent_id: "agent-1",
          gateway_id: "gw-2",
          partition: "default",
          service_type: "plugin",
          service_name: "Service A",
          available: false,
          state: "active",
          last_observed_at: older
        },
        %ServiceState{
          agent_id: "agent-1",
          gateway_id: "gw-1",
          partition: "default",
          service_type: "plugin",
          service_name: "Service B",
          available: false,
          state: "active",
          last_observed_at: now
        }
      ]

      summary = Data.summary(states, [])

      # Total must be exactly 2 distinct services, NOT 3
      assert summary.total == 2
      assert summary.available == 1
      assert summary.unavailable == 1
      assert summary.available + summary.unavailable == summary.total
      assert summary.availability_pct == 50.0
      assert summary.last_updated == now
    end

    test "empty states fall back to empty summary" do
      summary = Data.summary([], [])

      assert summary.total == 0
      assert summary.available == 0
      assert summary.unavailable == 0
      assert summary.availability_pct == 0.0
      assert summary.last_updated == nil
    end

    test "fallback services calculate distinct plugin count" do
      services = [
        %{
          "agent_id" => "agent-1",
          "partition" => "default",
          "service_type" => "plugin",
          "service_name" => "Svc 1",
          "available" => true,
          "timestamp" => "2026-10-06T02:00:00Z"
        },
        %{
          "agent_id" => "agent-1",
          "partition" => "default",
          "service_type" => "plugin",
          "service_name" => "Svc 1",
          "available" => true,
          "timestamp" => "2026-10-06T01:55:00Z"
        },
        %{
          "agent_id" => "agent-2",
          "partition" => "default",
          "service_type" => "plugin",
          "service_name" => "Svc 2",
          "available" => false,
          "timestamp" => "2026-10-06T02:00:00Z"
        }
      ]

      summary = Data.summary([], services)

      assert summary.total == 2
      assert summary.available == 1
      assert summary.unavailable == 1
      assert summary.available + summary.unavailable == summary.total
      assert summary.availability_pct == 50.0
    end
  end

  describe "show history live status updates" do
    test "appends ServiceStatus structs without raising Enumerable protocol errors" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          history: [],
          service: %{
            "service_id" => "svc-synthetic-01",
            "service_name" => "Synthetic Plugin Check",
            "service_type" => "plugin",
            "gateway_id" => "gw-1",
            "agent_id" => "agent-1",
            "partition" => "default"
          }
        }
      }

      status = %ServiceStatus{
        timestamp: ~U[2026-10-06 02:15:06.216822Z],
        gateway_id: "gw-1",
        agent_id: "agent-1",
        service_id: "svc-synthetic-01",
        service_name: "Synthetic Plugin Check",
        service_type: "plugin",
        partition: "default",
        available: true,
        message: "all checks nominal",
        details: ~s({"summary":"all checks nominal"})
      }

      assert {:matched, updated_socket} = History.apply_status(socket, status, 20)
      assert [entry] = updated_socket.assigns.history
      assert entry["service_id"] == "svc-synthetic-01"
      assert entry["timestamp"] == "2026-10-06T02:15:06.216822Z"
      assert entry["message"] == "all checks nominal"
      assert entry["available"] == true
      refute Map.has_key?(entry, "__meta__")
      refute Map.has_key?(entry, "__metadata__")

      # Deduplicating identical status updates does not insert duplicates
      assert {:matched, deduped_socket} = History.apply_status(updated_socket, status, 20)
      assert length(deduped_socket.assigns.history) == 1
    end
  end
end
