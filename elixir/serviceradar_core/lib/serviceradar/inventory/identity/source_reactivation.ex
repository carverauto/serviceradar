defmodule ServiceRadar.Inventory.Identity.SourceReactivation do
  @moduledoc """
  Decides where a retired source-authoritative identifier is written when its source reports it
  again (change `add-source-id-succession`, design D6; requirement "Retired Source Identifiers
  Are Reserved"). `resolve/3` runs in the sync ingest before batch resolution, on the updates
  carrying a source-authoritative identifier that no record holds and the archive does, whatever
  the archive reason.

  The holders are the records the archive says held it, each followed to its merge survivor.
  The identifier returns to a holder when exactly one qualifies:

    * it is live, or a tombstone that was not merged away;
    * it holds no other identifier of the type in the identifier's scope (its identifier
      partition);
    * it shares a hardware MAC (`SourceCorroboration.hardware_macs/1`) with the update: its own
      MAC, its MAC identifiers, its interface MACs, or the MAC the source last reported for the
      id before it retired;
    * the update corroborates it (`SourceCorroboration.corroboration/2`): the same source
      first-seen time, or a shared hostname (the one the source last reported or the record's
      own) when the update was first seen no earlier than the id was last seen. The source times
      are the ones the identifier row carried into the archive. A row archived before rows
      carried them is compared on the record's `first_seen_time`, for equality only.

  Returning moves the newest archived row of the identifier, and the integration id derived
  from it, back to the holder; restores a tombstone through `Device :restore` (releasing an
  address another live record holds); bumps the identity revision; and records
  `source_id_reactivated`, all in one transaction. The registered identifier clears a
  `source_retired` mark (a database trigger). The update then resolves to the holder, never to
  the uid the id derives.

  Otherwise the id is re-issued. The update is written to a uid no record carries
  (`Ids.reissued_device_id/2` when the derived one is taken), unless the usual resolution
  attaches it to a record with no history of the type, and never to a holder
  (`ServiceRadar.Inventory.Identity.BatchResolver`). Once the write lands, `record_reissued/2`
  records `source_id_reissued` naming the new record and the holders, which opens a
  de-duplication task. Nothing merges two live records.

  A failed read or return withholds the updates carrying the identifier until the next sync run.
  Telemetry: `[:serviceradar, :inventory, :source_reactivation, :reactivated | :reissued |
  :withheld]`.

  `unarchive/2` moves archived rows back to their holders for the remediation rollback (D11).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.BatchResolver
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Resolver
  alias ServiceRadar.Inventory.Identity.SourceAuthorityGuard
  alias ServiceRadar.Inventory.Identity.SourceCorroboration
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.Sync.Lookups
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @decision_source "source_reactivation"
  @telemetry_prefix [:serviceradar, :inventory, :source_reactivation]
  # A failed return is tried once more: the concurrent write it ran into has committed by then,
  # so the second attempt sees it.
  @return_attempts 2

  # Newest first, so each identifier's rows group newest first.
  @archived_sql """
  SELECT a.id, a.device_id, a.identifier_type, a.identifier_value, a.partition, a.metadata,
         a.archived_at, a.archive_reason
  FROM platform.device_identifier_archive AS a
  JOIN unnest($1::text[], $2::text[], $3::text[]) AS k(identifier_type, identifier_value, partition)
    ON a.identifier_type = k.identifier_type AND a.identifier_value = k.identifier_value
   AND a.partition = k.partition
  ORDER BY a.archived_at DESC NULLS LAST, a.id DESC
  """

  @archived_by_id_sql """
  SELECT a.id, a.device_id, a.identifier_type, a.identifier_value, a.partition, a.metadata,
         a.archived_at, a.archive_reason
  FROM platform.device_identifier_archive AS a
  WHERE a.id = ANY ($1::bigint[])
  """

  @identifiers_sql """
  SELECT di.device_id, di.identifier_type, di.identifier_value, di.partition
  FROM platform.device_identifiers AS di
  WHERE di.device_id = ANY ($1::text[]) AND di.identifier_type = ANY ($2::text[])
  """

  @interface_macs_sql """
  SELECT im.device_id, im.mac FROM platform.device_interface_macs AS im
  WHERE im.device_id = ANY ($1::text[])
  """

  @observations_sql """
  SELECT o.partition, o.source_instance, o.source_object_id, o.hostname, o.mac, o.last_observed_at
  FROM platform.device_source_observations AS o
  JOIN unnest($1::text[], $2::text[], $3::text[]) AS k(partition, source_instance, source_object_id)
    ON o.partition = k.partition AND o.source = 'armis' AND o.source_instance = k.source_instance
   AND o.source_object_id = k.source_object_id
  """

  @owner_lock_sql """
  SELECT pg_advisory_xact_lock(
           hashtextextended('serviceradar:armis-identifier-owner:' || $1::text, 0)
         )
  """

  @key_holder_sql """
  SELECT device_id FROM platform.device_identifiers
  WHERE identifier_type = $1::text AND identifier_value = $2::text AND partition = $3::text
  """

  @holds_type_sql """
  SELECT EXISTS (
    SELECT 1 FROM platform.device_identifiers
    WHERE device_id = $1::text AND identifier_type = $2::text AND partition = $3::text
  )
  """

  @lock_archived_sql """
  SELECT a.id FROM platform.device_identifier_archive AS a
  WHERE a.id = $1::bigint AND a.device_id = $2::text AND a.identifier_type = $3::text
    AND a.identifier_value = $4::text AND a.partition = $5::text
  FOR UPDATE
  """

  @lock_accompanying_sql """
  SELECT a.id FROM platform.device_identifier_archive AS a
  WHERE a.device_id = $1::text AND a.identifier_type = 'integration_id'
    AND a.identifier_value = $2::text AND a.partition = $3::text
  ORDER BY a.archived_at DESC NULLS LAST, a.id DESC
  LIMIT 1
  FOR UPDATE
  """

  # Insert and delete in one statement, so a row is either back or still archived. A row
  # another record registered meanwhile conflicts and stays archived.
  @return_sql """
  WITH returned AS (
    INSERT INTO platform.device_identifiers
      (id, device_id, identifier_type, identifier_value, partition, confidence, source,
       first_seen, last_seen, verified, metadata)
    SELECT a.id, $1::text, a.identifier_type, a.identifier_value, a.partition, a.confidence,
           a.source, a.first_seen AT TIME ZONE 'UTC', a.last_seen AT TIME ZONE 'UTC',
           a.verified, a.metadata
    FROM platform.device_identifier_archive AS a
    WHERE a.id = ANY ($2::bigint[])
    ON CONFLICT DO NOTHING
    RETURNING id
  )
  DELETE FROM platform.device_identifier_archive AS a
  USING returned
  WHERE a.id = returned.id
  RETURNING a.id
  """

  # Whether another live record holds the tombstone's address: the restore would violate the
  # unique active address index.
  @ip_conflict_sql """
  SELECT EXISTS (
    SELECT 1 FROM platform.ocsf_devices AS d
    JOIN platform.ocsf_devices AS other
      ON other.uid <> d.uid AND other.deleted_at IS NULL AND other.partition = d.partition
     AND other.ip = d.ip
    WHERE d.uid = $1::text AND d.ip IS NOT NULL AND d.ip <> ''
  )
  """

  @type key :: {atom(), String.t(), String.t()}
  @type reissue :: %{device_uid: String.t(), holders: [String.t()], evidence: map()}
  @type plan :: %{
          mappings: %{key() => String.t()},
          reactivated: %{key() => String.t()},
          reissued: %{key() => reissue()},
          targets: [{key(), String.t()}]
        }

  @doc """
  Judges the retired source ids `updates_with_ids` carry and returns the updates to resolve
  with the plan for `BatchResolver.resolve_batch/3`.

  `mappings` is the batch's identifier lookup. The plan's `mappings` is that lookup refreshed for
  the judged updates; `reactivated` maps each identifier returned to a record to that record;
  `reissued` maps each re-issued identifier to the uid it is written to, the holders it must not
  be written to, and the decision evidence. Updates carrying an identifier that could not be
  judged are left out.
  """
  @spec resolve([{map(), Ids.strong_identifiers()}], %{key() => String.t()}, term()) ::
          {[{map(), Ids.strong_identifiers()}], plan()}
  def resolve(updates_with_ids, mappings, actor) do
    plan = %{mappings: mappings, reactivated: %{}, reissued: %{}, targets: []}

    case candidates(updates_with_ids, mappings) do
      [] -> {updates_with_ids, plan}
      candidates -> judge(candidates, updates_with_ids, plan, actor)
    end
  end

  @doc """
  The uid each re-issued identifier resolved to, from the `resolved` output of
  `BatchResolver.resolve_batch/3` for `updates_with_ids` (in the same order), kept in the plan
  for `record_reissued/2`.
  """
  @spec reissue_targets(plan(), [{map(), Ids.strong_identifiers()}], [{map(), String.t()}]) ::
          plan()
  def reissue_targets(%{reissued: reissued} = plan, _updates_with_ids, _resolved)
      when map_size(reissued) == 0, do: plan

  def reissue_targets(%{reissued: reissued} = plan, updates_with_ids, resolved) do
    targets =
      updates_with_ids
      |> Enum.zip(resolved)
      |> Enum.flat_map(fn {{_update, ids}, {_resolved_update, device_uid}} ->
        for key <- source_keys(ids), Map.has_key?(reissued, key), do: {key, device_uid}
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    %{plan | targets: targets}
  end

  @doc """
  Records `source_id_reissued` for each re-issued identifier whose update landed: its target
  uid (`reissue_targets/3`) is among the uids of `written`. Best effort, like the other
  decisions the ingest records after its write: a failure is logged.
  """
  @spec record_reissued(plan(), [{map(), String.t()}]) :: :ok
  def record_reissued(%{targets: []}, _written), do: :ok

  def record_reissued(%{reissued: reissued, targets: targets}, written) do
    landed = MapSet.new(written, &elem(&1, 1))

    recorded =
      for {key, device_uid} <- targets,
          MapSet.member?(landed, device_uid),
          reissue = Map.fetch!(reissued, key),
          not held_by_holder?(key, device_uid, reissue),
          do: {key, device_uid, reissue}

    case recorded do
      [] ->
        :ok

      recorded ->
        _ = DecisionLog.record_many(Enum.map(recorded, &reissued_decision/1))
        Enum.each(recorded, &emit_reissued/1)
        :ok
    end
  end

  # BatchResolver never resolves a re-issued id to a holder; this keeps a decision from naming
  # one as the new record if that ever changes.
  defp held_by_holder?({type, _value, _partition}, device_uid, reissue) do
    holder? = device_uid in reissue.holders

    if holder? do
      Logger.warning(
        "SourceReactivation: a re-issued #{type} resolved to #{device_uid}, which held it; " <>
          "no source_id_reissued decision recorded"
      )
    end

    holder?
  end

  defp reissued_decision({{_type, value, _partition}, device_uid, reissue}) do
    %{
      kind: :source_id_reissued,
      reason: "source_id_reissued",
      device_uids: [device_uid | reissue.holders],
      subject: value,
      source: @decision_source,
      evidence: Map.put(reissue.evidence, "reissued_device_uid", device_uid)
    }
  end

  defp emit_reissued({{type, value, partition}, device_uid, reissue}) do
    :telemetry.execute(@telemetry_prefix ++ [:reissued], %{count: 1}, %{
      device_uid: device_uid,
      holders: reissue.holders,
      identifier_type: type,
      identifier_value: value,
      partition: partition
    })

    Logger.info(
      "SourceReactivation: re-issued retired #{type} #{value} to #{device_uid}; " <>
        "previous holders #{Enum.join(reissue.holders, ", ")}"
    )
  end

  ## Candidates

  defp candidates(updates_with_ids, mappings) do
    updates_with_ids
    |> Enum.flat_map(fn {update, ids} ->
      for key <- source_keys(ids),
          not Map.has_key?(mappings, key),
          do: %{key: key, update: update, ids: ids, scope: armis_scope(key)}
    end)
    |> Enum.uniq_by(& &1.key)
  end

  # Keyed as the identifier lookup keys them (`Lookups.update_identifiers/1`).
  defp source_keys(%{partition: partition} = ids) when is_binary(partition) do
    for {type, value} <- SourceAuthorityGuard.update_source_ids(ids), do: {type, value, partition}
  end

  defp source_keys(_ids), do: []

  # An Armis identifier partition is `<partition>:armis:<sync source id>` (`Ids`); the source's
  # observations are keyed by the base partition and the source id.
  defp armis_scope({:armis_device_id, _value, partition}) do
    case String.split(partition, ":armis:", parts: 2) do
      [base, instance] when base != "" and instance != "" ->
        %{partition: base, instance: instance}

      _other ->
        nil
    end
  end

  defp armis_scope(_key), do: nil

  ## Judging

  defp judge(candidates, updates_with_ids, plan, actor) do
    case archived_rows(Enum.map(candidates, & &1.key)) do
      {:ok, rows} ->
        case Enum.filter(candidates, &Map.has_key?(rows, &1.key)) do
          [] -> {updates_with_ids, plan}
          archived -> settle(archived, rows, updates_with_ids, plan, actor)
        end

      {:error, error} ->
        withhold(updates_with_ids, plan, Map.new(candidates, &{&1.key, {:read_failed, error}}))
    end
  end

  defp settle(candidates, rows, updates_with_ids, plan, actor) do
    case load(candidates, rows, actor) do
      {:ok, loaded} ->
        candidates
        |> Enum.map(&verdict(&1, loaded))
        |> conclude(updates_with_ids, plan, loaded, actor)

      {:error, error} ->
        withhold(updates_with_ids, plan, Map.new(candidates, &{&1.key, {:read_failed, error}}))
    end
  end

  defp archived_rows(keys) do
    %{rows: rows} =
      Repo.query!(@archived_sql, [
        Enum.map(keys, fn {type, _value, _partition} -> Atom.to_string(type) end),
        Enum.map(keys, &elem(&1, 1)),
        Enum.map(keys, &elem(&1, 2))
      ])

    {:ok, rows |> Enum.map(&archive_row/1) |> Enum.group_by(& &1.key)}
  rescue
    e -> {:error, e}
  end

  defp archive_row([id, device_id, type, value, partition, metadata, archived_at, reason]) do
    %{
      id: id,
      device_id: device_id,
      key: {source_type(type), value, partition},
      metadata: metadata || %{},
      archived_at: archived_at,
      archive_reason: reason
    }
  end

  defp source_type(type) when is_binary(type),
    do: Enum.find(SourceAuthorityGuard.source_identifier_types(), &(Atom.to_string(&1) == type))

  defp load(candidates, rows, actor) do
    raw_uids =
      candidates |> Enum.flat_map(&Map.fetch!(rows, &1.key)) |> Enum.map(& &1.device_id)

    canonical = canonical_uids(Enum.uniq(raw_uids), actor)
    holders = Map.new(candidates, &{&1.key, holders(Map.fetch!(rows, &1.key), canonical)})
    uids = holders |> Map.values() |> List.flatten() |> Enum.map(& &1.uid) |> Enum.uniq()

    {:ok,
     %{
       rows: rows,
       holders: holders,
       devices: devices(uids, actor),
       identifiers: identifiers(uids),
       interface_macs: interface_macs(uids),
       observations: observations(candidates)
     }}
  rescue
    e -> {:error, e}
  end

  # A merged-away holder's history moved to its survivor (`MergeEngine`), so the survivor is
  # the holder.
  defp canonical_uids(uids, actor) do
    candidates = Enum.filter(uids, &Ids.serviceradar_uuid?/1)

    followed =
      BatchResolver.tombstoned_ids(candidates, actor) ++
        BatchResolver.purged_merged_ids(candidates, actor)

    Map.new(followed, &{&1, Resolver.follow_canonical_device_id(&1, actor)})
  end

  defp holders(rows, canonical) do
    rows
    |> Enum.group_by(&Map.get(canonical, &1.device_id, &1.device_id))
    |> Enum.map(fn {uid, [newest | _] = held} ->
      %{uid: uid, row: newest, raw: held |> Enum.map(& &1.device_id) |> Enum.uniq()}
    end)
    |> Enum.sort_by(& &1.uid)
  end

  defp devices([], _actor), do: %{}

  defp devices(uids, actor) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid in ^uids)
    |> Ash.Query.select([
      :uid,
      :hostname,
      :mac,
      :partition,
      :deleted_at,
      :deleted_reason,
      :source_retired_at,
      :first_seen_time
    ])
    |> Page.stream!(actor: actor)
    |> Map.new(&{&1.uid, &1})
  end

  defp identifiers([]), do: %{}

  defp identifiers(uids) do
    types = Enum.map([:mac | SourceAuthorityGuard.source_identifier_types()], &Atom.to_string/1)
    %{rows: rows} = Repo.query!(@identifiers_sql, [uids, types])

    Enum.group_by(rows, &hd/1, fn [_uid, type, value, partition] ->
      {identifier_type(type), value, partition}
    end)
  end

  defp identifier_type("mac"), do: :mac
  defp identifier_type(type), do: source_type(type)

  defp interface_macs([]), do: %{}

  defp interface_macs(uids) do
    %{rows: rows} = Repo.query!(@interface_macs_sql, [uids])
    Enum.group_by(rows, &hd/1, &List.last/1)
  end

  defp observations(candidates) do
    scoped =
      for %{scope: %{} = scope, key: {_type, value, _partition}} <- candidates,
          uniq: true,
          do: {scope.partition, scope.instance, value}

    case scoped do
      [] ->
        %{}

      scoped ->
        %{rows: rows} =
          Repo.query!(@observations_sql, [
            Enum.map(scoped, &elem(&1, 0)),
            Enum.map(scoped, &elem(&1, 1)),
            Enum.map(scoped, &elem(&1, 2))
          ])

        Map.new(rows, fn [partition, instance, value, hostname, mac, last_observed_at] ->
          {{partition, instance, value},
           %{hostname: hostname, mac: mac, last_observed_at: last_observed_at}}
        end)
    end
  end

  defp verdict(candidate, loaded) do
    judged =
      loaded.holders
      |> Map.fetch!(candidate.key)
      |> Enum.map(&{&1, judge_holder(candidate, &1, loaded)})

    case for({holder, {:qualified, evidence}} <- judged, do: {holder, evidence}) do
      [{holder, evidence}] -> {candidate, {:return, holder, evidence}, judged}
      _none_or_several -> {candidate, :reissue, judged}
    end
  end

  defp judge_holder(candidate, holder, loaded) do
    {type, _value, partition} = candidate.key
    device = Map.get(loaded.devices, holder.uid)

    cond do
      is_nil(device) -> {:ineligible, "missing"}
      merged?(device) -> {:ineligible, "merged_tombstone"}
      holds_type?(loaded, holder.uid, type, partition) -> {:ineligible, "holds_current_id"}
      true -> qualify(candidate, holder, device, loaded)
    end
  end

  defp merged?(%{deleted_at: %DateTime{}, deleted_reason: "merged"}), do: true
  defp merged?(_device), do: false

  defp holds_type?(loaded, uid, type, partition) do
    loaded.identifiers
    |> Map.get(uid, [])
    |> Enum.any?(&match?({^type, _value, ^partition}, &1))
  end

  defp qualify(candidate, holder, device, loaded) do
    observation = observation(candidate, holder.row, loaded)

    record_macs =
      SourceCorroboration.hardware_macs(
        [device.mac, observation && observation.mac] ++
          for({:mac, value, _partition} <- Map.get(loaded.identifiers, holder.uid, []), do: value) ++
          Map.get(loaded.interface_macs, holder.uid, [])
      )

    matched =
      candidate.ids
      |> Ids.mac_lookup_values()
      |> SourceCorroboration.hardware_macs()
      |> MapSet.intersection(record_macs)

    {earlier, basis} = earlier_observation(holder.row, device, observation)

    later = %{
      first_seen: Map.get(candidate.update, :first_seen_time),
      hostnames: [Map.get(candidate.update, :hostname)]
    }

    with {:macs, true} <- {:macs, MapSet.size(matched) > 0},
         {:ok, corroboration} <- SourceCorroboration.corroboration(earlier, later) do
      {:qualified,
       %{
         "corroboration" => Atom.to_string(corroboration),
         "first_seen_basis" => basis,
         "matched_macs" => matched |> MapSet.to_list() |> Enum.sort(),
         "observation" => not is_nil(observation)
       }}
    else
      {:macs, false} -> {:ineligible, "no_shared_mac"}
      :error -> {:ineligible, "not_corroborated"}
    end
  end

  # The source's observation of the id counts only as it stood when the id retired: one the
  # source refreshed since describes whatever reports the id now.
  defp observation(%{scope: %{} = scope, key: {_type, value, _partition}}, row, loaded) do
    with %{last_observed_at: %NaiveDateTime{} = observed} = observation <-
           Map.get(loaded.observations, {scope.partition, scope.instance, value}),
         %DateTime{} = archived_at <- row.archived_at,
         true <- DateTime.compare(DateTime.from_naive!(observed, "Etc/UTC"), archived_at) != :gt do
      observation
    else
      _ -> nil
    end
  end

  defp observation(_candidate, _row, _loaded), do: nil

  # The times the source last reported for the id, as its identifier row carried them into the
  # archive. A row archived before rows carried them has no last-seen time, so only an equal
  # first-seen time, the record's own, corroborates it.
  defp earlier_observation(row, device, observation) do
    hostnames = [observation && observation.hostname, device.hostname]

    case row.metadata do
      %{"source_first_seen_time" => first_seen} when is_binary(first_seen) ->
        {%{
           first_seen: first_seen,
           last_seen: Map.get(row.metadata, "source_last_seen_time"),
           hostnames: hostnames
         }, "source"}

      _metadata ->
        {%{first_seen: device.first_seen_time, last_seen: nil, hostnames: hostnames}, "record"}
    end
  end

  ## Concluding

  defp conclude(verdicts, updates_with_ids, plan, loaded, actor) do
    {withheld, settled} =
      verdicts
      |> Enum.map(fn
        {candidate, {:return, holder, evidence}, judged} ->
          {candidate, reactivate(candidate, holder, evidence, actor), judged}

        {candidate, :reissue, judged} ->
          {candidate, :reissue, judged}
      end)
      |> Enum.split_with(&match?({_candidate, {:withhold, _reason, _error}, _judged}, &1))

    withheld =
      Map.new(withheld, fn {candidate, {:withhold, reason, error}, _judged} ->
        {candidate.key, {reason, error}}
      end)

    keys = MapSet.new(settled, fn {candidate, _outcome, _judged} -> candidate.key end)

    case refresh(plan.mappings, updates_with_ids, keys) do
      {:ok, mappings} ->
        {plan, withheld} =
          Enum.reduce(settled, {%{plan | mappings: mappings}, withheld}, fn settled, acc ->
            apply_outcome(settled, acc, loaded, actor)
          end)

        withhold(updates_with_ids, plan, withheld)

      {:error, error} ->
        withheld = Enum.reduce(keys, withheld, &Map.put(&2, &1, {:refresh_failed, error}))
        withhold(updates_with_ids, plan, withheld)
    end
  end

  # The judged updates' identifiers, looked up again: a return moved rows, and a concurrent
  # ingest may have registered an identifier since the batch's lookup. A failed lookup must not
  # read as "nobody holds them".
  defp refresh(mappings, updates_with_ids, keys) do
    looked_up =
      updates_with_ids
      |> Enum.filter(fn {_update, ids} ->
        Enum.any?(source_keys(ids), &MapSet.member?(keys, &1))
      end)
      |> Enum.flat_map(fn {update, _ids} -> Lookups.update_identifiers(update) end)
      |> Enum.uniq()

    case Lookups.lookup_identifiers_strict(looked_up) do
      {:ok, refreshed} -> {:ok, mappings |> Map.drop(looked_up) |> Map.merge(refreshed)}
      {:error, _} = error -> error
    end
  end

  defp apply_outcome({candidate, outcome, judged}, {plan, withheld}, loaded, actor) do
    key = candidate.key

    case outcome do
      {:reactivated, device_uid, _info} ->
        {%{plan | reactivated: Map.put(plan.reactivated, key, device_uid)}, withheld}

      {:already, device_uid} ->
        {%{plan | reactivated: Map.put(plan.reactivated, key, device_uid)}, withheld}

      :claimed ->
        if Map.has_key?(plan.mappings, key),
          do: {plan, withheld},
          else: {plan, Map.put(withheld, key, {:claim_changed, nil})}

      :ineligible ->
        reissue(candidate, now_holds_current_id(judged), {plan, withheld}, loaded, actor)

      :reissue ->
        reissue(candidate, judged, {plan, withheld}, loaded, actor)
    end
  end

  # The holder the return was judged for gained an identifier of the type before it was locked.
  defp now_holds_current_id(judged) do
    Enum.map(judged, fn
      {holder, {:qualified, _evidence}} -> {holder, {:ineligible, "holds_current_id"}}
      other -> other
    end)
  end

  # An identifier some record registered since the batch's lookup is resolved as usual.
  defp reissue(candidate, judged, {plan, withheld}, loaded, actor) do
    key = candidate.key

    if Map.has_key?(plan.mappings, key) do
      {plan, withheld}
    else
      case reissue_uid(candidate, loaded, actor) do
        {:ok, device_uid} ->
          reissue = reissue_entry(candidate, device_uid, judged, loaded)
          {%{plan | reissued: Map.put(plan.reissued, key, reissue)}, withheld}

        {:error, error} ->
          {plan, Map.put(withheld, key, {:read_failed, error})}
      end
    end
  end

  # The uid the id derives, unless a record carries it or carried it (a merge row outlives a
  # purged tombstone), or a holder is named by it; then the uid derived from it and the
  # archived rows, which is stable across retries.
  defp reissue_uid(candidate, loaded, actor) do
    derived = Ids.generate_deterministic_device_id(candidate.ids)

    alternate =
      Ids.reissued_device_id(derived, Enum.map(Map.fetch!(loaded.rows, candidate.key), & &1.id))

    options = Enum.uniq([derived, alternate])

    holders =
      loaded.holders |> Map.fetch!(candidate.key) |> Enum.flat_map(&[&1.uid | &1.raw])

    taken =
      MapSet.new(
        holders ++
          existing_uids(options, actor) ++ BatchResolver.purged_merged_ids(options, actor)
      )

    {:ok, Enum.find(options, &(not MapSet.member?(taken, &1))) || "sr:" <> Ecto.UUID.generate()}
  rescue
    e -> {:error, e}
  end

  defp existing_uids(uids, actor) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid in ^uids)
    |> Ash.Query.select([:uid])
    |> Page.stream!(actor: actor)
    |> Enum.map(& &1.uid)
  end

  defp reissue_entry(candidate, device_uid, judged, loaded) do
    {type, value, partition} = candidate.key
    reasons = Map.new(judged, fn {holder, verdict} -> {holder.uid, holder_reason(verdict)} end)

    %{
      device_uid: device_uid,
      holders:
        for(
          {uid, reason} <- Enum.sort(reasons),
          reason not in ["missing", "merged_tombstone"],
          do: uid
        ),
      evidence: %{
        "identifier_type" => Atom.to_string(type),
        "identifier_value" => value,
        "identifier_partition" => partition,
        "archived_identifier_ids" => Enum.map(Map.fetch!(loaded.rows, candidate.key), & &1.id),
        "holders" => reasons,
        "qualifying_holders" => for({holder, {:qualified, _}} <- judged, do: holder.uid)
      }
    }
  end

  defp holder_reason({:qualified, _evidence}), do: "qualified"
  defp holder_reason({:ineligible, reason}), do: reason

  defp withhold(updates_with_ids, plan, withheld) when map_size(withheld) == 0,
    do: {updates_with_ids, plan}

  defp withhold(updates_with_ids, plan, withheld) do
    {dropped, kept} =
      Enum.split_with(updates_with_ids, fn {_update, ids} ->
        Enum.any?(source_keys(ids), &Map.has_key?(withheld, &1))
      end)

    counts =
      dropped
      |> Enum.flat_map(fn {_update, ids} ->
        Enum.filter(source_keys(ids), &Map.has_key?(withheld, &1))
      end)
      |> Enum.frequencies()

    Enum.each(withheld, fn {{type, value, partition} = key, {reason, _error}} ->
      :telemetry.execute(
        @telemetry_prefix ++ [:withheld],
        %{updates: Map.get(counts, key, 0)},
        %{identifier_type: type, identifier_value: value, partition: partition, reason: reason}
      )
    end)

    withheld
    |> Enum.group_by(fn {_key, {reason, _error}} -> reason end, fn {_key, {_r, error}} ->
      error
    end)
    |> Enum.each(fn {reason, errors} ->
      Logger.warning(
        "SourceReactivation: withheld the updates of #{length(errors)} retired source id(s) " <>
          "until the next sync run (#{reason}): #{inspect(hd(errors))}"
      )
    end)

    {kept, plan}
  end

  ## Returning

  defp reactivate(candidate, holder, evidence, actor, attempt \\ 1) do
    case attempt_return(candidate, holder, evidence, actor) do
      {:failed, _error} when attempt < @return_attempts ->
        reactivate(candidate, holder, evidence, actor, attempt + 1)

      {:failed, error} ->
        {:withhold, :return_failed, error}

      {:reactivated, _device_uid, _info} = done ->
        emit_reactivated(done, candidate)
        done

      outcome ->
        outcome
    end
  end

  defp attempt_return(candidate, holder, evidence, actor) do
    Device
    |> Ash.transact(fn -> return_identifier(candidate, holder, evidence, actor) end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, error} -> {:failed, error}
    end
  rescue
    e -> {:failed, e}
  end

  # The holder's row is locked before its identifiers, as the fenced ingest write, `MergeEngine`
  # and `SourceRetirement` lock them, and the judgment is checked again under the locks.
  defp return_identifier(candidate, holder, evidence, actor) do
    {type, _value, partition} = candidate.key

    with {:ok, device} <- lock_holder(holder.uid, actor),
         :ok <- lock_identifier_owner(holder.uid),
         :unheld <- key_holder(candidate.key, holder.uid),
         :ok <- holds_no_type(holder.uid, type, partition),
         {:ok, archive_ids} <- lock_archive_rows(holder.row, candidate.scope) do
      write_return(candidate, holder, device, archive_ids, evidence, actor)
    else
      :missing -> {:withhold, :holder_changed, nil}
      :merged -> {:withhold, :holder_changed, nil}
      :archive_changed -> {:withhold, :archive_changed, nil}
      other -> other
    end
  end

  defp write_return(candidate, holder, device, archive_ids, evidence, actor) do
    {type, value, partition} = candidate.key

    with {:ok, revived} <- revive(device, actor),
         {:ok, returned} <- return_rows(holder.uid, archive_ids) do
      info =
        Map.merge(evidence, %{
          "identifier_type" => Atom.to_string(type),
          "identifier_value" => value,
          "identifier_partition" => partition,
          "archived_identifier_ids" => returned,
          "archived_at" => iso8601(holder.row.archived_at),
          "archive_reason" => holder.row.archive_reason,
          "previous_holders" => holder.raw,
          "restored_tombstone" => revived.restored,
          "previous_deleted_reason" => device.deleted_reason,
          "cleared_ip" => revived.cleared_ip,
          "was_marked_source_retired" => not is_nil(device.source_retired_at)
        })

      decision = %{
        kind: :source_id_reactivated,
        reason: "source_id_reactivated",
        device_uids: [holder.uid],
        subject: value,
        source: @decision_source,
        evidence: info
      }

      with :ok <- DecisionLog.record_many_strict([decision]) do
        {:reactivated, holder.uid, info}
      end
    end
  end

  defp lock_holder(device_uid, actor) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true}, actor: actor)
    |> Ash.Query.filter(uid == ^device_uid)
    |> Ash.Query.select([:uid])
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.read(actor: actor)
    |> Page.unwrap()
    |> case do
      {:ok, [_locked]} ->
        case Device.get_by_uid(device_uid, true, actor: actor) do
          {:ok, %Device{} = device} -> if merged?(device), do: :merged, else: {:ok, device}
          {:ok, nil} -> :missing
          {:error, _} = error -> error
        end

      {:ok, []} ->
        :missing

      {:error, _} = error ->
        error
    end
  end

  # The lock the `device_identifiers` ownership trigger takes for the holder's writes.
  defp lock_identifier_owner(device_uid) do
    _ = Repo.query!(@owner_lock_sql, [device_uid])
    :ok
  end

  defp key_holder({type, value, partition}, device_uid) do
    case Repo.query!(@key_holder_sql, [Atom.to_string(type), value, partition]) do
      %{rows: []} -> :unheld
      %{rows: [[^device_uid]]} -> {:already, device_uid}
      %{rows: [[_other]]} -> :claimed
    end
  end

  defp holds_no_type(device_uid, type, partition) do
    case Repo.query!(@holds_type_sql, [device_uid, Atom.to_string(type), partition]) do
      %{rows: [[false]]} -> :ok
      %{rows: [[true]]} -> :ineligible
    end
  end

  # The archived row the holder was judged on, which must not have moved, and the integration
  # id derived from it, when that is still archived for the same record.
  defp lock_archive_rows(row, scope) do
    {type, value, partition} = row.key

    case Repo.query!(@lock_archived_sql, [
           row.id,
           row.device_id,
           Atom.to_string(type),
           value,
           partition
         ]) do
      %{rows: [[id]]} -> {:ok, [id | accompanying_ids(row, scope)]}
      %{rows: []} -> :archive_changed
    end
  end

  defp accompanying_ids(row, %{instance: instance}) do
    {_type, value, partition} = row.key

    case IntegrationIdentity.scoped_device_id("armis", instance, value) do
      nil ->
        []

      integration_id ->
        %{rows: rows} =
          Repo.query!(@lock_accompanying_sql, [row.device_id, integration_id, partition])

        Enum.map(rows, &hd/1)
    end
  end

  defp accompanying_ids(_row, _scope), do: []

  # Restore before the identifier returns: the trigger that clears a `source_retired` mark acts
  # only on live records.
  defp revive(%Device{deleted_at: nil} = device, actor) do
    case Device.bump_identity_revision(device, actor: actor) do
      {:ok, _device} -> {:ok, %{restored: false, cleared_ip: false}}
      {:error, _} = error -> error
    end
  end

  defp revive(%Device{uid: device_uid}, actor) do
    cleared_ip = ip_conflict?(device_uid)
    input = if cleared_ip, do: %{allow_retained: true, ip: nil}, else: %{allow_retained: true}

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid == ^device_uid)
    |> Ash.bulk_update(:restore, input,
      actor: actor,
      return_records?: true,
      return_errors?: true,
      strategy: [:atomic, :stream]
    )
    |> case do
      %Ash.BulkResult{status: :success, records: [_restored | _]} ->
        {:ok, %{restored: true, cleared_ip: cleared_ip}}

      %Ash.BulkResult{status: :success} ->
        case Device.get_by_uid(device_uid, false, actor: actor) do
          {:ok, %Device{}} -> {:ok, %{restored: true, cleared_ip: cleared_ip}}
          _not_restored -> {:error, :not_restored}
        end

      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end

  defp ip_conflict?(device_uid) do
    %{rows: [[conflict]]} = Repo.query!(@ip_conflict_sql, [device_uid])
    conflict
  end

  # The first id is the identifier's own row, which must come back.
  defp return_rows(device_uid, [primary | _] = archive_ids) do
    %{rows: rows} = Repo.query!(@return_sql, [device_uid, archive_ids])
    returned = rows |> Enum.map(&hd/1) |> Enum.sort()

    if primary in returned, do: {:ok, returned}, else: {:error, :not_returned}
  end

  defp emit_reactivated({:reactivated, device_uid, info}, candidate) do
    {type, value, partition} = candidate.key

    :telemetry.execute(@telemetry_prefix ++ [:reactivated], %{count: 1}, %{
      device_uid: device_uid,
      identifier_type: type,
      identifier_value: value,
      partition: partition,
      restored_tombstone: info["restored_tombstone"],
      corroboration: info["corroboration"]
    })

    Logger.info(
      "SourceReactivation: returned retired #{type} #{value} to #{device_uid} " <>
        "(#{info["corroboration"]}, restored tombstone: #{info["restored_tombstone"]})"
    )
  end

  ## Rollback

  @doc """
  Moves the archived rows `archive_row_ids` back to the records that held them (followed to
  their merge survivors), for the remediation rollback (change `add-source-id-succession`,
  design D11). Each row returns with the integration id derived from it, bumps the holder's
  identity revision and records `source_id_reactivated`, in one transaction per row. It does
  not restore a tombstone: the rollback restores the records it deleted itself.

  A row is skipped, and stays archived, when it is not archived (`:not_archived`), is not a
  source-authoritative identifier (`:not_source_identifier`), its holder is gone
  (`:holder_missing`) or merged away (`:merged_holder`), the holder already holds it
  (`:already_held`), another record holds it (`:claimed`), or it moved meanwhile
  (`:archive_changed`). Unlike a reactivation, a row returns to a holder that holds another
  identifier of the type in its scope: a record that held a stale id beside a current one held
  both before the stale one retired (class 1), and a merge survivor would have held both had
  the id not retired before the merge.

  Options: `:actor` (default the `:source_reactivation` system actor) and `:source`, the
  decision source.
  """
  @spec unarchive([integer()], keyword()) :: [
          {integer(), {:ok, String.t()} | {:skipped, atom()} | {:error, term()}}
        ]
  def unarchive(archive_row_ids, opts \\ []) when is_list(archive_row_ids) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:source_reactivation))
    source = Keyword.get(opts, :source, @decision_source)
    archive_row_ids = Enum.uniq(archive_row_ids)

    case archived_by_id(archive_row_ids) do
      {:ok, rows} ->
        Enum.map(archive_row_ids, &{&1, unarchive_row(Map.get(rows, &1), actor, source)})

      {:error, _} = error ->
        Enum.map(archive_row_ids, &{&1, error})
    end
  end

  defp archived_by_id([]), do: {:ok, %{}}

  defp archived_by_id(archive_row_ids) do
    %{rows: rows} = Repo.query!(@archived_by_id_sql, [archive_row_ids])
    {:ok, Map.new(rows, &{hd(&1), archive_row(&1)})}
  rescue
    e -> {:error, e}
  end

  defp unarchive_row(nil, _actor, _source), do: {:skipped, :not_archived}
  defp unarchive_row(%{key: {nil, _, _}}, _actor, _source), do: {:skipped, :not_source_identifier}

  defp unarchive_row(row, actor, source) do
    holder = Map.get(canonical_uids([row.device_id], actor), row.device_id, row.device_id)

    Device
    |> Ash.transact(fn -> return_archived(row, holder, actor, source) end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, error} -> {:error, error}
    end
  rescue
    e -> {:error, e}
  end

  defp return_archived(row, holder, actor, source) do
    {type, value, partition} = row.key

    with {:ok, device} <- lock_holder(holder, actor),
         :ok <- lock_identifier_owner(holder),
         :unheld <- key_holder(row.key, holder),
         {:ok, archive_ids} <- lock_archive_rows(row, armis_scope(row.key)),
         {:ok, returned} <- return_rows(holder, archive_ids),
         {:ok, _device} <- bump_revision(device, actor),
         :ok <-
           DecisionLog.record_many_strict([
             %{
               kind: :source_id_reactivated,
               reason: "source_id_unarchived",
               device_uids: [holder],
               subject: value,
               source: source,
               evidence: %{
                 "identifier_type" => Atom.to_string(type),
                 "identifier_value" => value,
                 "identifier_partition" => partition,
                 "archived_identifier_ids" => returned,
                 "archived_at" => iso8601(row.archived_at),
                 "archive_reason" => row.archive_reason,
                 "previous_holders" => [row.device_id],
                 "holder_deleted" => not is_nil(device.deleted_at)
               }
             }
           ]) do
      {:ok, holder}
    else
      :missing -> {:skipped, :holder_missing}
      :merged -> {:skipped, :merged_holder}
      {:already, _holder} -> {:skipped, :already_held}
      :claimed -> {:skipped, :claimed}
      :archive_changed -> {:skipped, :archive_changed}
      {:error, _} = error -> error
    end
  end

  # A tombstone's row is outside the primary read an update is built from, so its revision is
  # bumped through a bulk update over a read that includes it.
  defp bump_revision(%Device{deleted_at: nil} = device, actor),
    do: Device.bump_identity_revision(device, actor: actor)

  defp bump_revision(%Device{uid: device_uid}, actor) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid == ^device_uid)
    |> Ash.bulk_update(:bump_identity_revision, %{},
      actor: actor,
      return_errors?: true,
      strategy: [:atomic, :stream]
    )
    |> case do
      %Ash.BulkResult{status: :success} -> {:ok, nil}
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
