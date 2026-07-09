defmodule ServiceRadar.Inventory.Remediation.DecisionsTest do
  @moduledoc """
  Unit coverage for the pure decision functions behind
  `mix serviceradar.dire_remediation` (DIRE tasks 4.1-4.4).
  """

  use ExUnit.Case, async: true

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
    test "corroborated by a shared host reference" do
      a = dev([], ["proxmox:hypervisor:pve02"])
      b = dev([], ["proxmox:hypervisor:pve02"])
      assert Decisions.same_physical_host?(a, b)
    end

    test "corroborated by a shared MAC" do
      a = dev(["001AA0B94040"], [])
      b = dev(["001AA0B94040"], [])
      assert Decisions.same_physical_host?(a, b)
    end

    test "integration_id churn corroborated via a legacy reference token" do
      old = dev([], ["proxmox:vm:12345"])
      new = dev([], ["proxmox:hypervisor:pve02", "proxmox:vm:12345"])
      assert Decisions.same_physical_host?(old, new)
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

  describe "plan_armis_unmerge/2 (armis-unmerge step)" do
    # Universal MACs: 2nd hex char without the 0x02 bit. Local: with it.
    @mac_a "001AA0B94040"
    @mac_b "001422F42A2A"
    @mac_c "0050B6AABB01"
    @local_mac "02EA1432D278"

    defp mega_device(overrides \\ %{}) do
      Map.merge(
        %{
          uid: "sr:mega",
          mac: nil,
          armis_device_id: "armis-777",
          partition: "default",
          tombstoned?: false
        },
        overrides
      )
    end

    defp row(id, value, last_seen \\ nil), do: %{id: id, value: value, last_seen: last_seen}

    test "no universal MAC -> skip (MAC-less / local-only collapses are unsplittable)" do
      assert {:skip, :no_universal_mac} = Decisions.plan_armis_unmerge(mega_device(), [])

      assert {:skip, :no_universal_mac} =
               Decisions.plan_armis_unmerge(mega_device(), [row("i1", @local_mac)])
    end

    test "a live device with one universal MAC is a normal device, not an over-merge" do
      assert {:skip, :single_universal_mac} =
               Decisions.plan_armis_unmerge(mega_device(), [row("i1", @mac_a)])
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

    test "without a device MAC anchor the most-recently-seen class survives, ties lexicographic" do
      newer = DateTime.utc_now()
      older = DateTime.add(newer, -3600, :second)

      {:split, plan} =
        Decisions.plan_armis_unmerge(mega_device(), [
          row("i1", @mac_a, older),
          row("i2", @mac_b, newer)
        ])

      assert plan.survivor.mac == @mac_b

      # Equal last_seen -> lexicographically smallest value, deterministic re-runs.
      {:split, tie_plan} =
        Decisions.plan_armis_unmerge(mega_device(), [
          row("i1", @mac_a, newer),
          row("i2", @mac_b, newer)
        ])

      assert tie_plan.survivor.mac == Enum.min([@mac_a, @mac_b])
    end

    test "non-atomic (blob) rows are ignored by the planner — blob-purge runs first" do
      rows = [row("i1", "#{@mac_a},#{@mac_b}"), row("i2", @mac_c)]

      # The blob row maps to two universal MACs and is dropped, leaving one class.
      assert {:skip, :single_universal_mac} = Decisions.plan_armis_unmerge(mega_device(), rows)
    end
  end
end
