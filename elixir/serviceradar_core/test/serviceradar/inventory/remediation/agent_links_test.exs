defmodule ServiceRadar.Inventory.Remediation.AgentLinksTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadar.Inventory.Remediation.AgentLinks
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag :tmp_dir

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:agent_links_restore_test)}
  end

  test "an unpurged tombstone keeps its recorded address when another live device holds the agent IP",
       %{
         actor: actor,
         tmp_dir: tmp_dir
       } do
    seed = System.unique_integer([:positive])
    host = "sr-agent-#{seed}.example.com"
    agent_ip = invented_ip(seed)
    recorded_ip = invented_ip(seed + 10_000)
    holder = create_device("sr:agent-links-holder-#{seed}", host <> ".holder", agent_ip, actor)
    tombstone = create_device("sr:agent-links-tomb-#{seed}", host, recorded_ip, actor)

    assert {:ok, _} =
             Device.soft_delete(tombstone, "stale", "system:agent_links_test", actor: actor)

    Repo.query!(
      "UPDATE platform.ocsf_devices SET hostname = $1, ip = $2, identity_purged_at = NULL, agent_id = NULL WHERE uid = $3",
      [host, recorded_ip, tombstone.uid]
    )

    agent = register_agent("sr:agent-links-#{seed}", host, agent_ip, nil, actor)
    report = execute(agent, tmp_dir, actor)

    assert report.errors == 0
    assert report.restore == 1
    assert {:ok, restored} = Device.get_by_uid(tombstone.uid, false, actor: actor)
    assert restored.deleted_at == nil
    assert restored.ip == recorded_ip
    assert {:ok, kept} = Device.get_by_uid(holder.uid, false, actor: actor)
    assert kept.deleted_at == nil
    assert kept.ip == agent_ip
  end

  test "a purge between planning and restore refills the scrubbed identity", %{
    actor: actor,
    tmp_dir: tmp_dir
  } do
    seed = System.unique_integer([:positive])
    host = "sr-agent-purged-#{seed}.example.com"
    agent_ip = invented_ip(seed + 20_000)
    recorded_ip = invented_ip(seed + 30_000)
    tombstone = create_device("sr:agent-links-purged-#{seed}", host, recorded_ip, actor)

    assert {:ok, _} =
             Device.soft_delete(tombstone, "stale", "system:agent_links_test", actor: actor)

    Repo.query!(
      """
      UPDATE platform.ocsf_devices
      SET hostname = $1, ip = $2, identity_purged_at = NULL, agent_id = NULL
      WHERE uid = $3
      """,
      [host, recorded_ip, tombstone.uid]
    )

    agent = register_agent("sr:agent-purged-#{seed}", host, agent_ip, nil, actor)
    parent = self()
    flag = :agent_links_purge_during_execute
    Process.delete(flag)
    handler = {__MODULE__, :purge_during_restore, make_ref()}
    event = Repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, _measurements, metadata, {flag, host, uid, parent} ->
          if self() == parent and Process.get(flag) != true and
               param_equals?(metadata[:params], host) do
            Process.put(flag, true)
            DeviceCleanupWorker.hard_delete_records(%{deleted: 0, errors: 0}, [%{uid: uid}])

            assert [[purged_at]] =
                     Repo.query!(
                       "SELECT identity_purged_at FROM platform.ocsf_devices WHERE uid = $1",
                       [uid]
                     ).rows

            assert purged_at
            send(parent, :purged_before_restore)
          end
        end,
        {flag, host, tombstone.uid, parent}
      )

    try do
      report = execute(agent, tmp_dir, actor)
      assert_receive :purged_before_restore
      assert report.errors == 0
      assert {:ok, restored} = Device.get_by_uid(tombstone.uid, false, actor: actor)
      assert restored.deleted_at == nil
      assert restored.hostname == host
      assert {:ok, %Agent{device_uid: device_uid}} = Ash.get(Agent, agent.uid, actor: actor)
      assert device_uid == tombstone.uid
    after
      :telemetry.detach(handler)
      Process.delete(flag)
    end
  end

  defp param_equals?(params, host) when is_list(params), do: Enum.any?(params, &(&1 == host))

  defp param_equals?(params, host) when is_map(params) do
    Enum.any?(Map.values(params), &(&1 == host))
  end

  defp param_equals?(_params, _host), do: false

  defp execute(agent, tmp_dir, actor) do
    path = Path.join(tmp_dir, "agent-links-#{agent.uid}.jsonl")
    manifest = Manifest.open(path, %{test: "agent_links"})

    try do
      AgentLinks.run(:execute, [agent_uids: [agent.uid]], manifest, actor)
    after
      Manifest.close(manifest)
    end
  end

  defp register_agent(uid, host, ip, device_uid, actor) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{uid: uid, name: host, host: host, ip: ip, port: 50_051, device_uid: device_uid},
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_device(uid, hostname, ip, actor) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      %{uid: uid, hostname: hostname, ip: ip, discovery_sources: ["mapper"]},
      actor: actor
    )
    |> Ash.create!()
  end

  defp invented_ip(seed) do
    "198.51.100.#{rem(seed, 254) + 1}"
  end
end
