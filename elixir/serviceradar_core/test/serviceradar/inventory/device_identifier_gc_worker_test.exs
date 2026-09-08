defmodule ServiceRadar.Inventory.DeviceIdentifierGcWorkerTest do
  @moduledoc """
  Integration coverage for identifier TTL garbage collection (DIRE task 8.2).
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceIdentifierGcWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  @prefix "platform"

  @doc false
  def forward_gc_run(_event, measurements, metadata, parent) do
    send(parent, {:gc_run, measurements, metadata})
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:device_identifier_gc_worker_test)
    {:ok, actor: actor}
  end

  test "deletes identifiers unseen past the TTL in batches, keeping fresh rows",
       %{actor: actor} do
    {:ok, device} = create_device(actor)
    suffix = System.unique_integer([:positive, :monotonic])

    old_mac = "gc-old-mac-#{suffix}"
    old_mac_2 = "gc-old-mac2-#{suffix}"
    fresh_mac = "gc-fresh-mac-#{suffix}"

    {:ok, _} = upsert_identifier(actor, device.uid, :mac, old_mac)
    {:ok, _} = upsert_identifier(actor, device.uid, :mac, old_mac_2)
    {:ok, _} = upsert_identifier(actor, device.uid, :mac, fresh_mac)

    age_identifiers([old_mac, old_mac_2], 91)

    stats = DeviceIdentifierGcWorker.run_gc(ttl_days: 90, batch_size: 1, max_batches: 50)

    assert stats.deleted >= 2
    assert stats.batches >= 2
    assert Map.get(stats.counts_by_type, "mac", 0) >= 2

    refute identifier_exists?(old_mac)
    refute identifier_exists?(old_mac_2)
    assert identifier_exists?(fresh_mac)
  end

  test "never deletes agent_id identifiers of agents that still exist", %{actor: actor} do
    {:ok, device} = create_device(actor)
    suffix = System.unique_integer([:positive, :monotonic])

    linked_agent_uid = "gc-linked-agent-#{suffix}"
    orphan_agent_uid = "gc-orphan-agent-#{suffix}"

    {:ok, _agent} = create_agent(actor, linked_agent_uid, device.uid)

    {:ok, _} = upsert_identifier(actor, device.uid, :agent_id, linked_agent_uid)
    {:ok, _} = upsert_identifier(actor, device.uid, :agent_id, orphan_agent_uid)

    age_identifiers([linked_agent_uid, orphan_agent_uid], 400)

    DeviceIdentifierGcWorker.run_gc(ttl_days: 90)

    # The linked agent's identifier survives despite being far past TTL;
    # the orphaned agent_id (no ocsf_agents row) is collected.
    assert identifier_exists?(linked_agent_uid)
    refute identifier_exists?(orphan_agent_uid)
  end

  test "emits a run summary with counts by type", %{actor: actor} do
    {:ok, device} = create_device(actor)
    suffix = System.unique_integer([:positive, :monotonic])

    old_value = "gc-telemetry-mac-#{suffix}"
    {:ok, _} = upsert_identifier(actor, device.uid, :mac, old_value)
    age_identifiers([old_value], 91)

    handler_id = "device-identifier-gc-test-#{suffix}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :device_identifier_gc, :run],
        &__MODULE__.forward_gc_run/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    DeviceIdentifierGcWorker.run_gc(ttl_days: 90)

    assert_received {:gc_run, measurements, metadata}
    assert measurements.deleted >= 1
    assert Map.get(metadata.counts_by_type, "mac", 0) >= 1
    assert metadata.ttl_days == 90
  end

  test "respects the max_batches budget", %{actor: actor} do
    {:ok, device} = create_device(actor)
    suffix = System.unique_integer([:positive, :monotonic])

    values = for n <- 1..4, do: "gc-budget-#{suffix}-#{n}"

    Enum.each(values, fn value -> {:ok, _} = upsert_identifier(actor, device.uid, :mac, value) end)

    age_identifiers(values, 91)

    stats = DeviceIdentifierGcWorker.run_gc(ttl_days: 90, batch_size: 1, max_batches: 2)

    assert stats.batches == 2
    assert stats.deleted == 2
    assert stats.exhausted

    remaining = Enum.count(values, &identifier_exists?/1)
    assert remaining == 2
  end

  defp create_device(actor) do
    uid = "sr:" <> Ecto.UUID.generate()
    seed = System.unique_integer([:positive, :monotonic])

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: uid,
      ip: "10.78.#{rem(seed, 250) + 1}.#{rem(div(seed, 250), 250) + 1}",
      hostname: "gc-test-#{seed}"
    })
    |> Ash.create(actor: actor)
  end

  defp create_agent(actor, agent_uid, device_uid) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_uid,
        name: "GC Test #{agent_uid}",
        host: "127.0.0.1",
        port: 50_051,
        device_uid: device_uid
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp upsert_identifier(actor, device_uid, type, value) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(:upsert, %{
      device_id: device_uid,
      identifier_type: type,
      identifier_value: value,
      partition: "default",
      confidence: :strong,
      source: "test"
    })
    |> Ash.create(actor: actor)
  end

  defp age_identifiers(values, days) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-days * 86_400, :second)
      |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(di in "device_identifiers", where: di.identifier_value in ^values),
        [set: [last_seen: cutoff]],
        prefix: @prefix
      )

    assert count == length(values)
  end

  defp identifier_exists?(value) do
    Repo.exists?(
      from(di in "device_identifiers", where: di.identifier_value == ^value),
      prefix: @prefix
    )
  end
end
