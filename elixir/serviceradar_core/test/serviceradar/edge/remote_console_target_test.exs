defmodule ServiceRadar.Edge.RemoteConsoleTargetTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteConsoleTarget

  test "builds provider-neutral metadata for a Proxmox SSH host target" do
    target =
      RemoteConsoleTarget.proxmox(
        %{uid: "sr:host-1", hostname: "pve01", ip: "192.0.2.10"},
        %{target_kind: :pve_host, console_mode: :ssh, agent_id: "agent-a"}
      )

    assert target.schema == RemoteConsoleTarget.schema()
    assert target.provider == "proxmox"
    assert target.target_ref == "proxmox:device:sr:host-1"
    assert target.target_type == "host"
    assert target.protocol == "ssh"
    assert target.transport == "pty"
    assert target.device_uid == "sr:host-1"
    assert target.agent_id == "agent-a"
    assert "resize" in target.capabilities

    assert target.metadata == %{
             "target_kind" => "pve_host",
             "console_mode" => "ssh",
             "hostname" => "pve01",
             "ip" => "192.0.2.10"
           }

    refute Map.has_key?(target.metadata, "identity_state")
  end

  test "preserves provider refs for hypervisor guest targets" do
    metadata =
      %{uid: "sr:guest-1"}
      |> RemoteConsoleTarget.proxmox(%{
        "target_kind" => "lxc_guest",
        "console_mode" => "proxmox_termproxy",
        "provider_ref" => "proxmox:cluster-a:guest:101"
      })
      |> RemoteConsoleTarget.to_metadata()

    assert metadata["schema"] == RemoteConsoleTarget.schema()
    assert metadata["provider"] == "proxmox"
    assert metadata["target_ref"] == "proxmox:cluster-a:guest:101"
    assert metadata["target_type"] == "guest"
    assert metadata["protocol"] == "proxmox-termproxy"
    assert metadata["transport"] == "pty"
    assert metadata["device_uid"] == "sr:guest-1"
    assert metadata["metadata"]["target_kind"] == "lxc_guest"
  end

  test "builds generic SSH device target metadata" do
    metadata =
      %{
        provider: "generic",
        device_uid: "sr:device-1",
        target_type: "device",
        protocol: "ssh",
        agent_id: "agent-site-a",
        capabilities: [:data, :resize, :close],
        metadata: %{hostname: "linux-1", ip: "10.0.0.10"}
      }
      |> RemoteConsoleTarget.build()
      |> RemoteConsoleTarget.to_metadata()

    assert metadata["schema"] == RemoteConsoleTarget.schema()
    assert metadata["provider"] == "generic"
    assert metadata["target_ref"] == "generic:device:sr:device-1"
    assert metadata["target_type"] == "device"
    assert metadata["protocol"] == "ssh"
    assert metadata["transport"] == "pty"
    assert metadata["agent_id"] == "agent-site-a"
    assert metadata["capabilities"] == ["data", "resize", "close"]
    assert metadata["metadata"] == %{"hostname" => "linux-1", "ip" => "10.0.0.10"}
  end
end
