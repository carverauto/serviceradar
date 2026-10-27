defmodule ServiceRadar.TestSupport.AvailabilityFixtures do
  @moduledoc """
  Shared fixtures and reads for the merged device availability integration tests
  (`add-merged-device-availability`). Every value is invented: 192.0.2.0/24 addresses,
  SITE01-style names and generated ids.
  """

  import ExUnit.Assertions

  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Availability.ResolverWorker
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.SyncIngestor
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

  def drain! do
    case ResolverWorker.pass() do
      %{claimed: 0} -> :ok
      _ -> drain!()
    end
  end

  def minutes_ago(minutes) do
    DateTime.utc_now() |> DateTime.shift(minute: -minutes) |> DateTime.truncate(:microsecond)
  end

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

  @doc """
  One agent's sweep results for one execution, as one ingest call. `results` are
  `{ip, available?, checked_at}`; `opts` are passed to the ingestor (an agent's chunk index).
  """
  def sweep_execution!(actor, group, agent_id, execution_id, results, opts \\ []) do
    results =
      Enum.map(results, fn {ip, available?, checked_at} ->
        %{
          "host_ip" => ip,
          "available" => available?,
          "port_results" => [],
          "last_sweep_time" => DateTime.to_iso8601(checked_at)
        }
      end)

    assert {:ok, _stats} =
             SweepResultsIngestor.ingest_results(
               results,
               execution_id,
               [
                 actor: actor,
                 sweep_group_id: group.id,
                 agent_id: agent_id,
                 authenticated_agent_id: agent_id,
                 authenticated_partition_id: "default"
               ] ++ opts
             )
  end

  @doc "A confirmed IP alias of `device` at `ip`, last seen by an identity source at `last_seen_at`."
  def ip_alias!(device, ip, last_seen_at) do
    Repo.query!(
      """
      INSERT INTO platform.device_alias_states
        (device_id, partition, alias_type, alias_value, state, first_seen_at, last_seen_at,
         sighting_count)
      VALUES ($1, 'default', 'ip', $2, 'confirmed', $3, $3, 3)
      """,
      [device.uid, ip, DateTime.to_naive(DateTime.truncate(last_seen_at, :second))]
    )

    :ok
  end

  def days_ago(days),
    do: DateTime.utc_now() |> DateTime.shift(day: -days) |> DateTime.truncate(:second)

  def armis_source!(actor, name, attrs \\ []) do
    attrs =
      Map.merge(
        %{
          name: name <> " " <> Ash.UUID.generate(),
          source_type: :armis,
          endpoint: "https://armis.example.invalid/#{System.unique_integer([:positive])}",
          northbound_enabled: true,
          custom_fields: ["availability"]
        },
        Map.new(attrs)
      )

    IntegrationSource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:credentials, %{secret_key: "secret", api_key: "api"})
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  @doc """
  A source created before merged availability: `legacy` semantics, which new sources
  cannot choose.
  """
  def keep_legacy_semantics!(source) do
    Repo.query!(
      "UPDATE platform.integration_sources SET northbound_availability_semantics = 'legacy' WHERE id = $1",
      [Ecto.UUID.dump!(source.id)]
    )

    %{source | northbound_availability_semantics: :legacy}
  end

  @doc "An Armis sync of one device at `ip`, linked to `source`."
  def ingest_armis!(actor, source, ip, armis_id, available?) do
    update = %{
      "ip" => ip,
      "mac" => unique_mac(),
      "hostname" => "armis-" <> String.replace(ip, ".", "-") <> ".example.com",
      "source" => "armis",
      "is_available" => available?,
      "metadata" => %{
        "armis_device_id" => armis_id,
        "integration_id" => armis_id,
        "integration_type" => "armis"
      },
      "sync_meta" => %{"sync_service_id" => source.id}
    }

    :ok = SyncIngestor.ingest_updates([update], actor: actor)
  end

  defp unique_mac do
    [:positive]
    |> System.unique_integer()
    |> Integer.to_string(16)
    |> String.pad_leading(10, "0")
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
    |> then(&"02:#{&1}")
  end
end
