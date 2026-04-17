defmodule ServiceRadar.Observability.MtrAutomationDispatcherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.MtrAutomationDispatcher

  describe "classify_transition/2" do
    test "classifies healthy to degraded as incident" do
      assert {:incident, "degraded"} =
               MtrAutomationDispatcher.classify_transition(:healthy, :degraded)
    end

    test "classifies healthy to unavailable as incident" do
      assert {:incident, "unavailable"} =
               MtrAutomationDispatcher.classify_transition(:healthy, :unavailable)
    end

    test "classifies degraded to healthy as recovery" do
      assert {:recovery, "recovery"} =
               MtrAutomationDispatcher.classify_transition(:degraded, :healthy)
    end

    test "ignores non-actionable transitions" do
      assert :ignore = MtrAutomationDispatcher.classify_transition(:healthy, :healthy)
      assert :ignore = MtrAutomationDispatcher.classify_transition(:degraded, :offline)
    end
  end

  describe "target_ctx_from_health_event/1" do
    test "extracts explicit target metadata" do
      event = %{
        entity_type: :checker,
        entity_id: "check-1",
        metadata: %{
          "target" => "google.com",
          "target_ip" => "8.8.8.8",
          "target_device_uid" => "dev-1",
          "partition_id" => "p1"
        }
      }

      assert {:ok, ctx} = MtrAutomationDispatcher.target_ctx_from_health_event(event)
      assert ctx.target == "google.com"
      assert ctx.target_ip == "8.8.8.8"
      assert ctx.target_device_uid == "dev-1"
      assert ctx.partition_id == "p1"
      assert ctx.target_key == "device:dev-1"
    end

    test "falls back to entity ip for target" do
      event = %{entity_type: :custom, entity_id: "1.1.1.1", metadata: %{}}

      assert {:ok, ctx} = MtrAutomationDispatcher.target_ctx_from_health_event(event)
      assert ctx.target == "1.1.1.1"
      assert ctx.target_ip == "1.1.1.1"
      assert ctx.target_key == "ip:1.1.1.1"
    end

    test "returns error when no target can be inferred" do
      event = %{entity_type: :custom, entity_id: "service-abc", metadata: %{}}

      assert {:error, :missing_target} =
               MtrAutomationDispatcher.target_ctx_from_health_event(event)
    end
  end

  describe "target_contexts_from_srql/3" do
    test "normalizes device SRQL queries and materializes target contexts" do
      translate_fn = fn "in:devices tags.role:edge limit:25", 25, nil, nil, nil ->
        {:ok,
         Jason.encode!(%{
           "sql" => "select ip, hostname, uid, partition_id, gateway_id from devices",
           "params" => []
         })}
      end

      query_fn = fn "select ip, hostname, uid, partition_id, gateway_id from devices", [] ->
        {:ok,
         %Postgrex.Result{
           columns: ["ip", "hostname", "uid", "partition_id", "gateway_id"],
           rows: [
             ["192.0.2.10", "edge-01", "dev-1", "p1", "gw-1"],
             ["192.0.2.11", nil, "dev-2", nil, nil]
           ]
         }}
      end

      assert {:ok, targets} =
               MtrAutomationDispatcher.target_contexts_from_srql("tags.role:edge", 25,
                 translate_fn: translate_fn,
                 query_fn: query_fn
               )

      assert targets == [
               %{
                 target: "edge-01",
                 target_ip: "192.0.2.10",
                 target_device_uid: "dev-1",
                 partition_id: "p1",
                 gateway_id: "gw-1",
                 target_key: "device:dev-1"
               },
               %{
                 target: "192.0.2.11",
                 target_ip: "192.0.2.11",
                 target_device_uid: "dev-2",
                 partition_id: "default",
                 gateway_id: nil,
                 target_key: "device:dev-2"
               }
             ]
    end

    test "returns SRQL errors" do
      translate_fn = fn "in:devices hostname:bad limit:10", 10, nil, nil, nil ->
        {:error, :bad_query}
      end

      assert {:error, :bad_query} =
               MtrAutomationDispatcher.target_contexts_from_srql("hostname:bad", 10,
                 translate_fn: translate_fn
               )
    end
  end
end
