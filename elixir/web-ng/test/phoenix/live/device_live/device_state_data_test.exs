defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceStateDataTest do
  # Touches the shared ocsf_agents table; keep serial like DeviceLiveTest.
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceStateData

  describe "proxmox_console_target?/1" do
    test "recognizes Proxmox hosts and guests" do
      assert DeviceStateData.proxmox_console_target?(%{kind: :host, host: %{provider: "proxmox"}})
      assert DeviceStateData.proxmox_console_target?(%{kind: :guest, guest: %{provider: "proxmox"}})
      refute DeviceStateData.proxmox_console_target?(%{kind: :host, host: %{provider: "vsphere"}})
      refute DeviceStateData.proxmox_console_target?(%{kind: :guest, guest: %{provider: "vsphere"}})
      refute DeviceStateData.proxmox_console_target?(nil)
    end
  end

  describe "agent?/1 (render-time flag reader)" do
    test "is true only when the injected agent flag is set" do
      assert DeviceStateData.agent?(%{"agent_device" => true})
      refute DeviceStateData.agent?(%{"agent_device" => false})
      refute DeviceStateData.agent?(%{})
      refute DeviceStateData.agent?(nil)
    end

    test "ignores the dead OCSF agent_list column" do
      refute DeviceStateData.agent?(%{"agent_list" => [%{"uid" => "agent-1"}]})
    end
  end

  describe "agent_labels/1" do
    test "returns injected labels, dropping blanks" do
      assert DeviceStateData.agent_labels(%{"agent_labels" => ["a", "", nil, "b"]}) == ["a", "b"]
      assert DeviceStateData.agent_labels(%{"agent_labels" => "oops"}) == []
      assert DeviceStateData.agent_labels(%{}) == []
      assert DeviceStateData.agent_labels(nil) == []
    end
  end

  describe "ocsf_agents linkage helpers" do
    setup do
      unique = System.unique_integer([:positive])
      linked_uid = "dsd-agent-device-#{unique}"
      plain_uid = "dsd-plain-device-#{unique}"

      Repo.insert_all("ocsf_devices", [
        %{
          uid: linked_uid,
          type_id: 1,
          hostname: "dsd-agent-host-#{unique}",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        },
        %{
          uid: plain_uid,
          type_id: 1,
          hostname: "dsd-plain-host-#{unique}",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      Repo.insert_all("ocsf_agents", [
        %{
          uid: "dsd-agent-#{unique}",
          name: "DSD Agent #{unique}",
          type_id: 0,
          device_uid: linked_uid,
          status: "connected",
          is_healthy: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      %{unique: unique, linked_uid: linked_uid, plain_uid: plain_uid}
    end

    test "agent_device?/1 answers via the device_uid linkage", ctx do
      assert DeviceStateData.agent_device?(ctx.linked_uid)
      refute DeviceStateData.agent_device?(ctx.plain_uid)
      refute DeviceStateData.agent_device?("missing-device-uid")
      refute DeviceStateData.agent_device?("")
      refute DeviceStateData.agent_device?(nil)

      assert DeviceStateData.agent_device?(%{"uid" => ctx.linked_uid})
      refute DeviceStateData.agent_device?(%{"uid" => ctx.plain_uid})
      refute DeviceStateData.agent_device?(%{})
    end

    test "agent_device_uids/1 returns only linked uids", ctx do
      result =
        DeviceStateData.agent_device_uids([ctx.linked_uid, ctx.plain_uid, "", nil, ctx.linked_uid])

      assert MapSet.member?(result, ctx.linked_uid)
      refute MapSet.member?(result, ctx.plain_uid)
      assert DeviceStateData.agent_device_uids([]) == MapSet.new()
    end

    test "agent_directory/1 maps linked uids to agent labels", ctx do
      directory = DeviceStateData.agent_directory([ctx.linked_uid, ctx.plain_uid])

      assert directory == %{ctx.linked_uid => ["DSD Agent #{ctx.unique}"]}
    end

    test "tag_agent_device/2 injects flag and labels into device rows", ctx do
      results = [%{"uid" => ctx.linked_uid, "hostname" => "dsd-agent-host"}, "not-a-map"]

      assert [row, "not-a-map"] = DeviceStateData.tag_agent_device(results, ctx.linked_uid)
      assert row["agent_device"] == true
      assert row["agent_labels"] == ["DSD Agent #{ctx.unique}"]
      assert DeviceStateData.agent?(row)

      assert [plain_row] =
               DeviceStateData.tag_agent_device([%{"uid" => ctx.plain_uid}], ctx.plain_uid)

      assert plain_row["agent_device"] == false
      assert plain_row["agent_labels"] == []
      refute DeviceStateData.agent?(plain_row)

      assert DeviceStateData.tag_agent_device(nil, ctx.linked_uid) == nil
      assert DeviceStateData.tag_agent_device([%{}], nil) == [%{}]
    end
  end
end
