defmodule ServiceRadar.Inventory.Identity.FenceEnforcementTest do
  @moduledoc """
  The identity fence enforced on the sync ingest path (#4618).

  `SyncIngestor` resolves a batch, pins the devices it resolved, and writes the
  device rows and identifiers in one transaction that locks those rows first. These
  tests put an identity transition between the pin and the write through the
  `:identity_fence_test_hooks` barriers, and check the write that follows: it must
  not land on the identity the batch resolved before the transition, it must be
  re-resolved and retried once, and a second transition abandons it with telemetry.

  Unboxed: the mutual-exclusion test needs a second transaction that really waits
  on the batch's row locks, which the shared sandbox cannot model.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Infrastructure.Agent, as: AgentRecord
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Registrar
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:fence_enforcement_test)
    test_pid = self()
    handler_id = "fence-enforcement-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:serviceradar, :identity_fence, :stale],
          [:serviceradar, :identity_fence, :abandoned],
          [:serviceradar, :identity_fence, :fallback]
        ],
        fn event, _measurements, metadata, _config ->
          send(test_pid, {:fence, List.last(event), metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.delete_env(:serviceradar_core, :identity_fence_test_hooks)
    end)

    {:ok, actor: actor, uids: start_supervised!({Agent, fn -> [] end})}
  end

  test "a merge between pin and write moves the write to the survivor", ctx do
    %{actor: actor} = ctx
    source = seed!(ctx, "fence-merge-source")
    survivor = seed!(ctx, "fence-merge-survivor")
    new_mac = doc_mac()

    once(fn -> merge!(source.uid, survivor.uid, actor) end)

    assert :ok =
             ingest(actor, [update(source.integration_id, source.ip, "after-merge", new_mac)])

    # The stale write for the source was withheld and re-resolved: the source's
    # integration id now belongs to the survivor, so the write -- hostname and the
    # new MAC -- landed there, and the tombstone was left alone.
    source_uid = source.uid
    assert_receive {:fence, :stale, %{pipeline: :sync_ingestor, device_id: ^source_uid}}

    assert %Device{deleted_reason: "merged"} = device!(source.uid, actor)
    assert %Device{deleted_at: nil, hostname: "after-merge"} = device!(survivor.uid, actor)
    assert new_mac |> String.replace(":", "") |> String.upcase() |> owner(actor) == survivor.uid
    refute_received {:fence, :abandoned, %{device_id: ^source_uid}}
  end

  test "a merge and a purge between pin and write do not re-create the purged uid", ctx do
    %{actor: actor} = ctx
    source = seed!(ctx, "fence-purge-source")
    survivor = seed!(ctx, "fence-purge-survivor")

    once(fn ->
      merge!(source.uid, survivor.uid, actor)
      assert {_stats, 1} = purge!(source.uid)
    end)

    assert :ok = ingest(actor, [uid_update(source.uid, source.ip, "after-purge")])

    source_uid = source.uid
    assert_receive {:fence, :stale, %{device_id: ^source_uid, current_revision: nil}}

    refute match?({:ok, %Device{}}, Device.get_by_uid(source.uid, true, actor: actor))
    assert %Device{hostname: "after-purge"} = device!(survivor.uid, actor)
  end

  test "a second transition during the retried write abandons it with telemetry", ctx do
    %{actor: actor} = ctx
    device = seed!(ctx, "fence-storm")

    # Every attempt sees its device's identity move under it.
    hook(fn ->
      {:ok, current} = Device.get_by_uid(device.uid, false, actor: actor)
      {:ok, _} = Device.bump_identity_revision(current, actor: actor)
    end)

    assert :ok = ingest(actor, [update(device.integration_id, device.ip, "never-lands", nil)])

    uid = device.uid
    assert_receive {:fence, :stale, %{device_id: ^uid}}
    assert_receive {:fence, :abandoned, %{pipeline: :sync_ingestor, device_id: ^uid}}
    assert %Device{hostname: hostname} = device!(device.uid, actor)
    assert hostname != "never-lands"
  end

  test "a merge that starts while the write holds its locks waits for it", ctx do
    %{actor: actor} = ctx
    source = seed!(ctx, "fence-lock-source")
    survivor = seed!(ctx, "fence-lock-survivor")
    test_pid = self()

    Application.put_env(:serviceradar_core, :identity_fence_test_hooks, %{
      sync_ingestor_in_fenced_write: fn ->
        merge = Task.async(fn -> merge!(source.uid, survivor.uid, actor) end)
        # The merge updates the rows this write has locked, so it cannot finish
        # while the write's transaction is open.
        send(test_pid, {:merge_blocked, Task.yield(merge, 1_000) == nil})
        send(test_pid, {:merge_task, merge})
      end
    })

    assert :ok = ingest(actor, [update(source.integration_id, source.ip, "before-merge", nil)])

    assert_receive {:merge_blocked, true}
    assert_receive {:merge_task, merge}
    assert :ok = Task.await(merge, 30_000)

    # The write committed first, on the device it resolved; the merge then folded
    # that device into the survivor. Nothing was stale.
    source_uid = source.uid
    refute_received {:fence, :stale, %{device_id: ^source_uid}}

    assert %Device{deleted_reason: "merged", hostname: "before-merge"} =
             device!(source.uid, actor)

    assert owner(source.integration_id, actor) == survivor.uid
  end

  test "an agent check-in whose device is merged before its identity writes lands on the survivor",
       ctx do
    %{actor: actor} = ctx
    agent_id = "fence-agent-#{System.unique_integer([:positive])}"
    attrs = agent_attrs(agent_id, unique_ip())

    assert {:ok, agent_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
    on_exit(fn -> cleanup!(agent_uid) end)
    survivor = seed!(ctx, "fence-agent-survivor")

    Application.put_env(:serviceradar_core, :identity_fence_test_hooks, %{
      agent_gateway_sync_after_pin: once_fun(fn -> merge!(agent_uid, survivor.uid, actor) end)
    })

    # The merge moved the agent's identifier to the survivor, so the re-resolved
    # check-in writes there instead of onto the merged-away device.
    assert {:ok, landed} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
    assert landed == survivor.uid

    assert_receive {:fence, :stale, %{pipeline: :agent_gateway_sync, device_id: ^agent_uid}}
    assert %Device{deleted_reason: "merged"} = device!(agent_uid, actor)
    assert owner(agent_id, actor) == survivor.uid
  end

  test "an agent check-in whose fenced identity write fails still completes unfenced", ctx do
    %{actor: actor} = ctx
    agent_id = "fence-agent-fallback-#{System.unique_integer([:positive])}"
    attrs = agent_attrs(agent_id, unique_ip())

    assert {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
    on_exit(fn -> cleanup!(device_uid) end)

    # The agent row exists but is not linked yet.
    assert {:ok, _agent} =
             AgentRecord
             |> Ash.Changeset.for_create(
               :register_connected,
               %{uid: agent_id, name: agent_id, host: "192.0.2.1", port: 50_051},
               actor: actor
             )
             |> Ash.create()

    on_exit(fn -> Repo.query!("DELETE FROM platform.ocsf_agents WHERE uid = $1", [agent_id]) end)

    # An identifier write fails inside the fenced transaction: a duplicate of the
    # agent's own identifier row violates the unique index and aborts it.
    Application.put_env(:serviceradar_core, :identity_fence_test_hooks, %{
      agent_gateway_sync_in_fenced_write:
        once_fun(fn ->
          _ =
            DeviceIdentifier
            |> Ash.Changeset.for_create(:register, %{
              device_id: device_uid,
              identifier_type: :agent_id,
              identifier_value: agent_id,
              partition: "default",
              source: "test"
            })
            |> Ash.create(actor: actor)
        end)
    })

    # Before the fence these writes were best effort; the check-in still completes.
    assert {:ok, ^device_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
    assert_receive {:fence, :fallback, %{pipeline: :agent_gateway_sync, device_id: ^device_uid}}

    assert {:ok, %AgentRecord{device_uid: ^device_uid}} =
             AgentRecord.get_by_uid(agent_id, actor: actor)

    assert owner(agent_id, actor) == device_uid
  end

  test "an agent check-in whose identifiers match two devices commits its writes, then merges",
       ctx do
    %{actor: actor} = ctx
    agent_id = "fence-agent-conflict-#{System.unique_integer([:positive])}"
    mac = doc_mac()
    # device_identifiers stores a MAC normalized: no separators, upper case.
    stored_mac = mac |> String.replace(":", "") |> String.upcase()
    attrs = agent_attrs(agent_id, unique_ip())

    assert {:ok, agent_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
    on_exit(fn -> cleanup!(agent_uid) end)

    # A second device already owns the MAC the agent host will report.
    mac_owner = "fence-mac-owner-#{System.unique_integer([:positive])}"
    assert :ok = ingest(actor, [update(mac_owner, unique_ip(), "mac-owner", mac)])
    other_uid = owner(stored_mac, actor)
    Agent.update(ctx.uids, &[other_uid | &1])
    on_exit(fn -> cleanup!(other_uid) end)
    assert other_uid != agent_uid

    assert {:ok, landed} =
             AgentGatewaySync.ensure_device_for_agent(agent_id, %{attrs | host_macs: [mac]})

    assert landed in [agent_uid, other_uid]
    loser = if landed == agent_uid, do: other_uid, else: agent_uid

    assert %Device{deleted_reason: "merged"} = device!(loser, actor)
    assert %Device{deleted_at: nil} = device!(landed, actor)
    assert owner(agent_id, actor) == landed
    assert owner(stored_mac, actor) == landed
  end

  test "identifier-conflict merges are returned deferred and run only on request", ctx do
    %{actor: actor} = ctx
    first = seed!(ctx, "fence-conflict-first")
    second = seed!(ctx, "fence-conflict-second")
    n = System.unique_integer([:positive])
    armis_id = "fence-armis-#{n}"
    netbox_id = "fence-netbox-#{n}"

    assert :ok = Registrar.register_identifiers(first.uid, %{armis_id: armis_id}, actor: actor)
    assert :ok = Registrar.register_identifiers(second.uid, %{netbox_id: netbox_id}, actor: actor)

    assert {:ok, [{:conflicts, canonical, device_ids, _matches}] = deferred} =
             Registrar.register_identifiers_deferring_merge(
               first.uid,
               %{armis_id: armis_id, netbox_id: netbox_id},
               actor: actor
             )

    assert Enum.sort(device_ids) == Enum.sort([first.uid, second.uid])
    loser = Enum.find(device_ids, &(&1 != canonical))
    assert %Device{deleted_at: nil} = device!(loser, actor)

    assert :ok = Registrar.run_deferred_merge(deferred, actor)

    assert %Device{deleted_reason: "merged"} = device!(loser, actor)
    assert owner(armis_id, actor) == canonical
    assert owner(netbox_id, actor) == canonical
  end

  # ---------------------------------------------------------------------------------------

  defp agent_attrs(agent_id, ip) do
    %{
      hostname: agent_id,
      os: "linux",
      arch: "amd64",
      partition: "default",
      source_ip: ip,
      capabilities: [],
      host_macs: []
    }
  end

  defp seed!(%{actor: actor, uids: uids}, name) do
    integration_id = "#{name}-#{System.unique_integer([:positive])}"
    ip = unique_ip()

    assert :ok = ingest(actor, [update(integration_id, ip, name, nil)])

    uid = owner(integration_id, actor)
    Agent.update(uids, &[uid | &1])
    on_exit(fn -> cleanup!(uid) end)

    %{uid: uid, integration_id: integration_id, ip: ip}
  end

  defp ingest(actor, updates), do: SyncIngestor.ingest_updates(updates, actor: actor)

  defp update(integration_id, ip, hostname, mac) do
    base = %{
      "ip" => ip,
      "hostname" => hostname,
      "source" => "integration-test",
      "metadata" => %{
        "integration_type" => "test-integration",
        "integration_id" => integration_id
      }
    }

    if mac, do: Map.put(base, "mac", mac), else: base
  end

  # A source that already knows the device by uid (NetBox-style).
  defp uid_update(uid, ip, hostname) do
    %{
      "device_id" => uid,
      "ip" => ip,
      "hostname" => hostname,
      "source" => "netbox",
      "metadata" => %{}
    }
  end

  defp once(fun), do: hook(once_fun(fun))

  defp once_fun(fun) do
    fired = :atomics.new(1, [])

    fn ->
      if :atomics.compare_exchange(fired, 1, 0, 1) == :ok, do: fun.()
    end
  end

  defp hook(fun) do
    Application.put_env(:serviceradar_core, :identity_fence_test_hooks, %{
      sync_ingestor_after_pin: fun
    })
  end

  defp merge!(from, to, actor) do
    IdentityReconciler.merge_devices(from, to, actor: actor, reason: "manual_merge")
  end

  defp purge!(uid),
    do: DeviceCleanupWorker.hard_delete_records(%{deleted: 0, errors: 0}, [%{uid: uid}])

  defp device!(uid, actor) do
    {:ok, device} = Device.get_by_uid(uid, true, actor: actor)
    device
  end

  defp owner(value, actor) do
    DeviceIdentifier
    |> Ash.Query.filter(identifier_value == ^value)
    |> Ash.read!(actor: actor)
    |> case do
      [%DeviceIdentifier{device_id: uid}] -> uid
      other -> flunk("expected one identifier row for #{value}, got #{inspect(other)}")
    end
  end

  # Unboxed rows outlive the test. Tombstone and purge through the cleanup worker,
  # which removes every child row that restricts the delete, then the audit rows.
  defp cleanup!(uid) do
    Repo.query!(
      "UPDATE platform.ocsf_devices SET deleted_at = now() WHERE uid = $1 AND deleted_at IS NULL",
      [uid]
    )

    purge!(uid)

    Repo.query!(
      "DELETE FROM platform.merge_audit WHERE from_device_id = $1 OR to_device_id = $1",
      [uid]
    )

    %{rows: [[0]]} =
      Repo.query!("SELECT count(*) FROM platform.ocsf_devices WHERE uid = $1", [uid])
  end

  defp unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    "192.0.2.#{rem(n, 54) + 200}"
  end

  # Invented MAC in the IANA 00:00:5E block, unique for the VM and clear of the
  # 00:00:5E:00:53:xx addresses other suites hard-code (unboxed rows are committed).
  defp doc_mac do
    n = [:positive, :monotonic] |> System.unique_integer() |> rem(0x10000)
    <<a, b>> = <<n::16>>

    "00:00:5E:F1:" <>
      Enum.map_join([a, b], ":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
  end
end
