defmodule ServiceRadar.Inventory.Remediation.DecisionsTest do
  @moduledoc """
  Unit coverage for the pure decision functions behind
  `mix serviceradar.dire_remediation` (DIRE tasks 4.1-4.4).
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.Remediation.Decisions

  describe "valid_mac_value?/1 and purgeable_mac_value?/1 (blob detection)" do
    test "accepts an atomic 12-hex uppercase value" do
      assert Decisions.valid_mac_value?("001AA0B94040")
      refute Decisions.purgeable_mac_value?("001AA0B94040")
    end

    test "rejects comma blobs" do
      refute Decisions.valid_mac_value?("001AA0B94040,001422F42A2A")
      assert Decisions.purgeable_mac_value?("001AA0B94040,001422F42A2A")
    end

    test "rejects wrong length, lowercase, non-hex, nil" do
      refute Decisions.valid_mac_value?("001AA0B940")
      refute Decisions.valid_mac_value?("001aa0b94040")
      refute Decisions.valid_mac_value?("ZZ1AA0B94040")
      refute Decisions.valid_mac_value?(nil)
      assert Decisions.purgeable_mac_value?(nil)
    end
  end

  describe "mac_blob?/1" do
    test "detects multi-value blobs" do
      assert Decisions.mac_blob?("001AA0B94040,001422F42A2A")
      assert Decisions.mac_blob?("001AA0B94040 001422F42A2A")
      refute Decisions.mac_blob?("001AA0B94040")
      refute Decisions.mac_blob?(nil)
    end
  end

  describe "first_mac_from_blob/1 (extraction)" do
    test "extracts the first MAC of a comma blob" do
      assert Decisions.first_mac_from_blob("001AA0B94040,001422F42A2A,70B3D59EDC93") ==
               "001AA0B94040"
    end

    test "skips invalid leading entries" do
      assert Decisions.first_mac_from_blob("garbage,001422F42A2A") == "001422F42A2A"
    end

    test "normalizes separators" do
      assert Decisions.first_mac_from_blob("00:1a:a0:b9:40:40,001422F42A2A") == "001AA0B94040"
    end

    test "returns nil when no valid MAC exists" do
      assert Decisions.first_mac_from_blob("garbage,also-garbage") == nil
      assert Decisions.first_mac_from_blob(nil) == nil
    end
  end

  defp debris_agent(overrides) do
    Map.merge(
      %{
        uid: "test-agent-1290",
        device_uid: nil,
        status: :unavailable,
        created_time: ~U[2026-04-25 02:19:22Z]
      },
      overrides
    )
  end

  describe "debris_agent?/2" do
    test "matches a named-pattern row with NULL device_uid on the debris date" do
      assert Decisions.debris_agent?(debris_agent(%{}))
      assert Decisions.debris_agent?(debris_agent(%{uid: "local-config-agent-2058"}))
      assert Decisions.debris_agent?(debris_agent(%{uid: "recover-agent-778"}))
      assert Decisions.debris_agent?(debris_agent(%{uid: "new-heartbeat-agent-10"}))
    end

    test "named patterns require a blank device_uid" do
      refute Decisions.debris_agent?(debris_agent(%{device_uid: "sr:abc"}))
      assert Decisions.debris_agent?(debris_agent(%{device_uid: "  "}))
    end

    test "simulation patterns may carry a device link" do
      assert Decisions.debris_agent?(
               debris_agent(%{uid: "agent-active-ip-conflict-3594", device_uid: "sr:abc"})
             )

      assert Decisions.debris_agent?(
               debris_agent(%{uid: "agent-active-ip-owner-3", device_uid: "sr:abc"})
             )
    end

    test "never matches active or off-date rows" do
      refute Decisions.debris_agent?(debris_agent(%{status: :connected}))
      refute Decisions.debris_agent?(debris_agent(%{status: "connected"}))
      refute Decisions.debris_agent?(debris_agent(%{created_time: ~U[2026-06-09 00:00:00Z]}))
      refute Decisions.debris_agent?(debris_agent(%{created_time: nil}))
    end

    test "never matches real agents" do
      refute Decisions.debris_agent?(
               debris_agent(%{uid: "agent-k8s-cp2-worker1", device_uid: nil})
             )
    end

    test "patterns are configurable" do
      agent = debris_agent(%{uid: "my-sim-agent-1"})
      refute Decisions.debris_agent?(agent)
      assert Decisions.debris_agent?(agent, null_device_patterns: ["my-sim-agent-"])
    end
  end

  describe "debris_device?/2" do
    test "matches reip agent ids and fake pod hostnames" do
      assert Decisions.debris_device?(%{agent_id: "agent-reip-904", hostname: "k8s-pod-x"})
      assert Decisions.debris_device?(%{agent_id: nil, hostname: "k8s-pod-b"})
      assert Decisions.debris_device?(%{agent_id: nil, hostname: "K8S-POD-A"})
      refute Decisions.debris_device?(%{agent_id: "agent-k8s-cp2-worker1", hostname: "worker1"})
      refute Decisions.debris_device?(%{agent_id: nil, hostname: nil})
    end
  end

  describe "hostname matching (agent-links)" do
    test "normalize_hostname/1 trims, lowercases, and rejects blanks" do
      assert Decisions.normalize_hostname("  K8S-CP2-Worker1 ") == "k8s-cp2-worker1"
      assert Decisions.normalize_hostname("") == nil
      assert Decisions.normalize_hostname("   ") == nil
      assert Decisions.normalize_hostname(nil) == nil
    end

    test "expected_hostname/1 prefers host over name" do
      assert Decisions.expected_hostname(%{host: "Dusk01", name: "other"}) == "dusk01"
      assert Decisions.expected_hostname(%{host: nil, name: "dusk01"}) == "dusk01"
      assert Decisions.expected_hostname(%{host: "", name: nil}) == nil
    end

    test "device_matches_host?/2 requires live device with the expected hostname" do
      live = %{hostname: "k8s-cp2-worker3", deleted_at: nil}
      tombstone = %{hostname: "k8s-cp2-worker3", deleted_at: ~U[2026-06-04 21:41:01Z]}

      assert Decisions.device_matches_host?(live, "k8s-cp2-worker3")
      refute Decisions.device_matches_host?(live, "k8s-cp2-worker1")
      refute Decisions.device_matches_host?(tombstone, "k8s-cp2-worker3")
      refute Decisions.device_matches_host?(nil, "k8s-cp2-worker3")
      refute Decisions.device_matches_host?(live, nil)
    end

    test "choose_device_owner/2 picks the hostname-matching agent of a shared device" do
      agents = [
        %{uid: "agent-k8s-cp2-worker2", host: "k8s-cp2-worker2"},
        %{uid: "agent-k8s-cp2-worker3", host: "k8s-cp2-worker3"},
        %{uid: "agent-k8s-cp2-worker1", host: "k8s-cp2-worker1"}
      ]

      owner = Decisions.choose_device_owner(agents, "k8s-cp2-worker3")
      assert owner.uid == "agent-k8s-cp2-worker3"

      assert Decisions.choose_device_owner(agents, "elsewhere") == nil
      assert Decisions.choose_device_owner(agents, nil) == nil
    end
  end

  describe "valid_ip?/1" do
    test "accepts v4/v6, rejects literals" do
      assert Decisions.valid_ip?("10.0.2.8")
      assert Decisions.valid_ip?("fe80::1")
      refute Decisions.valid_ip?("agent")
      refute Decisions.valid_ip?("")
      refute Decisions.valid_ip?(nil)
    end
  end

  describe "proxmox duplicate grouping and canonical selection" do
    test "duplicate_hostname_groups/2 groups by normalized hostname, size > 1" do
      devices = [
        %{uid: "sr:a", hostname: "Traefik"},
        %{uid: "sr:b", hostname: "traefik "},
        %{uid: "sr:c", hostname: "solo"},
        %{uid: "sr:d", hostname: nil},
        %{uid: "sr:e", hostname: "localhost"},
        %{uid: "sr:f", hostname: "localhost"}
      ]

      assert [{"traefik", group}] = Decisions.duplicate_hostname_groups(devices)
      assert group |> Enum.map(& &1.uid) |> Enum.sort() == ["sr:a", "sr:b"]
    end

    test "select_canonical/2 prefers agent-linked, then most recent, then uid" do
      old = %{uid: "sr:old", last_seen_time: ~U[2026-05-09 02:21:03Z]}
      new = %{uid: "sr:new", last_seen_time: ~U[2026-06-10 11:15:43Z]}
      linked = %{uid: "sr:linked", last_seen_time: ~U[2026-01-01 00:00:00Z]}

      assert Decisions.select_canonical([old, new], MapSet.new()).uid == "sr:new"

      assert Decisions.select_canonical([old, new, linked], MapSet.new(["sr:linked"])).uid ==
               "sr:linked"

      tie_a = %{uid: "sr:a", last_seen_time: nil}
      tie_b = %{uid: "sr:b", last_seen_time: nil}
      assert Decisions.select_canonical([tie_b, tie_a], MapSet.new()).uid == "sr:a"
    end
  end

  defp dev(macs, refs), do: %{macs: MapSet.new(macs), host_refs: MapSet.new(refs)}

  describe "same_physical_host?/2 (proxmox merge corroboration)" do
    test "corroborated by a shared vmid-scoped reference" do
      a = dev([], ["proxmox:v2:farm01:node:pve02"])
      b = dev([], ["proxmox:v2:farm01:node:pve02"])
      assert Decisions.same_physical_host?(a, b)
    end

    test "a shared bare-name token never corroborates (GitHub #4051)" do
      # pve02 names a node in two different clusters: sharing the
      # name-keyed token is the cross-cluster fusion, not same-host evidence.
      a = dev([], ["proxmox:hypervisor:pve02"])
      b = dev([], ["proxmox:hypervisor:pve02"])
      refute Decisions.same_physical_host?(a, b)

      c = dev([], ["proxmox:vm:k8s-cp3-worker1"])
      d = dev([], ["proxmox:vm:k8s-cp3-worker1"])
      refute Decisions.same_physical_host?(c, d)

      e = dev([], ["proxmox:node:pve01"])
      f = dev([], ["proxmox:node:pve01"])
      refute Decisions.same_physical_host?(e, f)
    end

    test "an ambiguous token alongside a shared strong token still corroborates" do
      a = dev([], ["proxmox:hypervisor:pve02", "proxmox:v2:farm01:node:pve02"])
      b = dev([], ["proxmox:hypervisor:pve02", "proxmox:v2:farm01:node:pve02"])
      assert Decisions.same_physical_host?(a, b)
    end

    test "corroborated by a shared MAC" do
      a = dev(["001AA0B94040"], [])
      b = dev(["001AA0B94040"], [])
      assert Decisions.same_physical_host?(a, b)
    end

    test "a shared unscoped VMID cannot corroborate integration_id churn" do
      old = dev([], ["proxmox:vm:901"])
      new = dev([], ["proxmox:hypervisor:host01.example.com", "proxmox:vm:901"])
      refute Decisions.same_physical_host?(old, new)
    end

    test "distinct cluster references are NOT the same host" do
      farm = dev([], ["proxmox:hypervisor:farm01:pve02"])
      tonka = dev([], ["proxmox:hypervisor:tonka01:pve02"])
      refute Decisions.same_physical_host?(farm, tonka)
    end

    test "no shared identity at all is NOT the same host" do
      refute Decisions.same_physical_host?(dev([], []), dev([], []))
    end

    test "distinct MACs are NOT the same host" do
      refute Decisions.same_physical_host?(dev(["001AA0B94040"], []), dev(["001422F42A2A"], []))
    end
  end

  describe "identity_components/1" do
    test "same-hostname rows from different clusters stay in separate components" do
      farm = %{uid: "sr:farm-pve02", macs: MapSet.new(), host_refs: MapSet.new(["farm01:pve02"])}
      tonka_a = %{uid: "sr:tonka-a", macs: MapSet.new(), host_refs: MapSet.new(["tonka01:pve02"])}
      tonka_b = %{uid: "sr:tonka-b", macs: MapSet.new(), host_refs: MapSet.new(["tonka01:pve02"])}

      components = Decisions.identity_components([farm, tonka_a, tonka_b])

      # farm01/pve02 is its own singleton; the two tonka01/pve02 rows form one
      # component and are the only pair eligible to merge.
      assert length(components) == 2

      farm_component =
        Enum.find(components, fn c -> Enum.any?(c, &(&1.uid == "sr:farm-pve02")) end)

      assert length(farm_component) == 1

      tonka_component =
        Enum.find(components, fn c -> Enum.any?(c, &(&1.uid == "sr:tonka-a")) end)

      assert MapSet.new(Enum.map(tonka_component, & &1.uid)) ==
               MapSet.new(["sr:tonka-a", "sr:tonka-b"])
    end

    test "identity-less rows each form their own singleton component" do
      a = %{uid: "sr:a", macs: MapSet.new(), host_refs: MapSet.new()}
      b = %{uid: "sr:b", macs: MapSet.new(), host_refs: MapSet.new()}

      assert [a, b] |> Decisions.identity_components() |> Enum.map(&length/1) == [1, 1]
    end

    test "transitively unions rows sharing overlapping reference tokens" do
      a = %{uid: "sr:a", macs: MapSet.new(), host_refs: MapSet.new(["r1"])}
      b = %{uid: "sr:b", macs: MapSet.new(), host_refs: MapSet.new(["r1", "r2"])}
      c = %{uid: "sr:c", macs: MapSet.new(), host_refs: MapSet.new(["r2"])}

      assert [component] = Decisions.identity_components([a, b, c])
      assert MapSet.new(Enum.map(component, & &1.uid)) == MapSet.new(["sr:a", "sr:b", "sr:c"])
    end
  end

  describe "plan_proxmox_unfuse/3 (proxmox-unfuse step, GitHub #4051)" do
    defp fused_device(overrides \\ %{}) do
      Map.merge(
        %{uid: "sr:fused", partition: "default", tombstoned?: false},
        overrides
      )
    end

    defp v2_row(id, value, source_id, first_seen) do
      %{id: id, value: value, partition: "default", first_seen: first_seen, source_id: source_id}
    end

    defp mac_row(id, value, source_id) do
      %{id: id, value: value, partition: "default", source_id: source_id}
    end

    @farm_v2 "proxmox:v2:farm01:vm:113"
    @tonka_v2 "proxmox:v2:tonka:vm:117"
    @farm_source "proxmox-farm01"
    @tonka_source "proxmox-tonka"
    @farm_seen ~U[2026-05-01 00:00:00Z]
    @tonka_seen ~U[2026-06-01 00:00:00Z]

    defp fused_rows do
      {[
         v2_row(1, @farm_v2, @farm_source, @farm_seen),
         v2_row(2, @tonka_v2, @tonka_source, @tonka_seen)
       ], [mac_row(10, "BC241176DF7E", @farm_source), mac_row(11, "BC2411AABBCC", @tonka_source)]}
    end

    test "splits cross-cluster v2 groups; earliest cluster survives" do
      {v2_rows, mac_rows} = fused_rows()

      assert {:split, plan} = Decisions.plan_proxmox_unfuse(fused_device(), v2_rows, mac_rows)

      assert plan.device_uid == "sr:fused"
      assert plan.survivor == %{cluster: "farm01", uid: "sr:fused", row_ids: [1]}
      assert [split] = plan.splits
      assert split.cluster == "tonka"
      assert split.v2_values == [@tonka_v2]
      assert split.row_ids == [2]
      assert split.mac_row_ids == [11]

      expected_uid =
        Ids.generate_deterministic_device_id(%{integration_id: @tonka_v2, partition: "default"})

      assert split.new_uid == expected_uid
      refute split.new_uid == "sr:fused"
    end

    test "single-cluster devices are not over-merges" do
      {[farm_row, _], [_farm_mac, _]} = fused_rows()

      assert {:skip, :single_cluster} =
               Decisions.plan_proxmox_unfuse(fused_device(), [farm_row], [])
    end

    test "tombstoned fused devices wait for operator judgment" do
      {v2_rows, mac_rows} = fused_rows()

      assert {:skip, :tombstoned} =
               Decisions.plan_proxmox_unfuse(
                 fused_device(%{tombstoned?: true}),
                 v2_rows,
                 mac_rows
               )
    end

    test "unparseable v2 values fail closed" do
      assert {:skip, :unexpected_identifier_shape} =
               Decisions.plan_proxmox_unfuse(
                 fused_device(),
                 [
                   v2_row(1, @farm_v2, @farm_source, @farm_seen),
                   v2_row(2, "proxmox:vm:k8s-cp3-worker1", @tonka_source, @tonka_seen)
                 ],
                 []
               )

      assert {:skip, :no_v2_identifiers} = Decisions.plan_proxmox_unfuse(fused_device(), [], [])
    end

    test "MAC rows without attributable provenance fail closed" do
      # one sync source behind both clusters: every MAC matches both groups
      shared_v2 = [
        v2_row(1, @farm_v2, "shared-src", @farm_seen),
        v2_row(2, @tonka_v2, "shared-src", @tonka_seen)
      ]

      assert {:skip, :ambiguous_mac_attribution} =
               Decisions.plan_proxmox_unfuse(fused_device(), shared_v2, [
                 mac_row(10, "BC241176DF7E", "shared-src")
               ])

      # missing source: unattributable
      {v2_rows, _} = fused_rows()

      assert {:skip, :ambiguous_mac_attribution} =
               Decisions.plan_proxmox_unfuse(fused_device(), v2_rows, [
                 mac_row(10, "BC241176DF7E", @farm_source),
                 mac_row(11, "BC2411AABBCC", nil)
               ])
    end

    test "partition drift fails closed" do
      {v2_rows, mac_rows} = fused_rows()
      [farm_row, tonka_row] = v2_rows
      drifted = %{tonka_row | partition: "other"}

      assert {:skip, :multiple_partitions} =
               Decisions.plan_proxmox_unfuse(fused_device(), [farm_row, drifted], mac_rows)
    end
  end

  describe "plan_armis_unmerge/2 (armis-unmerge step)" do
    # Universal MACs: 2nd hex char without the 0x02 bit. Local: with it.
    @mac_a "001AA0B94040"
    @mac_b "001422F42A2A"
    @mac_c "0050B6AABB01"
    @local_mac "02EA1432D278"

    defp mega_device(overrides \\ %{}) do
      armis_id = Map.get(overrides, :armis_device_id, "armis-777")

      Map.merge(
        %{
          uid: "sr:mega",
          mac: nil,
          armis_device_id: armis_id,
          metadata_armis_device_id: armis_id,
          typed_armis_rows: [%{id: "armis-row", value: armis_id}],
          armis_provenance_valid?: true,
          integration_type: "armis",
          partition: "default",
          source_partition: "default",
          tombstoned?: false,
          live_overmerge_verified?: true
        },
        overrides
      )
    end

    defp row(id, value, last_seen \\ nil),
      do: %{id: id, value: value, last_seen: last_seen, partition: "default"}

    test "no universal MAC -> skip (MAC-less / local-only collapses are unsplittable)" do
      assert {:skip, :no_universal_mac} = Decisions.plan_armis_unmerge(mega_device(), [])

      assert {:skip, :no_universal_mac} =
               Decisions.plan_armis_unmerge(mega_device(), [row("i1", @local_mac)])
    end

    test "a live device with one universal MAC is a normal device, not an over-merge" do
      assert {:skip, :single_universal_mac} =
               Decisions.plan_armis_unmerge(mega_device(), [row("i1", @mac_a)])
    end

    test "live splitting requires an Armis identity and an independent over-merge signal" do
      rows = [row("i1", @mac_a), row("i2", @mac_b)]

      assert {:skip, :missing_armis_device_id} =
               Decisions.plan_armis_unmerge(mega_device(%{armis_device_id: nil}), rows)

      assert {:skip, :missing_live_overmerge_signal} =
               Decisions.plan_armis_unmerge(
                 mega_device(%{live_overmerge_verified?: false}),
                 rows
               )
    end

    test "typed Armis ownership must be exact and agree with metadata" do
      rows = [row("i1", @mac_a), row("i2", @mac_b)]

      assert {:skip, :ambiguous_typed_armis_identity} =
               Decisions.plan_armis_unmerge(mega_device(%{typed_armis_rows: []}), rows)

      assert {:skip, :ambiguous_typed_armis_identity} =
               Decisions.plan_armis_unmerge(
                 mega_device(%{
                   typed_armis_rows: [
                     %{id: "armis-1", value: "armis-777"},
                     %{id: "armis-2", value: "armis-778"}
                   ]
                 }),
                 rows
               )

      assert {:skip, :armis_identity_mismatch} =
               Decisions.plan_armis_unmerge(
                 mega_device(%{metadata_armis_device_id: "armis-other"}),
                 rows
               )

      assert {:skip, :unproven_armis_identity_source} =
               Decisions.plan_armis_unmerge(
                 mega_device(%{armis_provenance_valid?: false}),
                 rows
               )

      assert {:skip, :noncanonical_armis_integration} =
               Decisions.plan_armis_unmerge(mega_device(%{integration_type: "custom"}), rows)
    end

    test "a tombstoned ghost with one universal MAC still plans a restore (sole-copy rescue)" do
      assert {:split, plan} =
               Decisions.plan_armis_unmerge(mega_device(%{tombstoned?: true}), [
                 row("i1", @mac_a)
               ])

      assert plan.survivor.action == :restore
      assert plan.survivor.mac == @mac_a
      assert plan.survivor.row_ids == ["i1"]
      assert plan.splits == []
    end

    test "live mega-device splits per distinct universal MAC; device.mac class survives" do
      rows = [row("i1", @mac_a), row("i2", @mac_b), row("i3", @mac_c)]

      assert {:split, plan} = Decisions.plan_armis_unmerge(mega_device(%{mac: @mac_b}), rows)

      assert plan.survivor.action == :adopt
      assert plan.survivor.mac == @mac_b
      assert plan.survivor.row_ids == ["i2"]

      assert Enum.map(plan.splits, & &1.mac) == Enum.sort([@mac_a, @mac_c])
      assert Enum.all?(plan.splits, &String.starts_with?(&1.new_uid, "sr:"))
      # One class per MAC, each carrying exactly its own row.
      assert plan.splits |> Enum.map(& &1.row_ids) |> List.flatten() |> Enum.sort() == [
               "i1",
               "i3"
             ]
    end

    test "a multi-value display MAC matching multiple planned classes is ambiguous" do
      rows = [row("i1", @mac_a), row("i2", @mac_b), row("i3", @mac_c)]

      assert {:skip, :ambiguous_display_mac} =
               Decisions.plan_armis_unmerge(
                 mega_device(%{mac: "#{@mac_b},#{@mac_a}"}),
                 rows
               )
    end

    test "target UIDs are deterministic per {armis_id, mac, partition} and distinct per class" do
      rows = [row("i1", @mac_a), row("i2", @mac_b)]

      {:split, plan1} = Decisions.plan_armis_unmerge(mega_device(%{mac: @mac_a}), rows)
      {:split, plan2} = Decisions.plan_armis_unmerge(mega_device(%{mac: @mac_a}), rows)

      assert Enum.map(plan1.splits, & &1.new_uid) == Enum.map(plan2.splits, & &1.new_uid)

      uids = Enum.map(plan1.splits, & &1.new_uid) ++ [plan1.device_uid]
      assert length(Enum.uniq(uids)) == length(uids)

      # A different armis id yields different target uids.
      {:split, plan3} =
        Decisions.plan_armis_unmerge(
          mega_device(%{mac: @mac_a, armis_device_id: "armis-888"}),
          rows
        )

      refute Enum.map(plan3.splits, & &1.new_uid) == Enum.map(plan1.splits, & &1.new_uid)
    end

    test "target UID parity is limited to canonical Armis-only update shapes" do
      rows = [row("i1", @mac_a), row("i2", @mac_b)]
      {:split, plan} = Decisions.plan_armis_unmerge(mega_device(%{mac: @mac_a}), rows)
      split = Enum.find(plan.splits, &(&1.mac == @mac_b))

      canonical_ids =
        Ids.extract_strong_identifiers(%{
          mac: @mac_b,
          partition: "default",
          metadata: %{
            "integration_type" => "armis",
            "armis_device_id" => "armis-777"
          }
        })

      enriched_ids = put_in(canonical_ids.agent_id, "agent-strong-seed")

      assert Ids.generate_deterministic_device_id(canonical_ids) == split.new_uid
      refute Ids.generate_deterministic_device_id(enriched_ids) == split.new_uid
    end

    test "the remediation-derived UID class survives even when device.mac changed" do
      existing_uid =
        Ids.generate_deterministic_device_id(%{
          armis_id: "armis-777",
          mac: @mac_a,
          partition: "default"
        })

      rows = [row("original", @mac_a), row("display", @mac_b), row("other", @mac_c)]

      assert {:split, plan} =
               Decisions.plan_armis_unmerge(
                 mega_device(%{uid: existing_uid, mac: @mac_b}),
                 rows
               )

      assert plan.survivor.mac == @mac_a
      assert plan.survivor.row_ids == ["original"]
      refute Enum.any?(plan.splits, &(&1.new_uid == existing_uid))
      assert Enum.sort(Enum.map(plan.splits, & &1.mac)) == Enum.sort([@mac_b, @mac_c])
    end

    test "without a device MAC anchor the lexical class survives timestamp-only churn" do
      newer = DateTime.utc_now()
      older = DateTime.shift(newer, hour: -1)

      {:split, first_plan} =
        Decisions.plan_armis_unmerge(mega_device(), [
          row("i1", @mac_a, newer),
          row("i2", @mac_b, older)
        ])

      {:split, churned_plan} =
        Decisions.plan_armis_unmerge(mega_device(), [
          row("i1", @mac_a, older),
          row("i2", @mac_b, newer)
        ])

      assert first_plan.survivor.mac == Enum.min([@mac_a, @mac_b])
      assert churned_plan.survivor == first_plan.survivor
      assert churned_plan.splits == first_plan.splits
    end

    test "non-atomic (blob) rows are ignored by the planner — blob-purge runs first" do
      rows = [row("i1", "#{@mac_a},#{@mac_b}"), row("i2", @mac_c)]

      # The blob row maps to two universal MACs and is dropped, leaving one class.
      assert {:skip, :single_universal_mac} = Decisions.plan_armis_unmerge(mega_device(), rows)
    end

    test "mixed identifier partitions are blocked rather than cross-wired" do
      rows = [
        "i1" |> row(@mac_a) |> Map.put(:partition, "default"),
        "i2" |> row(@mac_b) |> Map.put(:partition, "tenant-b")
      ]

      assert {:skip, :multiple_partitions} =
               Decisions.plan_armis_unmerge(mega_device(), rows)
    end

    test "every universal MAC row requires one canonical nonblank partition" do
      base_rows = [row("i1", @mac_a), row("i2", @mac_b)]

      for invalid <- [nil, "", "   ", " default "] do
        rows =
          List.replace_at(base_rows, 1, base_rows |> Enum.at(1) |> Map.put(:partition, invalid))

        assert {:skip, :missing_partition} =
                 Decisions.plan_armis_unmerge(mega_device(), rows)
      end
    end

    test "a live source partition must be canonical and match the MAC partition" do
      rows = [row("i1", @mac_a), row("i2", @mac_b)]

      for invalid <- [nil, "", " default "] do
        assert {:skip, :missing_source_partition} =
                 Decisions.plan_armis_unmerge(
                   mega_device(%{source_partition: invalid}),
                   rows
                 )
      end

      assert {:skip, :source_partition_mismatch} =
               Decisions.plan_armis_unmerge(
                 mega_device(%{source_partition: "tenant-b"}),
                 rows
               )

      assert {:split, _plan} = Decisions.plan_armis_unmerge(mega_device(), rows)
    end
  end

  describe "plan_netprobe_alias_purge/1" do
    # A collector that absorbed two neighbours it merely fingerprinted.
    defp collector(overrides \\ %{}) do
      Map.merge(
        %{
          uid: "sr:collector",
          ip: "10.0.2.11",
          metadata: %{},
          discovery_sources: ["passive-netprobe", "sysmon", "agent", "sweep"],
          foreign_aliases: ["10.0.2.8", "10.0.2.12"],
          addresses_with_own_device: ["10.0.2.8", "10.0.2.12"]
        },
        overrides
      )
    end

    test "purges addresses the collector absorbed from hosts that exist in their own right" do
      assert {:purge, ["10.0.2.8", "10.0.2.12"]} =
               Decisions.plan_netprobe_alias_purge(collector())
    end

    test "never purges the device's own address" do
      device =
        collector(%{
          foreign_aliases: ["10.0.2.11", "10.0.2.8"],
          addresses_with_own_device: ["10.0.2.11", "10.0.2.8"]
        })

      assert {:purge, ["10.0.2.8"]} = Decisions.plan_netprobe_alias_purge(device)
    end

    test "leaves an address that has no device of its own" do
      # The alias may be the only surviving record that the address was ever
      # seen. Debris is cheaper than losing that.
      device = collector(%{addresses_with_own_device: ["10.0.2.8"]})

      assert {:purge, ["10.0.2.8"]} = Decisions.plan_netprobe_alias_purge(device)
    end

    test "skips a device netprobe never wrote to" do
      device = collector(%{discovery_sources: ["sysmon", "agent", "sweep"]})

      assert {:skip, :not_netprobe} = Decisions.plan_netprobe_alias_purge(device)
    end

    test "skips a device the mapper also wrote to" do
      # The mapper is the other writer of foreign-looking ip_alias keys and it
      # writes a device's OWN alternate addresses, so attribution is lost.
      device = collector(%{discovery_sources: ["passive-netprobe", "mapper", "sweep"]})

      assert {:skip, :mapper_wrote_here} = Decisions.plan_netprobe_alias_purge(device)
    end

    test "skips a router-role device even when every other guard passes" do
      # For router-role devices the mapper records the device's own interface
      # addresses as ip_alias and nowhere else -- and a multi-homed gateway is
      # exactly where netprobe is deployed, so this is the dangerous case.
      assert {:skip, :router_role} =
               Decisions.plan_netprobe_alias_purge(
                 collector(%{metadata: %{"device_role" => "router"}})
               )

      assert {:skip, :router_role} =
               Decisions.plan_netprobe_alias_purge(
                 collector(%{metadata: %{"_device_role" => "Router"}})
               )
    end

    test "does not mistake a non-router role for a router" do
      assert {:purge, _} =
               Decisions.plan_netprobe_alias_purge(
                 collector(%{metadata: %{"device_role" => "switch"}})
               )
    end

    test "skips when nothing is left to purge" do
      assert {:skip, :no_addresses} =
               Decisions.plan_netprobe_alias_purge(collector(%{foreign_aliases: []}))

      assert {:skip, :no_addresses} =
               Decisions.plan_netprobe_alias_purge(collector(%{addresses_with_own_device: []}))
    end
  end

  # Invented fixtures: two Proxmox clusters that reuse a VMID, one AWX controller, MACs under the
  # IANA documentation OUI (00-00-5E) and its locally administered twin.
  @controller "00000000-0000-4000-8000-0000000000c1"
  @guest_a "proxmox:v2:cluster-a:vm:101"
  @universal_a "00005E005301"
  @universal_b "00005E005302"
  @local_mac "02005E0053EE"

  defp guest_b_ref(native_cluster_id \\ "cluster-b") do
    {:ok, fields} =
      IntegrationIdentity.proxmox_v3_fields(
        "00000000-0000-4000-8000-0000000000a1",
        "00000000-0000-4000-8000-0000000000a2",
        native_cluster_id,
        "qemu",
        "101"
      )

    fields.provider_ref
  end

  defp ident(type, value), do: %{"type" => type, "value" => value, "partition" => "default"}
  defp awx_id(host), do: ident("integration_id", "awx:v2:#{@controller}:host:#{host}")

  # The merged record is the holder: a guest of cluster A with its own universal MAC. The survivor
  # is the guest of cluster B the AWX host was bound to.
  defp awx_merge(overrides) do
    Map.merge(
      %{
        event_id: "m1",
        created_at: ~U[2026-01-01 00:00:10Z],
        reason: "awx_proxmox_network_match",
        from_uid: "sr:a",
        to_uid: "sr:b",
        guest_provider_ref: guest_b_ref(),
        corroboration: "ip_proxmox",
        source_identifiers: [ident("integration_id", @guest_a), ident("mac", @universal_a)],
        from_mac: nil,
        to_own_identifiers: [ident("integration_id", guest_b_ref()), ident("mac", @universal_b)],
        to_absorbed_before: [],
        to_mac: nil,
        reversed?: false,
        from_state: :merged,
        superseded?: false,
        to_state: :live
      },
      overrides
    )
  end

  describe "awx_merge_evidence/1 (awx-proxmox-unmerge)" do
    test "proves different machines only on the evidence the owner approved" do
      cases = [
        {"guest of another cluster, same VMID", %{}, :different_machines,
         [:proxmox_guest_mismatch]},
        {"two AWX hosts of one controller",
         %{
           source_identifiers: [awx_id(11)],
           to_own_identifiers: [awx_id(12)],
           guest_provider_ref: nil
         }, :different_machines, [:different_awx_hosts]},
        {"AWX hosts of two controllers are not comparable",
         %{
           source_identifiers: [ident("integration_id", "awx:v2:ctrl-x:host:11")],
           to_own_identifiers: [awx_id(12)],
           guest_provider_ref: nil
         }, :ambiguous, :no_distinguishing_evidence},
        {"a holder that only matched on a locally administered MAC",
         %{
           corroboration: "mac",
           source_identifiers: [ident("mac", @local_mac)],
           to_own_identifiers: []
         }, :different_machines, [:laa_only_corroboration]},
        {"a holder with a universal MAC was a real MAC match",
         %{
           corroboration: "mac",
           source_identifiers: [ident("mac", @local_mac), ident("mac", @universal_a)],
           to_own_identifiers: []
         }, :ambiguous, :no_distinguishing_evidence},
        {"an AWX record is not the holder, so its MACs prove nothing",
         %{
           corroboration: "mac",
           source_identifiers: [awx_id(11), ident("mac", @local_mac)],
           to_own_identifiers: []
         }, :ambiguous, :no_distinguishing_evidence},
        {"the same cluster name and VMID on both sides",
         %{source_identifiers: [ident("integration_id", "proxmox:v2:cluster-b:vm:101")]},
         :ambiguous, :no_distinguishing_evidence},
        {"a v3 cluster-status id and the v2 id of that cluster name and VMID",
         %{
           source_identifiers: [ident("integration_id", "proxmox:v2:cluster-b:vm:101")],
           to_own_identifiers: [ident("integration_id", guest_b_ref("cluster/cluster-b"))]
         }, :ambiguous, :no_distinguishing_evidence},
        {"a v3 standalone id and the v2 id of that node and VMID",
         %{
           source_identifiers: [ident("integration_id", "proxmox:v2:pve01:vm:101")],
           to_own_identifiers: [ident("integration_id", guest_b_ref("standalone/pve01"))]
         }, :ambiguous, :no_distinguishing_evidence},
        {"a v3 cluster-status id of another cluster name",
         %{to_own_identifiers: [ident("integration_id", guest_b_ref("cluster/cluster-b"))]},
         :different_machines, [:proxmox_guest_mismatch]},
        {"a shared universal MAC voids the proof",
         %{
           to_own_identifiers: [
             ident("integration_id", guest_b_ref()),
             ident("mac", @universal_a)
           ]
         }, :ambiguous, :conflicting_evidence},
        {"a shared universal display MAC voids the proof without MAC identifiers",
         %{
           source_identifiers: [ident("integration_id", @guest_a)],
           from_mac: "00:00:5e:00:53:01",
           to_own_identifiers: [ident("integration_id", guest_b_ref())],
           to_mac: @universal_a
         }, :ambiguous, :conflicting_evidence},
        {"a universal MAC an earlier merge brought the survivor voids the proof",
         %{to_absorbed_before: [ident("mac", @universal_a)]}, :ambiguous, :conflicting_evidence},
        {"a merge that recorded no source identifiers", %{source_identifiers: nil}, :ambiguous,
         :source_identifiers_unrecorded}
      ]

      for {name, overrides, verdict, expected} <- cases do
        evidence = Decisions.awx_merge_evidence(awx_merge(overrides))
        assert evidence.verdict == verdict, name

        case verdict do
          :different_machines -> assert evidence.proofs == expected, name
          :ambiguous -> assert evidence.reason == expected, name
        end
      end
    end

    test "keys a v2 id and a v3 reference of one cluster and VMID alike" do
      assert Decisions.awx_guest_key(guest_b_ref()) == {"cluster-b", "101"}
      assert Decisions.awx_guest_key("proxmox:v2:Cluster-B:vm:101") == {"cluster-b", "101"}
      assert Decisions.awx_guest_key(guest_b_ref("cluster/cluster-b")) == {"cluster-b", "101"}
      assert Decisions.awx_guest_key(guest_b_ref("standalone/pve01")) == {"pve01", "101"}
      assert Decisions.awx_guest_key("proxmox:guest:pve01:qemu:101") == nil
      assert Decisions.awx_guest_key("proxmox:v2:cluster-b:node:pve01") == nil
    end
  end

  describe "plan_awx_proxmox_unmerge/3" do
    # A merge of another reason, onto a survivor `sr:s` that holds AWX host 1 and no guest identity.
    defp chained(overrides) do
      Map.merge(
        %{
          reason: "hypervisor_guest_network_match",
          to_uid: "sr:s",
          guest_provider_ref: nil,
          corroboration: nil,
          evidence: nil,
          from_ip: nil,
          to_ip_before: nil,
          from_mac: nil,
          to_own_identifiers: [awx_id(1)],
          to_absorbed_before: [],
          to_mac: nil,
          reversed?: false,
          from_state: :merged,
          superseded?: false,
          to_state: :live
        },
        overrides
      )
    end

    defp guest_ref(vmid), do: "proxmox:v2:cluster-x:vm:#{vmid}"
    defp at(second), do: DateTime.shift(~U[2026-01-01 00:00:00Z], second: second)

    defp poisoned_context do
      %{
        own: %{"sr:s" => [awx_id(1)]},
        guests: %{
          guest_ref(136) => %{
            key: {"cluster-x", "136"},
            macs: ["00:00:5E:00:53:36"],
            ips: ["192.0.2.36"]
          }
        }
      }
    end

    # The AWX host 2 record merged into the survivor of AWX host 1, the host bound to guest 136.
    defp poisoning_merge do
      awx_merge(%{
        event_id: "e1",
        created_at: at(1),
        from_uid: "sr:h2",
        to_uid: "sr:s",
        guest_provider_ref: guest_ref(136),
        source_identifiers: [awx_id(2)],
        to_own_identifiers: [awx_id(1)]
      })
    end

    test "follows the poison through merges of other reasons, and undoes them as one unit" do
      merges = [
        poisoning_merge(),
        # Guest 136's own record matched on the guest MAC the bound AWX host left behind.
        chained(%{
          event_id: "e2",
          created_at: at(2),
          from_uid: "sr:g136",
          guest_provider_ref: guest_ref(136),
          source_identifiers: [
            ident("integration_id", guest_ref(136)),
            ident("mac", "00005E005336")
          ]
        }),
        # Guest 114 matched on an address the poison did not bring: it may be this machine.
        chained(%{
          event_id: "e3",
          created_at: at(3),
          from_uid: "sr:g114",
          guest_provider_ref: guest_ref(114),
          source_identifiers: [
            ident("integration_id", guest_ref(114)),
            ident("mac", "00005E005314")
          ],
          from_ip: "192.0.2.14",
          to_ip_before: "192.0.2.14"
        }),
        # Guest 137 is a second guest on a record that now carries guest 114.
        chained(%{
          event_id: "e4",
          created_at: at(4),
          from_uid: "sr:g137",
          guest_provider_ref: guest_ref(137),
          source_identifiers: [
            ident("integration_id", guest_ref(137)),
            ident("mac", "00005E005337")
          ]
        }),
        # A backfill that matched on the copied guest MAC, as it recorded.
        chained(%{
          event_id: "e5",
          created_at: at(5),
          reason: "identifier_backfill",
          from_uid: "sr:fresh",
          source_identifiers: [ident("mac", "00005E005399")],
          evidence: [%{"type" => "mac_column", "value" => "00:00:5E:00:53:36"}]
        })
      ]

      plan = Decisions.plan_awx_proxmox_unmerge(merges, poisoned_context())
      by_id = Map.new(plan.report, &{&1.event_id, &1})

      assert [%{event_ids: ["e5", "e4", "e2", "e1"]}] = plan.units
      assert by_id["e1"].proofs == [:different_awx_hosts]
      assert by_id["e2"].proofs == [:tainted_evidence]
      assert by_id["e4"].proofs == [:proxmox_guest_mismatch]
      assert by_id["e5"].proofs == [:tainted_evidence]
      assert %{disposition: :chained_unproven, bad?: false} = by_id["e3"]
    end

    test "a merged record sharing the survivor's own identity is never chained" do
      own = [awx_id(1), ident("mac", "00005E0053AA")]

      merges = [
        poisoning_merge(),
        chained(%{
          event_id: "e2",
          created_at: at(2),
          from_uid: "sr:g137",
          guest_provider_ref: guest_ref(137),
          source_identifiers: [
            ident("integration_id", guest_ref(137)),
            ident("mac", "00005E0053AA")
          ],
          to_own_identifiers: own
        })
      ]

      context = put_in(poisoned_context(), [:own, "sr:s"], own)
      plan = Decisions.plan_awx_proxmox_unmerge(merges, context)

      assert Enum.find(plan.report, &(&1.event_id == "e2")).disposition == :conflicting_evidence
      assert [%{event_ids: ["e1"]}] = plan.units
    end

    test "an address the poisoned merged record owns is not tainted evidence" do
      # `sr:s` owns 192.0.2.36 and the guest bound to it brought the same address; `sr:s` is then
      # merged into `sr:t`, which does not own it, on that address.
      own = [awx_id(1), ident("ip", "192.0.2.36")]

      merges = [
        %{poisoning_merge() | to_own_identifiers: own},
        chained(%{
          event_id: "e2",
          created_at: at(2),
          reason: "identifier_backfill",
          from_uid: "sr:s",
          to_uid: "sr:t",
          source_identifiers: [ident("mac", "00005E005399")],
          evidence: [%{"type" => "ip", "value" => "192.0.2.36"}],
          to_own_identifiers: []
        })
      ]

      context = put_in(poisoned_context(), [:own, "sr:s"], own)
      plan = Decisions.plan_awx_proxmox_unmerge(merges, context)
      e2 = Enum.find(plan.report, &(&1.event_id == "e2"))

      refute :tainted_evidence in e2.proofs
      refute e2.bad?
    end

    test "a same-second sibling carries no poison into the next second, in either id order" do
      # The AWX merge poisons `sr:s` with guest 136's address while, in the same second, `sr:s`
      # is merged into `sr:t`. A backfill into `sr:t` a second later on that address is not tainted.
      for {awx_id, sibling_id} <- [{"e1", "e2"}, {"e9", "e2"}] do
        merges = [
          %{poisoning_merge() | event_id: awx_id},
          chained(%{
            event_id: sibling_id,
            created_at: at(1),
            reason: "identifier_backfill",
            from_uid: "sr:s",
            to_uid: "sr:t",
            source_identifiers: [ident("mac", "00005E005398")],
            to_own_identifiers: []
          }),
          chained(%{
            event_id: "e5",
            created_at: at(2),
            reason: "identifier_backfill",
            from_uid: "sr:fresh",
            to_uid: "sr:t",
            source_identifiers: [ident("mac", "00005E005399")],
            evidence: [%{"type" => "ip", "value" => "192.0.2.36"}],
            to_own_identifiers: []
          })
        ]

        plan = Decisions.plan_awx_proxmox_unmerge(merges, poisoned_context())
        by_id = Map.new(plan.report, &{&1.event_id, &1})

        assert [%{event_ids: [^awx_id]}] = plan.units
        assert %{disposition: :chained_unproven, bad?: false} = by_id[sibling_id]
        refute by_id["e5"][:bad?]
      end
    end

    test "a merge in the same second as the bad merge is reported, never undone or dropped" do
      # `sr:s` holds guest 101; in the second the AWX merge poisons it, guest 102 is merged in.
      own = [awx_id(1), ident("integration_id", guest_ref(101))]
      context = put_in(poisoned_context(), [:own, "sr:s"], own)

      for {awx_id, guest_id} <- [{"e1", "e2"}, {"e9", "e2"}] do
        merges = [
          %{poisoning_merge() | event_id: awx_id},
          chained(%{
            event_id: guest_id,
            created_at: at(1),
            from_uid: "sr:g102",
            guest_provider_ref: guest_ref(102),
            source_identifiers: [ident("integration_id", guest_ref(102))],
            to_own_identifiers: own
          })
        ]

        plan = Decisions.plan_awx_proxmox_unmerge(merges, context)
        guest = Enum.find(plan.report, &(&1.event_id == guest_id))

        assert %{disposition: :chained_unproven, bad?: false} = guest
        assert [%{event_ids: [^awx_id]}] = plan.units
      end
    end

    test "recorded ip evidence a poisoned survivor owns is not tainted by the guest's address" do
      own = [awx_id(1), ident("ip", "192.0.2.36")]

      merges = [
        %{poisoning_merge() | to_own_identifiers: own},
        chained(%{
          event_id: "e2",
          created_at: at(2),
          reason: "identifier_backfill",
          from_uid: "sr:fresh",
          source_identifiers: [ident("mac", "00005E005399")],
          evidence: [%{"type" => "ip", "value" => "192.0.2.36"}],
          to_own_identifiers: own
        })
      ]

      context = put_in(poisoned_context(), [:own, "sr:s"], own)
      plan = Decisions.plan_awx_proxmox_unmerge(merges, context)
      e2 = Enum.find(plan.report, &(&1.event_id == "e2"))

      refute :tainted_evidence in e2.proofs
      refute e2.bad?
      assert [%{event_ids: ["e1"]}] = plan.units
    end

    test "a merged ip identifier equal to a poisoned guest address is tainted" do
      merges = [
        poisoning_merge(),
        chained(%{
          event_id: "e2",
          created_at: at(2),
          reason: "identifier_backfill",
          from_uid: "sr:fresh",
          source_identifiers: [ident("ip", "192.0.2.36")]
        })
      ]

      plan = Decisions.plan_awx_proxmox_unmerge(merges, poisoned_context())
      e2 = Enum.find(plan.report, &(&1.event_id == "e2"))

      assert e2.proofs == [:tainted_evidence]
    end

    test "undoes a chain newest first, the survivor's own merge away before the merge into it" do
      # A merged into B, then B into C, in one second, under ids that sort the other way: B's
      # merge away still runs first.
      m9 = awx_merge(%{event_id: "m9", to_state: {:merged, "m1"}})

      m1 =
        awx_merge(%{
          event_id: "m1",
          from_uid: "sr:b",
          to_uid: "sr:c",
          source_identifiers: [ident("integration_id", @guest_a)],
          to_own_identifiers: [ident("integration_id", "proxmox:v2:cluster-c:vm:101")]
        })

      plan = Decisions.plan_awx_proxmox_unmerge([m9, m1])

      assert Enum.map(plan.unmerge, & &1.event_id) == ["m1", "m9"]
    end

    test "reports a whole unit when one of its merges cannot be undone" do
      blocked = awx_merge(%{event_id: "m1", to_state: {:merged, "other-away"}})
      ambiguous = awx_merge(%{event_id: "m3", from_uid: "sr:d", source_identifiers: nil})

      # A, already a bad pair, also took D in; D cannot be undone, so A's merge waits too.
      superseded =
        awx_merge(%{event_id: "m4", from_uid: "sr:x", to_uid: "sr:y", superseded?: true})

      partner = awx_merge(%{event_id: "m5", from_uid: "sr:w", to_uid: "sr:y"})

      plan = Decisions.plan_awx_proxmox_unmerge([blocked, ambiguous, superseded, partner])
      by_id = Map.new(plan.report, &{&1.event_id, &1})

      assert plan.unmerge == []
      assert %{disposition: :blocked_by_later_merge, blocked_by: "other-away"} = by_id["m1"]
      assert %{disposition: :source_identifiers_unrecorded, bad?: false} = by_id["m3"]
      assert by_id["m4"].disposition == :merge_superseded
      assert %{disposition: :chain_blocked, blocked_by: "m4: merge_superseded"} = by_id["m5"]
    end

    test "refuses a merge whose state no longer allows the unmerge" do
      cases = [
        {%{reversed?: true}, :already_unmerged},
        {%{from_state: :live}, :not_merged},
        {%{superseded?: true}, :merge_superseded},
        {%{to_state: :deleted}, :survivor_not_live}
      ]

      for {overrides, disposition} <- cases do
        %{unmerge: [], report: [entry]} =
          Decisions.plan_awx_proxmox_unmerge([awx_merge(overrides)])

        assert entry.disposition == disposition
        assert entry.bad?
      end
    end

    test "a selected merge selects its whole unit, and other units wait" do
      m1 = awx_merge(%{event_id: "m1", to_state: {:merged, "m2"}})
      m2 = awx_merge(%{event_id: "m2", from_uid: "sr:b", to_uid: "sr:c"})
      other = awx_merge(%{event_id: "m3", from_uid: "sr:x", to_uid: "sr:y"})

      plan = Decisions.plan_awx_proxmox_unmerge([m1, m2, other], %{}, event_ids: ["m1"])

      assert Enum.map(plan.unmerge, & &1.event_id) == ["m2", "m1"]
      assert Enum.find(plan.report, &(&1.event_id == "m3")).disposition == :not_selected
    end
  end

  describe "project_awx_unmerges/2" do
    test "moves each recorded identifier back along the chain" do
      rows = [
        %{id: 1, device_id: "sr:c", type: "mac", value: @universal_a, partition: "default"},
        %{id: 2, device_id: "sr:c", type: "mac", value: @universal_b, partition: "default"},
        %{id: 3, device_id: "sr:c", type: "mac", value: @local_mac, partition: "default"}
      ]

      unmerges = [
        %{
          from_uid: "sr:b",
          to_uid: "sr:c",
          source_identifiers: [ident("mac", @universal_a), ident("mac", @universal_b)]
        },
        %{from_uid: "sr:a", to_uid: "sr:b", source_identifiers: [ident("mac", @universal_a)]}
      ]

      assert rows
             |> Decisions.project_awx_unmerges(unmerges)
             |> Map.new(&{&1.id, &1.device_id}) == %{1 => "sr:a", 2 => "sr:b", 3 => "sr:c"}
    end

    test "moves only the partition the merge recorded, any partition when it recorded none" do
      rows = [
        %{id: 1, device_id: "sr:c", type: "mac", value: @universal_a, partition: "default"},
        %{id: 2, device_id: "sr:c", type: "mac", value: @universal_a, partition: "site-b"},
        %{id: 3, device_id: "sr:c", type: "mac", value: @universal_b, partition: "site-b"}
      ]

      unmerges = [
        %{
          from_uid: "sr:b",
          to_uid: "sr:c",
          source_identifiers: [
            ident("mac", @universal_a),
            %{"type" => "mac", "value" => @universal_b, "partition" => nil}
          ]
        }
      ]

      assert rows
             |> Decisions.project_awx_unmerges(unmerges)
             |> Map.new(&{&1.id, &1.device_id}) == %{1 => "sr:b", 2 => "sr:c", 3 => "sr:b"}
    end
  end

  describe "plan_awx_wrong_guest_macs/1" do
    defp mac_input(device_overrides, row_overrides \\ %{}) do
      %{
        guest: %{
          provider_ref: "proxmox:v2:cluster-b:vm:101",
          key: {"cluster-b", "101"},
          device_uid: "sr:guest-b",
          macs: ["00:00:5E:00:53:02", "02:00:5E:00:53:EE"]
        },
        device:
          Map.merge(
            %{
              uid: "sr:a",
              own_guest_keys: MapSet.new([{"cluster-a", "101"}]),
              other_side_is_guest?: false,
              interface_macs: [],
              awx_declared_macs: [],
              absorbed_macs: []
            },
            device_overrides
          ),
        rows: [
          Map.merge(
            %{id: 7, value: @universal_b, source: "sync_ingestor", integration_type: "awx"},
            row_overrides
          ),
          %{id: 8, value: @universal_a, source: "sync_ingestor", integration_type: "awx"}
        ]
      }
    end

    test "removes a guest MAC an AWX update wrote to another machine, and keeps the rest" do
      cases = [
        {%{}, %{}, :remove, nil},
        {%{uid: "sr:guest-b"}, %{}, :remove, nil},
        {%{own_guest_keys: MapSet.new(), other_side_is_guest?: true}, %{}, :remove, nil},
        {%{own_guest_keys: MapSet.new()}, %{}, :keep, :device_not_proven_other_machine},
        {%{}, %{source: "proxmox_enrichment"}, :keep, :not_awx_provenance},
        {%{}, %{integration_type: "armis"}, :keep, :not_awx_provenance},
        {%{},
         %{integration_type: "hypervisor", reported_guest_ref: "proxmox:v2:cluster-b:vm:101"},
         :keep, :refreshed_by_guest_report},
        {%{interface_macs: ["00005E005302"]}, %{}, :keep, :observed_on_device},
        {%{awx_declared_macs: ["00:00:5e:00:53:02"]}, %{}, :keep, :declared_by_awx_host},
        {%{absorbed_macs: ["00005E005302"]}, %{}, :keep, :absorbed_by_merge}
      ]

      for {device, row, decision, reason} <- cases do
        # Row 8 is not a MAC of the guest and is never considered.
        assert [%{id: 7, decision: ^decision, reason: ^reason}] =
                 Decisions.plan_awx_wrong_guest_macs(mac_input(device, row)),
               inspect({device, row})
      end
    end

    test "keeps a proved guest MAC when several live records hold the guest" do
      input = put_in(mac_input(%{}), [:guest, :record_ambiguous?], true)

      assert [%{id: 7, decision: :keep, reason: :guest_record_ambiguous, target_uid: nil}] =
               Decisions.plan_awx_wrong_guest_macs(input)
    end

    test "gives a proved guest MAC back to the guest's own record when one is live" do
      input = put_in(mac_input(%{}), [:guest, :record_uid], "sr:guest-b-restored")

      assert [%{id: 7, decision: :move, target_uid: "sr:guest-b-restored"}] =
               Decisions.plan_awx_wrong_guest_macs(input)

      # A row the guest's own report refreshed is the guest's: moved, never archived.
      refreshed =
        put_in(
          mac_input(%{}, %{
            integration_type: "hypervisor",
            reported_guest_ref: "proxmox:v2:cluster-b:vm:101"
          }),
          [:guest, :record_uid],
          "sr:guest-b-restored"
        )

      assert [%{id: 7, decision: :move}] = Decisions.plan_awx_wrong_guest_macs(refreshed)
    end

    test "keeps a locally administered guest MAC, which many machines carry" do
      assert [%{decision: :keep, reason: :locally_administered}] =
               Decisions.plan_awx_wrong_guest_macs(mac_input(%{}, %{value: @local_mac}))
    end

    test "never touches the guest's own device" do
      assert [] =
               Decisions.plan_awx_wrong_guest_macs(
                 mac_input(%{uid: "sr:guest-b", own_guest_keys: MapSet.new()})
               )

      assert [] =
               Decisions.plan_awx_wrong_guest_macs(
                 mac_input(%{own_guest_keys: MapSet.new([{"cluster-b", "101"}])})
               )
    end
  end
end
