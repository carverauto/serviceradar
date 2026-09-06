defmodule ServiceRadar.Inventory.Identity.IdsProxmoxGuardTest do
  @moduledoc """
  The GitHub #4051 guard: ambiguous name-keyed Proxmox integration ids are
  never integration_id lookup values.

  Two clusters reuse guest and node names, so `proxmox:vm:<name>` and kin
  matched devices from different clusters onto one row. Filtering happens in
  `Ids.get_identifier_values/2`, which every resolution path consults
  (Resolver, BatchResolver, Registrar conflict checks, sync lookups).
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.Ids

  defp ids(metadata) do
    Ids.extract_strong_identifiers(%{
      metadata: metadata,
      ip: "10.0.0.1",
      mac: nil,
      partition: "default"
    })
  end

  describe "get_identifier_values(:integration_id, ids)" do
    test "drops stale bare-name bridges but keeps scoped values" do
      values =
        %{
          "integration_id" => "proxmox:v2:farm01:vm:113",
          "integration_type" => "proxmox",
          "legacy_integration_ids" => [
            # stale gen-1 bridge from a pre-fix producer: must never match
            "proxmox:vm:k8s-cp3-worker1",
            "proxmox:hypervisor:pve01",
            # vmid-scoped and MAC-keyed bridges still resolve
            "proxmox:vm:113",
            "proxmox:vm:qemu/113",
            "proxmox:guest:pve01:qemu:113",
            "proxmox:vm:BC:24:11:BD:DA:44"
          ]
        }
        |> ids()
        |> then(&Ids.get_identifier_values(:integration_id, &1))

      assert "proxmox:v2:farm01:vm:113" in values
      assert "proxmox:vm:113" in values
      assert "proxmox:vm:qemu/113" in values
      assert "proxmox:guest:pve01:qemu:113" in values
      assert "proxmox:vm:BC:24:11:BD:DA:44" in values

      refute "proxmox:vm:k8s-cp3-worker1" in values
      refute "proxmox:hypervisor:pve01" in values
    end

    test "an ambiguous primary never resolves either" do
      values =
        %{
          "integration_id" => "proxmox:vm:k8s-cp3-worker1",
          "integration_type" => "proxmox"
        }
        |> ids()
        |> then(&Ids.get_identifier_values(:integration_id, &1))

      assert values == []
    end

    test "leaves other sources untouched" do
      values =
        %{
          "integration_id" => "netbox:device:42",
          "integration_type" => "netbox"
        }
        |> ids()
        |> then(&Ids.get_identifier_values(:integration_id, &1))

      assert values == ["netbox:device:42"]
    end
  end
end
