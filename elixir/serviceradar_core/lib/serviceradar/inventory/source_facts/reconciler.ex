defmodule ServiceRadar.Inventory.SourceFacts.Reconciler do
  @moduledoc """
  Persist per-source facts, promote canonical device fields, and record
  disagreements. DIRE last-writer upserts do not set these fields.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceSourceFact
  alias ServiceRadar.Inventory.SourceFactAuthority
  alias ServiceRadar.Inventory.SourceFactDisagreement
  alias ServiceRadar.Inventory.SourceFacts
  alias ServiceRadar.Inventory.SourceFacts.Events
  alias ServiceRadar.Repo

  require Logger

  @facts_table "device_source_facts"
  @disagreements_table "source_fact_disagreements"
  @prefix "platform"

  @spec ingest_resolved([{map(), String.t()}], keyword()) :: :ok
  def ingest_resolved(resolved_updates, opts \\ [])

  def ingest_resolved(resolved_updates, opts) when is_list(resolved_updates) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    authorities = load_authorities()

    resolved_updates
    |> Enum.group_by(fn {_update, device_uid} -> device_uid end)
    |> Enum.each(fn {device_uid, pairs} ->
      Enum.each(pairs, fn {update, _} ->
        persist_update_facts(device_uid, update, now)
      end)

      reconcile_device(device_uid, authorities, now)
    end)

    :ok
  rescue
    error ->
      Logger.warning("Source fact ingest failed: #{Exception.message(error)}")
      :ok
  end

  def ingest_resolved(_resolved_updates, _opts), do: :ok

  @spec reconcile_device(String.t(), list() | nil, DateTime.t()) :: :ok
  def reconcile_device(device_uid, authorities \\ nil, now \\ DateTime.utc_now())

  def reconcile_device(device_uid, authorities, now) when is_binary(device_uid) do
    authorities = authorities || load_authorities()
    facts = load_present_facts(device_uid)
    current = load_canonical(device_uid)

    Enum.each(SourceFacts.keys(), fn fact_key ->
      key_facts = Enum.filter(facts, &(&1.fact_key == fact_key))
      key_authorities = Enum.filter(authorities, &(&1.fact_key == fact_key))
      current_value = current_for(current, fact_key)

      case SourceFacts.decide(key_facts, key_authorities, current_value) do
        {:promote, winner, disagreement} ->
          promote(device_uid, winner, now)
          sync_disagreement(device_uid, fact_key, disagreement, now)

        {:hold, disagreement} ->
          sync_disagreement(device_uid, fact_key, disagreement, now)

        {:config_conflict, disagreement} ->
          sync_disagreement(device_uid, fact_key, disagreement, now)

        :noop ->
          sync_disagreement(device_uid, fact_key, nil, now)
      end
    end)

    :ok
  end

  def reconcile_device(_device_uid, _authorities, _now), do: :ok

  @spec backfill(keyword()) :: %{promoted: non_neg_integer(), scanned: non_neg_integer()}
  def backfill(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50_000)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    authorities = load_authorities()

    rows =
      Repo.all(
        from(d in Device,
          where:
            fragment(
              "(coalesce((? ->> 'armis_access_switch'), '') <> '' OR coalesce((? ->> 'armis_vlans'), '') <> '' OR coalesce((? ->> 'armis_vlan'), '') <> '')",
              d.metadata,
              d.metadata,
              d.metadata
            ),
          select: %{uid: d.uid, metadata: d.metadata},
          limit: ^limit
        )
      )

    Enum.each(rows, fn row ->
      update = %{
        source: "armis",
        source_instance: "default",
        metadata: stringify_keys(row.metadata || %{})
      }

      persist_update_facts(row.uid, update, now)
      reconcile_device(row.uid, authorities, now)
    end)

    promoted =
      Repo.one(
        from(d in Device,
          where:
            fragment(
              "(coalesce((? ->> 'armis_access_switch'), '') <> '' OR coalesce((? ->> 'armis_vlans'), '') <> '' OR coalesce((? ->> 'armis_vlan'), '') <> '') AND (switch_port_attachment IS NOT NULL OR vlan_uid IS NOT NULL)",
              d.metadata,
              d.metadata,
              d.metadata
            ),
          select: count(d.uid)
        )
      )

    scanned = length(rows)

    if scanned > 0 and promoted == 0 do
      raise "source-fact backfill wrote no canonical fields for #{scanned} Armis attachment rows"
    end

    %{promoted: promoted, scanned: scanned}
  end

  defp persist_update_facts(device_uid, update, now) do
    source = SourceFacts.source(update)
    instance = SourceFacts.source_instance(update)
    reported = SourceFacts.extract(update)
    reported_keys = MapSet.new(Enum.map(reported, & &1.fact_key))

    Enum.each(reported, fn fact ->
      upsert_fact(device_uid, source, instance, fact, true, now)
    end)

    SourceFacts.keys()
    |> Enum.reject(&MapSet.member?(reported_keys, &1))
    |> Enum.each(fn fact_key ->
      mark_absent(device_uid, source, instance, fact_key, now)
    end)
  end

  defp upsert_fact(device_uid, source, instance, fact, present, now) do
    # insert_all on a table name skips Ecto UUID dumping; Postgrex needs 16 bytes.
    row = %{
      id: Ecto.UUID.bingenerate(),
      device_uid: device_uid,
      source: source,
      source_instance: instance,
      fact_key: fact.fact_key,
      compare_hash: fact.compare_hash,
      value: fact.value,
      raw: fact[:raw],
      present: present,
      observed_at: now,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(@facts_table, [row],
      prefix: @prefix,
      conflict_target: [:device_uid, :source, :source_instance, :fact_key],
      on_conflict: {:replace, [:compare_hash, :value, :raw, :present, :observed_at, :updated_at]}
    )
  end

  defp mark_absent(device_uid, source, instance, fact_key, now) do
    Repo.update_all(
      from(f in DeviceSourceFact,
        where:
          f.device_uid == ^device_uid and f.source == ^source and f.source_instance == ^instance and
            f.fact_key == ^fact_key and f.present == true
      ),
      set: [present: false, updated_at: now]
    )
  end

  defp promote(device_uid, winner, now) do
    updates =
      Keyword.merge([modified_time: DateTime.truncate(now, :second)], canonical_updates(winner))

    Repo.update_all(from(d in Device, where: d.uid == ^device_uid), set: updates)
  end

  defp canonical_updates(
         %{fact_key: "switch_port_attachment", value: value, source: source} = fact
       ) do
    attachment =
      value
      |> Map.put("source", source)
      |> Map.put("source_instance", fact.source_instance)
      |> Map.put("observed_at", DateTime.to_iso8601(fact[:observed_at] || DateTime.utc_now()))

    [switch_port_attachment: attachment]
  end

  defp canonical_updates(%{fact_key: "vlan_uid", value: value}) do
    [vlan_uid: Map.get(value, "vlan_uid")]
  end

  defp canonical_updates(_fact), do: []

  defp sync_disagreement(device_uid, fact_key, nil, now) do
    open = open_disagreement(device_uid, fact_key)

    if open do
      Repo.update_all(from(d in SourceFactDisagreement, where: d.id == ^open.id),
        set: [status: "cleared", cleared_at: now, updated_at: now]
      )

      Events.emit(:cleared, open)
    end

    :ok
  end

  defp sync_disagreement(device_uid, fact_key, disagreement, now) do
    open = open_disagreement(device_uid, fact_key)
    signature = disagreement.compare_signature
    values = disagreement.values
    config? = disagreement.configuration_conflict == true

    cond do
      is_nil(open) ->
        id = Ecto.UUID.generate()

        row = %{
          id: Ecto.UUID.dump!(id),
          device_uid: device_uid,
          fact_key: fact_key,
          status: "open",
          compare_signature: signature,
          values: values,
          configuration_conflict: config?,
          first_detected_at: now,
          last_detected_at: now,
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }

        Repo.insert_all(@disagreements_table, [row], prefix: @prefix)
        Events.emit(:opened, Map.put(row, :id, id))

      open.compare_signature == signature and open.configuration_conflict == config? ->
        Repo.update_all(from(d in SourceFactDisagreement, where: d.id == ^open.id),
          set: [last_detected_at: now, updated_at: now]
        )

      true ->
        Repo.update_all(from(d in SourceFactDisagreement, where: d.id == ^open.id),
          set: [
            compare_signature: signature,
            values: values,
            configuration_conflict: config?,
            last_detected_at: now,
            updated_at: now
          ]
        )

        Events.emit(:changed, %{
          id: open.id,
          device_uid: device_uid,
          fact_key: fact_key,
          values: values,
          configuration_conflict: config?
        })
    end

    :ok
  end

  defp open_disagreement(device_uid, fact_key) do
    Repo.one(
      from(d in SourceFactDisagreement,
        where: d.device_uid == ^device_uid and d.fact_key == ^fact_key and d.status == "open",
        select: %{
          id: d.id,
          device_uid: d.device_uid,
          fact_key: d.fact_key,
          compare_signature: d.compare_signature,
          configuration_conflict: d.configuration_conflict,
          values: d.values
        },
        limit: 1
      )
    )
  end

  defp load_present_facts(device_uid) do
    Repo.all(
      from(f in DeviceSourceFact,
        where: f.device_uid == ^device_uid and f.present == true,
        select: %{
          device_uid: f.device_uid,
          source: f.source,
          source_instance: f.source_instance,
          fact_key: f.fact_key,
          compare_hash: f.compare_hash,
          value: f.value,
          raw: f.raw,
          present: f.present,
          observed_at: f.observed_at
        }
      )
    )
  end

  defp load_canonical(device_uid) do
    Repo.one(
      from(d in Device,
        where: d.uid == ^device_uid,
        select: %{switch_port_attachment: d.switch_port_attachment, vlan_uid: d.vlan_uid},
        limit: 1
      )
    )
  end

  defp current_for(nil, _key), do: nil

  defp current_for(current, "switch_port_attachment"), do: current.switch_port_attachment

  defp current_for(current, "vlan_uid"), do: current.vlan_uid
  defp current_for(_current, _key), do: nil

  defp load_authorities do
    Repo.all(
      from(a in SourceFactAuthority,
        where: a.enabled == true,
        select: %{
          source_kind: a.source_kind,
          source_ref: a.source_ref,
          source: a.source,
          source_instance: a.source_instance,
          fact_key: a.fact_key,
          rank: a.rank,
          enabled: a.enabled,
          inserted_at: a.inserted_at
        },
        order_by: [asc: a.rank, asc: a.inserted_at]
      )
    )
  rescue
    _ -> []
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_keys(_map), do: %{}
end
