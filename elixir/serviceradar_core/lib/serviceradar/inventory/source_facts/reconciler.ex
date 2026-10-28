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

  # Before SourceFacts read an absent key as absent, every update without an explicit
  # source instance was stored under this one. See retire_legacy_instance_facts/2.
  @legacy_instance "nil"

  # Rows per fact upsert: each row binds 12 parameters, under PostgreSQL's 65,535.
  @upsert_chunk_size 1_000

  @doc """
  Records the facts of a sync batch's written `{update, device_uid}` pairs and reconciles
  each device.

  The batch costs a fixed number of statements, whatever its size: the facts are written
  with one upsert and one absent mark, and the devices' facts, canonical values and open
  disagreements are read once for all of them. A device is written on its own only when
  its facts promote a canonical value or it has a disagreement to open, refresh or clear.
  When a batch carries several updates of one source for a device, the last one decides
  each fact, as writing them in order did.
  """
  @spec ingest_resolved([{map(), String.t()}], keyword()) :: :ok
  def ingest_resolved(resolved_updates, opts \\ [])

  def ingest_resolved(resolved_updates, opts) when is_list(resolved_updates) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    authorities = load_authorities()

    resolved_updates =
      Enum.filter(resolved_updates, fn {_update, device_uid} -> is_binary(device_uid) end)

    persist_batch_facts(resolved_updates, now)
    retire_legacy_instance_facts(resolved_updates, now)

    resolved_updates
    |> Enum.map(fn {_update, device_uid} -> device_uid end)
    |> Enum.uniq()
    |> reconcile_devices(authorities, now)

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
    reconcile_devices([device_uid], authorities || load_authorities(), now)
  end

  def reconcile_device(_device_uid, _authorities, _now), do: :ok

  defp reconcile_devices([], _authorities, _now), do: :ok

  defp reconcile_devices(device_uids, authorities, now) do
    facts = device_uids |> load_present_facts() |> Enum.group_by(& &1.device_uid)
    current = load_canonical(device_uids)
    open = load_open_disagreements(device_uids)

    Enum.each(device_uids, fn device_uid ->
      reconcile_loaded(
        device_uid,
        Map.get(facts, device_uid, []),
        Map.get(current, device_uid),
        open,
        authorities,
        now
      )
    end)
  end

  defp reconcile_loaded(device_uid, facts, current, open, authorities, now) do
    Enum.each(SourceFacts.keys(), fn fact_key ->
      key_facts = Enum.filter(facts, &(&1.fact_key == fact_key))
      key_authorities = Enum.filter(authorities, &(&1.fact_key == fact_key))
      current_value = current_for(current, fact_key)
      key_open = Map.get(open, {device_uid, fact_key})

      case SourceFacts.decide(key_facts, key_authorities, current_value) do
        {:promote, winner, disagreement} ->
          promote(device_uid, winner, now)
          sync_disagreement(device_uid, fact_key, key_open, disagreement, now)

        {:hold, disagreement} ->
          sync_disagreement(device_uid, fact_key, key_open, disagreement, now)

        {:config_conflict, disagreement} ->
          sync_disagreement(device_uid, fact_key, key_open, disagreement, now)

        :noop ->
          sync_disagreement(device_uid, fact_key, key_open, nil, now)
      end
    end)
  end

  @doc """
  Records one fact an external caller reported under its own source and
  instance, then reconciles the device.

  A sync update replaces everything its source knows about a device, so keys it
  omits are marked absent. A report names one key and says nothing about the
  others, so the caller's other facts are left as they are.
  """
  @spec report(String.t(), String.t(), String.t(), SourceFacts.fact(), keyword()) :: :ok
  def report(device_uid, source, instance, fact, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    upsert_fact(device_uid, source, instance, fact, true, now)
    reconcile_device(device_uid, nil, now)
  end

  @doc """
  Withdraws a caller's fact, then reconciles the device.

  Reconciliation keeps a canonical value when no source reports the fact any
  more, which suits a sync source that skipped one snapshot. A caller that
  withdraws its value has said the value is gone. So when the withdrawn value is
  the canonical one and no present source still reports it, the canonical value
  is cleared rather than left with nothing behind it. Withdrawing a fact that is
  not present is a no-op.
  """
  @spec retract(String.t(), String.t(), String.t(), String.t(), keyword()) :: :ok
  def retract(device_uid, source, instance, fact_key, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case load_fact(device_uid, source, instance, fact_key) do
      %{present: true, compare_hash: withdrawn_hash} ->
        mark_absent(device_uid, source, instance, fact_key, now)
        reconcile_device(device_uid, nil, now)
        clear_unsupported_canonical(device_uid, fact_key, withdrawn_hash, now)

      _absent ->
        :ok
    end
  end

  @doc """
  The caller's recorded fact for one key, the device's canonical value for that
  key, and whether a disagreement is open on it.
  """
  @spec snapshot(String.t(), String.t(), String.t(), String.t()) :: %{
          fact: map() | nil,
          canonical: term(),
          disagreement_open: boolean()
        }
  def snapshot(device_uid, source, instance, fact_key) do
    fact =
      case load_fact(device_uid, source, instance, fact_key) do
        nil -> nil
        loaded -> Map.take(loaded, [:value, :present, :observed_at])
      end

    %{
      fact: fact,
      canonical: [device_uid] |> load_canonical() |> Map.get(device_uid) |> current_for(fact_key),
      disagreement_open:
        [device_uid] |> load_open_disagreements() |> Map.has_key?({device_uid, fact_key})
    }
  end

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
      # The instance comes from the device's metadata, as it does for a sync update,
      # so backfilled facts land under the integration's instance and match its
      # authority row.
      update = %{source: "armis", metadata: stringify_keys(row.metadata || %{})}

      persist_batch_facts([{update, row.uid}], now)
      retire_legacy_instance_facts([{update, row.uid}], now)
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

  # What each `{device, source, instance, fact key}` the batch touches ends as, in update
  # order: a reported fact is written present, an omitted key is marked absent. An omitted
  # key that an earlier update of the batch reported keeps that fact, marked absent.
  defp persist_batch_facts(resolved_updates, now) do
    {written, absent} =
      resolved_updates
      |> Enum.reduce(%{}, &final_fact_states/2)
      |> Enum.split_with(fn {_key, {fact, _present}} -> not is_nil(fact) end)

    written
    |> Enum.map(fn {{device_uid, source, instance, _fact_key}, {fact, present}} ->
      fact_row(device_uid, source, instance, fact, present, now)
    end)
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.each(&upsert_fact_rows/1)

    absent
    |> Enum.map(fn {key, _state} -> key end)
    |> mark_absent_keys(now)
  end

  defp final_fact_states({update, device_uid}, states) do
    source = SourceFacts.source(update)
    instance = SourceFacts.source_instance(update)
    reported = SourceFacts.extract(update)
    reported_keys = MapSet.new(Enum.map(reported, & &1.fact_key))

    states =
      Enum.reduce(reported, states, fn fact, states ->
        Map.put(states, {device_uid, source, instance, fact.fact_key}, {fact, true})
      end)

    SourceFacts.keys()
    |> Enum.reject(&MapSet.member?(reported_keys, &1))
    |> Enum.reduce(states, fn fact_key, states ->
      Map.update(states, {device_uid, source, instance, fact_key}, {nil, false}, fn
        {fact, _present} -> {fact, false}
      end)
    end)
  end

  defp mark_absent_keys([], _now), do: :ok

  defp mark_absent_keys(keys, now) do
    device_uids = Enum.map(keys, &elem(&1, 0))
    sources = Enum.map(keys, &elem(&1, 1))
    instances = Enum.map(keys, &elem(&1, 2))
    fact_keys = Enum.map(keys, &elem(&1, 3))

    Repo.update_all(
      from(f in DeviceSourceFact,
        join:
          k in fragment(
            "SELECT * FROM unnest(?::text[], ?::text[], ?::text[], ?::text[]) AS k(device_uid, source, source_instance, fact_key)",
            ^device_uids,
            ^sources,
            ^instances,
            ^fact_keys
          ),
        on:
          f.device_uid == k.device_uid and f.source == k.source and
            f.source_instance == k.source_instance and f.fact_key == k.fact_key,
        where: f.present == true
      ),
      set: [present: false, updated_at: now]
    )

    :ok
  end

  # Facts a source stored under the legacy "nil" instance are superseded once the same
  # source reports for that device under its real instance. Marking them absent keeps a
  # stale twin from competing with the source's own facts. It is one statement per
  # source per batch, and it touches nothing once a deployment has healed.
  defp retire_legacy_instance_facts(resolved_updates, now) do
    resolved_updates
    |> Enum.map(fn {update, device_uid} ->
      {SourceFacts.source(update), SourceFacts.source_instance(update), device_uid}
    end)
    |> Enum.reject(fn {_source, instance, _device_uid} -> instance == @legacy_instance end)
    |> Enum.group_by(fn {source, _instance, _device_uid} -> source end, &elem(&1, 2))
    |> Enum.each(fn {source, device_uids} ->
      device_uids = Enum.uniq(device_uids)

      Repo.update_all(
        from(f in DeviceSourceFact,
          where:
            f.device_uid in ^device_uids and f.source == ^source and
              f.source_instance == ^@legacy_instance and f.present == true
        ),
        set: [present: false, updated_at: now]
      )
    end)
  end

  defp upsert_fact(device_uid, source, instance, fact, present, now) do
    upsert_fact_rows([fact_row(device_uid, source, instance, fact, present, now)])
  end

  defp fact_row(device_uid, source, instance, fact, present, now) do
    # insert_all on a table name skips Ecto UUID dumping; Postgrex needs 16 bytes.
    %{
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
  end

  defp upsert_fact_rows(rows) do
    Repo.insert_all(@facts_table, rows,
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

  defp load_fact(device_uid, source, instance, fact_key) do
    Repo.one(
      from(f in DeviceSourceFact,
        where:
          f.device_uid == ^device_uid and f.source == ^source and f.source_instance == ^instance and
            f.fact_key == ^fact_key,
        select: %{
          value: f.value,
          present: f.present,
          observed_at: f.observed_at,
          compare_hash: f.compare_hash
        },
        limit: 1
      )
    )
  end

  defp clear_unsupported_canonical(device_uid, fact_key, withdrawn_hash, now) do
    canonical = [device_uid] |> load_canonical() |> Map.get(device_uid) |> current_for(fact_key)
    canonical_hash = canonical_compare_hash(fact_key, canonical)

    supported? =
      [device_uid]
      |> load_present_facts()
      |> Enum.any?(&(&1.fact_key == fact_key and &1.compare_hash == withdrawn_hash))

    if canonical_hash == withdrawn_hash and not supported? do
      Repo.update_all(from(d in Device, where: d.uid == ^device_uid),
        set: [
          {canonical_column(fact_key), nil},
          {:modified_time, DateTime.truncate(now, :second)}
        ]
      )
    end

    :ok
  end

  defp canonical_compare_hash(fact_key, canonical) do
    case SourceFacts.parse_explicit_facts(%{fact_key => canonical}) do
      [%{compare_hash: hash}] -> hash
      _unparsed -> nil
    end
  end

  defp canonical_column("switch_port_attachment"), do: :switch_port_attachment
  defp canonical_column("vlan_uid"), do: :vlan_uid

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

  defp sync_disagreement(_device_uid, _fact_key, open, nil, now) do
    if open do
      Repo.update_all(from(d in SourceFactDisagreement, where: d.id == ^open.id),
        set: [status: "cleared", cleared_at: now, updated_at: now]
      )

      Events.emit(:cleared, open)
    end

    :ok
  end

  defp sync_disagreement(device_uid, fact_key, open, disagreement, now) do
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

  # The open disagreement of each `{device, fact key}`; at most one is open per pair.
  defp load_open_disagreements(device_uids) do
    from(d in SourceFactDisagreement,
      where: d.device_uid in ^device_uids and d.status == "open",
      select: %{
        id: d.id,
        device_uid: d.device_uid,
        fact_key: d.fact_key,
        compare_signature: d.compare_signature,
        configuration_conflict: d.configuration_conflict,
        values: d.values
      }
    )
    |> Repo.all()
    |> Map.new(&{{&1.device_uid, &1.fact_key}, &1})
  end

  defp load_present_facts(device_uids) do
    Repo.all(
      from(f in DeviceSourceFact,
        where: f.device_uid in ^device_uids and f.present == true,
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

  defp load_canonical(device_uids) do
    from(d in Device,
      where: d.uid in ^device_uids,
      select: {d.uid, %{switch_port_attachment: d.switch_port_attachment, vlan_uid: d.vlan_uid}}
    )
    |> Repo.all()
    |> Map.new()
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
