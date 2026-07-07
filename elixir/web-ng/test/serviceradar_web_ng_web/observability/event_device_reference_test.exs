defmodule ServiceRadarWebNGWeb.Observability.EventDeviceReferenceTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Observability.EventDeviceReference

  # Pure parser: no database, so it can run in the db-free lane.
  @moduletag :db_free

  @device_uid "sr:5bf1b6f6-0e7c-43ac-b883-a13447199d85"

  describe "extract/1 with a Proxmox condition key" do
    test "extracts the device uid and guest label from a guest memory bottleneck" do
      event = %{
        "message" => "Proxmox guest memory bottleneck 95%",
        "log_provider" => "serviceradar-plugin",
        "unmapped" => %{"condition_key" => "proxmox:guest_memory:#{@device_uid}:qemu:116"}
      }

      assert %{uid: @device_uid, guest: "qemu:116", via: :condition_key} =
               EventDeviceReference.extract(event)
    end

    test "handles lxc guests" do
      event = %{"unmapped" => %{"condition_key" => "proxmox:guest_cpu:#{@device_uid}:lxc:200"}}

      assert %{uid: @device_uid, guest: "lxc:200"} = EventDeviceReference.extract(event)
    end

    test "extracts the device uid for node-scoped signals with no guest" do
      event = %{"unmapped" => %{"condition_key" => "proxmox:node_cpu:#{@device_uid}:pve1"}}

      assert %{uid: @device_uid, guest: nil} = EventDeviceReference.extract(event)
    end

    test "reads a condition key nested under metadata" do
      event = %{"metadata" => %{"condition_key" => "proxmox:node_memory:#{@device_uid}:pve1"}}

      assert %{uid: @device_uid} = EventDeviceReference.extract(event)
    end
  end

  describe "extract/1 with a structured device field" do
    test "prefers a canonical device_uid field over the condition key" do
      other_uid = "sr:11111111-2222-3333-4444-555555555555"

      event = %{
        "device_uid" => @device_uid,
        "unmapped" => %{"condition_key" => "proxmox:guest_memory:#{other_uid}:qemu:9"}
      }

      # uid comes from the structured field; guest is still surfaced from the key.
      assert %{uid: @device_uid, guest: "qemu:9", via: :structured} =
               EventDeviceReference.extract(event)
    end

    test "reads a device id nested under metadata.service_radar" do
      event = %{"metadata" => %{"service_radar" => %{"device_id" => @device_uid}}}

      assert %{uid: @device_uid, via: :structured} = EventDeviceReference.extract(event)
    end

    test "ignores a non-canonical device_id (hostname/agent) and does not link it" do
      event = %{"device_id" => "pve-host-01", "log_provider" => "syslog"}

      assert EventDeviceReference.extract(event) == nil
    end
  end

  describe "extract/1 with an anomaly finding series key" do
    test "decodes the device identity from a v2 series key" do
      series_key = "v2:identity=" <> Base.encode16(@device_uid)

      event = %{
        "log_provider" => "anomaly_detection",
        "metadata" => %{"detection_finding" => %{"series_key" => series_key}}
      }

      assert %{uid: @device_uid, via: :anomaly_series_key} = EventDeviceReference.extract(event)
    end
  end

  describe "extract/1 graceful degradation" do
    test "returns nil for a non-device signal (no crash)" do
      event = %{
        "message" => "RPZ blocked suspicious.example",
        "log_provider" => "ns03",
        "unmapped" => %{"condition_key" => "powerdns:rpz:suspicious.example"}
      }

      assert EventDeviceReference.extract(event) == nil
    end

    test "returns nil when a proxmox key carries a hostname prefix instead of an sr uid" do
      event = %{"unmapped" => %{"condition_key" => "proxmox:guest_memory:pve01.local:qemu:116"}}

      assert EventDeviceReference.extract(event) == nil
    end

    test "returns nil for events with no keys and does not raise" do
      assert EventDeviceReference.extract(%{}) == nil
      assert EventDeviceReference.extract(%{"unmapped" => %{}}) == nil
      assert EventDeviceReference.extract(nil) == nil
      assert EventDeviceReference.extract("not a map") == nil
    end

    test "rejects a malformed uid that is not a full uuid" do
      event = %{"unmapped" => %{"condition_key" => "proxmox:guest_memory:sr:not-a-uuid:qemu:1"}}

      assert EventDeviceReference.extract(event) == nil
    end
  end
end
