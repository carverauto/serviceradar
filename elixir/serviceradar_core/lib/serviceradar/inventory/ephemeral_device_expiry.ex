defmodule ServiceRadar.Inventory.EphemeralDeviceExpiry do
  @moduledoc """
  Expires ephemeral devices on last-seen (#4603).

  A device whose identity rests on nothing stronger than evidence -- locally-administered
  (randomized) MACs, an IP address -- is ephemeral: a phone that rotates its MAC, or a host a
  sweep found once, can never be recognized again with certainty, so its record has a
  lifetime. Once such a device has not been seen for the configured window it is soft-deleted
  with `deleted_reason: "stale_ephemeral"`. A device seen again later comes back: a sweep that
  finds its address answering restores it whatever its discovery sources, and so does a sync
  that reports it again, while a sweep that finds the address down leaves it deleted. Either
  restore bumps its identity revision and leaves a `platform.device_revival_audit` row.

  Eligibility is by identity strength, never by source. A device is NEVER expired when it
  holds any of:

    * an agent (`agent_id` identifier, attribute or metadata);
    * a source-authoritative identifier (`armis_device_id`, `integration_id`,
      `netbox_device_id`), in `device_identifiers` or in its metadata;
    * a hardware serial;
    * a globally-unique MAC, as an identifier, an own-interface MAC
      (`device_interface_macs`) or its `mac` attribute. A MAC value that does not normalize
      to twelve hex digits is treated as globally unique, so a value this module cannot read
      keeps the device.

  The SQL function `platform.device_holds_strong_identifier/1` holds a device by its
  identifier rows, its own-interface MACs and the agent and source ids in its metadata (a
  string or a number, without the admission rules the identity code applies), so the
  candidate read and the delete apply one definition. The in-memory check
  (`strong_attributes?/1`) adds the `mac` attribute and the rest of the metadata evidence.

  Devices an operator created (`discovery_sources` contains `"manual"`) and devices matched by
  the configured SRQL exclusion query are never expired either. If the exclusion query cannot
  be evaluated, nothing is expired in that run.

  The strong-identifier check is repeated inside the `UPDATE ... WHERE` that soft-deletes, so a
  device that gained a strong identifier, or was seen again, after it was selected is not
  expired.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.Repo
  alias ServiceRadar.SRQLQuery

  require Ash.Query
  require Logger

  @deleted_reason "stale_ephemeral"
  @deleted_by "system:ephemeral_device_expiry"
  @operator_sources ["manual"]
  @default_days 30
  @default_max_fraction 0.5
  @exclusion_page_limit 1_000
  @exclusion_max_pages 1_000

  @type settings :: %{
          optional(:ephemeral_expiry_enabled) => boolean(),
          optional(:ephemeral_expiry_days) => pos_integer(),
          optional(:ephemeral_expiry_exclusion_query) => String.t() | nil,
          optional(:ephemeral_expiry_max_fraction) => float(),
          optional(:ephemeral_expiry_guard_override) => boolean(),
          optional(:batch_size) => pos_integer()
        }

  @type counts :: %{
          candidates: non_neg_integer(),
          kept_by_evidence: non_neg_integer(),
          kept_by_exclusion: non_neg_integer(),
          eligible: non_neg_integer(),
          expired: non_neg_integer(),
          skipped_at_delete: non_neg_integer()
        }

  @no_counts %{
    candidates: 0,
    kept_by_evidence: 0,
    kept_by_exclusion: 0,
    eligible: 0,
    expired: 0,
    skipped_at_delete: 0
  }

  # What the guard judges, and what its refusal reports.
  @judged_counts [:candidates, :kept_by_evidence, :kept_by_exclusion, :eligible]

  @doc "The `deleted_reason` an expired device carries."
  @spec deleted_reason() :: String.t()
  def deleted_reason, do: @deleted_reason

  @doc """
  Runs one expiry pass. Returns `{:ok, counts}` or `{:error, reason}`; nothing is expired on
  error. The counts, which the `DeviceCleanupWorker` log line and the `:run` telemetry event
  carry too:

    * `candidates` - live devices unseen since the cutoff, with no agent, not operator-created
      and holding no strong identifier by `platform.device_holds_strong_identifier/1`;
    * `kept_by_evidence` - candidates the exclusion query did not match whose `mac` attribute
      or metadata carry evidence the identifier tables do not (`strong_attributes?/1`);
    * `kept_by_exclusion` - candidates the exclusion query matched, whatever their evidence;
    * `eligible` - the candidates neither kept;
    * `expired` - the eligible devices soft-deleted;
    * `skipped_at_delete` - the eligible devices the delete did not expire: its re-check
      refused them (they gained a strong identifier, were seen again or were deleted after the
      read), or it failed, which is logged.

  A pass that would expire more than `ephemeral_expiry_max_fraction` of the live devices in
  scope is refused (`{:error, {:mass_expiry_refused, counts}}`, the counts up to `eligible`
  with `live` and `max_fraction`) unless `ephemeral_expiry_guard_override` is set -- the same
  guard, on the same terms, as the canonical topology prune
  (`CanonicalRebuild.prune_guard_check/4`). It judges the `eligible` count, which a read-only
  walk over the same pages takes before any delete; the override skips that walk.

  `opts`:
    * `:now` - the reference time (default `DateTime.utc_now/0`);
    * `:uids` - restrict the pass to these device uids (used by the DIRE lifecycle trace, which
      must not expire devices outside its own world);
    * `:query_page` - the SRQL page function (tests);
    * `:before_delete` - called with each page's eligible uids just before their delete
      (tests: a device that changes between the read and the delete).
  """
  @spec run(settings(), term(), keyword()) :: {:ok, counts()} | {:error, term()}
  def run(settings, actor, opts \\ []) do
    if Map.get(settings, :ephemeral_expiry_enabled, false) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      days = Map.get(settings, :ephemeral_expiry_days) || @default_days

      with {:ok, excluded} <-
             excluded_uids(Map.get(settings, :ephemeral_expiry_exclusion_query), opts),
           pass = %{
             cutoff: now |> DateTime.shift(day: -days) |> DateTime.truncate(:second),
             batch_size: Map.get(settings, :batch_size) || 1_000,
             excluded: excluded,
             opts: opts
           },
           :ok <- mass_expiry_guard(settings, pass) do
        counts = expire(pass, actor)
        emit(counts)
        {:ok, counts}
      end
    else
      {:ok, @no_counts}
    end
  end

  defp expire(pass, actor) do
    before_delete = Keyword.get(pass.opts, :before_delete, fn _uids -> :ok end)

    walk(pass, nil, @no_counts, fn page, counts ->
      case judge(page, counts, pass.excluded) do
        {counts, []} ->
          counts

        {counts, eligible} ->
          before_delete.(eligible)
          expired = soft_delete(eligible, pass.cutoff, actor)

          %{
            counts
            | expired: counts.expired + length(expired),
              skipped_at_delete: counts.skipped_at_delete + length(eligible) - length(expired)
          }
      end
    end)
  end

  # Keyset pagination on (last_seen_time, uid): each page starts after the last device the
  # previous one judged, so a kept device is never read twice in a walk.
  defp walk(pass, after_key, acc, fun) do
    page = candidates(pass.cutoff, pass.batch_size, after_key, pass.opts)
    acc = fun.(page, acc)

    if length(page) == pass.batch_size do
      last = List.last(page)
      walk(pass, {last.last_seen_time, last.uid}, acc, fun)
    else
      acc
    end
  end

  # Stage 2 on one page of candidates: the exclusion query, then the evidence the identifier
  # tables may not carry (an identifier row can be garbage-collected while the device row
  # still names its hardware MAC or source id). A device both would keep counts as kept by the
  # exclusion query.
  defp judge(page, counts, excluded) do
    {by_exclusion, rest} = Enum.split_with(page, &MapSet.member?(excluded, &1.uid))
    {by_evidence, eligible} = Enum.split_with(rest, &strong_attributes?/1)

    counts = %{
      counts
      | candidates: counts.candidates + length(page),
        kept_by_evidence: counts.kept_by_evidence + length(by_evidence),
        kept_by_exclusion: counts.kept_by_exclusion + length(by_exclusion),
        eligible: counts.eligible + length(eligible)
    }

    {counts, Enum.map(eligible, & &1.uid)}
  end

  # The override lifts the guard, so the read-only walk is skipped.
  defp mass_expiry_guard(%{ephemeral_expiry_guard_override: true}, _pass), do: :ok

  defp mass_expiry_guard(settings, pass) do
    max_fraction = Map.get(settings, :ephemeral_expiry_max_fraction) || @default_max_fraction

    counts =
      pass
      |> walk(nil, @no_counts, fn page, counts ->
        page |> judge(counts, pass.excluded) |> elem(0)
      end)
      |> Map.take(@judged_counts)

    live = live_count(pass.opts)

    case CanonicalRebuild.prune_guard_check(counts.eligible, live, max_fraction, false) do
      :allow ->
        :ok

      {:refuse, reason} ->
        :telemetry.execute(
          [:serviceradar, :inventory, :ephemeral_expiry, :refused],
          Map.put(counts, :live_devices, live),
          %{reason: reason, max_fraction: max_fraction}
        )

        Logger.error(
          "EphemeralDeviceExpiry: pass refused (#{reason}): it would expire " <>
            "#{counts.eligible} of #{live} live devices (max fraction #{max_fraction}; " <>
            "#{counts.candidates} unseen past the window, #{counts.kept_by_evidence} kept " <>
            "by evidence, #{counts.kept_by_exclusion} by the exclusion query). " <>
            "ephemeral_expiry_guard_override in the device cleanup settings forces it, and " <>
            "stays set, lifting this guard for every later pass, until it is cleared"
        )

        {:error,
         {:mass_expiry_refused, Map.merge(counts, %{live: live, max_fraction: max_fraction})}}
    end
  end

  defp live_count(opts) do
    query = from(d in "ocsf_devices", prefix: "platform", where: is_nil(d.deleted_at))

    query =
      case Keyword.get(opts, :uids) do
        nil -> query
        uids -> where(query, [d], d.uid in ^uids)
      end

    Repo.one(select(query, [d], count()))
  end

  # Live devices unseen since the cutoff, with no agent, not operator-created, and holding no
  # strong identifier, oldest first.
  defp candidates(cutoff, batch_size, after_key, opts) do
    cutoff
    |> candidate_query(after_key, opts)
    |> limit(^batch_size)
    |> select([d], %{
      uid: d.uid,
      last_seen_time: d.last_seen_time,
      mac: d.mac,
      metadata: d.metadata,
      partition: d.partition
    })
    |> Repo.all()
  end

  defp candidate_query(cutoff, after_key, opts) do
    query =
      from(d in "ocsf_devices",
        prefix: "platform",
        where: is_nil(d.deleted_at) and d.last_seen_time < ^cutoff,
        where: is_nil(d.agent_id) or d.agent_id == "",
        where:
          not fragment(
            "COALESCE(?, ARRAY[]::text[]) && ?::text[]",
            d.discovery_sources,
            ^@operator_sources
          ),
        where: not fragment("platform.device_holds_strong_identifier(?)", d.uid),
        order_by: [asc: d.last_seen_time, asc: d.uid]
      )

    query =
      case after_key do
        nil ->
          query

        {seen, uid} ->
          where(query, [d], fragment("(?, ?) > (?, ?)", d.last_seen_time, d.uid, ^seen, ^uid))
      end

    case Keyword.get(opts, :uids) do
      nil -> query
      uids -> where(query, [d], d.uid in ^uids)
    end
  end

  @doc false
  @spec strong_attributes?(map()) :: boolean()
  def strong_attributes?(candidate) do
    ids =
      Ids.extract_strong_identifiers(%{
        mac: candidate[:mac],
        metadata: candidate[:metadata] || %{},
        partition: candidate[:partition]
      })

    Enum.any?([:agent_id, :armis_id, :integration_id, :netbox_id, :hardware_serial], fn key ->
      Ids.present_id?(Ids.ids_get(ids, key))
    end) or Enum.any?(Map.get(ids, :macs, []), &(not Mac.locally_administered_mac?(&1))) or
      unreadable_mac?(candidate[:mac])
  end

  # A mac attribute that carries something but normalizes to no MAC at all could be a format
  # this module does not read; keep the device rather than guess.
  defp unreadable_mac?(mac) when is_binary(mac),
    do: String.trim(mac) != "" and Mac.normalize_mac_list(mac) == []

  defp unreadable_mac?(_mac), do: false

  # The soft delete re-checks liveness, last-seen and the strong-identifier rule in the UPDATE's
  # WHERE clause, so the decision and the delete are one statement.
  defp soft_delete(uids, cutoff, actor) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false})
      |> Ash.Query.filter(
        uid in ^uids and is_nil(deleted_at) and last_seen_time < ^cutoff and
          not fragment("platform.device_holds_strong_identifier(?)", uid)
      )

    result =
      Ash.bulk_update(
        query,
        :soft_delete,
        %{deleted_reason: @deleted_reason, deleted_by: @deleted_by},
        actor: actor,
        strategy: [:atomic],
        return_records?: true,
        return_errors?: true,
        select: [:uid]
      )

    case result do
      %Ash.BulkResult{status: :success, records: records} ->
        expired = Enum.map(records || [], & &1.uid)
        log_expired(expired)
        expired

      %Ash.BulkResult{errors: errors, records: records} ->
        Logger.warning("EphemeralDeviceExpiry: soft delete failed", errors: inspect(errors))
        Enum.map(records || [], & &1.uid)
    end
  end

  defp log_expired([]), do: :ok

  defp log_expired(uids) do
    Logger.info(
      "EphemeralDeviceExpiry: expired #{length(uids)} device(s) unseen past the window " <>
        "with no strong identifier: #{inspect(Enum.take(uids, 50))}"
    )
  end

  defp emit(counts) do
    :telemetry.execute(
      [:serviceradar, :inventory, :ephemeral_expiry, :run],
      counts,
      %{deleted_reason: @deleted_reason}
    )
  end

  # ---------------------------------------------------------------------------------------
  # The SRQL exclusion query

  defp excluded_uids(query, opts) when is_binary(query) do
    case String.trim(query) do
      "" ->
        {:ok, MapSet.new()}

      query ->
        query
        |> SRQLQuery.ensure_target(:devices)
        |> collect_excluded(Keyword.get(opts, :query_page, &SRQLRunner.query_page/2))
    end
  end

  defp excluded_uids(_query, _opts), do: {:ok, MapSet.new()}

  defp collect_excluded(query, query_page) do
    1..@exclusion_max_pages
    |> Enum.reduce_while({nil, MapSet.new()}, fn _page, {cursor, acc} ->
      opts = [limit: @exclusion_page_limit, direction: "next"]
      opts = if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts

      case query_page.(query, opts) do
        {:ok, %{rows: rows} = page} when is_list(rows) ->
          acc =
            rows
            |> Enum.map(&row_uid/1)
            |> Enum.reject(&is_nil/1)
            |> MapSet.new()
            |> MapSet.union(acc)

          next = page[:next_cursor]

          if is_binary(next) and next != "" and next != cursor,
            do: {:cont, {next, acc}},
            else: {:halt, {:done, acc}}

        other ->
          {:halt, {:error, other}}
      end
    end)
    |> case do
      {:done, acc} ->
        {:ok, acc}

      {:error, other} ->
        Logger.warning(
          "EphemeralDeviceExpiry: exclusion query failed; expiring nothing this run: " <>
            inspect(other)
        )

        {:error, {:exclusion_query_failed, other}}

      {_cursor, _acc} ->
        Logger.warning(
          "EphemeralDeviceExpiry: exclusion query exceeded #{@exclusion_max_pages} pages; " <>
            "expiring nothing this run"
        )

        {:error, :exclusion_query_too_large}
    end
  end

  defp row_uid(%{"uid" => uid}) when is_binary(uid), do: uid
  defp row_uid(%{uid: uid}) when is_binary(uid), do: uid
  defp row_uid(_row), do: nil
end
