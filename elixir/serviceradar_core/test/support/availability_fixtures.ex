defmodule ServiceRadar.TestSupport.AvailabilityFixtures do
  @moduledoc """
  Shared fixtures and reads for the merged device availability integration tests
  (`add-merged-device-availability`). Every value is invented: 192.0.2.0/24 addresses,
  SITE01-style names and generated ids.
  """

  import ExUnit.Assertions

  alias ServiceRadar.Inventory.Availability.ResolverWorker
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  def create_device!(actor, ip) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "sr:" <> Ash.UUID.generate(),
          ip: ip,
          hostname: "host-" <> String.replace(ip, ".", "-") <> ".example.com",
          discovery_sources: ["netbox"],
          tags: %{}
        },
        actor: actor
      )
      |> Ash.create()

    device
  end

  def sweep_group!(actor) do
    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "SITE01 sweep " <> Ash.UUID.generate(), partition: "default", agent_ids: []},
        actor: actor
      )
      |> Ash.create()

    {group, "agent-" <> Ash.UUID.generate()}
  end

  def sweep!(actor, group, agent_id, ip, available?, checked_at) do
    result = %{
      "host_ip" => ip,
      "available" => available?,
      "port_results" => [],
      "last_sweep_time" => DateTime.to_iso8601(checked_at)
    }

    assert {:ok, _stats} =
             SweepResultsIngestor.ingest_results([result], Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               authenticated_agent_id: agent_id,
               authenticated_partition_id: "default"
             )
  end

  def ledger_row!(actor, device, agent_id, available?, checked_at) do
    {:ok, row} =
      DeviceAgentAvailability
      |> Ash.Changeset.for_create(
        :create,
        %{
          device_uid: device.uid,
          agent_id: agent_id,
          is_available: available?,
          checked_at: checked_at
        },
        actor: actor
      )
      |> Ash.create()

    row
  end

  def update_ledger!(row, actor, attrs) do
    {:ok, row} =
      row
      |> Ash.Changeset.for_update(:update, attrs, actor: actor)
      |> Ash.update()

    row
  end

  @doc "Two validation-scan failures from one agent: confirmed down."
  def confirmed_down!(actor, device, agent_id) do
    row = ledger_row!(actor, device, agent_id, false, minutes_ago(3))
    update_ledger!(row, actor, %{is_available: false, checked_at: minutes_ago(2)})
  end

  def pin!(actor, device, agent_id) do
    {:ok, _} =
      device
      |> Ash.Changeset.for_update(:update, %{availability_source_agent_id: agent_id},
        actor: actor
      )
      |> Ash.update()
  end

  def wifi(uid, state, observed_at) do
    %{
      device_uid: uid,
      source_kind: "wifi_map",
      source_instance: "SITE01-wlc",
      state: state,
      observed_at: observed_at
    }
  end

  def set_mode!(mode) do
    Repo.query!("UPDATE platform.availability_settings SET mode = $1", [mode])
  end

  def drain! do
    case ResolverWorker.pass() do
      %{claimed: 0} -> :ok
      _ -> drain!()
    end
  end

  def minutes_ago(minutes) do
    DateTime.utc_now() |> DateTime.shift(minute: -minutes) |> DateTime.truncate(:microsecond)
  end

  def perform_job(worker, args), do: worker.perform(%Oban.Job{args: args})

  @doc "`{is_available, availability_state, availability_decided_by rule}` of a device."
  def device_state(uid) do
    %{rows: [[available, state, rule]]} =
      Repo.query!(
        """
        SELECT is_available, availability_state, availability_decided_by ->> 'rule'
        FROM platform.ocsf_devices WHERE uid = $1
        """,
        [uid]
      )

    {available, state, rule}
  end

  def ledger(uid) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT agent_id, is_available, checked_at, consecutive_down
        FROM platform.device_agent_availability WHERE device_uid = $1 ORDER BY agent_id
        """,
        [uid]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  def legacy_value(uid) do
    %{rows: [[available]]} =
      Repo.query!(
        "SELECT is_available FROM platform.device_availability_legacy WHERE device_uid = $1",
        [uid]
      )

    available
  end

  def invalidation_uids do
    %{rows: rows} =
      Repo.query!("SELECT device_uid FROM platform.availability_invalidations ORDER BY id")

    Enum.map(rows, &hd/1)
  end
end
