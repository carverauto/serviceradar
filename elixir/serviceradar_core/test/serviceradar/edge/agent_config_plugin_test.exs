defmodule ServiceRadar.Edge.AgentConfigPluginTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator

  test "plugin config preserves github metadata on agent assignments" do
    assignment = %{
      assignment_id: "assign-1",
      plugin_id: "plugin-1",
      package_id: "package-1",
      version: "1.0.0",
      name: "HTTP Check",
      entrypoint: "run_check",
      runtime: nil,
      outputs: "serviceradar.plugin_result.v1",
      capabilities: [],
      params: %{},
      permissions: %{},
      resources: %{},
      enabled: true,
      interval_sec: 60,
      timeout_sec: 10,
      wasm_object_key: "plugins/http-check/1.0.0/package.wasm",
      content_hash: "abc123",
      source_type: "github",
      source_repo_url: "https://github.com/acme/demo",
      source_commit: "abc123",
      download_url: "https://internal/download"
    }

    config = AgentConfigGenerator.to_proto_plugin_config([assignment], %{})
    [proto] = config.assignments

    assert proto.source_repo_url == "https://github.com/acme/demo"
    assert proto.source_commit == "abc123"
  end
end
