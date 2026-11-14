defmodule ServiceRadar.Inventory.Remediation.MultiGuestSplitTest do
  @moduledoc """
  Database coverage for the `multi-guest-split` repair and its `multi-guest-verify` check, run
  through `DireRemediation` as an operator runs them: a record holding two hypervisor guests is
  split along its operator-facing bindings, each guest's proven MAC and AWX host rows move with
  it, unproven rows stay and are reported, the split survives the next sync, a replay does
  nothing, and `source-id-rollback` joins the records again. Records whose bindings cannot name
  one guest are left whole.

  Every value is invented: integrations, controllers, VMIDs, hosts, addresses (192.0.2.0/24,
  198.51.100.0/24) and MACs (Proxmox's vendor OUI with invented suffixes).
  """

  use ServiceRadar.DataCase, async: false

  alias Ash.Seed
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.Remediation.DireRemediation
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration
  @moduletag :capture_log

  @step "multi-guest-split"
  @verify "multi-guest-verify"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  # The execute gate is runtime configuration of the VM, so the module runs serially and
  # restores it.
  setup do
    original = Application.get_env(:serviceradar_core, DireRemediation)

    Application.put_env(
      :serviceradar_core,
      DireRemediation,
      Keyword.put(original || [], :enable_multi_guest_split_execute, true)
    )

    n = System.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "multi_guest_split_test_#{n}_#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      case original do
        nil -> Application.delete_env(:serviceradar_core, DireRemediation)
        value -> Application.put_env(:serviceradar_core, DireRemediation, value)
      end
    end)

    controller =
      Seed.seed!(Controller, %{
        name: "multi-guest-split-#{n}",
        base_url: "https://awx.example.com",
        agent_id: "multi-guest-split-agent-#{n}",
        credential_secret_id: CredentialIntegrationFixtures.secret_id!()
      })

    {:ok,
     actor: SystemActor.system(:multi_guest_split_test), n: n, dir: dir, controller: controller.id}
  end

  # Two clusters, each its own integration, reuse VMIDs and hostnames. The record holds guest
  # 104 of one and guest 102 of the other; an AWX membership linked to it names guest 102's
  # address, so guest 102 keeps it although guest 104's reference was registered first.
  test "splits a record of two integrations' guests along its linked AWX host, and rolls back",
       ctx do
    shared = mac(ctx, 9)
    moved = guest_ref(new_scope(), "lxc", 104)
    kept = guest_ref(new_scope(), "lxc", 102)

    record =
      multi_guest_record!(ctx, [
        %{ref: moved, macs: [mac(ctx, 1), shared], addresses: ["192.0.2.16/24"]},
        %{ref: kept, macs: [mac(ctx, 2), shared], addresses: ["198.51.100.3/29"]}
      ])

    awx_kept = awx!(ctx, record, 158, "198.51.100.3", linked: true)
    awx_moved = awx!(ctx, record, 154, "192.0.2.16", linked: false)
    legacy_awx = "awx:host:host#{ctx.n}.example.com"
    identifier!(ctx.actor, record, :integration_id, legacy_awx)
    scope = [multi_guest_split_device_uids: [record]]

    assert {:ok, %{reports: %{@step => plan}}} = DireRemediation.run([steps: [@step]] ++ scope)
    assert %{candidates: 1, planned_splits: 1, planned_rows_moved: 3} = plan
    assert [planned] = plan.plans
    assert %{keeper: ^kept, keeper_basis: "binding", status: :split} = planned

    assert [%{guest: ^moved, rows: rows}] = planned.splits

    assert rows |> Enum.map(& &1.value) |> Enum.sort() ==
             Enum.sort([moved, mac(ctx, 1), awx_moved])

    assert planned.unproven |> Enum.map(& &1.value) |> Enum.sort() ==
             Enum.sort([shared, legacy_awx])

    # The dry run changed nothing, and the check lists the record.
    assert owner(moved) == record

    assert {:error, {:step_failures, %{reports: %{@verify => before}}}} =
             DireRemediation.run(steps: [@verify])

    assert record in hd(before.checks).sample

    manifest = Path.join(ctx.dir, "execute.ndjson")

    assert {:ok, %{reports: %{@step => report}}} =
             DireRemediation.run(
               [mode: :execute, steps: [@step], manifest_path: manifest, actor: ctx.actor] ++
                 scope
             )

    assert %{
             units_applied: 1,
             records_created: 1,
             rows_moved: 3,
             distinct_asserted: 1,
             unit_accounting_failures: 0
           } = report

    guest_record = owner(moved)
    refute guest_record in [nil, record]
    assert owner(mac(ctx, 1)) == guest_record
    assert owner(awx_moved) == guest_record
    assert owner(kept) == record
    assert owner(mac(ctx, 2)) == record
    assert owner(awx_kept) == record
    assert owner(shared) == record
    assert owner(legacy_awx) == record
    assert Deduplication.asserted_distinct?(record, guest_record)

    # The next sync of the moved guest lands on its own record, and the check passes for both.
    assert :ok =
             SyncIngestor.ingest_updates([guest_update(moved, "192.0.2.16", mac(ctx, 1))],
               actor: ctx.actor
             )

    assert owner(moved) == guest_record

    assert {_ok_or_error, %{reports: %{@verify => verified}}} =
             DireRemediation.run(steps: [@verify])

    refute Enum.any?([record, guest_record], &(&1 in hd(verified.checks).sample))

    # A replay finds nothing to split.
    assert {:ok, %{reports: %{@step => replay}}} =
             DireRemediation.run(
               [
                 mode: :execute,
                 steps: [@step],
                 manifest_path: Path.join(ctx.dir, "replay.ndjson"),
                 actor: ctx.actor
               ] ++ scope
             )

    assert %{candidates: 0, units_applied: 0} = replay

    {:ok, _header, entries} = Manifest.read(manifest)

    assert [split] = Enum.filter(entries, &(&1["action"] == "guest_split"))
    assert split["device_uid"] == record and split["new_device_uid"] == guest_record

    assert {:ok, %{reports: %{"source-id-rollback" => rollback}}} =
             DireRemediation.run(
               mode: :execute,
               steps: ["source-id-rollback"],
               rollback_manifests: [manifest],
               manifest_path: Path.join(ctx.dir, "rollback.ndjson"),
               actor: ctx.actor
             )

    assert %{remerged: 1, rollback_failures: 0} = rollback
    assert owner(moved) == record
    assert owner(mac(ctx, 1)) == record
    assert deleted_reason(guest_record) == "merged"
    refute Deduplication.asserted_distinct?(record, guest_record)
  end

  # Two containers of one integration share a hostname. The agent linked to the record reports
  # container 107's address, so container 107 keeps it although 106 registered first.
  test "splits two guests of one integration along the record's agent", ctx do
    scope = new_scope()
    moved = guest_ref(scope, "lxc", 106)
    kept = guest_ref(scope, "lxc", 107)

    record =
      multi_guest_record!(ctx, [
        %{
          ref: moved,
          macs: [mac(ctx, 1), mac(ctx, 3)],
          addresses: ["192.0.2.200/24", "198.51.100.13/24"]
        },
        %{
          ref: kept,
          macs: [mac(ctx, 2), mac(ctx, 4)],
          addresses: ["192.0.2.14/24", "198.51.100.14/24"]
        }
      ])

    agent!(ctx, record, "192.0.2.14")

    assert {:ok, %{reports: %{@step => report}}} =
             DireRemediation.run(
               mode: :execute,
               steps: [@step],
               manifest_path: Path.join(ctx.dir, "execute.ndjson"),
               actor: ctx.actor,
               multi_guest_split_device_uids: [record]
             )

    assert %{units_applied: 1, rows_moved: 3} = report
    assert owner(kept) == record
    assert owner(mac(ctx, 2)) == record and owner(mac(ctx, 4)) == record

    guest_record = owner(moved)
    refute guest_record in [nil, record]
    assert owner(mac(ctx, 1)) == guest_record and owner(mac(ctx, 3)) == guest_record
  end

  # Bindings that name two guests, or one no guest's NICs report, leave the record whole.
  test "a record whose bindings do not name one guest is reported and left whole", ctx do
    guests = fn ctx ->
      scope = new_scope()

      [
        %{ref: guest_ref(scope, "qemu", 201), macs: [mac(ctx, 1)], addresses: ["192.0.2.31/24"]},
        %{
          ref: guest_ref(scope, "qemu", 202),
          macs: [mac(ctx, 2)],
          addresses: ["198.51.100.31/24"]
        }
      ]
    end

    ctx = %{ctx | n: ctx.n * 10 + 1}
    conflicting = multi_guest_record!(ctx, guests.(ctx))
    agent!(ctx, conflicting, "192.0.2.31")
    awx!(ctx, conflicting, 170, "198.51.100.31", linked: true)

    ctx = %{ctx | n: ctx.n * 10 + 2}
    unproven = multi_guest_record!(ctx, guests.(ctx))
    agent!(ctx, unproven, "198.51.100.99")

    assert {:ok, %{reports: %{@step => report}}} =
             DireRemediation.run(
               mode: :execute,
               steps: [@step],
               manifest_path: Path.join(ctx.dir, "execute.ndjson"),
               actor: ctx.actor,
               multi_guest_split_device_uids: [conflicting, unproven]
             )

    assert %{
             candidates: 2,
             units_applied: 0,
             units_skipped: %{"ambiguous_keeper" => 1, "unproven_binding" => 1},
             unit_accounting_failures: 0
           } = report

    for record <- [conflicting, unproven] do
      assert length(guest_refs(record)) == 2
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # One integration's controller and cluster.
  defp new_scope, do: {Ecto.UUID.generate(), Ecto.UUID.generate()}

  defp guest_ref({integration, controller}, kind, vmid),
    do: "proxmox:v3:#{integration}:#{controller}:cluster:#{kind}:#{vmid}"

  # A live record holding each guest's reference (registered in order, a minute apart) and NIC
  # MACs, and the guests' own hypervisor inventory: their names and NICs.
  defp multi_guest_record!(ctx, guests) do
    uid = "sr:" <> Ecto.UUID.generate()

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(:create, %{uid: uid, hostname: "guest#{ctx.n}.example.com"},
        actor: ctx.actor
      )
      |> Ash.create()

    guests
    |> Enum.with_index()
    |> Enum.each(fn {guest, index} ->
      identifier!(ctx.actor, uid, :integration_id, guest.ref)

      Repo.query!(
        """
        UPDATE platform.device_identifiers SET first_seen = now() - make_interval(mins => $2)
        WHERE identifier_type = 'integration_id' AND identifier_value = $1
        """,
        [guest.ref, 60 - index]
      )

      {host_id, guest_id} = inventory_guest!(ctx, guest.ref, uid, index)

      for {mac, nic} <- Enum.with_index(guest.macs) do
        if !owner(mac), do: identifier!(ctx.actor, uid, :mac, mac)

        Repo.query!(
          """
          INSERT INTO platform.virtualization_network_interfaces
            (id, provider, provider_ref, host_id, name, guest_id, guest_provider_ref, mac_address,
             ip_addresses, device_uid, observed_at)
          VALUES ($1::uuid, 'proxmox', $2, $3::uuid, $4, $5::uuid, $6, $7, $8::text[], $9, now())
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            "#{guest.ref}:net#{nic}",
            Ecto.UUID.dump!(host_id),
            "eth#{nic}",
            Ecto.UUID.dump!(guest_id),
            guest.ref,
            mac,
            if(nic == 0, do: Enum.take(guest.addresses, 1), else: Enum.drop(guest.addresses, 1)),
            uid
          ]
        )
      end
    end)

    uid
  end

  # The guest's authoritative v3 inventory row and the v3 node it runs on.
  defp inventory_guest!(ctx, ref, uid, index) do
    {:ok, guest} = IntegrationIdentity.parse_v3(ref)
    node = "pve#{index}-#{ctx.n}"
    host_ref = "#{guest.provider_instance_ref}:node:#{node}"
    host_id = Ecto.UUID.generate()
    guest_id = Ecto.UUID.generate()

    for {table, id, row_ref, kind, object, name, extra, extra_values} <- [
          {"virtualization_hosts", host_id, host_ref, "node", node, node, "", []},
          {"virtualization_guests", guest_id, ref, guest.object_kind, guest.native_object_id,
           "guest#{ctx.n}", ", guest_type, host_id, device_uid",
           [guest.object_kind, Ecto.UUID.dump!(host_id), uid]}
        ] do
      placeholders = Enum.map_join(1..length(extra_values)//1, "", &", $#{9 + &1}")

      Repo.query!(
        """
        INSERT INTO platform.#{table}
          (id, provider, provider_ref, identity_version, identity_state, integration_id,
           controller_id, native_cluster_id, object_kind, native_object_id,
           provider_instance_ref, name, observed_at#{extra})
        VALUES ($1::uuid, 'proxmox', $2, 3, 'authoritative', $3::uuid, $4::uuid, $5, $6, $7, $8,
                $9, now()#{placeholders})
        """,
        [
          Ecto.UUID.dump!(id),
          row_ref,
          Ecto.UUID.dump!(guest.integration_id),
          Ecto.UUID.dump!(guest.controller_id),
          guest.native_cluster_id,
          kind,
          object,
          guest.provider_instance_ref,
          name
        ] ++ extra_values
      )
    end

    {host_id, guest_id}
  end

  # An AWX host row on the record and the host's current membership, linked to the record or not.
  defp awx!(ctx, record, host, ansible_host, linked: linked?) do
    host_id = ctx.n * 1000 + host
    value = "awx:v2:#{ctx.controller}:host:#{host_id}"
    identifier!(ctx.actor, record, :integration_id, value)

    Repo.query!(
      """
      INSERT INTO platform.ansible_awx_host_memberships
        (controller_id, inventory_id, awx_host_id, source_generation, host_name, ansible_host,
         last_seen_at, source_fingerprint, canonical_device_uid, link_disposition)
      VALUES ($1::uuid, 68, $2, 1, $3, $4, now(), 'test', $5, $6)
      """,
      [
        Ecto.UUID.dump!(ctx.controller),
        host_id,
        "host#{host_id}.example.com",
        ansible_host,
        if(linked?, do: record),
        if(linked?, do: "approved", else: "unlinked")
      ]
    )

    value
  end

  defp agent!(ctx, record, ip) do
    Repo.query!(
      "INSERT INTO platform.ocsf_agents (uid, ip, device_uid) VALUES ($1, $2, $3)",
      ["agent-#{ctx.n}-#{System.unique_integer([:positive])}", ip, record]
    )
  end

  defp identifier!(actor, uid, type, value) do
    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: uid,
        identifier_type: type,
        identifier_value: value,
        partition: "default",
        confidence: :strong,
        source: "sync_ingestor"
      })
      |> Ash.create(actor: actor)
  end

  defp guest_update(ref, ip, mac) do
    %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "guest.example.com",
      "source" => "hypervisor_enrichment",
      "metadata" => %{
        "integration_id" => ref,
        "integration_type" => "hypervisor",
        "hypervisor_provider" => "proxmox",
        "hypervisor_provider_ref" => ref
      }
    }
  end

  defp owner(value) do
    case Repo.query!(
           "SELECT device_id FROM platform.device_identifiers WHERE identifier_value = $1",
           [value]
         ).rows do
      [[uid]] -> uid
      [] -> nil
    end
  end

  defp guest_refs(uid) do
    Repo.query!(
      """
      SELECT identifier_value FROM platform.device_identifiers
      WHERE device_id = $1 AND identifier_value LIKE 'proxmox:v3:%'
      """,
      [uid]
    ).rows
  end

  defp deleted_reason(uid) do
    [[reason]] =
      Repo.query!("SELECT deleted_reason FROM platform.ocsf_devices WHERE uid = $1", [uid]).rows

    reason
  end

  defp mac(ctx, nic) do
    suffix =
      (ctx.n * 16 + nic)
      |> rem(0x1000000)
      |> Integer.to_string(16)
      |> String.pad_leading(6, "0")

    "BC2411" <> suffix
  end
end
