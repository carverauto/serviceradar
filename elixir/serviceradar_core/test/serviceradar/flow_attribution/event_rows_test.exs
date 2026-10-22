defmodule ServiceRadar.FlowAttribution.EventRowsTest do
  use ExUnit.Case, async: true

  alias Serviceradar.Agent.Netprobe.V1.ExecutableOwnership
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias ServiceRadar.FlowAttribution.EventRows
  alias ServiceRadar.Inventory.EndpointPackageAssessmentIdentity
  alias ServiceRadar.Inventory.EndpointPackageIdentity

  test "attribution_key is socket-scoped (ignores pid/comm/container)" do
    base = %FlowAttributionEvent{
      local_ip: "10.42.0.1",
      local_port: 4000,
      remote_ip: "0.0.0.0",
      remote_port: 0,
      transport_protocol: "tcp",
      pid: 1787,
      tgid: 1787,
      uid: 0,
      gid: 0,
      comm: "k3s-agent",
      redacted_cmdline: ["/usr/local/bin/k3s"],
      container_id: "",
      observed_at_unix_nano: System.system_time(:nanosecond)
    }

    host = EventRows.from_event(base, "default", "agent-a")

    container =
      EventRows.from_event(
        %{base | pid: 99, comm: "beam.smp", container_id: String.duplicate("a", 64)},
        "default",
        "agent-a"
      )

    assert host.attribution_key == container.attribution_key
    assert host.pid == 1787
    assert container.pid == 99
  end

  defp listener(ownership) do
    %FlowAttributionEvent{
      local_ip: "192.0.2.10",
      local_port: 22,
      remote_ip: "198.51.100.20",
      remote_port: 51_000,
      transport_protocol: "tcp",
      pid: 4242,
      comm: "exampled",
      executable_ownership: ownership,
      observed_at_unix_nano: 1_790_000_000_000_000_000
    }
  end

  # The fields netprobe fills for a dpkg package on an invented Debian host.
  @resolved %ExecutableOwnership{
    resolution_state: :EXECUTABLE_OWNERSHIP_STATE_RESOLVED,
    source_scope: "host",
    package_type: "deb",
    package_manager: "dpkg",
    namespace: "debian",
    release: "bookworm",
    ecosystem: "",
    binary_package: "example-daemon",
    source_package: "example-src",
    architecture: "amd64",
    installed_version: "1:2.4.1-3",
    resolver: :EXECUTABLE_OWNERSHIP_RESOLVER_DPKG,
    executable_path: "/usr/sbin/exampled",
    executable_dev: 2049,
    executable_inode: 131_072
  }

  test "a resolved reference carries the identity key the matcher derives for the inventory package" do
    # The same package as the ScaLibr inventory stores it (no ecosystem), derived the
    # way the vulnerability matcher prepares inventory packages.
    inventory_package = %{
      name: "example-daemon",
      version: "1:2.4.1-3",
      architecture: "amd64",
      package_manager: "dpkg",
      ecosystem: nil,
      source_scope: "host",
      purl:
        "pkg:deb/debian/example-daemon@1%3A2.4.1-3?arch=amd64&distro=bookworm&source=example-src"
    }

    matcher_key =
      inventory_package
      |> Map.merge(EndpointPackageIdentity.from_package(inventory_package, nil))
      |> EndpointPackageAssessmentIdentity.key()

    row = EventRows.from_event(listener(@resolved), "default", "agent-a")

    assert %{
             "resolution_state" => "resolved",
             "resolver" => "dpkg",
             "binary_package" => "example-daemon",
             "installed_version" => "1:2.4.1-3",
             "executable_path" => "/usr/sbin/exampled",
             "executable_inode" => 131_072,
             "package_identity_key" => ^matcher_key
           } = row.executable_ownership
  end

  test "an unresolved reference names no package" do
    ownership = %{
      @resolved
      | resolution_state: :EXECUTABLE_OWNERSHIP_STATE_NOT_FOUND,
        detail: "not_owned",
        resolver: :EXECUTABLE_OWNERSHIP_RESOLVER_UNSPECIFIED
    }

    row = EventRows.from_event(listener(ownership), "default", "agent-a")

    assert row.executable_ownership == %{
             "resolution_state" => "not_found",
             "detail" => "not_owned",
             "source_scope" => "host",
             "executable_path" => "/usr/sbin/exampled",
             "executable_dev" => 2049,
             "executable_inode" => 131_072
           }
  end
end
