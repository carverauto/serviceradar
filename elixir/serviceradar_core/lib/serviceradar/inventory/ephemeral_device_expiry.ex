defmodule ServiceRadar.Inventory.EphemeralDeviceExpiry do
  @moduledoc """
  Expires ephemeral devices on last-seen (#4603).

  A device whose identity rests on nothing stronger than evidence -- locally-administered
  (randomized) MACs, an IP address -- is ephemeral: a phone that rotates its MAC, or a host a
  sweep found once, can never be recognized again with certainty, so its record has a
  lifetime. Once such a device has not been seen for the configured window it is soft-deleted
  with `deleted_reason: "stale_ephemeral"`. A device seen again later comes back through the
  ordinary restore paths (a sweep, a sync), which bump its identity revision and leave a
  `platform.device_revival_audit` row.

  Eligibility is by identity strength, never by source. A device is NEVER expired when it
  holds any of:

    * an agent (`agent_id` identifier or attribute);
    * a source-authoritative identifier (`armis_device_id`, `integration_id`,
      `netbox_device_id`), in `device_identifiers` or in its metadata;
    * a hardware serial;
    * a globally-unique MAC, as an identifier, an own-interface MAC
      (`device_interface_macs`) or its `mac` attribute. A MAC value that does not normalize
      to twelve hex digits is treated as globally unique, so a value this module cannot read
      keeps the device.

  The identifier-table part of that rule is the SQL function
  `platform.device_holds_strong_identifier/1`, so the candidate read and the delete apply one
  definition.

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

  @doc "The `deleted_reason` an expired device carries."
  @spec deleted_reason() :: String.t()
  def deleted_reason, do: @deleted_reason

  @doc """
  Runs one expiry pass. Returns `%{expired: n, candidates: n, excluded: n}` or
  `{:error, reason}`; nothing is expired on error.

  A pass that would expire more than `ephemeral_expiry_max_fraction` of the live devices in
  scope is refused (`{:error, {:mass_expiry_refused, counts}}`) unless
  `ephemeral_expiry_guard_override` is set -- the same guard, on the same terms, as the
  canonical topology prune (`CanonicalRebuild.prune_guard_check/4`). The candidate count it
  judges is taken before the attribute and exclusion-query checks, so it can only over-count,
  which errs toward refusing.

  `opts`:
    * `:now` - the reference time (default `DateTime.utc_now/0`);
    * `:uids` - restrict the pass to these device uids (used by the DIRE lifecycle trace, which
      must not expire devices outside its own world);
    * `:query_page` - the SRQL page function (tests).
  """
  @spec run(settings(), term(), keyword()) ::
          {:ok,
           %{
             expired: non_neg_integer(),
             candidates: non_neg_integer(),
             excluded: non_neg_integer()
           }}
          | {:error, term()}
  def run(settings, actor, opts \\ []) do
    if Map.get(settings, :ephemeral_expiry_enabled, false) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      days = Map.get(settings, :ephemeral_expiry_days) || @default_days
      cutoff = now |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)
      batch_size = Map.get(settings, :batch_size) || 1_000

      with {:ok, excluded} <-
             excluded_uids(Map.get(settings, :ephemeral_expiry_exclusion_query), opts),
           :ok <- mass_expiry_guard(settings, cutoff, opts) do
        expire_batches(cutoff, batch_size, excluded, actor, opts, nil, %{
          expired: 0,
          candidates: 0,
          excluded: 0
        })
      end
    else
      {:ok, %{expired: 0, candidates: 0, excluded: 0}}
    end
  end

  defp expire_batches(cutoff, batch_size, excluded, actor, opts, after_key, stats) do
    candidates = candidates(cutoff, batch_size, after_key, opts)
    {kept, eligible} = Enum.split_with(candidates, &keep?(&1, excluded))

    expired =
      case eligible do
        [] -> []
        eligible -> soft_delete(Enum.map(eligible, & &1.uid), cutoff, actor)
      end

    stats = %{
      stats
      | expired: stats.expired + length(expired),
        candidates: stats.candidates + length(candidates),
        excluded: stats.excluded + length(kept)
    }

    # Keyset pagination on (last_seen_time, uid): each batch starts after the last device the
    # previous one judged, so a kept device is never read twice in a pass.
    if length(candidates) == batch_size do
      last = List.last(candidates)

      expire_batches(
        cutoff,
        batch_size,
        excluded,
        actor,
        opts,
        {last.last_seen_time, last.uid},
        stats
      )
    else
      emit(stats)
      {:ok, stats}
    end
  end

  defp mass_expiry_guard(settings, cutoff, opts) do
    max_fraction = Map.get(settings, :ephemeral_expiry_max_fraction) || @default_max_fraction
    override? = Map.get(settings, :ephemeral_expiry_guard_override, false) == true
    candidates = cutoff |> candidate_query(nil, opts) |> count()
    live = live_count(opts)

    case CanonicalRebuild.prune_guard_check(candidates, live, max_fraction, override?) do
      :allow ->
        :ok

      {:refuse, reason} ->
        :telemetry.execute(
          [:serviceradar, :inventory, :ephemeral_expiry, :refused],
          %{candidates: candidates, live_devices: live},
          %{reason: reason, max_fraction: max_fraction}
        )

        Logger.error(
          "EphemeralDeviceExpiry: pass refused (#{reason}): would expire up to #{candidates} " <>
            "of #{live} live devices in one pass (max fraction #{max_fraction}); set " <>
            "ephemeral_expiry_guard_override in the device cleanup settings to force"
        )

        {:error,
         {:mass_expiry_refused, %{candidates: candidates, live: live, max_fraction: max_fraction}}}
    end
  end

  defp count(query), do: query |> exclude(:order_by) |> select([d], count()) |> Repo.one()

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

  # Attribute and metadata evidence the identifier tables may not carry (an identifier row can
  # be garbage-collected while the device row still names its hardware MAC or source id).
  defp keep?(candidate, excluded) do
    MapSet.member?(excluded, candidate.uid) or strong_attributes?(candidate)
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

  defp emit(stats) do
    :telemetry.execute(
      [:serviceradar, :inventory, :ephemeral_expiry, :run],
      %{expired: stats.expired, candidates: stats.candidates, excluded: stats.excluded},
      %{deleted_reason: @deleted_reason}
    )
  end

  # ---------------------------------------------------------------------------------------
  # The SRQL exclusion query

  defp excluded_uids(query, opts) when is_binary(query) do
    case String.trim(query) do
      "" -> {:ok, MapSet.new()}
      query -> collect_excluded(query, Keyword.get(opts, :query_page, &SRQLRunner.query_page/2))
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
