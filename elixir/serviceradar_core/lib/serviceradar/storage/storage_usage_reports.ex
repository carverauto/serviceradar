defmodule ServiceRadar.Storage.StorageUsageReports do
  @moduledoc """
  Closed-UTC-day storage usage report persistence, idempotent replay, explicit
  revision recomputation, opaque policy rate/projection formatting, and current-day
  Prometheus gauge calculation (`F.6`, `design.md` `F5`, `spec.md:742-759`).
  """

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.CameraRecordingPolicies
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingAccessAudit
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingDisposition
  alias ServiceRadar.Camera.RecordingHold
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Camera.RetentionCalculator
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Storage.StorageEntitlements
  alias ServiceRadar.Storage.StorageUsageDailyReport

  require Ash.Query

  @max_days_per_page 31
  @seconds_per_day 86_400
  @window_7d_seconds 604_800
  @system_actor SystemActor.system(:storage_usage_reports)

  @doc """
  Computes an opaque 64-character lowercase SHA-256 reference for a policy ID,
  guaranteeing camera names and raw source identifiers never appear in control-plane
  usage reports (`design.md:2610-2612`).
  """
  @spec opaque_policy_ref(map() | String.t()) :: String.t()
  def opaque_policy_ref(policy) when is_map(policy) do
    id = Map.get(policy, :id) || Map.get(policy, "id") || "default"
    opaque_policy_ref(to_string(id))
  end

  def opaque_policy_ref(policy_id) when is_binary(policy_id) do
    :sha256
    |> :crypto.hash("nvr-policy-ref-v1:" <> policy_id)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Queries bounded (`<= 31` days) closed UTC day reports (`GET /v1/storage/usage?from=`).

  Any previously computed closed day is returned verbatim from
  `platform.storage_usage_daily_reports` with its persisted `report_revision` and
  figures (`spec.md:756-759`). Missing closed days are computed once and persisted
  at `report_revision = 1`.
  """
  @spec query_closed_days(map() | keyword(), keyword()) :: {:ok, map()} | {:error, atom()}
  def query_closed_days(params, opts \\ [])
      when (is_map(params) or is_list(params)) and is_list(opts) do
    map_params = if is_list(params), do: Map.new(params), else: params
    now = Keyword.get(opts, :now, DateTime.utc_now())
    today = DateTime.to_date(now)

    with :ok <- authorize_usage_reader(opts),
         {:ok, from_date, closed_dates, next_from} <-
           resolve_closed_date_window(map_params, today),
         {:ok, day_entries} <- resolve_or_persist_days(closed_dates, now, opts) do
      to_str =
        case List.last(closed_dates) do
          %Date{} = last -> Date.to_iso8601(last)
          nil -> nil
        end

      {:ok,
       %{
         "schema_version" => 1,
         "from" => Date.to_iso8601(from_date),
         "to" => to_str,
         "next_from" => next_from && Date.to_iso8601(next_from),
         "days" => day_entries
       }}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :storage_usage_unavailable}
  end

  @doc """
  Explicitly recomputes a closed UTC day (`usage_date < Date.utc_today(now)`) and
  atomically increments `report_revision` (`design.md:2613-2614`, `spec.md:744`).
  """
  @spec recompute_closed_day(Date.t() | String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def recompute_closed_day(date_or_iso, opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    today = DateTime.to_date(now)

    with :ok <- authorize_system_submitter(opts),
         {:ok, date} <- cast_closed_date(date_or_iso, today),
         {:ok, snapshot} <- load_usage_inputs(opts),
         payload = compute_day_payload(date, snapshot, opts),
         {:ok, persisted} <- persist_recomputed_day(date, payload, now, opts) do
      {:ok, format_day_row(persisted)}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :storage_usage_unavailable}
  end

  @doc """
  Computes current-day object storage gauges (`used_bytes`, `hard_limit_bytes`,
  `cutoff_days`, `held_bytes`) for web-ng Prometheus `/metrics` (`design.md:2616-2617`).
  """
  @spec current_gauges(keyword()) ::
          {:ok,
           %{
             used_bytes: non_neg_integer(),
             hard_limit_bytes: non_neg_integer(),
             cutoff_days: float(),
             raw_cutoff_days: float() | :infinity,
             held_bytes: non_neg_integer()
           }}
          | {:error, term()}
  def current_gauges(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    summary_opts = Keyword.merge([actor: @system_actor, now: now], opts)

    with {:ok, summary} <- RetentionCalculator.usage_summary(summary_opts) do
      obj = summary.object_projection
      used_bytes = max(0, summary.archive.archive_used_bytes || 0)
      held_bytes = max(0, summary.holds.held_archive_bytes || 0)
      hard_limit_bytes = max(0, obj.hard_limit_bytes || 0)
      raw_cutoff = obj.capacity_days
      finite_cutoff = numeric_cutoff_for_gauge(raw_cutoff, obj.policies)

      {:ok,
       %{
         used_bytes: used_bytes,
         hard_limit_bytes: hard_limit_bytes,
         cutoff_days: finite_cutoff,
         raw_cutoff_days: raw_cutoff,
         held_bytes: held_bytes
       }}
    end
  end

  defp numeric_cutoff_for_gauge(cutoff, _policies) when is_number(cutoff) and cutoff >= 0,
    do: cutoff * 1.0

  defp numeric_cutoff_for_gauge(_infinity, policies) when is_list(policies) do
    finite =
      policies
      |> Enum.map(&Map.get(&1, :effective_days))
      |> Enum.filter(&is_number/1)

    if finite == [], do: 0.0, else: Enum.max(finite) * 1.0
  end

  defp numeric_cutoff_for_gauge(_, _), do: 0.0

  ## Date range parsing & bounds

  defp resolve_closed_date_window(params, today) do
    raw_from = Map.get(params, "from") || Map.get(params, :from)
    raw_to = Map.get(params, "to") || Map.get(params, :to)
    last_closed = Date.add(today, -1)

    with {:ok, from_date} <- parse_date(raw_from),
         :ok <- ensure_from_not_future(from_date, today) do
      if is_nil(raw_to) or raw_to == "" do
        build_implicit_to_window(from_date, today, last_closed)
      else
        build_explicit_to_window(from_date, raw_to, today, last_closed)
      end
    end
  end

  defp ensure_from_not_future(from_date, today) do
    if Date.after?(from_date, today) do
      {:error, :invalid_usage_date_range}
    else
      :ok
    end
  end

  defp build_implicit_to_window(from_date, today, last_closed) do
    if Date.compare(from_date, today) == :eq do
      {:ok, from_date, [], nil}
    else
      page_limit_end = Date.add(from_date, @max_days_per_page - 1)

      effective_end =
        if Date.before?(page_limit_end, last_closed),
          do: page_limit_end,
          else: last_closed

      dates = Enum.to_list(Date.range(from_date, effective_end))

      next_from =
        if Date.before?(effective_end, last_closed),
          do: Date.add(effective_end, 1)

      {:ok, from_date, dates, next_from}
    end
  end

  defp build_explicit_to_window(from_date, raw_to, today, last_closed) do
    with {:ok, to_date} <- parse_date(raw_to),
         true <- Date.compare(to_date, from_date) != :lt,
         true <- Date.before?(to_date, today),
         true <- Date.diff(to_date, from_date) + 1 <= @max_days_per_page do
      dates = Enum.to_list(Date.range(from_date, to_date))

      next_from =
        if Date.before?(to_date, last_closed),
          do: Date.add(to_date, 1)

      {:ok, from_date, dates, next_from}
    else
      _ -> {:error, :invalid_usage_date_range}
    end
  end

  defp cast_closed_date(%Date{} = date, today) do
    if Date.before?(date, today), do: {:ok, date}, else: {:error, :invalid_usage_date_range}
  end

  defp cast_closed_date(iso, today) when is_binary(iso) do
    with {:ok, date} <- parse_date(iso) do
      cast_closed_date(date, today)
    end
  end

  defp cast_closed_date(_, _), do: {:error, :invalid_usage_date_range}

  defp parse_date(%Date{} = d), do: {:ok, d}

  defp parse_date(raw) when is_binary(raw) and byte_size(raw) == 10 do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_usage_date_range}
    end
  end

  defp parse_date(_), do: {:error, :invalid_usage_date_range}

  ## Persistence & Replay

  defp resolve_or_persist_days([], _now, _opts), do: {:ok, []}

  defp resolve_or_persist_days(closed_dates, now, opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    first_date = hd(closed_dates)
    last_date = List.last(closed_dates)

    with {:ok, existing_rows} <- load_existing_reports(first_date, last_date, loaders) do
      by_date = Map.new(existing_rows, &{&1.usage_date, &1})
      missing = Enum.reject(closed_dates, &Map.has_key?(by_date, &1))

      if missing == [] do
        {:ok, Enum.map(closed_dates, &format_day_row(Map.fetch!(by_date, &1)))}
      else
        compute_and_fill_missing_days(closed_dates, by_date, missing, now, opts)
      end
    end
  end

  defp compute_and_fill_missing_days(closed_dates, by_date, missing, now, opts) do
    with {:ok, snapshot} <- load_usage_inputs(opts) do
      updated_by_date =
        Enum.reduce(missing, by_date, fn date, acc ->
          payload = compute_day_payload(date, snapshot, opts)
          {:ok, row} = persist_initial_day(date, payload, now, opts)
          Map.put(acc, date, row)
        end)

      {:ok, Enum.map(closed_dates, &format_day_row(Map.fetch!(updated_by_date, &1)))}
    end
  end

  defp load_existing_reports(from_date, to_date, loaders) do
    case Map.get(loaders, :reports_loader) do
      loader when is_function(loader, 2) ->
        loader.(from_date, to_date)

      loader when is_function(loader, 0) ->
        loader.()

      _ when map_size(loaders) > 0 ->
        {:ok, []}

      _ ->
        StorageUsageDailyReport.list_in_range(from_date, to_date, actor: @system_actor)
    end
  end

  defp persist_initial_day(date, payload, now, opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    case Map.get(loaders, :report_persister) do
      persister when is_function(persister, 3) ->
        persister.(date, payload, now)

      _ when map_size(loaders) > 0 ->
        {:ok,
         %{
           usage_date: date,
           report_revision: 1,
           payload: payload,
           computed_at: now
         }}

      _ ->
        with {:ok, _} <-
               StorageUsageDailyReport
               |> Ash.Changeset.for_create(
                 :record_initial,
                 %{usage_date: date, payload: payload, computed_at: now},
                 actor: @system_actor
               )
               |> Ash.create(actor: @system_actor) do
          StorageUsageDailyReport.get_by_date(date, actor: @system_actor)
        end
    end
  end

  defp persist_recomputed_day(date, payload, now, opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    if map_size(loaders) > 0 do
      rev = Keyword.get(opts, :previous_revision, 1) + 1
      {:ok, %{usage_date: date, report_revision: rev, payload: payload, computed_at: now}}
    else
      case StorageUsageDailyReport.get_by_date(date, actor: @system_actor) do
        {:ok, nil} ->
          persist_initial_day(date, payload, now, opts)

        {:ok, %StorageUsageDailyReport{} = existing} ->
          existing
          |> Ash.Changeset.for_update(
            :revise_report,
            %{payload: payload, computed_at: now},
            actor: @system_actor
          )
          |> Ash.update(actor: @system_actor)

        other ->
          other
      end
    end
  end

  defp format_day_row(row) do
    %{
      "date" => Date.to_iso8601(row.usage_date),
      "report_revision" => row.report_revision,
      "computed_at" => DateTime.to_iso8601(row.computed_at),
      "consumers" => row.payload
    }
  end

  ## Closed-Day Calculation (`recordings`)

  defp compute_day_payload(date, snapshot, opts) do
    day_start = DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
    day_end = DateTime.new!(Date.add(date, 1), ~T[00:00:00.000000], "Etc/UTC")

    entitlement =
      opts
      |> Keyword.put(:now, day_end)
      |> Keyword.put(:loaders, Keyword.get(opts, :loaders, %{}))
      |> StorageEntitlements.effective_state()

    settings = RecordingArchiveSettings.apply_entitlement_bounds(snapshot.settings, entitlement)

    same_bucket_ids =
      resolve_same_bucket_ids(snapshot.bindings, settings.active_archive_binding_id)

    receipts_by_id = Map.new(snapshot.receipts, &{to_string(field(&1, :id)), &1})

    day_metrics =
      aggregate_day_catalog_and_events(
        snapshot,
        same_bucket_ids,
        receipts_by_id,
        day_start,
        day_end
      )

    {rates_json, projection_json} =
      compute_day_rates_and_projection(
        snapshot.policies,
        snapshot.catalog_entries,
        receipts_by_id,
        settings,
        entitlement,
        day_metrics,
        day_end
      )

    %{
      "recordings" => %{
        "retained_bytes_end" => day_metrics.retained_bytes_end,
        "retained_bytes_max" => day_metrics.retained_bytes_max,
        "added_bytes" => day_metrics.added_bytes,
        "deleted_bytes" => day_metrics.deleted_bytes,
        "held_bytes" => day_metrics.held_bytes,
        "non_reapable_bytes" => day_metrics.non_reapable_bytes,
        "object_count" => day_metrics.object_count,
        "requests" => day_metrics.requests,
        "archive_read_bytes" => day_metrics.archive_read_bytes,
        "rates" => rates_json,
        "projection" => projection_json
      }
    }
  end

  defp aggregate_day_catalog_and_events(
         snapshot,
         same_bucket_ids,
         receipts_by_id,
         day_start,
         day_end
       ) do
    active_holds_at_end =
      Enum.filter(snapshot.holds, &hold_active_at?(&1, day_end))

    cat_acc =
      Enum.reduce(
        snapshot.catalog_entries,
        %{
          retained_start: 0,
          retained_end: 0,
          added_bytes: 0,
          added_objects: 0,
          held_bytes: 0,
          non_reapable_bytes: 0,
          object_count: 0
        },
        fn entry, st ->
          accumulate_day_entry(
            entry,
            st,
            same_bucket_ids,
            receipts_by_id,
            active_holds_at_end,
            day_start,
            day_end
          )
        end
      )

    {deleted_by_reason, delete_requests, deleted_total} =
      aggregate_day_deletions(
        snapshot.dispositions,
        snapshot.catalog_entries,
        receipts_by_id,
        day_start,
        day_end
      )

    {get_requests, head_read_requests, archive_read_bytes} =
      aggregate_day_reads(snapshot.access_audits, day_start, day_end)

    peak_candidate = cat_acc.retained_start + cat_acc.added_bytes
    retained_max = max(cat_acc.retained_end, max(cat_acc.retained_start, peak_candidate - 0))
    _ = deleted_total

    %{
      retained_bytes_end: cat_acc.retained_end,
      retained_bytes_max: retained_max,
      added_bytes: cat_acc.added_bytes,
      deleted_bytes: deleted_by_reason,
      held_bytes: cat_acc.held_bytes,
      non_reapable_bytes: cat_acc.non_reapable_bytes,
      object_count: cat_acc.object_count,
      requests: %{
        "put" => cat_acc.added_objects,
        "get" => get_requests,
        "head" => cat_acc.added_objects + delete_requests + head_read_requests,
        "delete" => delete_requests
      },
      archive_read_bytes: archive_read_bytes
    }
  end

  defp accumulate_day_entry(
         entry,
         st,
         same_bucket_ids,
         receipts_by_id,
         active_holds,
         day_start,
         day_end
       ) do
    local_state = field(entry, :local_state)
    archive_state = field(entry, :archive_state)
    binding_id = field(entry, :archive_binding_id) || field(entry, :quarantine_binding_id)

    if in_bucket_group?(binding_id, same_bucket_ids) do
      {bytes, obj_count} = entry_bytes_and_objects(entry, receipts_by_id)
      archived_at = field(entry, :archived_at) || field(entry, :sealed_at)
      deleted_at = if archive_state in [:deleted, "deleted"], do: field(entry, :archive_state_at)

      present_at_start? =
        archived_before?(archived_at, day_start) and not deleted_before?(deleted_at, day_start)

      present_at_end? =
        archived_before?(archived_at, day_end) and not deleted_before?(deleted_at, day_end) and
          archive_state in [
            :verified,
            "verified",
            :deleting,
            "deleting",
            :deleted,
            "deleted"
          ]

      in_flight_at_end? =
        archive_state in [:pending, "pending", :failed_retryable, "failed_retryable"] and
          archived_before?(field(entry, :sealed_at), day_end)

      added_in_day? = timestamp_in_window?(archived_at, day_start, day_end)

      quarantined? = local_state in [:quarantined, "quarantined"]
      blocked? = field(entry, :archive_last_error_class) == "blocked_by_provider"

      held_end? =
        present_at_end? and not quarantined? and
          Enum.any?(active_holds, &RecordingHolds.hold_protects_entry?(&1, entry))

      end_bytes =
        cond do
          present_at_end? -> bytes
          in_flight_at_end? -> bytes
          true -> 0
        end

      nr_bytes =
        cond do
          in_flight_at_end? -> bytes
          present_at_end? and (quarantined? or blocked? or held_end?) -> bytes
          true -> 0
        end

      %{
        st
        | retained_start: st.retained_start + if(present_at_start?, do: bytes, else: 0),
          retained_end: st.retained_end + end_bytes,
          added_bytes: st.added_bytes + if(added_in_day?, do: bytes, else: 0),
          added_objects: st.added_objects + if(added_in_day?, do: obj_count, else: 0),
          held_bytes: st.held_bytes + if(held_end?, do: bytes, else: 0),
          non_reapable_bytes: st.non_reapable_bytes + nr_bytes,
          object_count: st.object_count + if(present_at_end?, do: obj_count, else: 0)
      }
    else
      st
    end
  end

  defp aggregate_day_deletions(dispositions, catalog_entries, receipts_by_id, day_start, day_end) do
    entries_by_id = Map.new(catalog_entries, &{to_string(field(&1, :id)), &1})

    verified_absent_disps =
      Enum.filter(dispositions, fn d ->
        field(d, :copy) in [:archive, "archive"] and
          field(d, :step) in [:verified_absent, "verified_absent"] and
          timestamp_in_window?(field(d, :inserted_at), day_start, day_end)
      end)

    initial = %{"object_retention" => 0, "object_capacity" => 0, "operator" => 0}

    {by_reason, del_reqs, total, seen_entry_ids} =
      Enum.reduce(verified_absent_disps, {initial, 0, 0, MapSet.new()}, fn d,
                                                                           {map, reqs, sum_b,
                                                                            seen} ->
        cid = field(d, :catalog_entry_id) && to_string(field(d, :catalog_entry_id))
        entry = cid && Map.get(entries_by_id, cid)

        {bytes, obj_count} =
          if entry, do: entry_bytes_and_objects(entry, receipts_by_id), else: {0, 3}

        bucket = classify_delete_reason(field(d, :reason))
        next_seen = if cid, do: MapSet.put(seen, cid), else: seen

        {
          Map.update!(map, bucket, &(&1 + bytes)),
          reqs + obj_count,
          sum_b + bytes,
          next_seen
        }
      end)

    Enum.reduce(catalog_entries, {by_reason, del_reqs, total}, fn entry, {map, reqs, sum_b} ->
      eid = to_string(field(entry, :id))

      if not MapSet.member?(seen_entry_ids, eid) and
           field(entry, :archive_state) in [:deleted, "deleted"] and
           timestamp_in_window?(field(entry, :archive_state_at), day_start, day_end) do
        {bytes, obj_count} = entry_bytes_and_objects(entry, receipts_by_id)
        bucket = classify_delete_reason(field(entry, :archive_deleted_reason))
        {Map.update!(map, bucket, &(&1 + bytes)), reqs + obj_count, sum_b + bytes}
      else
        {map, reqs, sum_b}
      end
    end)
  end

  defp classify_delete_reason(r) when r in [:object_retention, "object_retention"],
    do: "object_retention"

  defp classify_delete_reason(r) when r in [:object_capacity, "object_capacity"],
    do: "object_capacity"

  defp classify_delete_reason(_), do: "operator"

  defp aggregate_day_reads(access_audits, day_start, day_end) do
    Enum.reduce(access_audits, {0, 0, 0}, fn audit, {gets, heads, read_bytes} ->
      if field(audit, :source_mode) in [:archive, "archive"] and
           timestamp_in_window?(field(audit, :inserted_at), day_start, day_end) do
        details = field(audit, :details) || %{}
        segs = max(1, int_val(field(audit, :segment_count) || details["segment_count"] || 1))
        bytes = max(0, int_val(details["archive_read_bytes"] || details["bytes_read"] || 0))
        {gets + segs, heads + 1, read_bytes + bytes}
      else
        {gets, heads, read_bytes}
      end
    end)
  end

  defp compute_day_rates_and_projection(
         policies,
         catalog_entries,
         receipts_by_id,
         settings,
         entitlement,
         day_metrics,
         day_end
       ) do
    archiving_policies =
      if settings.archive_enabled do
        Enum.filter(policies, fn p ->
          field(p, :mode) in [:continuous, "continuous"] and
            field(p, :storage) in [:local_and_archive, "local_and_archive"]
        end)
      else
        []
      end

    specs =
      Enum.map(archiving_policies, fn pol ->
        ref = opaque_policy_ref(pol)
        est = CameraRecordingPolicies.profile_estimate(field(pol, :stream_profile) || pol)
        rate = policy_rate_at(pol, est.bitrate_bps, catalog_entries, receipts_by_id, day_end)

        conf_days =
          CameraRecordingPolicies.resolve_policy_archive_retention(pol, settings, entitlement)

        %{
          id: ref,
          policy_ref: ref,
          rate_bytes_per_day: rate.bytes_per_day,
          basis: rate.basis,
          retention_days: conf_days
        }
      end)

    calc =
      RetentionCalculator.calculate_object_retention(specs, %{
        object_budget_mode: settings.object_budget_mode,
        object_budget_bytes: settings.object_budget_bytes,
        object_high_water_percent: settings.object_high_water_percent || 90,
        object_low_water_percent: settings.object_low_water_percent || 80,
        object_capacity_policy: settings.object_capacity_policy,
        non_reapable_bytes: day_metrics.non_reapable_bytes,
        usage_bytes: day_metrics.retained_bytes_end
      })

    rates_json =
      Enum.map(specs, fn s ->
        %{
          "policy_ref" => s.policy_ref,
          "bytes_per_day" => s.rate_bytes_per_day,
          "basis" => Atom.to_string(s.basis)
        }
      end)

    proj_policies =
      Enum.map(calc.policies, fn p ->
        %{
          "policy_ref" => p.id,
          "configured_days" => json_limit(p.configured_days),
          "effective_days" => json_limit(p.effective_days),
          "binding_bound" => Atom.to_string(p.binding_bound)
        }
      end)

    projection_json = %{
      "cutoff_days" => json_limit(calc.capacity_days),
      "cutoff_unbounded" => calc.capacity_days == :infinity,
      "policies" => proj_policies
    }

    {rates_json, projection_json}
  end

  defp policy_rate_at(pol, nominal_bps, catalog_entries, receipts_by_id, ref_time) do
    cam_id = to_string(field(pol, :camera_source_id) || "")
    prof_id = to_string(field(pol, :stream_profile_id) || "")
    cut_24h = DateTime.shift(ref_time, second: -@seconds_per_day)
    cut_7d = DateTime.shift(ref_time, second: -@window_7d_seconds)

    matching =
      Enum.filter(catalog_entries, fn e ->
        field(e, :local_state) not in [:quarantined, "quarantined"] and
          to_string(field(e, :camera_source_id) || "") == cam_id and
          to_string(field(e, :stream_profile_id) || "") == prof_id and
          archived_before?(field(e, :archived_at) || field(e, :sealed_at), ref_time)
      end)

    {oldest, b24, b7} =
      Enum.reduce(matching, {nil, 0, 0}, fn e, {old_acc, s24, s7} ->
        {bytes, _} = entry_bytes_and_objects(e, receipts_by_id)
        ts = field(e, :archived_at) || field(e, :sealed_at)
        in_24? = match?(%DateTime{}, ts) and DateTime.compare(ts, cut_24h) != :lt
        in_7? = match?(%DateTime{}, ts) and DateTime.compare(ts, cut_7d) != :lt
        next_old = if is_nil(old_acc) or DateTime.before?(ts, old_acc), do: ts, else: old_acc
        {next_old, s24 + if(in_24?, do: bytes, else: 0), s7 + if(in_7?, do: bytes, else: 0)}
      end)

    hist_sec =
      case oldest do
        %DateTime{} = dt -> max(0, DateTime.diff(ref_time, dt, :second))
        _ -> 0
      end

    RetentionCalculator.rate_from_history_or_nominal(%{
      history_seconds: hist_sec,
      trailing_24h_bytes: b24,
      trailing_7d_bytes: b7,
      nominal_bitrate_bps: nominal_bps
    })
  end

  defp json_limit(:infinity), do: nil
  defp json_limit(:unlimited), do: "unlimited"
  defp json_limit(val), do: val

  ## Data loading & predicates

  defp load_usage_inputs(opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    with {:ok, settings} <- load_or_call(loaders, :settings_loader, &default_load_settings/0),
         {:ok, bindings} <- load_or_call(loaders, :bindings_loader, &default_load_bindings/0),
         {:ok, receipts} <- load_or_call(loaders, :receipts_loader, &default_load_receipts/0),
         {:ok, catalog} <- load_or_call(loaders, :catalog_loader, &default_load_catalog/0),
         {:ok, holds} <- load_or_call(loaders, :holds_loader, &default_load_holds/0),
         {:ok, policies} <- load_or_call(loaders, :policies_loader, &default_load_policies/0),
         {:ok, disps} <- load_or_call(loaders, :dispositions_loader, &default_load_dispositions/0),
         {:ok, audits} <- load_or_call(loaders, :access_audits_loader, &default_load_audits/0) do
      {:ok,
       %{
         settings: settings || RecordingArchiveSettings.default_settings(),
         bindings: bindings,
         receipts: receipts,
         catalog_entries: catalog,
         holds: holds,
         policies: policies,
         dispositions: disps,
         access_audits: audits
       }}
    end
  end

  defp load_or_call(loaders, key, default_fun) do
    case Map.get(loaders, key) do
      fun when is_function(fun, 0) -> fun.()
      _ when map_size(loaders) > 0 -> default_empty_for(key)
      _ -> default_fun.()
    end
  end

  defp default_empty_for(:settings_loader), do: {:ok, RecordingArchiveSettings.default_settings()}
  defp default_empty_for(_), do: {:ok, []}

  defp default_load_settings, do: RecordingArchiveSettings.get_settings(actor: @system_actor)
  defp default_load_bindings, do: Ash.read(ArchiveBinding, actor: @system_actor)
  defp default_load_receipts, do: Ash.read(NVRArchiveReceipt, actor: @system_actor)
  defp default_load_catalog, do: Ash.read(RecordingCatalogEntry, actor: @system_actor)
  defp default_load_holds, do: Ash.read(RecordingHold, actor: @system_actor)

  defp default_load_policies do
    CameraRecordingPolicy
    |> Ash.Query.load(
      stream_profile: [:id, :camera_source_id, :profile_name, :relay_eligible, :metadata]
    )
    |> Ash.read(actor: @system_actor)
  end

  defp default_load_dispositions, do: Ash.read(RecordingDisposition, actor: @system_actor)
  defp default_load_audits, do: Ash.read(RecordingAccessAudit, actor: @system_actor)

  defp resolve_same_bucket_ids(_bindings, nil), do: nil

  defp resolve_same_bucket_ids(bindings, active_id) do
    active_str = to_string(active_id)

    case Enum.find(bindings, &(to_string(field(&1, :id)) == active_str)) do
      nil ->
        MapSet.new([active_str])

      active ->
        ep = field(active, :endpoint)
        bucket = field(active, :bucket)

        bindings
        |> Enum.filter(&(field(&1, :endpoint) == ep and field(&1, :bucket) == bucket))
        |> MapSet.new(&to_string(field(&1, :id)))
    end
  end

  defp in_bucket_group?(nil, _same_bucket_ids), do: false
  defp in_bucket_group?(_bid, nil), do: true

  defp in_bucket_group?(bid, %MapSet{} = ids), do: MapSet.member?(ids, to_string(bid))

  defp entry_bytes_and_objects(entry, receipts_by_id) do
    rid = field(entry, :nvr_archive_receipt_id)
    local_state = field(entry, :local_state)
    default_objs = if local_state in [:quarantined, "quarantined"], do: 1, else: 3
    fallback_b = field(entry, :quarantined_bytes) || field(entry, :media_bytes) || 0

    case rid && Map.get(receipts_by_id, to_string(rid)) do
      %{} = receipt ->
        objs = List.wrap(field(receipt, :objects))

        bytes =
          Enum.reduce(objs, 0, fn o, acc ->
            acc + max(0, int_val(is_map(o) && field(o, :length)))
          end)

        {bytes, length(objs)}

      _ ->
        {max(0, int_val(fallback_b)), default_objs}
    end
  end

  defp hold_active_at?(hold, ts) do
    accepted_at = field(hold, :accepted_at) || field(hold, :inserted_at)
    released_at = field(hold, :released_at)
    state = field(hold, :state)

    active_state? = state in [:accepted, "accepted", :released, "released", nil]
    accepted_ok? = is_nil(accepted_at) or DateTime.before?(accepted_at, ts)
    not_released_yet? = is_nil(released_at) or DateTime.compare(released_at, ts) != :lt

    active_state? and accepted_ok? and not_released_yet?
  end

  defp archived_before?(%DateTime{} = ts, bound), do: DateTime.before?(ts, bound)
  defp archived_before?(_, _), do: false

  defp deleted_before?(%DateTime{} = ts, bound), do: DateTime.before?(ts, bound)
  defp deleted_before?(_, _), do: false

  defp timestamp_in_window?(%DateTime{} = ts, start_dt, end_dt) do
    DateTime.compare(ts, start_dt) != :lt and DateTime.before?(ts, end_dt)
  end

  defp timestamp_in_window?(_, _, _), do: false

  defp authorize_usage_reader(opts) do
    actor = Keyword.get(opts, :actor)

    cond do
      match?(%{role: :system}, actor) ->
        :ok

      Enum.any?(
        ["settings.recording.view", "settings.recording.manage", "settings.recording.operate"],
        &ActorHasPermission.match?(actor, [permission: &1], %{})
      ) ->
        :ok

      true ->
        case RecordingArchiveSettings.authorize_recording_read(opts) do
          :ok -> :ok
          {:error, %Forbidden{}} -> {:error, :forbidden}
          _ -> {:error, :forbidden}
        end
    end
  end

  defp authorize_system_submitter(opts) do
    case Keyword.get(opts, :actor) do
      %{role: :system} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp int_val(v) when is_integer(v), do: v
  defp int_val(v) when is_float(v), do: trunc(v)
  defp int_val(_), do: 0

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
