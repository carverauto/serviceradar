defmodule ServiceRadar.Inventory.Remediation.DecisionsTest do
  @moduledoc """
  Unit coverage for the pure decision functions behind
  `mix serviceradar.dire_remediation` (DIRE tasks 4.1-4.4).
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.Ids
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
      older = DateTime.add(newer, -3600, :second)

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
end
