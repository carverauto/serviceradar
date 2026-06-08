defmodule ServiceRadar.EventWriter.StateChangePublisherTest do
  # async: false — toggles the global application/system env for the feed flag.
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.StateChangePublisher

  setup do
    prior_app = Application.get_env(:serviceradar_core, :state_change_events_enabled)
    prior_env = System.get_env("STATE_CHANGE_EVENTS_ENABLED")

    on_exit(fn ->
      if is_nil(prior_app) do
        Application.delete_env(:serviceradar_core, :state_change_events_enabled)
      else
        Application.put_env(:serviceradar_core, :state_change_events_enabled, prior_app)
      end

      if is_nil(prior_env) do
        System.delete_env("STATE_CHANGE_EVENTS_ENABLED")
      else
        System.put_env("STATE_CHANGE_EVENTS_ENABLED", prior_env)
      end
    end)

    Application.delete_env(:serviceradar_core, :state_change_events_enabled)
    System.delete_env("STATE_CHANGE_EVENTS_ENABLED")
    :ok
  end

  describe "enabled?/0" do
    test "defaults to disabled" do
      refute StateChangePublisher.enabled?()
    end

    test "honors the application env" do
      Application.put_env(:serviceradar_core, :state_change_events_enabled, true)
      assert StateChangePublisher.enabled?()
    end

    test "honors the STATE_CHANGE_EVENTS_ENABLED env var" do
      System.put_env("STATE_CHANGE_EVENTS_ENABLED", "true")
      assert StateChangePublisher.enabled?()
    end
  end

  describe "publish_transition/3" do
    test "no-ops (returns :ok) when the feed is disabled" do
      assert :ok =
               StateChangePublisher.publish_transition("ocsf_devices", "sr:device:abc",
                 field: "is_available",
                 old: true,
                 new: false
               )
    end

    test "no-ops on an unusable entity id even when enabled" do
      Application.put_env(:serviceradar_core, :state_change_events_enabled, true)

      assert :ok =
               StateChangePublisher.publish_transition("ocsf_devices", nil, field: "is_available")

      assert :ok =
               StateChangePublisher.publish_transition("ocsf_devices", "", field: "is_available")

      assert :ok =
               StateChangePublisher.publish_transition("ocsf_devices", "   ",
                 field: "is_available"
               )
    end
  end

  describe "build_envelope/3" do
    test "builds a normalized signals.state envelope" do
      env =
        StateChangePublisher.build_envelope("ocsf_devices", "sr:device:abc",
          field: "is_available",
          old: true,
          new: false,
          partition_id: "default",
          entity_type: "device"
        )

      assert env["schema_version"] == "1.0"
      assert env["signal_type"] == "state_change"
      assert env["event_type"] == "state_transition"
      assert env["primary_domain"] == "data_change"
      assert env["signal_domains"] == ["data_change"]
      assert env["source"]["subject"] == "signals.state.ocsf_devices"
      assert env["source"]["collector"] == "serviceradar_core"

      assert env["source_identity"] == %{
               "table" => "ocsf_devices",
               "entity_uid" => "sr:device:abc",
               "entity_type" => "device"
             }

      assert is_binary(env["event_identity"])
      assert %DateTime{} = env["event_time"]
      assert is_integer(env["seq"])

      assert env["routing_correlation"]["table"] == "ocsf_devices"
      assert env["routing_correlation"]["record_id"] == "sr:device:abc"
      assert env["routing_correlation"]["partition_id"] == "default"
      assert env["routing_correlation"]["topology_keys"] == ["ocsf_devices", "sr:device:abc"]

      assert env["explainability"]["field"] == "is_available"
      assert env["explainability"]["old"] == true
      assert env["explainability"]["new"] == false
      assert env["explainability"]["changed_fields"] == ["is_available"]
    end

    test "normalizes atom transition values and merges extra context with string keys" do
      env =
        StateChangePublisher.build_envelope("health_events", "gateway-1",
          field: "state",
          old: :healthy,
          new: :degraded,
          entity_type: "gateway",
          extra: %{reason: "poll timeout"}
        )

      assert env["explainability"]["old"] == "healthy"
      assert env["explainability"]["new"] == "degraded"
      assert env["explainability"]["reason"] == "poll timeout"
    end

    test "produces a JSON-encodable envelope" do
      env =
        StateChangePublisher.build_envelope("service_state", "agent-1:grpc:foo",
          field: "available",
          old: true,
          new: false
        )

      assert {:ok, json} = Jason.encode(env)
      assert is_binary(json)
    end
  end
end
