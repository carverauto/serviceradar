defmodule ServiceRadar.Inventory.Remediation.AwxProxmoxUnmergeTest do
  @moduledoc """
  Database coverage for the `awx-proxmox-unmerge` repair and its checks, run through
  `DireRemediation` as an operator runs them: a merge of a guest of one cluster into the guest of
  another (what an AWX host bound by node name and VMID alone produced) is undone, the guest MAC
  an AWX update copied onto the merged record is archived, the rows that cannot be proved are
  kept, a replay does nothing, and `source-id-rollback` restores the joined state. Chains are
  undone in order, or reported when a merge that does not qualify blocks them.

  Every value is invented: the clusters, VMIDs, controller, hosts and MACs (IANA documentation
  OUI 00-00-5E).
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor
  alias ServiceRadar.Inventory.Remediation.AwxProxmoxUnmerge
  alias ServiceRadar.Inventory.Remediation.DireRemediation
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag :capture_log

  @step "awx-proxmox-unmerge"
  @guest_reason "awx_proxmox_network_match"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  # The execute gate is runtime configuration of the VM, so the module runs serially and
  # restores it.
  setup do
    original = Application.get_env(:serviceradar_core, DireRemediation)
    config = original || []

    Application.put_env(
      :serviceradar_core,
      DireRemediation,
      Keyword.put(config, :enable_awx_proxmox_unmerge_execute, true)
    )

    n = System.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "awx_proxmox_unmerge_test_#{n}_#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      case original do
        nil -> Application.delete_env(:serviceradar_core, DireRemediation)
        value -> Application.put_env(:serviceradar_core, DireRemediation, value)
      end
    end)

    {:ok, actor: SystemActor.system(:awx_proxmox_unmerge_test), n: n, dir: dir}
  end

  test "undoes a proved merge, gives the copied guest MACs back to the guest, and replays to nothing",
       ctx do
    w = guest_world!(ctx)
    ambiguous = ambiguous_merge!(ctx)
    scope = [awx_proxmox_unmerge_event_ids: [w.merge, ambiguous.merge]]

    assert {:ok, %{reports: %{@step => plan}}} = DireRemediation.run([steps: [@step]] ++ scope)

    assert [%{merges: [planned]}] = plan.unmerge_plan
    assert planned.event_id == w.merge
    assert planned.proofs == ["proxmox_guest_mismatch"]
    assert planned.from.uid == w.holder and planned.to.uid == w.guest_device
    assert planned.from.proxmox_guests == ["cluster-a-#{ctx.n}/#{w.vmid}"]
    assert "cluster-b-#{ctx.n}/#{w.vmid}" in planned.to.proxmox_guests

    # The AWX-written row and the row the guest's own report refreshed go to the guest's record.
    assert plan.mac_cleanup_plan
           |> Enum.map(&{&1.id, &1.device_uid, &1.decision, &1.target_uid})
           |> Enum.sort() ==
             Enum.sort([
               {w.copied_row, w.holder, "move", w.guest_device},
               {w.refreshed_row, w.holder, "move", w.guest_device}
             ])

    assert plan.mac_rows_kept == %{"locally_administered" => 1}

    assert Enum.find(plan.reported_merges, &(&1.event_id == ambiguous.merge)).disposition ==
             "no_distinguishing_evidence"

    # The dry run changed nothing.
    assert merged?(w.holder)

    manifest = Path.join(ctx.dir, "execute_1.ndjson")

    assert {:ok, %{reports: %{@step => report}}} =
             DireRemediation.run(
               [mode: :execute, steps: [@step], manifest_path: manifest, actor: ctx.actor] ++
                 scope
             )

    assert %{
             units_applied: 1,
             unmerged: 1,
             distinct_asserted: 1,
             mac_rows_moved: 2,
             mac_rows_archived: 0,
             mac_rows_not_settled: 0
           } = report

    # The pair is apart again, each with its own guest identity.
    refute merged?(w.holder)
    assert owner("integration_id", w.holder_v2) == w.holder
    assert owner("integration_id", w.guest_ref) == w.guest_device
    assert Deduplication.asserted_distinct?(w.holder, w.guest_device)

    assert [[unmerged_by]] =
             Repo.query!(
               """
               SELECT details->>'unmerged_by' FROM platform.merge_audit
               WHERE reason = 'unmerge' AND details->>'original_merge_event_id' = $1
               """,
               [w.merge]
             ).rows

    assert unmerged_by == AwxProxmoxUnmerge.unmerged_by()

    # The guest's MACs are back on the guest's record; the locally administered one stays.
    assert owner("mac", w.copied_mac) == w.guest_device
    assert owner("mac", w.refreshed_mac) == w.guest_device
    assert owner("mac", w.local_mac) == w.holder

    # The ambiguous merge stays.
    assert merged?(ambiguous.from)

    {:ok, _header, entries} = Manifest.read(manifest)
    actions = entries |> Enum.map(& &1["action"]) |> Enum.frequencies()

    assert %{
             "candidate_preflight" => 2,
             "awx_unmerge" => 1,
             "reassign_wrong_guest_mac" => 1,
             "candidate_committed" => 2
           } = actions

    # A replay finds nothing left to do.
    assert {:ok, %{reports: %{@step => replay}}} =
             DireRemediation.run(
               [
                 mode: :execute,
                 steps: [@step],
                 manifest_path: Path.join(ctx.dir, "execute_2.ndjson"),
                 actor: ctx.actor
               ] ++ scope
             )

    assert %{unmerged: 0, mac_rows_moved: 0, mac_rows_archived: 0, planned_unmerges: 0} = replay

    # The checks see the pair apart, the MAC gone and the assertion in place.
    assert {:ok, %{reports: %{"awx-proxmox-verify" => verify}}} =
             DireRemediation.run([steps: ["awx-proxmox-verify"]] ++ scope)

    for check <- verify.checks, check.check in ["A1", "A4", "A5"] do
      refute Enum.any?(check.sample, &(&1[:event_id] == w.merge or &1[:device_uid] == w.holder)),
             check.check
    end

    refute Enum.any?(
             Enum.find(verify.checks, &(&1.check == "A2")).sample,
             &(&1.event_id == w.merge)
           )
  end

  test "source-id-rollback merges the pair again and returns the moved MACs", ctx do
    w = guest_world!(ctx)
    manifest = Path.join(ctx.dir, "execute.ndjson")

    assert {:ok, _result} =
             DireRemediation.run(
               mode: :execute,
               steps: [@step],
               manifest_path: manifest,
               actor: ctx.actor,
               awx_proxmox_unmerge_event_ids: [w.merge]
             )

    refute merged?(w.holder)

    assert {:ok, %{reports: %{"source-id-rollback" => dry}}} =
             DireRemediation.run(steps: ["source-id-rollback"], rollback_manifests: [manifest])

    assert %{would_remerge: 1, would_restore_macs: 2} = dry

    assert {:ok, %{reports: %{"source-id-rollback" => rollback}}} =
             DireRemediation.run(
               mode: :execute,
               steps: ["source-id-rollback"],
               rollback_manifests: [manifest],
               manifest_path: Path.join(ctx.dir, "rollback.ndjson"),
               actor: ctx.actor
             )

    assert %{remerged: 1, macs_restored: 2, rollback_failures: 0} = rollback

    # Joined again: the MACs went back to the holder, then with it to the survivor.
    assert merged?(w.holder)
    assert owner("integration_id", w.holder_v2) == w.guest_device
    assert owner("mac", w.copied_mac) == w.guest_device
    refute Deduplication.asserted_distinct?(w.holder, w.guest_device)

    # A replayed rollback does nothing.
    assert {:ok, %{reports: %{"source-id-rollback" => replay}}} =
             DireRemediation.run(
               mode: :execute,
               steps: ["source-id-rollback"],
               rollback_manifests: [manifest],
               manifest_path: Path.join(ctx.dir, "rollback_2.ndjson"),
               actor: ctx.actor
             )

    assert %{remerged: 0, macs_restored: 0, rollback_failures: 0} = replay
  end

  test "undoes a chain survivor first, and reports a chain a non-qualifying merge blocks", ctx do
    # A merged into B, then B into C, both proved: one unit, B's merge away undone first.
    [a, b, c] = for label <- ~w(a b c), do: guest_record!(ctx, label)
    ab = historical_merge!(ctx, a, b, minutes_ago: 30)
    bc = historical_merge!(ctx, b, c, minutes_ago: 20)

    # X merged into Y (proved), then Y into Z by ordinary identity resolution, on a universal MAC
    # that Z shows as its own: that merge proves nothing wrong, so neither is undone.
    shared_mac = mac(ctx.n, 7)
    [x, y] = for label <- ~w(x y), do: guest_record!(ctx, label)
    z = guest_record!(ctx, "z", mac: shared_mac)
    identifier!(ctx.actor, y.uid, :mac, String.replace(shared_mac, ":", ""), %{})
    xy = historical_merge!(ctx, x, y, minutes_ago: 30)
    yz = historical_merge!(ctx, y, z, minutes_ago: 20, reason: "identity_resolution")

    scope = [awx_proxmox_unmerge_event_ids: [ab, bc, xy]]

    assert {:ok, %{reports: %{@step => plan}}} = DireRemediation.run([steps: [@step]] ++ scope)
    assert [%{merges: merges}] = plan.unmerge_plan
    assert Enum.map(merges, & &1.event_id) == [bc, ab]

    assert Enum.find(plan.reported_merges, &(&1.event_id == yz)).disposition ==
             "conflicting_evidence"

    blocked = Enum.find(plan.reported_merges, &(&1.event_id == xy))
    assert %{disposition: "blocked_by_later_merge", blocked_by: ^yz} = blocked

    assert {:ok, %{reports: %{@step => report}}} =
             DireRemediation.run(
               [
                 mode: :execute,
                 steps: [@step],
                 manifest_path: Path.join(ctx.dir, "chain.ndjson"),
                 actor: ctx.actor
               ] ++ scope
             )

    assert %{units_applied: 1, unmerged: 2} = report

    for record <- [a, b] do
      refute merged?(record.uid)
      assert owner("integration_id", record.v2) == record.uid
    end

    # Neither merge of the blocked chain moved.
    assert merged?(x.uid) and merged?(y.uid)
    assert owner("integration_id", x.v2) == z.uid
  end

  test "undoes a merge of another reason that rested on what a bad AWX merge brought, with it",
       ctx do
    # AWX host 2's record merged into host 1's survivor, the host bound by mistake to guest G. The
    # survivor then held G's NIC MAC, and G's own record merged into it on that MAC.
    vmid = 100 + rem(ctx.n, 800_000)
    guest_mac = mac(ctx.n, 5)

    {guest_ref, guest_device} =
      ingest_proxmox_guest!(ctx.actor, "cluster-g-#{ctx.n}", vmid, [guest_mac])

    identifier!(ctx.actor, guest_device, :integration_id, guest_ref, hypervisor(guest_ref))

    identifier!(
      ctx.actor,
      guest_device,
      :mac,
      String.replace(guest_mac, ":", ""),
      hypervisor(guest_ref)
    )

    survivor = awx_record!(ctx, 1)
    host2 = awx_record!(ctx, 2)

    poisoning =
      historical_merge!(ctx, %{uid: host2}, %{uid: survivor},
        minutes_ago: 40,
        details: %{"guest_provider_ref" => guest_ref}
      )

    chained =
      historical_merge!(ctx, %{uid: guest_device}, %{uid: survivor},
        minutes_ago: 30,
        reason: "hypervisor_guest_network_match",
        details: %{"guest_provider_ref" => guest_ref}
      )

    scope = [awx_proxmox_unmerge_event_ids: [poisoning]]

    assert {:ok, %{reports: %{@step => plan}}} = DireRemediation.run([steps: [@step]] ++ scope)
    assert [%{merges: [first, second]}] = plan.unmerge_plan
    assert {first.event_id, first.proofs} == {chained, ["tainted_evidence"]}
    assert {second.event_id, second.proofs} == {poisoning, ["different_awx_hosts"]}
    assert first.match_evidence == ["mac:" <> String.replace(guest_mac, ":", "")]

    assert {:ok, %{reports: %{@step => report}}} =
             DireRemediation.run(
               [
                 mode: :execute,
                 steps: [@step],
                 manifest_path: Path.join(ctx.dir, "poison.ndjson"),
                 actor: ctx.actor
               ] ++ scope
             )

    assert %{units_applied: 1, unmerged: 2, distinct_asserted: 2} = report

    # The guest's record and host 2's record stand apart again, each with its own identity.
    refute merged?(guest_device)
    refute merged?(host2)
    assert owner("integration_id", guest_ref) == guest_device
    assert owner("mac", guest_mac) == guest_device
    assert owner("integration_id", awx_id(2, ctx)) == host2
    assert owner("integration_id", awx_id(1, ctx)) == survivor
  end

  test "archives a copied guest MAC when no live record holds that guest", ctx do
    vmid = 100 + rem(ctx.n, 800_000)
    copied = mac(ctx.n, 6)

    {guest_ref, guest_device} =
      ingest_proxmox_guest!(ctx.actor, "cluster-c-#{ctx.n}", vmid, [copied])

    holder = guest_record!(ctx, "a2")
    survivor = guest_record!(ctx, "b2")
    copied_row = move_mac!(ctx.actor, copied, holder.uid, awx_metadata())
    soft_delete!(ctx, guest_device, "test_guest_gone")

    merge =
      historical_merge!(ctx, holder, survivor,
        minutes_ago: 20,
        details: %{"guest_provider_ref" => guest_ref}
      )

    assert {:ok, %{reports: %{@step => report}}} =
             DireRemediation.run(
               mode: :execute,
               steps: [@step],
               manifest_path: Path.join(ctx.dir, "archive.ndjson"),
               actor: ctx.actor,
               awx_proxmox_unmerge_event_ids: [merge]
             )

    assert %{unmerged: 1, mac_rows_archived: 1, mac_rows_not_settled: 0} = report
    assert owner("mac", copied) == nil
    assert archived(copied_row) == {holder.uid, AwxProxmoxUnmerge.archive_reason()}
  end

  # -- worlds -------------------------------------------------------------------------------

  # A guest of cluster B, reported by its own Proxmox integration, and a guest of cluster A with the
  # same VMID (the holder) that the AWX reconciliation merged into it. Before the merge the holder
  # held three of the cluster B guest's NIC MACs: one an AWX update wrote, one the guest's own
  # Proxmox report refreshed since, and a locally administered one.
  defp guest_world!(ctx) do
    vmid = 100 + rem(ctx.n, 800_000)
    [copied, refreshed, own] = for nic <- 1..3, do: mac(ctx.n, nic)
    local = local_mac(ctx.n, 4)

    {guest_ref, guest_device} =
      ingest_proxmox_guest!(ctx.actor, "cluster-b-#{ctx.n}", vmid, [copied, refreshed, local])

    identifier!(ctx.actor, guest_device, :integration_id, guest_ref, hypervisor(guest_ref))

    holder = device!(ctx.actor, "holder#{ctx.n}")
    holder_v2 = "proxmox:v2:cluster-a-#{ctx.n}:vm:#{vmid}"
    identifier!(ctx.actor, holder, :integration_id, holder_v2, hypervisor(holder_v2))
    identifier!(ctx.actor, holder, :mac, own, %{"integration_type" => "sweep"})

    copied_row = move_mac!(ctx.actor, copied, holder, awx_metadata())
    refreshed_row = move_mac!(ctx.actor, refreshed, holder, hypervisor(guest_ref))
    move_mac!(ctx.actor, local, holder, awx_metadata())

    merge =
      historical_merge!(ctx, %{uid: holder}, %{uid: guest_device},
        minutes_ago: 60,
        details: %{"guest_provider_ref" => guest_ref, "corroboration" => "mac"}
      )

    %{
      vmid: vmid,
      guest_ref: guest_ref,
      guest_device: guest_device,
      holder: holder,
      holder_v2: holder_v2,
      merge: merge,
      copied_mac: copied,
      copied_row: copied_row,
      refreshed_mac: refreshed,
      refreshed_row: refreshed_row,
      local_mac: local
    }
  end

  # An AWX record merged into a device that holds nothing to tell them apart.
  defp ambiguous_merge!(ctx) do
    awx = device!(ctx.actor, "awx#{ctx.n}")

    identifier!(
      ctx.actor,
      awx,
      :integration_id,
      "awx:v2:00000000-0000-4000-8000-0000000000c1:host:#{ctx.n}",
      awx_metadata()
    )

    survivor = device!(ctx.actor, "sweep#{ctx.n}")

    merge =
      historical_merge!(ctx, %{uid: awx}, %{uid: survivor},
        minutes_ago: 50,
        reason: "awx_host_network_match",
        details: %{"corroboration" => "ip_host_name"}
      )

    %{from: awx, merge: merge}
  end

  # A record holding its own cluster's guest identity: every one of them has the same VMID in a
  # cluster of its own, so any two are different machines.
  defp guest_record!(ctx, label, attrs \\ []) do
    uid = device!(ctx.actor, "#{label}#{ctx.n}", Map.new(attrs))
    v2 = "proxmox:v2:cluster-#{label}-#{ctx.n}:vm:101"
    identifier!(ctx.actor, uid, :integration_id, v2, hypervisor(v2))
    %{uid: uid, v2: v2}
  end

  # -- fixtures -----------------------------------------------------------------------------

  defp ingest_proxmox_guest!(actor, cluster, vmid, macs) do
    scope = %{
      integration_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      partition_id: "default"
    }

    # The ingestor skips a guest with no address, so each NIC gets an invented one, distinct per
    # test (the VMID follows the test's number) and per NIC.
    host_base = rem(vmid, 84) * 3 + 1

    interfaces =
      macs
      |> Enum.with_index()
      |> Enum.map(fn {mac, i} ->
        %{
          "name" => "eth#{i}",
          "mac_address" => mac,
          "ip_addresses" => ["192.0.2.#{host_base + i}/24"],
          "source" => "config+agent"
        }
      end)

    payload = %{
      "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "details" => %{
        "schema" => "serviceradar.proxmox_enrichment.v1",
        "targets" => [
          %{
            "cluster" => [%{"type" => "cluster", "name" => cluster}],
            "nodes" => [%{"node" => "pve01", "status" => "online"}],
            "guests" => [
              %{
                "node" => "pve01",
                "type" => "qemu",
                "vmid" => vmid,
                "name" => "vm#{vmid}",
                "status" => "running",
                "interfaces" => interfaces
              }
            ]
          }
        ]
      }
    }

    assert :ok = ProxmoxEnrichmentIngestor.ingest(payload, %{}, actor: actor, source_scope: scope)

    {:ok, identity} =
      IntegrationIdentity.proxmox_v3_fields(
        scope.integration_id,
        scope.controller_id,
        cluster,
        "qemu",
        vmid
      )

    [[uid]] =
      Repo.query!(
        "SELECT device_uid FROM platform.virtualization_guests WHERE provider_ref = $1",
        [identity.provider_ref]
      ).rows

    {identity.provider_ref, uid}
  end

  defp device!(actor, label, attrs \\ %{}) do
    uid = "sr:" <> Ecto.UUID.generate()

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{uid: uid, hostname: "#{label}.example.com", name: label, type: "Server", type_id: 1},
          attrs
        ),
        actor: actor
      )
      |> Ash.create()

    uid
  end

  # An AWX host's record, holding its v2 id of one invented controller.
  defp awx_record!(ctx, host) do
    uid = device!(ctx.actor, "awxhost#{host}-#{ctx.n}")
    identifier!(ctx.actor, uid, :integration_id, awx_id(host, ctx), awx_metadata())
    uid
  end

  defp awx_id(host, ctx), do: "awx:v2:00000000-0000-4000-8000-0000000000c1:host:#{ctx.n}#{host}"

  defp soft_delete!(ctx, uid, reason) do
    {:ok, device} = Device.get_by_uid(uid, false, actor: ctx.actor)

    {:ok, _tombstone} =
      device
      |> Ash.Changeset.for_update(:soft_delete, %{deleted_reason: reason, deleted_by: "test"})
      |> Ash.update(actor: ctx.actor)
  end

  defp identifier!(actor, uid, type, value, metadata) do
    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:upsert, %{
        device_id: uid,
        identifier_type: type,
        identifier_value: value,
        partition: "default",
        confidence: :strong,
        source: "sync_ingestor",
        metadata: metadata
      })
      |> Ash.create(actor: actor)
  end

  # Before the fix, the row of each of these guest MACs sat on the holder instead of the guest's
  # device, last written as `metadata` says.
  defp move_mac!(actor, mac, uid, metadata) do
    value = String.replace(mac, ":", "")
    identifier!(actor, uid, :mac, value, metadata)

    [[id]] =
      Repo.query!(
        """
        UPDATE platform.device_identifiers SET device_id = $2, metadata = $3
        WHERE identifier_type = 'mac' AND identifier_value = $1 AND partition = 'default'
        RETURNING id
        """,
        [value, uid, metadata]
      ).rows

    id
  end

  defp hypervisor(ref),
    do: %{"integration_type" => "hypervisor", "hypervisor_provider_ref" => ref}

  defp awx_metadata,
    do: %{
      "integration_type" => "awx",
      "sync_service_id" => "00000000-0000-4000-8000-00000000a1a1"
    }

  # A merge as the AWX reconciliation recorded it before the fix: the merged record's identifiers
  # move to the survivor and are listed in `source_identifiers`, and the merged record becomes a
  # `merged` tombstone. The audit time is set, so a test can order merges.
  defp historical_merge!(ctx, from, to, opts) do
    reason = Keyword.get(opts, :reason, @guest_reason)
    created_at = DateTime.shift(DateTime.utc_now(), minute: -Keyword.fetch!(opts, :minutes_ago))

    source_identifiers =
      Enum.map(
        Repo.query!(
          """
          SELECT identifier_type::text, identifier_value, partition
          FROM platform.device_identifiers WHERE device_id = $1
          ORDER BY identifier_type, identifier_value
          """,
          [from.uid]
        ).rows,
        fn [type, value, partition] ->
          %{"type" => type, "value" => value, "partition" => partition}
        end
      )

    Repo.query!(
      "UPDATE platform.device_identifiers SET device_id = $2 WHERE device_id = $1",
      [from.uid, to.uid]
    )

    {:ok, device} = Device.get_by_uid(from.uid, false, actor: ctx.actor)
    soft_delete!(ctx, from.uid, "merged")

    details =
      Map.merge(
        %{
          "awx_integration_id" => nil,
          "guest_provider_ref" => nil,
          "corroboration" => "ip_proxmox",
          "source_identifiers" => source_identifiers,
          "source_archived_identifiers" => [],
          "from_device_hostname" => device.hostname,
          "from_device_ip" => nil,
          "to_device_ip_before" => nil
        },
        Keyword.get(opts, :details, %{})
      )

    [[event_id]] =
      Repo.query!(
        """
        INSERT INTO platform.merge_audit
          (event_id, from_device_id, to_device_id, reason, source, details, created_at)
        VALUES (gen_random_uuid(), $1, $2, $3, 'identity_reconciler', $4, $5)
        RETURNING event_id::text
        """,
        [
          from.uid,
          to.uid,
          reason,
          details,
          DateTime.to_naive(DateTime.truncate(created_at, :second))
        ]
      ).rows

    event_id
  end

  # -- reads --------------------------------------------------------------------------------

  defp merged?(uid) do
    [[deleted_reason]] =
      Repo.query!("SELECT deleted_reason FROM platform.ocsf_devices WHERE uid = $1", [uid]).rows

    deleted_reason == "merged"
  end

  defp owner(type, value) do
    case Repo.query!(
           """
           SELECT device_id FROM platform.device_identifiers
           WHERE identifier_type = $1 AND identifier_value = $2
           """,
           [type, String.replace(value, ":", "")]
         ).rows do
      [[uid]] -> uid
      [] -> nil
    end
  end

  defp archived(id) do
    case Repo.query!(
           "SELECT device_id, archive_reason FROM platform.device_identifier_archive WHERE id = $1",
           [id]
         ).rows do
      [[uid, reason]] -> {uid, reason}
      [] -> nil
    end
  end

  # A universally administered MAC: bit 1 of the first octet is clear.
  defp mac(n, nic), do: format_mac([0x00, 0x00, 0x5E, rem(div(n, 256), 256), rem(n, 256), nic])

  # A locally administered MAC: bit 1 of the first octet is set.
  defp local_mac(n, nic),
    do: format_mac([0x02, 0x00, 0x5E, rem(div(n, 256), 256), rem(n, 256), nic])

  defp format_mac(octets) do
    Enum.map_join(octets, ":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
  end
end
