defmodule ServiceRadar.Inventory.IntegrationIdentityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.IntegrationIdentity

  @farm_integration_id "11111111-1111-4111-8111-111111111111"
  @farm_controller_id "22222222-2222-4222-8222-222222222222"
  @tonka_integration_id "33333333-3333-4333-8333-333333333333"
  @tonka_controller_id "44444444-4444-4444-8444-444444444444"

  describe "proxmox v3 source-scoped identities" do
    test "renders and parses canonical cluster, node, and guest refs" do
      assert {:ok, cluster} =
               IntegrationIdentity.proxmox_v3_fields(
                 @farm_integration_id,
                 @farm_controller_id,
                 "cluster/farm 01",
                 :cluster,
                 "cluster/farm 01"
               )

      assert cluster.provider_instance_ref ==
               "proxmox:v3:#{@farm_integration_id}:#{@farm_controller_id}:cluster%2Ffarm%2001"

      assert cluster.provider_ref ==
               "#{cluster.provider_instance_ref}:cluster:cluster%2Ffarm%2001"

      assert {:ok, node} =
               IntegrationIdentity.proxmox_v3_fields(
                 @farm_integration_id,
                 @farm_controller_id,
                 "cluster/farm 01",
                 :node,
                 "pve:a"
               )

      assert node.provider_ref == "#{cluster.provider_instance_ref}:node:pve%3Aa"
      assert {:ok, ^node} = IntegrationIdentity.parse_v3(node.provider_ref)
      assert IntegrationIdentity.v3?(node.provider_ref)

      assert {:ok, guest} =
               IntegrationIdentity.proxmox_v3_fields(
                 @farm_integration_id,
                 @farm_controller_id,
                 "cluster/farm 01",
                 :vm,
                 "00100"
               )

      assert guest.object_kind == "qemu"
      assert guest.native_object_id == "100"
      assert guest.provider_ref == "#{cluster.provider_instance_ref}:qemu:100"
    end

    test "keeps identical native identifiers distinct across integration/controller scopes" do
      assert {:ok, farm} =
               IntegrationIdentity.proxmox_v3_fields(
                 @farm_integration_id,
                 @farm_controller_id,
                 "lab",
                 :qemu,
                 155
               )

      assert {:ok, tonka} =
               IntegrationIdentity.proxmox_v3_fields(
                 @tonka_integration_id,
                 @tonka_controller_id,
                 "lab",
                 :qemu,
                 155
               )

      refute farm.provider_instance_ref == tonka.provider_instance_ref
      refute farm.provider_ref == tonka.provider_ref
      assert farm.native_cluster_id == tonka.native_cluster_id
      assert farm.native_object_id == tonka.native_object_id
    end

    test "rejects malformed, noncanonical, and mismatched structured refs" do
      assert {:error, :invalid_uuid} =
               IntegrationIdentity.proxmox_v3_fields(
                 "farm01",
                 @farm_controller_id,
                 "lab",
                 :node,
                 "pve01"
               )

      refute IntegrationIdentity.v3?(
               "proxmox:v3:#{@farm_integration_id}:#{@farm_controller_id}:lab:node:pve%30%31"
             )

      assert {:ok, identity} =
               IntegrationIdentity.proxmox_v3_fields(
                 @farm_integration_id,
                 @farm_controller_id,
                 "lab",
                 :node,
                 "pve01"
               )

      assert :ok = IntegrationIdentity.validate_v3_record(identity)

      assert {:error, :invalid_proxmox_v3_identity} =
               identity
               |> Map.put(:native_object_id, "pve02")
               |> IntegrationIdentity.validate_v3_record()

      assert {:error, :invalid_proxmox_v3_identity} =
               IntegrationIdentity.validate_v3_record(%{
                 provider_ref: identity.provider_ref,
                 identity_version: 3
               })
    end

    test "returns v2 and older refs only as lookup candidates" do
      assert {:ok, identity} =
               IntegrationIdentity.proxmox_v3_fields(
                 @farm_integration_id,
                 @farm_controller_id,
                 "cluster/farm01",
                 :qemu,
                 132
               )

      candidates =
        IntegrationIdentity.legacy_candidates(identity.provider_ref, %{
          node: "pve01",
          name: "dusk01",
          guest_type: "qemu"
        })

      assert "proxmox:v2:farm01:vm:132" in candidates
      assert "proxmox:guest:pve01:qemu:132" in candidates
      assert "proxmox:vm:dusk01" in candidates
      refute identity.provider_ref in candidates
    end
  end

  describe "proxmox_node_id/2" do
    test "mints the versioned cluster-scoped node id" do
      assert IntegrationIdentity.proxmox_node_id("farm01", "pve01") ==
               "proxmox:v2:farm01:node:pve01"
    end

    test "normalizes segments so case/format churn cannot rotate the id" do
      assert IntegrationIdentity.proxmox_node_id(" Farm01 ", "PVE01") ==
               "proxmox:v2:farm01:node:pve01"

      assert IntegrationIdentity.proxmox_node_id("lab cluster", "node:a") ==
               "proxmox:v2:lab-cluster:node:node-a"
    end

    test "returns nil when either segment is missing" do
      assert IntegrationIdentity.proxmox_node_id(nil, "pve01") == nil
      assert IntegrationIdentity.proxmox_node_id("farm01", nil) == nil
      assert IntegrationIdentity.proxmox_node_id("  ", "pve01") == nil
      assert IntegrationIdentity.proxmox_node_id("farm01", "") == nil
    end
  end

  describe "proxmox_guest_id/3" do
    test "mints vmid-keyed guest ids for qemu and lxc" do
      assert IntegrationIdentity.proxmox_guest_id("farm01", "qemu", 132) ==
               "proxmox:v2:farm01:vm:132"

      assert IntegrationIdentity.proxmox_guest_id("farm01", "lxc", 201) ==
               "proxmox:v2:farm01:lxc:201"
    end

    test "accepts already-normalized kinds and string vmids" do
      assert IntegrationIdentity.proxmox_guest_id("farm01", "vm", "132") ==
               "proxmox:v2:farm01:vm:132"

      assert IntegrationIdentity.proxmox_guest_id("farm01", "container", 201) ==
               "proxmox:v2:farm01:lxc:201"
    end

    test "returns nil when cluster, kind, or vmid are unusable" do
      assert IntegrationIdentity.proxmox_guest_id(nil, "qemu", 132) == nil
      assert IntegrationIdentity.proxmox_guest_id("farm01", nil, 132) == nil
      assert IntegrationIdentity.proxmox_guest_id("farm01", "qemu", nil) == nil
      assert IntegrationIdentity.proxmox_guest_id("farm01", "qemu", "abc") == nil
      assert IntegrationIdentity.proxmox_guest_id("farm01", "qemu", -1) == nil
    end
  end

  describe "v2?/1 and parse_v2/1" do
    test "recognizes v2 ids" do
      assert IntegrationIdentity.v2?("proxmox:v2:farm01:vm:132")
      refute IntegrationIdentity.v2?("proxmox:vm:dusk01")
      refute IntegrationIdentity.v2?(nil)
      refute IntegrationIdentity.v2?(132)
    end

    test "parses v2 ids into components" do
      assert {:ok, %{provider: "proxmox", cluster: "farm01", kind: "vm", ref: "132"}} =
               IntegrationIdentity.parse_v2("proxmox:v2:farm01:vm:132")

      assert {:ok, %{cluster: "farm01", kind: "node", ref: "pve01"}} =
               IntegrationIdentity.parse_v2("proxmox:v2:farm01:node:pve01")

      assert :error = IntegrationIdentity.parse_v2("proxmox:v2:farm01:vm")
      assert :error = IntegrationIdentity.parse_v2("proxmox:vm:dusk01")
      assert :error = IntegrationIdentity.parse_v2(nil)
    end
  end

  describe "legacy_candidates/2 for guests" do
    # Live-DB legacy generations this bridge must cover:
    #   gen 1 name-keyed:  proxmox:vm:dusk01, proxmox:container:traefik,
    #                      proxmox:vm:qemu/132 (id-as-name fallback)
    #   gen 2 MAC-keyed:   proxmox:vm:BC:24:11:BD:DA:44,
    #                      proxmox:container:BC:24:11:0E:62:C9
    #   gen 3 vmid-keyed:  proxmox:guest:<node>:<type>:<vmid>,
    #                      proxmox:<kind>:<node>:<vmid>, proxmox:<kind>:<vmid>
    test "covers all qemu guest generations" do
      candidates =
        IntegrationIdentity.legacy_candidates("proxmox:v2:farm01:vm:132", %{
          name: "dusk01",
          node: "pve01",
          guest_type: "qemu",
          macs: ["BC2411BDDA44"]
        })

      # gen 3 current-gen provider refs / uid-shaped ids (vmid-keyed)
      assert "proxmox:guest:pve01:qemu:132" in candidates
      assert "proxmox:qemu:pve01:132" in candidates
      assert "proxmox:vm:pve01:132" in candidates
      assert "proxmox:qemu:132" in candidates
      assert "proxmox:vm:132" in candidates

      # gen 1 id-as-name fallback (live: proxmox:vm:qemu/132)
      assert "proxmox:vm:qemu/132" in candidates

      # gen 2 MAC-keyed (live: proxmox:vm:BC:24:11:BD:DA:44)
      assert "proxmox:vm:BC:24:11:BD:DA:44" in candidates

      # gen 1 name-keyed (live: proxmox:vm:dusk01)
      assert "proxmox:vm:dusk01" in candidates

      # never echoes the v2 id back
      refute "proxmox:v2:farm01:vm:132" in candidates

      # name-keyed is the weakest evidence and must come last
      assert List.last(candidates) == "proxmox:vm:dusk01"

      # MAC-keyed outranks name-keyed but trails vmid-keyed forms
      mac_index = Enum.find_index(candidates, &(&1 == "proxmox:vm:BC:24:11:BD:DA:44"))
      vmid_index = Enum.find_index(candidates, &(&1 == "proxmox:guest:pve01:qemu:132"))
      name_index = Enum.find_index(candidates, &(&1 == "proxmox:vm:dusk01"))
      assert vmid_index < mac_index
      assert mac_index < name_index
    end

    test "covers all lxc guest generations (container naming)" do
      candidates =
        IntegrationIdentity.legacy_candidates("proxmox:v2:farm01:lxc:201", %{
          "name" => "traefik",
          "node" => "pve02",
          "guest_type" => "lxc",
          "macs" => ["bc:24:11:0e:62:c9"]
        })

      assert "proxmox:guest:pve02:lxc:201" in candidates
      assert "proxmox:lxc:pve02:201" in candidates
      assert "proxmox:container:pve02:201" in candidates
      assert "proxmox:lxc:201" in candidates
      assert "proxmox:container:201" in candidates
      assert "proxmox:container:lxc/201" in candidates

      # gen 2 MAC-keyed, colon-separated uppercase regardless of input format
      assert "proxmox:container:BC:24:11:0E:62:C9" in candidates

      # gen 1 name-keyed (live: proxmox:container:traefik)
      assert List.last(candidates) == "proxmox:container:traefik"
    end

    test "normalizes multi-format MAC inputs and drops invalid ones" do
      candidates =
        IntegrationIdentity.legacy_candidates("proxmox:v2:farm01:vm:140", %{
          macs: ["bc-24-11-23-3a-0d", "not-a-mac"],
          mac: "BC:24:11:25:77:A5"
        })

      assert "proxmox:vm:BC:24:11:23:3A:0D" in candidates
      assert "proxmox:vm:BC:24:11:25:77:A5" in candidates
      refute Enum.any?(candidates, &String.contains?(&1, "not-a-mac"))
    end

    test "falls back to the vmid from the v2 id when fields omit it" do
      candidates = IntegrationIdentity.legacy_candidates("proxmox:v2:farm01:vm:146", %{})

      assert "proxmox:vm:146" in candidates
      assert "proxmox:qemu:146" in candidates
      assert "proxmox:vm:qemu/146" in candidates
      # no node/name/macs -> no node-scoped, MAC- or name-keyed forms
      refute Enum.any?(candidates, &String.starts_with?(&1, "proxmox:guest:"))
    end
  end

  describe "legacy_candidates/2 for nodes" do
    test "covers node provider refs, pve placeholders, and gen-1 hypervisor ids" do
      candidates =
        IntegrationIdentity.legacy_candidates("proxmox:v2:farm01:node:pve01", %{name: "pve01"})

      # gen 3 provider ref + placeholder uid forms
      assert "proxmox:node:pve01" in candidates
      assert "proxmox:pve:pve01" in candidates

      # gen 1 host form (live: proxmox:hypervisor:pve01)
      assert "proxmox:hypervisor:pve01" in candidates
    end

    test "includes forms for a differing record name (for example an FQDN)" do
      candidates =
        IntegrationIdentity.legacy_candidates("proxmox:v2:farm01:node:pve01", %{
          name: "pve01.example.com"
        })

      assert "proxmox:hypervisor:pve01" in candidates
      assert "proxmox:hypervisor:pve01.example.com" in candidates
    end
  end

  describe "legacy_candidates/2 edge cases" do
    test "returns no candidates for non-v2 or missing ids" do
      assert IntegrationIdentity.legacy_candidates("proxmox:vm:dusk01", %{name: "dusk01"}) == []
      assert IntegrationIdentity.legacy_candidates(nil, %{name: "dusk01"}) == []
      assert IntegrationIdentity.legacy_candidates("proxmox:v2:bad", %{}) == []
    end

    test "deduplicates and drops blank values" do
      candidates =
        IntegrationIdentity.legacy_candidates("proxmox:v2:farm01:vm:132", %{
          name: "  ",
          node: "pve01",
          guest_type: "qemu"
        })

      assert candidates == Enum.uniq(candidates)
      refute Enum.any?(candidates, &(String.trim(&1) == ""))
      refute Enum.any?(candidates, &String.ends_with?(&1, ":"))
    end
  end

  describe "lookup_values/1" do
    test "returns the canonical id first and legacy bridges last" do
      assert IntegrationIdentity.lookup_values(%{
               integration_id: "proxmox:v2:farm01:vm:132",
               legacy_integration_ids: ["proxmox:vm:dusk01", "proxmox:vm:qemu/132"]
             }) == [
               "proxmox:v2:farm01:vm:132",
               "proxmox:vm:dusk01",
               "proxmox:vm:qemu/132"
             ]
    end

    test "accepts string keys, list primaries, and deduplicates" do
      assert IntegrationIdentity.lookup_values(%{
               "integration_id" => ["proxmox:v2:farm01:vm:132", "proxmox:guest:pve01:qemu:132"],
               "legacy_integration_ids" => ["proxmox:guest:pve01:qemu:132", "", nil]
             }) == [
               "proxmox:v2:farm01:vm:132",
               "proxmox:guest:pve01:qemu:132"
             ]
    end

    test "handles missing keys and non-map input" do
      assert IntegrationIdentity.lookup_values(%{integration_id: "proxmox:v2:c:vm:1"}) ==
               ["proxmox:v2:c:vm:1"]

      assert IntegrationIdentity.lookup_values(%{}) == []
      assert IntegrationIdentity.lookup_values(nil) == []
    end
  end
end
