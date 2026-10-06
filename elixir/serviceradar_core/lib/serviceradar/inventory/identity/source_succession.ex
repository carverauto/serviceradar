defmodule ServiceRadar.Inventory.Identity.SourceSuccession do
  @moduledoc """
  Converges a record whose source identifier retired with the record its source re-keyed it to
  (change `add-source-id-succession`, designs D3 and D4; requirements "Source Succession
  Converges One Device" and "Weak Succession Evidence Goes To Review"). `run/1` is a stage of the
  duplicate pass (`DuplicateSweep`).

  A predecessor is a live record that holds no live identifier of the type and holds rows of it
  the retirement pass archived (`source_absent`). A current record is a live record that holds a
  live identifier of the type. A predecessor and a current record are paired, in the identifier
  partitions where the predecessor's id retired and the current record holds one, when:

    * a hardware MAC (`SourceCorroboration.hardware_macs/1`) links them: both carry it and no
      other current record does. A predecessor carries its MAC, its MAC identifiers, its
      interface MACs and the MACs the source last reported for its ids before they retired; a
      current record carries the same, with what the source reports now;
    * the source corroborates the pair in each of those partitions
      (`SourceCorroboration.corroboration/2`): an equal source first-seen time, or a shared
      hostname when the current id was first seen no earlier than the retired one was last seen.
      A hostname another current record of the source holds in the partition does not
      corroborate. The current record's times are the source's own; a retired row archived
      before rows carried them is compared on the record's `first_seen_time`, for equality only.

  The pair is successive when neither side is paired with another record, no distinct assertion
  covers it, and the two do not carry different agent ids. A successive pair merges through
  `MergeEngine.merge_devices/3` with reason `source_succession`, which re-checks it in the
  merge transaction (`revalidate/2`). The record created first survives; it takes the current
  record's source-owned metadata and address, each fact the side the source updated last, and
  loses a `source_retired` mark (a database trigger clears it when the survivor gains the
  current id). An open de-duplication task for exactly the pair is marked merged into the
  survivor. At most `max_successions_per_run` (`DeviceCleanupSettings`) pairs merge per run; the
  rest wait for the next one, and none merge when the setting cannot be read.

  A pair that shares a MAC, or an equal first-seen time and a hostname, and is not successive is
  recorded as `succession_review`, which opens a de-duplication task naming the pair and the
  records it competes with. A review touching a record that merges in the run waits for the next
  run. A pair that is asserted distinct, or carries different agent ids, is left alone.

  Telemetry: `[:serviceradar, :inventory, :source_succession, :merged | :reviewed | :skipped]`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata
  alias ServiceRadar.Inventory.Changes.MergeDeviceFacts
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.SourceCorroboration
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @decision_source "source_succession"
  @merge_reason "source_succession"
  @archive_reason "source_absent"
  @identifier_type :armis_device_id
  @telemetry_prefix [:serviceradar, :inventory, :source_succession]

  # The metadata a sync writes for the source id a record carries. It describes the current id,
  # so the current record's values win. `source_device_id` is not among them: a record keeps
  # the first source device id it was seen with.
  @source_owned_keys ~w(integration_type armis_device_id integration_id sync_service_id
                        sync_run_id sync_total_devices)

  # The highest first; a review of several pairs records the highest of their reasons.
  @review_reasons [
    :not_one_to_one,
    :shared_mac,
    :overlapping_hostname,
    :mac_only,
    :corroborated_without_mac
  ]

  # Newest first, so each record's rows group newest first.
  @predecessors_sql """
  SELECT a.id, a.device_id, a.identifier_value, a.partition, a.metadata, a.archived_at
  FROM platform.device_identifier_archive AS a
  JOIN platform.ocsf_devices AS d ON d.uid = a.device_id AND d.deleted_at IS NULL
  WHERE a.identifier_type = $1 AND a.archive_reason = $2
    AND NOT EXISTS (
      SELECT 1 FROM platform.device_identifiers AS di
      WHERE di.device_id = a.device_id AND di.identifier_type = $1
    )
  ORDER BY a.device_id, a.archived_at DESC NULLS LAST, a.id DESC
  """

  @predecessors_of_sql """
  SELECT a.id, a.device_id, a.identifier_value, a.partition, a.metadata, a.archived_at
  FROM platform.device_identifier_archive AS a
  JOIN platform.ocsf_devices AS d ON d.uid = a.device_id AND d.deleted_at IS NULL
  WHERE a.identifier_type = $1 AND a.archive_reason = $2
    AND a.device_id = ANY (CAST($3 AS text[]))
    AND NOT EXISTS (
      SELECT 1 FROM platform.device_identifiers AS di
      WHERE di.device_id = a.device_id AND di.identifier_type = $1
    )
  ORDER BY a.device_id, a.archived_at DESC NULLS LAST, a.id DESC
  """

  # The live records reporting one of the MACs: as their MAC, a MAC identifier, an interface
  # MAC, or the MAC the source reports for an id of the type they hold or held. The token
  # expressions are the ones the MAC indexes are built on (migration 20260709210000).
  @mac_reporters_sql """
  SELECT d.uid FROM platform.ocsf_devices AS d
  WHERE d.deleted_at IS NULL AND d.mac IS NOT NULL
    AND regexp_split_to_array(upper(translate(d.mac, ':-.', '')), '[,;[:space:]]+')
        && CAST($2 AS text[])
  UNION
  SELECT di.device_id FROM platform.device_identifiers AS di
  JOIN platform.ocsf_devices AS d ON d.uid = di.device_id AND d.deleted_at IS NULL
  WHERE di.identifier_type = 'mac'
    AND regexp_split_to_array(upper(translate(di.identifier_value, ':-.', '')), '[,;[:space:]]+')
        && CAST($2 AS text[])
  UNION
  SELECT im.device_id FROM platform.device_interface_macs AS im
  JOIN platform.ocsf_devices AS d ON d.uid = im.device_id AND d.deleted_at IS NULL
  WHERE im.mac = ANY (CAST($2 AS text[]))
  UNION
  SELECT di.device_id FROM platform.device_source_observations AS o
  JOIN platform.device_identifiers AS di
    ON di.identifier_type = $1 AND di.identifier_value = o.source_object_id
   AND di.partition = o.partition || ':armis:' || o.source_instance
  JOIN platform.ocsf_devices AS d ON d.uid = di.device_id AND d.deleted_at IS NULL
  WHERE o.source = 'armis' AND o.mac IS NOT NULL
    AND regexp_split_to_array(upper(translate(o.mac, ':-.', '')), '[,;[:space:]]+')
        && CAST($2 AS text[])
  UNION
  SELECT a.device_id FROM platform.device_source_observations AS o
  JOIN platform.device_identifier_archive AS a
    ON a.identifier_type = $1 AND a.identifier_value = o.source_object_id
   AND a.partition = o.partition || ':armis:' || o.source_instance
  JOIN platform.ocsf_devices AS d ON d.uid = a.device_id AND d.deleted_at IS NULL
  WHERE o.source = 'armis' AND o.mac IS NOT NULL
    AND regexp_split_to_array(upper(translate(o.mac, ':-.', '')), '[,;[:space:]]+')
        && CAST($2 AS text[])
  """

  # The live records holding an id of the type the source first saw at one of the times.
  @first_seen_holders_sql """
  SELECT DISTINCT di.device_id FROM platform.device_identifiers AS di
  JOIN unnest(CAST($2 AS text[]), CAST($3 AS text[])) AS k(partition, first_seen)
    ON di.partition = k.partition AND di.metadata ->> 'source_first_seen_time' = k.first_seen
  JOIN platform.ocsf_devices AS d ON d.uid = di.device_id AND d.deleted_at IS NULL
  WHERE di.identifier_type = $1
  """

  # The current records of the partitions whose hostname, or the one the source reports for
  # their id, has one of the keys: the hostname with every character but a letter or a digit
  # removed, lower-cased. `hostname_key/1` is the same key; the match is re-checked on the
  # normalized hostname.
  @hostname_holders_sql """
  SELECT di.device_id, di.partition, d.hostname, o.hostname
  FROM platform.device_identifiers AS di
  JOIN platform.ocsf_devices AS d ON d.uid = di.device_id AND d.deleted_at IS NULL
  LEFT JOIN platform.device_source_observations AS o
    ON o.source = 'armis' AND o.source_object_id = di.identifier_value
   AND di.partition = o.partition || ':armis:' || o.source_instance
  WHERE di.identifier_type = $1 AND di.partition = ANY (CAST($2 AS text[]))
    AND (
      translate(regexp_replace(replace(replace(d.hostname, chr(8490), 'k'), chr(304), 'i'),
                               '[^A-Za-z0-9]+', '', 'g'),
                'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')
        = ANY (CAST($3 AS text[]))
      OR translate(regexp_replace(replace(replace(o.hostname, chr(8490), 'k'), chr(304), 'i'),
                                  '[^A-Za-z0-9]+', '', 'g'),
                   'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')
        = ANY (CAST($3 AS text[]))
    )
  """

  @identifiers_sql """
  SELECT di.device_id, di.identifier_type, di.identifier_value, di.partition, di.metadata
  FROM platform.device_identifiers AS di
  WHERE di.device_id = ANY (CAST($1 AS text[])) AND di.identifier_type = ANY (CAST($2 AS text[]))
  """

  @interface_macs_sql """
  SELECT im.device_id, im.mac FROM platform.device_interface_macs AS im
  WHERE im.device_id = ANY (CAST($1 AS text[]))
  """

  @observations_sql """
  SELECT o.partition, o.source_instance, o.source_object_id, o.hostname, o.mac, o.last_observed_at
  FROM platform.device_source_observations AS o
  JOIN unnest(CAST($1 AS text[]), CAST($2 AS text[]), CAST($3 AS text[]))
       AS k(partition, source_instance, source_object_id)
    ON o.partition = k.partition AND o.source = 'armis' AND o.source_instance = k.source_instance
   AND o.source_object_id = k.source_object_id
  """

  @retirements_sql """
  SELECT d.evidence FROM platform.identity_decisions AS d
  WHERE d.decision_kind = 'source_id_retired'
    AND d.evidence ->> 'archived_identifier_id' = ANY (CAST($1 AS text[]))
  """

  @type succession :: %{
          identifier_type: atom(),
          partitions: [String.t()],
          predecessor: String.t(),
          successor: String.t()
        }

  # `hostname_shared`: the pair shares a hostname as well as the MAC (design D11 counts these
  # apart from pairs a first-seen time corroborates alone).
  @type pair :: %{
          predecessor: String.t(),
          successor: String.t(),
          partitions: [String.t()],
          survivor: String.t(),
          merged: String.t(),
          hostname_shared: boolean(),
          evidence: map()
        }

  @type review :: %{reason: atom(), device_uids: [String.t()], decision: DecisionLog.decision()}

  @doc """
  Runs one pass: records the reviews, then merges the successive pairs in uid order, up to the
  cap. `opts`: `:actor`, and `:max_successions` to use instead of the setting. Returns the
  counts; `max_successions` is nil when no pair needed it.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:source_succession))
    %{successive: pairs, reviews: reviews} = plan(actor: actor)

    record_reviews(reviews)

    {cap, merging, deferred} = split_at_cap(pairs, opts, actor)

    counts =
      merging
      |> with_collections()
      |> Enum.reduce(%{merged: 0, skipped: 0}, &merge(&1, &2, actor))

    defer(deferred, cap)

    {:ok,
     Map.merge(counts, %{
       reviewed: length(reviews),
       deferred: length(deferred),
       max_successions: cap
     })}
  end

  @doc """
  Re-checks a succession inside its merge transaction (`MergeEngine`): the pair must still be
  successive, in the same partitions. The run's earlier merges can change both.
  """
  @spec revalidate(succession(), term()) :: :ok | {:error, term()}
  def revalidate(%{predecessor: predecessor, successor: successor, partitions: partitions}, actor) do
    predecessors = predecessors_of([predecessor], actor)
    currents = currents([successor], actor)

    with {:ok, pred} <- fetch(predecessors, predecessor, :not_predecessor),
         {:ok, current} <- fetch(currents, successor, :not_successive) do
      others =
        pred.macs
        |> MapSet.union(current.macs)
        |> MapSet.to_list()
        |> mac_reporters()
        |> Enum.reject(&(&1 in [predecessor, successor]))

      predecessors = Map.merge(predecessors, predecessors_of(others, actor))

      currents =
        Map.merge(currents, currents(Enum.reject(others, &Map.has_key?(predecessors, &1)), actor))

      %{successive: pairs} = predecessors |> snapshot(currents) |> classify()

      case Enum.find(pairs, &(&1.predecessor == predecessor and &1.successor == successor)) do
        %{partitions: ^partitions} -> :ok
        %{} -> {:error, {:succession_stale, :scope_changed}}
        nil -> {:error, {:succession_stale, :not_successive}}
      end
    end
  rescue
    e -> {:error, {:succession_check_failed, Exception.message(e)}}
  end

  @doc false
  @spec plan(keyword()) :: %{successive: [pair()], reviews: [review()]}
  def plan(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:source_succession))
    %{rows: rows} = Repo.query!(@predecessors_sql, [type_name(), @archive_reason])
    predecessors = rows |> Enum.map(&archive_row/1) |> predecessors(actor)

    reporters =
      predecessors
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union(&2, &1.macs))
      |> MapSet.to_list()
      |> mac_reporters()

    predecessors
    |> first_seen_holders()
    |> Enum.concat(reporters)
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(predecessors, &1))
    |> currents(actor)
    |> then(&snapshot(predecessors, &1))
    |> classify()
  end

  @doc """
  Classifies the pairs of a snapshot into successive pairs and reviews. Pure: the snapshot holds
  the predecessors and current records by uid, the hostname holders by partition and normalized
  hostname, and the asserted-distinct pairs as sorted uid tuples.
  """
  @spec classify(map()) :: %{successive: [pair()], reviews: [review()]}
  def classify(%{predecessors: predecessors, currents: currents} = snapshot) do
    holders = mac_holders(currents)
    first_seen = first_seen_index(currents)

    evaluated =
      Enum.flat_map(predecessors, fn {_uid, pred} ->
        pred
        |> related(holders, first_seen)
        |> Enum.flat_map(&evaluate(pred, Map.fetch!(currents, &1), holders, snapshot))
      end)

    paired = Enum.filter(evaluated, &paired?/1)
    by_predecessor = Enum.group_by(paired, & &1.predecessor, & &1.successor)
    by_successor = Enum.group_by(paired, & &1.successor, & &1.predecessor)

    successive =
      paired
      |> Enum.filter(fn entry ->
        not entry.distinct and Map.fetch!(by_predecessor, entry.predecessor) == [entry.successor] and
          Map.fetch!(by_successor, entry.successor) == [entry.predecessor]
      end)
      |> Enum.map(&pair(&1, snapshot))
      |> Enum.sort_by(&{&1.predecessor, &1.successor})

    merging = successive |> Enum.flat_map(&[&1.predecessor, &1.successor]) |> MapSet.new()

    reviews =
      evaluated
      |> Enum.reject(& &1.distinct)
      |> Enum.flat_map(&review_entry(&1, by_predecessor, by_successor, holders))
      |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
      |> Enum.reject(fn {uids, _entries} -> Enum.any?(uids, &MapSet.member?(merging, &1)) end)
      |> Enum.map(&review(&1, snapshot))
      |> Enum.sort_by(& &1.device_uids)

    %{successive: successive, reviews: reviews}
  end

  @doc """
  The metadata change a succession makes to the survivor, after the merge kept the survivor's
  value of every key both records carry: the source-owned keys are removed and the current
  record's put back (`successor_side` says which record that is), and each fact carrying
  provenance is the one updated last. A fact the survivor lacks is added while the survivor
  holds fewer than `MergeDeviceFacts.max_facts/0`, the newest first.
  """
  @spec metadata_patch(map() | nil, map() | nil, :survivor | :merged) :: %{
          remove: [String.t()],
          put: map()
        }
  def metadata_patch(survivor_metadata, merged_metadata, successor_side) do
    survivor_metadata = survivor_metadata || %{}
    merged_metadata = merged_metadata || %{}

    successor_metadata =
      if successor_side == :survivor, do: survivor_metadata, else: merged_metadata

    owned =
      successor_metadata |> source_owned() |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %{
      remove: @source_owned_keys,
      put: Map.merge(owned, fact_patch(survivor_metadata, merged_metadata))
    }
  end

  @doc false
  @spec source_owned_keys() :: [String.t()]
  def source_owned_keys, do: @source_owned_keys

  @doc "The source-owned metadata keys of `metadata` and their values."
  @spec source_owned(map() | nil) :: map()
  def source_owned(metadata) when is_map(metadata), do: Map.take(metadata, @source_owned_keys)
  def source_owned(_metadata), do: %{}

  ## Running

  defp record_reviews([]), do: :ok

  defp record_reviews(reviews) do
    reviews |> Enum.map(& &1.decision) |> DecisionLog.record_many()

    Enum.each(reviews, fn review ->
      :telemetry.execute(@telemetry_prefix ++ [:reviewed], %{count: 1}, %{
        identifier_type: @identifier_type,
        reason: review.reason,
        device_uids: review.device_uids
      })
    end)

    Logger.info("Source succession recorded #{length(reviews)} review(s)")
  end

  defp split_at_cap([], opts, _actor), do: {Keyword.get(opts, :max_successions), [], []}

  defp split_at_cap(pairs, opts, actor) do
    cap = max_successions(opts, actor)
    {merging, deferred} = Enum.split(pairs, cap)
    {cap, merging, deferred}
  end

  defp max_successions(opts, actor) do
    case Keyword.get(opts, :max_successions) do
      cap when is_integer(cap) and cap >= 0 -> cap
      _other -> configured_cap(actor)
    end
  end

  # Fails closed: without the setting nothing merges, and the pairs wait for a run that can
  # read it.
  defp configured_cap(actor) do
    case DeviceCleanupSettings.get_settings(actor: actor) do
      {:ok, %DeviceCleanupSettings{max_successions_per_run: cap}}
      when is_integer(cap) and cap >= 0 ->
        cap

      other ->
        Logger.warning(
          "Source succession merges nothing this run: max_successions_per_run is unavailable " <>
            "(#{inspect(other, limit: 5)})"
        )

        0
    end
  rescue
    e ->
      Logger.warning(
        "Source succession merges nothing this run: max_successions_per_run is unavailable " <>
          "(#{Exception.message(e)})"
      )

      0
  end

  defp merge(pair, counts, actor) do
    case merge_pair(pair, actor) do
      :ok -> Map.update!(counts, :merged, &(&1 + 1))
      {:error, _reason, _error} -> Map.update!(counts, :skipped, &(&1 + 1))
    end
  end

  @doc false
  # Merges one successive pair of `plan/1`, its evidence read by `with_collections/1`, as a
  # pass does. The remediation (design D11) merges through here. `opts`: `:on_merged`, passed
  # to `MergeEngine.merge_devices/3`. Returns `:ok` or `{:error, skip_reason, error}`.
  @spec merge_pair(pair(), term(), keyword()) :: :ok | {:error, atom(), term()}
  def merge_pair(pair, actor, opts \\ []) do
    result =
      MergeEngine.merge_devices(
        pair.merged,
        pair.survivor,
        [
          actor: actor,
          reason: @merge_reason,
          succession: %{
            identifier_type: @identifier_type,
            partitions: pair.partitions,
            predecessor: pair.predecessor,
            successor: pair.successor
          },
          details: pair.evidence
        ] ++ Keyword.take(opts, [:on_merged])
      )

    case result do
      :ok ->
        Deduplication.resolve_merged_pair(pair.predecessor, pair.successor, pair.survivor)
        emit(:merged, pair, %{survivor: pair.survivor})

        Logger.info(
          "Source succession merged #{pair.merged} into #{pair.survivor} " <>
            "(predecessor #{pair.predecessor}, successor #{pair.successor})"
        )

        :ok

      {:error, error} ->
        reason = skip_reason(error)

        if reason == :failed do
          Logger.warning(
            "Source succession could not merge #{pair.merged} into #{pair.survivor}: " <>
              inspect(error, limit: 10)
          )
        end

        emit(:skipped, pair, %{reason: reason})
        {:error, reason, error}
    end
  end

  defp skip_reason({:merge_blocked, _reason}), do: :merge_blocked
  defp skip_reason({:source_authority_conflict, _details}), do: :merge_blocked
  defp skip_reason({:succession_stale, _reason}), do: :stale
  defp skip_reason(_error), do: :failed

  defp defer([], _cap), do: :ok

  defp defer(deferred, cap) do
    Enum.each(deferred, &emit(:skipped, &1, %{reason: :max_successions}))

    Logger.warning(
      "Source succession deferred #{length(deferred)} pair(s) to the next run " <>
        "(max_successions_per_run #{cap})"
    )
  end

  defp emit(event, pair, metadata) do
    :telemetry.execute(
      @telemetry_prefix ++ [event],
      %{count: 1},
      Map.merge(
        %{
          identifier_type: @identifier_type,
          predecessor: pair.predecessor,
          successor: pair.successor,
          partitions: pair.partitions
        },
        metadata
      )
    )
  end

  @doc false
  # The collection ids that proved each retirement, from its `source_id_retired` decision; read
  # for the pairs that merge only.
  @spec with_collections([pair()]) :: [pair()]
  def with_collections([]), do: []

  def with_collections(pairs) do
    ids =
      pairs
      |> Enum.flat_map(&Map.get(&1.evidence, "retired_ids", []))
      |> Enum.map(&to_string(&1["archived_identifier_id"]))
      |> Enum.uniq()

    %{rows: rows} = Repo.query!(@retirements_sql, [ids])

    collections =
      Map.new(rows, fn [evidence] ->
        {to_string(evidence["archived_identifier_id"]), Map.get(evidence, "collection_ids", [])}
      end)

    Enum.map(pairs, fn pair ->
      retired =
        Enum.map(pair.evidence["retired_ids"], fn retired ->
          Map.put(
            retired,
            "collection_ids",
            Map.get(collections, to_string(retired["archived_identifier_id"]), [])
          )
        end)

      put_in(pair, [:evidence, "retired_ids"], retired)
    end)
  end

  ## Loading

  defp predecessors_of([], _actor), do: %{}

  defp predecessors_of(uids, actor) do
    %{rows: rows} = Repo.query!(@predecessors_of_sql, [type_name(), @archive_reason, uids])
    rows |> Enum.map(&archive_row/1) |> predecessors(actor)
  end

  defp archive_row([id, device_id, value, partition, metadata, archived_at]) do
    %{
      id: id,
      device_id: device_id,
      value: value,
      partition: partition,
      metadata: metadata || %{},
      archived_at: archived_at
    }
  end

  defp predecessors([], _actor), do: %{}

  defp predecessors(rows, actor) do
    by_uid = Enum.group_by(rows, & &1.device_id)
    uids = Map.keys(by_uid)
    devices = devices(uids, actor)
    identifiers = identifiers(uids)
    interface_macs = interface_macs(uids)
    observations = rows |> Enum.map(&{&1.partition, &1.value}) |> observations()

    Enum.reduce(by_uid, %{}, fn {uid, rows}, acc ->
      case Map.get(devices, uid) do
        %{deleted_at: nil} = device ->
          seen = Enum.map(rows, &as_of(observation(observations, &1.partition, &1.value), &1))
          ids = Map.get(identifiers, uid, [])

          Map.put(acc, uid, %{
            uid: uid,
            device: device,
            macs: macs(device, ids, Map.get(interface_macs, uid, []), seen),
            names: names(device, seen),
            agents: agents(device, ids),
            scopes: predecessor_scopes(rows, device)
          })

        _missing ->
          acc
      end
    end)
  end

  # The source's times for the retired ids of each partition, as their rows carried them into
  # the archive. The last-seen time is the latest, and unknown when a row has none.
  defp predecessor_scopes(rows, device) do
    rows
    |> Enum.group_by(& &1.partition)
    |> Map.new(fn {partition, rows} ->
      {partition,
       %{
         rows: rows,
         firsts: Enum.map(rows, &retired_first_seen(&1, device)),
         last_seen: latest(Enum.map(rows, &time(&1.metadata, "source_last_seen_time")))
       }}
    end)
  end

  defp retired_first_seen(row, device) do
    case time(row.metadata, "source_first_seen_time") do
      %DateTime{} = time -> %{time: time, basis: "source"}
      nil -> %{time: SourceCorroboration.parse_time(device.first_seen_time), basis: "record"}
    end
  end

  defp currents([], _actor), do: %{}

  defp currents(uids, actor) do
    devices = devices(uids, actor)
    identifiers = identifiers(uids)
    interface_macs = interface_macs(uids)
    type = type_name()

    held =
      Map.new(identifiers, fn {uid, ids} -> {uid, Enum.filter(ids, &(&1.type == type))} end)

    observations =
      held
      |> Map.values()
      |> List.flatten()
      |> Enum.map(&{&1.partition, &1.value})
      |> observations()

    Enum.reduce(held, %{}, fn
      {_uid, []}, acc ->
        acc

      {uid, rows}, acc ->
        case Map.get(devices, uid) do
          %{deleted_at: nil} = device ->
            seen = Enum.map(rows, &observation(observations, &1.partition, &1.value))
            ids = Map.fetch!(identifiers, uid)

            Map.put(acc, uid, %{
              uid: uid,
              device: device,
              values: rows |> Enum.map(&{&1.value, &1.partition}) |> Enum.sort(),
              macs: macs(device, ids, Map.get(interface_macs, uid, []), seen),
              names: names(device, seen),
              agents: agents(device, ids),
              scopes: current_scopes(rows)
            })

          _missing ->
            acc
        end
    end)
  end

  # The source's own first-seen times for the current ids of each partition; the earliest is
  # unknown when a row has none.
  defp current_scopes(rows) do
    rows
    |> Enum.group_by(& &1.partition)
    |> Map.new(fn {partition, rows} ->
      times = Enum.map(rows, &time(&1.metadata, "source_first_seen_time"))

      {partition,
       %{
         firsts: Enum.reject(times, &is_nil/1),
         first_seen: if(Enum.any?(times, &is_nil/1), do: nil, else: Enum.min(times, DateTime))
       }}
    end)
  end

  defp snapshot(predecessors, currents) do
    %{
      predecessors: predecessors,
      currents: currents,
      hostname_holders: hostname_holders(predecessors, currents),
      distinct:
        Deduplication.asserted_distinct_pairs(Map.keys(predecessors) ++ Map.keys(currents))
    }
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
      :ip,
      :agent_id,
      :first_seen_time,
      :created_time,
      :metadata,
      :source_retired_at,
      :deleted_at
    ])
    |> Page.stream!(actor: actor)
    |> Map.new(&{&1.uid, &1})
  end

  defp identifiers(uids) do
    types = [type_name(), "mac", "agent_id"]
    %{rows: rows} = Repo.query!(@identifiers_sql, [uids, types])

    Enum.group_by(rows, &hd/1, fn [_uid, type, value, partition, metadata] ->
      %{type: type, value: value, partition: partition, metadata: metadata || %{}}
    end)
  end

  defp interface_macs(uids) do
    %{rows: rows} = Repo.query!(@interface_macs_sql, [uids])
    Enum.group_by(rows, &hd/1, &List.last/1)
  end

  defp observations(keys) do
    scoped =
      keys
      |> Enum.flat_map(fn {partition, value} ->
        case armis_scope(partition) do
          {base, instance} -> [{base, instance, value}]
          nil -> []
        end
      end)
      |> Enum.uniq()

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

  defp observation(observations, partition, value) do
    case armis_scope(partition) do
      {base, instance} -> Map.get(observations, {base, instance, value})
      nil -> nil
    end
  end

  # What the source reported for a retired id as of its retirement.
  defp as_of(%{last_observed_at: %NaiveDateTime{} = observed} = observation, %{
         archived_at: %DateTime{} = archived_at
       }) do
    if DateTime.after?(DateTime.from_naive!(observed, "Etc/UTC"), archived_at),
      do: nil,
      else: observation
  end

  defp as_of(_observation, _row), do: nil

  # An Armis identifier partition is `<partition>:armis:<sync source id>` (`Ids`); the source's
  # observations are keyed by the base partition and the source id.
  defp armis_scope(partition) when is_binary(partition) do
    case String.split(partition, ":armis:", parts: 2) do
      [base, instance] when base != "" and instance != "" -> {base, instance}
      _other -> nil
    end
  end

  defp armis_scope(_partition), do: nil

  defp mac_reporters([]), do: []

  defp mac_reporters(macs) do
    %{rows: rows} = Repo.query!(@mac_reporters_sql, [type_name(), macs])
    Enum.map(rows, &hd/1)
  end

  # Candidates for a review without a shared MAC: the current records whose id the source first
  # saw when it first saw a retired one.
  defp first_seen_holders(predecessors) do
    keys =
      for pred <- Map.values(predecessors),
          {partition, scope} <- pred.scopes,
          %{time: %DateTime{} = time} <- scope.firsts,
          uniq: true,
          do: {partition, iso8601(time)}

    case keys do
      [] ->
        []

      keys ->
        %{rows: rows} =
          Repo.query!(@first_seen_holders_sql, [
            type_name(),
            Enum.map(keys, &elem(&1, 0)),
            Enum.map(keys, &elem(&1, 1))
          ])

        Enum.map(rows, &hd/1)
    end
  end

  # The current records of each partition holding each hostname a predecessor and a current
  # record of the partition share; a hostname held by two does not corroborate.
  defp hostname_holders(predecessors, currents) do
    pred_names =
      predecessors |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union(&2, &1.names))

    pred_partitions =
      predecessors |> Map.values() |> Enum.flat_map(&Map.keys(&1.scopes)) |> MapSet.new()

    keys =
      for current <- Map.values(currents),
          partition <- Map.keys(current.scopes),
          MapSet.member?(pred_partitions, partition),
          name <- MapSet.intersection(current.names, pred_names),
          uniq: true,
          do: {partition, name}

    case keys do
      [] ->
        %{}

      keys ->
        %{rows: rows} =
          Repo.query!(@hostname_holders_sql, [
            type_name(),
            keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
            keys |> Enum.map(&hostname_key(elem(&1, 1))) |> Enum.uniq()
          ])

        Enum.reduce(rows, %{}, fn [uid, partition | hostnames], acc ->
          hostnames
          |> Enum.map(&SourceCorroboration.normalize_hostname/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.reduce(acc, fn name, acc ->
            Map.update(acc, {partition, name}, MapSet.new([uid]), &MapSet.put(&1, uid))
          end)
        end)
    end
  end

  defp hostname_key(name), do: String.replace(name, ~r/[^a-z0-9]+/, "")

  defp macs(device, ids, interface_macs, observations) do
    SourceCorroboration.hardware_macs(
      [device.mac] ++
        for(%{type: "mac", value: value} <- ids, do: value) ++
        interface_macs ++ Enum.map(observations, &(&1 && &1.mac))
    )
  end

  defp names(device, observations) do
    [device.hostname | Enum.map(observations, &(&1 && &1.hostname))]
    |> Enum.map(&SourceCorroboration.normalize_hostname/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp agents(device, ids) do
    [device.agent_id | for(%{type: "agent_id", value: value} <- ids, do: value)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  ## Classifying

  defp mac_holders(currents) do
    Enum.reduce(currents, %{}, fn {uid, current}, acc ->
      Enum.reduce(current.macs, acc, fn mac, acc ->
        Map.update(acc, mac, MapSet.new([uid]), &MapSet.put(&1, uid))
      end)
    end)
  end

  defp first_seen_index(currents) do
    for {uid, current} <- currents,
        {partition, scope} <- current.scopes,
        time <- scope.firsts,
        reduce: %{} do
      acc -> Map.update(acc, {partition, iso8601(time)}, MapSet.new([uid]), &MapSet.put(&1, uid))
    end
  end

  # The current records that share a MAC or a first-seen time with the predecessor.
  defp related(pred, holders, first_seen) do
    by_mac = Enum.flat_map(pred.macs, &Enum.to_list(Map.get(holders, &1, [])))

    by_time =
      for {partition, scope} <- pred.scopes,
          %{time: %DateTime{} = time} <- scope.firsts,
          uid <- Map.get(first_seen, {partition, iso8601(time)}, []),
          do: uid

    (by_mac ++ by_time) |> Enum.uniq() |> Enum.reject(&(&1 == pred.uid)) |> Enum.sort()
  end

  defp evaluate(pred, current, holders, snapshot) do
    partitions = pred.scopes |> Map.keys() |> Enum.filter(&Map.has_key?(current.scopes, &1))

    case Enum.sort(partitions) do
      [] ->
        []

      partitions ->
        shared = pred.macs |> MapSet.intersection(current.macs) |> Enum.sort()
        checks = Enum.map(partitions, &corroborate(pred, current, &1, snapshot))

        [
          %{
            predecessor: pred.uid,
            successor: current.uid,
            partitions: partitions,
            shared: shared,
            link: Enum.filter(shared, &(holders |> Map.fetch!(&1) |> MapSet.size() == 1)),
            corroboration:
              if(Enum.all?(checks, &match?({:ok, _}, &1)), do: Enum.map(checks, &elem(&1, 1))),
            equal_first_seen: Enum.any?(partitions, &equal_first_seen(pred, current, &1)),
            names_overlap: not MapSet.disjoint?(pred.names, current.names),
            distinct: distinct?(pred, current, snapshot)
          }
        ]
    end
  end

  defp corroborate(pred, current, partition, snapshot) do
    earlier = Map.fetch!(pred.scopes, partition)
    later = Map.fetch!(current.scopes, partition)

    case equal_first_seen(pred, current, partition) do
      %{time: time, basis: basis} ->
        {:ok,
         %{
           "partition" => partition,
           "field" => "first_seen",
           "first_seen" => iso8601(time),
           "basis" => basis
         }}

      nil ->
        unique = unique_names(current, partition, Map.get(snapshot, :hostname_holders, %{}))

        case SourceCorroboration.corroboration(
               %{last_seen: earlier.last_seen, hostnames: MapSet.to_list(pred.names)},
               %{first_seen: later.first_seen, hostnames: unique}
             ) do
          {:ok, :hostname} ->
            {:ok,
             %{
               "partition" => partition,
               "field" => "hostname",
               "hostname" => pred.names |> MapSet.intersection(MapSet.new(unique)) |> Enum.min(),
               "predecessor_last_seen" => iso8601(earlier.last_seen),
               "successor_first_seen" => iso8601(later.first_seen)
             }}

          _no ->
            :error
        end
    end
  end

  defp equal_first_seen(pred, current, partition) do
    later = Map.fetch!(current.scopes, partition)

    pred.scopes
    |> Map.fetch!(partition)
    |> Map.get(:firsts)
    |> Enum.find(fn
      %{time: %DateTime{} = time} -> Enum.any?(later.firsts, &(DateTime.compare(&1, time) == :eq))
      _unknown -> false
    end)
  end

  defp unique_names(current, partition, hostname_holders) do
    Enum.filter(current.names, fn name ->
      hostname_holders
      |> Map.get({partition, name}, MapSet.new())
      |> MapSet.delete(current.uid)
      |> MapSet.size() == 0
    end)
  end

  defp distinct?(pred, current, snapshot) do
    asserted = Map.get(snapshot, :distinct, MapSet.new())

    MapSet.member?(asserted, Enum.min_max([pred.uid, current.uid])) or
      (MapSet.size(pred.agents) > 0 and MapSet.size(current.agents) > 0 and
         MapSet.disjoint?(pred.agents, current.agents))
  end

  defp paired?(entry), do: entry.link != [] and not is_nil(entry.corroboration)

  defp review_entry(entry, by_predecessor, by_successor, holders) do
    case review_reason(entry) do
      nil ->
        []

      reason ->
        rivals =
          case reason do
            :not_one_to_one ->
              Map.get(by_predecessor, entry.predecessor, []) ++
                Map.get(by_successor, entry.successor, [])

            :shared_mac ->
              Enum.flat_map(entry.shared, &Enum.to_list(Map.fetch!(holders, &1)))

            _other ->
              []
          end

        uids = Enum.sort(Enum.uniq([entry.predecessor, entry.successor | rivals]))
        [{uids, reason, entry}]
    end
  end

  defp review_reason(entry) do
    cond do
      paired?(entry) -> :not_one_to_one
      entry.shared != [] and entry.link == [] -> :shared_mac
      entry.link != [] and entry.names_overlap -> :overlapping_hostname
      entry.link != [] -> :mac_only
      entry.equal_first_seen and entry.names_overlap -> :corroborated_without_mac
      true -> nil
    end
  end

  defp review({uids, entries}, snapshot) do
    reason = entries |> Enum.map(&elem(&1, 0)) |> Enum.min_by(&rank/1)

    pairs =
      entries
      |> Enum.map(fn {pair_reason, entry} -> review_evidence(entry, pair_reason, snapshot) end)
      |> Enum.sort_by(&{&1["predecessor"], &1["successor"]})

    %{
      reason: reason,
      device_uids: uids,
      decision: %{
        kind: :succession_review,
        reason: Atom.to_string(reason),
        device_uids: uids,
        subject: pairs |> Enum.flat_map(& &1["retired_ids"]) |> Enum.min(fn -> nil end),
        source: @decision_source,
        evidence: %{"identifier_type" => type_name(), "pairs" => pairs}
      }
    }
  end

  defp rank(reason), do: Enum.find_index(@review_reasons, &(&1 == reason))

  defp review_evidence(entry, reason, snapshot) do
    pred = Map.fetch!(snapshot.predecessors, entry.predecessor)

    %{
      "predecessor" => entry.predecessor,
      "successor" => entry.successor,
      "reason" => Atom.to_string(reason),
      "partitions" => entry.partitions,
      "shared_macs" => entry.shared,
      "linking_macs" => entry.link,
      "corroboration" => entry.corroboration || [],
      "retired_ids" =>
        entry.partitions
        |> Enum.flat_map(&Enum.map(pred.scopes[&1].rows, fn row -> row.value end))
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp pair(entry, snapshot) do
    pred = Map.fetch!(snapshot.predecessors, entry.predecessor)
    current = Map.fetch!(snapshot.currents, entry.successor)
    [survivor, merged] = Enum.sort_by([pred.device, current.device], &{created_rank(&1), &1.uid})

    %{
      predecessor: entry.predecessor,
      successor: entry.successor,
      partitions: entry.partitions,
      survivor: survivor.uid,
      merged: merged.uid,
      hostname_shared: entry.names_overlap,
      evidence: %{
        "source" => "scheduled_reconciliation",
        "identifier_type" => type_name(),
        "partitions" => entry.partitions,
        "predecessor" => entry.predecessor,
        "successor" => entry.successor,
        "shared_macs" => entry.link,
        "corroboration" => entry.corroboration,
        "retired_ids" =>
          for partition <- entry.partitions, row <- pred.scopes[partition].rows do
            %{
              "value" => row.value,
              "partition" => row.partition,
              "archived_identifier_id" => row.id,
              "archived_at" => iso8601(row.archived_at)
            }
          end,
        "current_ids" =>
          for {value, partition} <- current.values, partition in entry.partitions do
            %{"value" => value, "partition" => partition}
          end
      }
    }
  end

  # The record created first, then the lowest uid.
  defp created_rank(device) do
    case device.created_time || device.first_seen_time do
      %DateTime{} = time -> {0, DateTime.to_unix(time, :microsecond)}
      _unknown -> {1, 0}
    end
  end

  ## Facts

  # The merged record's facts that win: the survivor has none of the key, or an older one. A
  # tie keeps the survivor's. Each replaces the survivor's value; an addition is taken while the
  # survivor has room, newest first.
  defp fact_patch(survivor_metadata, merged_metadata) do
    key = DeviceMetadata.provenance_key()
    survivor_facts = provenance(survivor_metadata, key)
    reserved = [key | @source_owned_keys] ++ MergeDeviceFacts.reserved_keys()

    winners =
      merged_metadata
      |> provenance(key)
      |> Enum.filter(fn {fact, entry} ->
        fact not in reserved and Map.has_key?(merged_metadata, fact) and
          newer?(entry, Map.get(survivor_facts, fact))
      end)

    {replacements, additions} =
      Enum.split_with(winners, fn {fact, _entry} -> Map.has_key?(survivor_facts, fact) end)

    room = max(MergeDeviceFacts.max_facts() - map_size(survivor_facts), 0)

    taken =
      replacements ++
        (additions
         |> Enum.sort_by(fn {_fact, entry} -> updated_at(entry) end, {:desc, DateTime})
         |> Enum.take(room))

    case taken do
      [] ->
        %{}

      taken ->
        taken
        |> Map.new(fn {fact, _entry} -> {fact, Map.fetch!(merged_metadata, fact)} end)
        |> Map.put(key, Map.merge(survivor_facts, Map.new(taken)))
    end
  end

  defp provenance(metadata, key) do
    case Map.get(metadata, key) do
      %{} = facts -> facts
      _none -> %{}
    end
  end

  defp newer?(entry, survivor_entry) do
    case {updated_at(entry), updated_at(survivor_entry)} do
      {nil, _survivor} -> false
      {_merged, nil} -> true
      {merged, survivor} -> DateTime.after?(merged, survivor)
    end
  end

  defp updated_at(%{"updated_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _invalid -> nil
    end
  end

  defp updated_at(_entry), do: nil

  ## Helpers

  defp fetch(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:succession_stale, reason}}
    end
  end

  defp time(metadata, key), do: SourceCorroboration.parse_time(Map.get(metadata || %{}, key))

  defp latest(times) do
    if Enum.any?(times, &is_nil/1), do: nil, else: Enum.max(times, DateTime)
  end

  defp type_name, do: Atom.to_string(@identifier_type)

  defp iso8601(%DateTime{} = time),
    do: time |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp iso8601(_time), do: nil
end
