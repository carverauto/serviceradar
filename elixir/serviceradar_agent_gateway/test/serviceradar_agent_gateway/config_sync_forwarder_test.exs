defmodule ServiceRadarAgentGateway.ConfigSyncForwarderTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.ConfigSyncForwarder

  setup do
    test_pid = self()

    Application.put_env(:serviceradar_agent_gateway, :config_sync_rpc, fn function, args ->
      send(test_pid, {:config_sync, function, args})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:serviceradar_agent_gateway, :config_sync_rpc) end)

    :ok
  end

  test "sectioned ack forwards normalized per-section statuses" do
    ack = %Monitoring.ConfigAck{
      config_version: "v2",
      timestamp: 1_782_000_000,
      section_statuses: [
        %Monitoring.ConfigSectionStatus{section: "bumblebee", disposition: "success"},
        %Monitoring.ConfigSectionStatus{
          section: "visibility",
          disposition: "permanent_failure",
          error: "merge netprobe add-on config: cannot unmarshal string",
          since: 1_781_900_000
        }
      ]
    }

    assert :ok = ConfigSyncForwarder.record_config_ack("agent-1", ack)

    assert_receive {:config_sync, :record_config_ack, ["agent-1", attrs]}
    assert attrs.config_version == "v2"
    assert %DateTime{} = attrs.acked_at

    assert [
             %{"section" => "bumblebee", "disposition" => "success"},
             %{"section" => "visibility", "disposition" => "permanent_failure"} = failing
           ] = attrs.section_statuses

    assert failing["error"] =~ "cannot unmarshal string"
    assert failing["since"] =~ "2026"
  end

  test "legacy ack (no section statuses) forwards nil section detail" do
    ack = %Monitoring.ConfigAck{config_version: "v1", timestamp: 1_782_000_000}

    assert :ok = ConfigSyncForwarder.record_config_ack("agent-legacy", ack)

    assert_receive {:config_sync, :record_config_ack, ["agent-legacy", attrs]}
    assert attrs.config_version == "v1"
    assert attrs.section_statuses == nil
  end

  test "reported committed version forwards as a whole-version ack" do
    assert :ok = ConfigSyncForwarder.record_reported_version("agent-2", "v3")

    assert_receive {:config_sync, :record_config_ack, ["agent-2", attrs]}
    assert attrs.config_version == "v3"
    assert attrs.section_statuses == nil
  end

  test "config push forwards version and timestamp" do
    assert :ok = ConfigSyncForwarder.record_config_push("agent-3", "v4")

    assert_receive {:config_sync, :record_config_push, ["agent-3", attrs]}
    assert attrs.config_version == "v4"
    assert %DateTime{} = attrs.pushed_at
  end

  test "rpc errors are surfaced, not raised" do
    Application.put_env(:serviceradar_agent_gateway, :config_sync_rpc, fn _function, _args ->
      {:error, :core_unavailable}
    end)

    ack = %Monitoring.ConfigAck{config_version: "v1", timestamp: 0}
    assert {:error, :core_unavailable} = ConfigSyncForwarder.record_config_ack("agent-4", ack)
  end
end
