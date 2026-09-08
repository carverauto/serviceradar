defmodule ServiceRadarWebNGWeb.ServiceLiveModulesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.ServiceLive.Index.Data
  alias ServiceRadarWebNGWeb.ServiceLive.Service
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
end
