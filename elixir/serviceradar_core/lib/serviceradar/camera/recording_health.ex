defmodule ServiceRadar.Camera.RecordingHealth do
  @moduledoc """
  Authorized CNPG recording & storage health aggregator (`E.3`, `R.10`) for
  `/settings/recording?tab=health`.

  Aggregates live CNPG state under `settings.recording.view | manage | operate`
  authorization across:
  - `RecordingCatalogEntry` (archive backlog, oldest unarchived age, `awaiting_binding`,
    `failed_retryable`, `failed_terminal`, `missing` entries, and `quarantined` entries)
  - `RecordingGap` (24-hour breakdown grouped by `A7` `reason` + currently open gaps)
  - `NVRStorageSettings`, `CameraRecordingPolicy`, and `RetentionCalculator`
    (per-storage-UUID desired settings, disjoint `C1a` pinned bytes, local present
    bytes, effective local window projection, `time_to_full_seconds`, and assigned
    continuous cameras)
  - `RecordingHold` and `RecordingDisposition` (active holds, held archive/local
    pinned bytes, held archive missing count, 24-hour disposition counts & failures)
  - `HealthEvent` (`storage.recordings.*` and `nvr.*` checks recorded via
    `TripwireHealth.record/4`).

  Exposes a full `:loaders` seam for `:db_free` unit tests and a pure
  `default_summary/1` baseline for disconnected LiveView `mount/3`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.CameraRecordingPolicies
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.NVRStorageSettings
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingDisposition
  alias ServiceRadar.Camera.RecordingGap
  alias ServiceRadar.Camera.RecordingHold
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Camera.RetentionCalculator
  alias ServiceRadar.Infrastructure.HealthEvent

  require Ash.Query

  @window_24h_seconds 86_400
  @microseconds_per_second 1_000_000
  @default_local_budget_bytes 1_073_741_824
  @health_events_limit 500

  @system_actor SystemActor.system(:camera_recording_health)

  @backlog_states [:awaiting_binding, :pending, :failed_retryable, :failed_terminal]

  @doc """
  DB-free baseline health summary used during disconnected LiveView `mount/3`
  or fallback states. Performs zero database I/O.
  """
  @spec default_summary(map() | nil) :: map()
  def default_summary(settings \\ nil) do
    base = settings || RecordingArchiveSettings.default_settings()
    projected = RetentionCalculator.project_settings(base, %{camera_count: 0})
    zero_reasons = Map.new(RecordingGap.reasons(), &{&1, 0})

    %{
      archive_backlog: %{
        archive_enabled: Map.get(base, :archive_enabled) == true,
        unarchived_count: 0,
        unarchived_bytes: 0,
        oldest_unarchived_at: nil,
        oldest_unarchived_age_seconds: nil,
        awaiting_binding_count: 0,
        pending_count: 0,
        failed_retryable_count: 0,
        failed_terminal_count: 0,
        missing_count: 0,
        missing_entries: [],
        quarantined_count: 0,
        quarantined_bytes: 0,
        quarantined_entries: [],
        unattributable_count: 0,
        unattributable_blocks: [],
        reconciler_status: :awaiting_reconciler,
        reconciler_last_pass_at: nil
      },
      reservations: default_reservations_summary(),
      quarantined_entries: [],
      unattributable_count: 0,
      unattributable_blocks: [],
      missing_archive_count: 0,
      missing_archive_entries: [],
      gaps_24h: %{
        total_24h_count: 0,
        open_gaps_count: 0,
        open_gaps: [],
        by_reason: zero_reasons,
        reasons_with_counts: Enum.map(RecordingGap.reasons(), &%{reason: &1, count: 0})
      },
      storage_members: [],
      storage_by_id: %{},
      unassigned_continuous_cameras: 0,
      retention_and_dispositions: %{
        active_hold_count: 0,
        held_archive_bytes: 0,
        held_local_pinned_bytes: 0,
        held_archive_missing_count: 0,
        recent_dispositions_24h: 0,
        recent_operations_24h: 0,
        verified_absent_24h: 0,
        failed_dispositions_24h: 0,
        by_reason_24h: %{},
        recent_failures_24h: [],
        object_retention_enforced?: not is_nil(Map.get(base, :retention_credential_secret_id)),
        object_projection: projected.object_projection
      },
      alerts: []
    }
  end

  @doc """
  Aggregates live CNPG recording & storage health under
  `settings.recording.view | manage | operate` authorization.

  ## Options
  - `:scope` or `:actor` — caller authorization context
  - `:now` — reference `DateTime` (defaults to `DateTime.utc_now/0`)
  - `:known_storage_ids` — optional list of storage UUID strings from configured NVR targets
  - `:member_by_storage_id` — optional `%{storage_id => member_name}` map
  - `:member_measurements` — optional `%{storage_id => %{effective_budget_bytes: ..., ...}}` map
  - `:loaders` — map of loader functions for `:db_free` unit tests:
    `settings_loader`, `bindings_loader`, `all_receipts_loader` / `receipts_loader`,
    `catalog_loader`, `holds_loader`, `blocks_loader`, `policies_loader`,
    `storage_settings_loader`, `local_storage_bindings_loader`, `gaps_loader`,
    `dispositions_loader`, `alerts_loader` / `health_events_loader`.
  """
  @spec summary(keyword()) :: {:ok, map()} | {:error, term()}
  def summary(opts \\ []) when is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- RecordingArchiveSettings.authorize_recording_read(opts),
         {:ok, usage} <- RetentionCalculator.usage_summary(opts),
         {:ok, catalog_entries} <- load_full_catalog_entries(loaders),
         {:ok, retained_binding_ids} <- load_retained_binding_ids(loaders),
         {:ok, accepted_holds} <- load_accepted_holds(loaders),
         {:ok, reservations} <- load_reservations_summary(loaders),
         {:ok, policies} <- load_policies(loaders),
         {:ok, storage_settings_rows} <- load_storage_settings(loaders),
         {:ok, local_bindings} <- load_local_storage_bindings(loaders),
         {:ok, gaps} <- load_recent_and_open_gaps(now, loaders),
         {:ok, dispositions} <- load_recent_dispositions(now, loaders),
         {:ok, alerts} <- load_active_alerts(loaders) do
      settings = usage.settings

      archive_backlog =
        build_archive_backlog(
          settings,
          catalog_entries,
          retained_binding_ids,
          accepted_holds,
          now,
          opts
        )

      gaps_24h = build_gaps_summary(gaps, now)

      {storage_members, unassigned_continuous} =
        build_storage_members(
          usage,
          settings,
          catalog_entries,
          accepted_holds,
          policies,
          storage_settings_rows,
          local_bindings,
          reservations,
          opts
        )

      storage_by_id = Map.new(storage_members, &{&1.storage_id, &1})

      retention_and_dispositions =
        build_retention_and_dispositions(usage, dispositions, now)

      {:ok,
       %{
         archive_backlog: archive_backlog,
         reservations: reservations,
         quarantined_entries: archive_backlog.quarantined_entries,
         unattributable_count: archive_backlog.unattributable_count,
         unattributable_blocks: archive_backlog.unattributable_blocks,
         missing_archive_count: archive_backlog.missing_count,
         missing_archive_entries: archive_backlog.missing_entries,
         gaps_24h: gaps_24h,
         storage_members: storage_members,
         storage_by_id: storage_by_id,
         unassigned_continuous_cameras: unassigned_continuous,
         retention_and_dispositions: retention_and_dispositions,
         alerts: alerts
       }}
    end
  end

  defp build_archive_backlog(
         settings,
         catalog_entries,
         retained_binding_ids,
         accepted_holds,
         now,
         opts
       ) do
    acc =
      Enum.reduce(
        catalog_entries,
        %{
          unarchived_count: 0,
          unarchived_bytes: 0,
          oldest_unarchived_at: nil,
          awaiting_binding_count: 0,
          pending_count: 0,
          failed_retryable_count: 0,
          failed_terminal_count: 0,
          missing_entries: [],
          quarantined_bytes: 0,
          quarantined_entries: []
        },
        fn entry, st ->
          accumulate_backlog_entry(entry, st, retained_binding_ids, accepted_holds)
        end
      )

    oldest_age_seconds =
      case acc.oldest_unarchived_at do
        %DateTime{} = dt -> max(0, DateTime.diff(now, dt, :second))
        _ -> nil
      end

    quarantined_sorted =
      Enum.sort_by(
        acc.quarantined_entries,
        fn q ->
          case q.recorded_at do
            %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
            _ -> 0
          end
        end,
        :desc
      )

    unattributable_blocks =
      Enum.filter(quarantined_sorted, &(&1.quarantine_reason == :unattributable))

    missing_sorted =
      Enum.sort_by(
        acc.missing_entries,
        fn m ->
          case m.sealed_at || m.archive_state_at do
            %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
            _ -> 0
          end
        end,
        :desc
      )

    last_pass = Keyword.get(opts, :reconciler_last_pass_at)
    reconciler_status = if match?(%DateTime{}, last_pass), do: :active, else: :awaiting_reconciler

    %{
      archive_enabled: settings.archive_enabled == true,
      unarchived_count: acc.unarchived_count,
      unarchived_bytes: acc.unarchived_bytes,
      oldest_unarchived_at: acc.oldest_unarchived_at,
      oldest_unarchived_age_seconds: oldest_age_seconds,
      awaiting_binding_count: acc.awaiting_binding_count,
      pending_count: acc.pending_count,
      failed_retryable_count: acc.failed_retryable_count,
      failed_terminal_count: acc.failed_terminal_count,
      missing_count: length(missing_sorted),
      missing_entries: missing_sorted,
      quarantined_count: length(quarantined_sorted),
      quarantined_bytes: acc.quarantined_bytes,
      quarantined_entries: quarantined_sorted,
      unattributable_count: length(unattributable_blocks),
      unattributable_blocks: unattributable_blocks,
      reconciler_status: reconciler_status,
      reconciler_last_pass_at: last_pass
    }
  end

  defp accumulate_backlog_entry(entry, st, retained_binding_ids, accepted_holds) do
    local_state = normalize_catalog_state(fetch_field(entry, :local_state))
    archive_state = normalize_catalog_state(fetch_field(entry, :archive_state))
    q_reason = normalize_quarantine_reason(fetch_field(entry, :quarantine_reason))
    quarantined? = local_state == :quarantined

    active_quarantine_item? =
      quarantined? or (local_state == :reclaiming and not is_nil(q_reason))

    media_bytes = max(0, int_or_zero(fetch_field(entry, :media_bytes)))
    q_bytes = max(0, int_or_zero(fetch_field(entry, :quarantined_bytes)))
    entry_bytes = if active_quarantine_item?, do: q_bytes, else: media_bytes

    ts =
      fetch_field(entry, :sealed_at) || fetch_field(entry, :local_state_at) ||
        fetch_field(entry, :archive_state_at)

    in_backlog? = archive_state in @backlog_states

    st =
      if in_backlog? do
        %{
          st
          | unarchived_count: st.unarchived_count + 1,
            unarchived_bytes: st.unarchived_bytes + entry_bytes,
            oldest_unarchived_at: min_dt(st.oldest_unarchived_at, ts),
            awaiting_binding_count:
              st.awaiting_binding_count + if(archive_state == :awaiting_binding, do: 1, else: 0),
            pending_count: st.pending_count + if(archive_state == :pending, do: 1, else: 0),
            failed_retryable_count:
              st.failed_retryable_count + if(archive_state == :failed_retryable, do: 1, else: 0),
            failed_terminal_count:
              st.failed_terminal_count + if(archive_state == :failed_terminal, do: 1, else: 0)
        }
      else
        st
      end

    st =
      if active_quarantine_item? do
        q_item =
          build_quarantine_health_item(entry, local_state, archive_state, q_reason, q_bytes)

        %{
          st
          | quarantined_bytes: st.quarantined_bytes + if(quarantined?, do: q_bytes, else: 0),
            quarantined_entries: [q_item | st.quarantined_entries]
        }
      else
        st
      end

    if archive_state == :missing do
      m_item =
        build_missing_archive_health_item(
          entry,
          local_state,
          q_reason,
          entry_bytes,
          active_quarantine_item?,
          retained_binding_ids,
          accepted_holds
        )

      %{st | missing_entries: [m_item | st.missing_entries]}
    else
      st
    end
  end

  defp build_quarantine_health_item(entry, local_state, archive_state, q_reason, q_bytes) do
    entry_id = to_string(fetch_field(entry, :id))
    receipt = fetch_field(entry, :quarantine_receipt)
    evidence = resolve_quarantine_evidence(entry, receipt)
    disp_state = resolve_quarantine_disposition_state(entry, local_state)

    recorded_at =
      fetch_field(entry, :local_state_at) || fetch_field(entry, :inserted_at) ||
        fetch_field(entry, :sealed_at)

    %{
      id: entry_id,
      catalog_entry_id: entry_id,
      storage_id: fetch_field(entry, :storage_id) && to_string(fetch_field(entry, :storage_id)),
      block_key: fetch_field(entry, :block_key),
      camera_source_id: fetch_field(entry, :camera_source_id),
      stream_profile_id: fetch_field(entry, :stream_profile_id),
      local_state: local_state,
      quarantine_reason: q_reason,
      quarantined_bytes: q_bytes,
      quarantine_evidence: evidence,
      evidence_summary: format_quarantine_evidence_summary(q_reason, evidence),
      quarantine_receipt: receipt,
      operator_disposition_state: disp_state,
      operator_decision: fetch_field(entry, :operator_decision),
      archive_state: archive_state,
      recorded_at: recorded_at,
      local_state_at: fetch_field(entry, :local_state_at),
      sealed_at: fetch_field(entry, :sealed_at)
    }
  end

  defp build_missing_archive_health_item(
         entry,
         local_state,
         q_reason,
         media_bytes,
         quarantined?,
         retained_binding_ids,
         accepted_holds
       ) do
    entry_id = to_string(fetch_field(entry, :id))
    binding_id = fetch_field(entry, :archive_binding_id)
    q_binding_id = fetch_field(entry, :quarantine_binding_id)

    owed_binding_id =
      cond do
        local_state == :present -> binding_id
        local_state == :quarantined and not is_nil(q_reason) -> q_binding_id
        true -> nil
      end

    rearchive_eligible? =
      not is_nil(owed_binding_id) and binding_retained?(owed_binding_id, retained_binding_ids)

    covering =
      if quarantined? do
        []
      else
        Enum.filter(accepted_holds, &entry_protected_by_hold?(&1, entry))
      end

    held? = covering != []

    hold_ids =
      covering
      |> Enum.map(&fetch_field(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    %{
      id: entry_id,
      catalog_entry_id: entry_id,
      storage_id: fetch_field(entry, :storage_id) && to_string(fetch_field(entry, :storage_id)),
      block_key: fetch_field(entry, :block_key),
      camera_source_id: fetch_field(entry, :camera_source_id),
      stream_profile_id: fetch_field(entry, :stream_profile_id),
      local_state: local_state,
      local_copy_present?: local_state == :present,
      rearchive_eligible?: rearchive_eligible?,
      archive_binding_id: binding_id,
      quarantine_binding_id: q_binding_id,
      owed_binding_id: owed_binding_id,
      media_bytes: media_bytes,
      archive_last_error_class: fetch_field(entry, :archive_last_error_class),
      sealed_at: fetch_field(entry, :sealed_at),
      archive_state_at: fetch_field(entry, :archive_state_at),
      held?: held?,
      hold_count: length(covering),
      hold_ids: hold_ids,
      requires_hold_permission?: held?
    }
  end

  defp binding_retained?(_binding_id, :unverified_in_loader), do: true

  defp binding_retained?(binding_id, %MapSet{} = retained_ids) do
    MapSet.member?(retained_ids, to_string(binding_id))
  end

  defp build_gaps_summary(gaps, now) do
    cutoff_us =
      DateTime.to_unix(now, :microsecond) - @window_24h_seconds * @microseconds_per_second

    zero_reasons = Map.new(RecordingGap.reasons(), &{&1, 0})

    {total_24h, open_list, by_reason} =
      Enum.reduce(gaps, {0, [], zero_reasons}, fn gap, {cnt, opens, reasons_acc} ->
        start_us = int_or_zero(fetch_field(gap, :start_us))
        end_us = fetch_field(gap, :end_us)
        open? = is_nil(end_us)
        in_24h? = open? or start_us >= cutoff_us or (is_integer(end_us) and end_us >= cutoff_us)
        reason = normalize_gap_reason(fetch_field(gap, :reason))

        next_reasons =
          if in_24h? and not is_nil(reason) do
            Map.update(reasons_acc, reason, 1, &(&1 + 1))
          else
            reasons_acc
          end

        next_opens =
          if open? do
            [
              %{
                id: fetch_field(gap, :id) && to_string(fetch_field(gap, :id)),
                camera_source_id: fetch_field(gap, :camera_source_id),
                stream_profile_id: fetch_field(gap, :stream_profile_id),
                storage_id: fetch_field(gap, :storage_id),
                reason: reason,
                detail_class: fetch_field(gap, :detail_class),
                start_us: start_us,
                time_basis: fetch_field(gap, :time_basis) || :received
              }
              | opens
            ]
          else
            opens
          end

        {cnt + if(in_24h?, do: 1, else: 0), next_opens, next_reasons}
      end)

    reasons_with_counts =
      RecordingGap.reasons()
      |> Enum.map(&%{reason: &1, count: Map.get(by_reason, &1, 0)})
      |> Enum.sort_by(fn %{reason: r, count: c} -> {-c, Atom.to_string(r)} end)

    %{
      total_24h_count: total_24h,
      open_gaps_count: length(open_list),
      open_gaps: Enum.reverse(open_list),
      by_reason: by_reason,
      reasons_with_counts: reasons_with_counts
    }
  end

  defp build_storage_members(
         usage,
         settings,
         catalog_entries,
         accepted_holds,
         policies,
         storage_settings_rows,
         local_bindings,
         reservations,
         opts
       ) do
    member_by_sid =
      opts
      |> Keyword.get(:member_by_storage_id, %{})
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    measurements_by_sid =
      opts
      |> Keyword.get(:member_measurements, %{})
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    settings_by_sid =
      Map.new(storage_settings_rows, fn row ->
        {to_string(fetch_field(row, :storage_id)), row}
      end)

    known_sids =
      collect_known_storage_ids(
        usage,
        catalog_entries,
        storage_settings_rows,
        local_bindings,
        reservations,
        opts
      )

    continuous_policies =
      Enum.filter(policies, &(fetch_field(&1, :mode) in [:continuous, "continuous"]))

    mapped_member_names =
      member_by_sid
      |> Map.values()
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    unassigned_continuous =
      Enum.count(continuous_policies, fn pol ->
        not MapSet.member?(mapped_member_names, fetch_field(pol, :nvr_member))
      end)

    members =
      Enum.map(known_sids, fn sid ->
        member_reservations =
          Map.get(reservations.by_storage, sid, zero_storage_reservations())

        build_single_storage_summary(
          sid,
          Map.get(member_by_sid, sid),
          Map.get(settings_by_sid, sid),
          Map.get(measurements_by_sid, sid, %{}),
          Map.get(usage.local_blocks.by_storage, sid, %{}),
          settings,
          catalog_entries,
          accepted_holds,
          continuous_policies,
          member_reservations
        )
      end)

    {members, unassigned_continuous}
  end

  defp collect_known_storage_ids(
         usage,
         catalog_entries,
         storage_settings_rows,
         local_bindings,
         reservations,
         opts
       ) do
    from_opts = opts |> Keyword.get(:known_storage_ids, []) |> Enum.map(&to_string/1)

    from_map =
      opts |> Keyword.get(:member_by_storage_id, %{}) |> Map.keys() |> Enum.map(&to_string/1)

    from_usage = usage.local_blocks.by_storage |> Map.keys() |> Enum.reject(&(&1 == "unknown"))

    from_catalog =
      catalog_entries
      |> Enum.map(&fetch_field(&1, :storage_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    from_settings =
      Enum.map(storage_settings_rows, &to_string(fetch_field(&1, :storage_id)))

    from_bindings =
      local_bindings
      |> Enum.map(&fetch_field(&1, :storage_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    from_reservations = Map.keys(reservations.by_storage)

    (from_opts ++
       from_map ++
       from_settings ++
       from_usage ++
       from_catalog ++
       from_bindings ++
       from_reservations)
    |> Enum.reject(&(&1 in ["", "nil", "unknown"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp build_single_storage_summary(
         sid,
         member_name,
         persisted_settings,
         measurements,
         storage_block_stats,
         archive_settings,
         catalog_entries,
         accepted_holds,
         continuous_policies,
         member_reservations
       ) do
    desired = persisted_settings || NVRStorageSettings.default_storage_settings(sid)

    assigned =
      if is_binary(member_name) do
        Enum.filter(continuous_policies, &(fetch_field(&1, :nvr_member) == member_name))
      else
        []
      end

    pinned_partition =
      NVRStorageSettings.pinned_bytes_for_storage(sid,
        settings: archive_settings,
        unreconciled_bytes: int_or_zero(fetch_field(measurements, :unreconciled_bytes)),
        loaders: %{
          catalog_loader: fn -> {:ok, catalog_entries} end,
          holds_loader: fn -> {:ok, accepted_holds} end
        }
      )

    eff_budget = resolve_storage_effective_budget(desired, measurements)

    {r15m, r6h, history_sec, present_blocks} =
      storage_local_rate_stats(sid, catalog_entries, storage_block_stats)

    nominal_bps =
      Enum.reduce(assigned, 0, fn pol, acc ->
        est = CameraRecordingPolicies.profile_estimate(fetch_field(pol, :stream_profile))
        acc + (est.bitrate_bps || 0)
      end)

    enabled_count =
      cond do
        assigned != [] -> length(assigned)
        present_blocks > 0 or r15m > 0.0 or r6h > 0.0 -> 1
        true -> 0
      end

    storage_mode =
      if archive_settings.archive_enabled, do: :local_and_archive, else: :local_only

    window_proj =
      RetentionCalculator.calculate_local_window(%{
        storage_mode: storage_mode,
        effective_budget_bytes: eff_budget,
        local_high_water_percent: archive_settings.local_high_water_percent || 90,
        local_low_water_percent: archive_settings.local_low_water_percent || 80,
        max_local_age_mode: archive_settings.max_local_age_mode,
        max_local_age_seconds: archive_settings.max_local_age_seconds,
        local_window_alert_mode: archive_settings.local_window_alert_mode,
        local_window_alert_seconds: archive_settings.local_window_alert_seconds,
        local_only_full_policy: archive_settings.local_only_full_policy,
        local_only_max_age_mode: archive_settings.local_only_max_age_mode,
        local_only_max_age_seconds: archive_settings.local_only_max_age_seconds,
        pinned_bytes: pinned_partition.total_pinned_bytes,
        r15m_bytes_per_sec: r15m,
        r6h_bytes_per_sec: r6h,
        history_seconds: history_sec,
        estimated_bitrate_bps: nominal_bps,
        enabled_policy_count: enabled_count,
        max_blocks: fetch_field(measurements, :max_blocks)
      })

    has_live_measurements? = map_size(measurements) > 0
    live_status = if has_live_measurements?, do: normalize_live_status(measurements)

    ledger_state =
      fetch_field(measurements, :ledger_state) ||
        fetch_field(measurements, :inventory) ||
        :unknown_until_nvr_status

    %{
      storage_id: sid,
      member_name: member_name,
      desired_settings: desired,
      persisted_settings?: not is_nil(persisted_settings),
      pinned_bytes: pinned_partition.total_pinned_bytes,
      pinned_breakdown: Map.delete(pinned_partition, :min_budget_bytes),
      min_custom_budget_bytes: pinned_partition.min_budget_bytes,
      local_present_blocks: present_blocks,
      local_present_bytes: int_or_zero(Map.get(storage_block_stats, :local_present_bytes)),
      unarchived_local_bytes: int_or_zero(Map.get(storage_block_stats, :unarchived_local_bytes)),
      quarantined_local_bytes:
        int_or_zero(Map.get(storage_block_stats, :quarantined_local_bytes)),
      held_local_pinned_bytes:
        int_or_zero(Map.get(storage_block_stats, :held_local_pinned_bytes)),
      effective_budget_bytes: eff_budget,
      window_projection: window_proj,
      time_to_full_seconds: window_proj.time_to_full_seconds,
      assigned_continuous_cameras: length(assigned),
      reservations: member_reservations,
      live_status_state:
        if(has_live_measurements?, do: :reported, else: :unknown_until_nvr_status),
      ledger_state: ledger_state,
      live_status: live_status
    }
  end

  defp normalize_live_status(measurements) when is_map(measurements) do
    capacity =
      case fetch_field(measurements, :capacity) do
        %{} = cap -> cap
        _ -> %{}
      end

    used_bytes = fetch_int(measurements, :used_bytes) || fetch_int(capacity, :used_bytes)

    max_spool_bytes =
      fetch_int(measurements, :max_spool_bytes) || fetch_int(capacity, :max_spool_bytes)

    available_bytes =
      fetch_int(measurements, :available_bytes) || fetch_int(capacity, :available_bytes)

    reserve_bytes = fetch_int(measurements, :reserve_bytes) || fetch_int(capacity, :reserve_bytes)

    reserved_bytes =
      fetch_int(measurements, :reserved_bytes) || fetch_int(capacity, :reserved_bytes)

    reservations = fetch_int(measurements, :reservations) || fetch_int(capacity, :reservations)
    blocks = fetch_int(measurements, :blocks) || fetch_int(capacity, :blocks)
    max_blocks = fetch_int(measurements, :max_blocks) || fetch_int(capacity, :max_blocks)
    drift_count = fetch_int(measurements, :drift_count)

    used_percent =
      if is_integer(used_bytes) and is_integer(max_spool_bytes) and max_spool_bytes > 0 do
        used_bytes
        |> Kernel.*(100.0)
        |> Kernel./(max_spool_bytes)
        |> min(100.0)
        |> max(0.0)
        |> Float.round(1)
      end

    recovery_state =
      case fetch_field(measurements, :recovery) do
        %{} = rec -> fetch_field(rec, :state)
        _ -> fetch_field(measurements, :recovery_state)
      end

    %{
      used_bytes: used_bytes,
      max_spool_bytes: max_spool_bytes,
      used_percent: used_percent,
      available_bytes: available_bytes,
      reserve_bytes: reserve_bytes,
      reserved_bytes: reserved_bytes,
      reservations: reservations,
      blocks: blocks,
      max_blocks: max_blocks,
      inventory:
        fetch_field(measurements, :inventory) || fetch_field(measurements, :ledger_state),
      drift_count: drift_count,
      recovery_state: recovery_state,
      archive_busy: fetch_field(measurements, :archive_busy),
      release: fetch_field(measurements, :release)
    }
  end

  defp fetch_int(map, key) when is_map(map) do
    case fetch_field(map, key) do
      val when is_integer(val) and val >= 0 -> val
      _ -> nil
    end
  end

  defp resolve_storage_effective_budget(desired, measurements) do
    max_spool =
      fetch_int(measurements, :max_spool_bytes) ||
        case fetch_field(measurements, :capacity) do
          %{} = cap -> fetch_int(cap, :max_spool_bytes)
          _ -> nil
        end

    cond do
      is_integer(fetch_field(measurements, :effective_budget_bytes)) and
          fetch_field(measurements, :effective_budget_bytes) > 0 ->
        fetch_field(measurements, :effective_budget_bytes)

      fetch_field(desired, :budget_mode) in [:custom, "custom"] and
        is_integer(fetch_field(desired, :budget_bytes)) and
          fetch_field(desired, :budget_bytes) > 0 ->
        fetch_field(desired, :budget_bytes)

      is_integer(max_spool) and max_spool > 0 ->
        max_spool

      is_integer(fetch_field(measurements, :volume_capacity_bytes)) and
          fetch_field(measurements, :volume_capacity_bytes) > 0 ->
        NVRStorageSettings.derive_install_defaults(
          fetch_field(measurements, :volume_capacity_bytes)
        ).budget_bytes

      true ->
        @default_local_budget_bytes
    end
  end

  defp storage_local_rate_stats(sid, catalog_entries, storage_block_stats) do
    r15m = Map.get(storage_block_stats, :catalog_r15m_bytes_per_sec, 0.0) * 1.0
    r6h = Map.get(storage_block_stats, :catalog_r6h_bytes_per_sec, 0.0) * 1.0

    {present_count, oldest_sealed, newest_sealed} =
      Enum.reduce(catalog_entries, {0, nil, nil}, fn entry, {cnt, old_dt, new_dt} ->
        if to_string(fetch_field(entry, :storage_id) || "") == sid do
          local_st = normalize_catalog_state(fetch_field(entry, :local_state))
          sealed_at = fetch_field(entry, :sealed_at)
          next_cnt = cnt + if(local_st == :present, do: 1, else: 0)

          if local_st == :quarantined do
            {next_cnt, old_dt, new_dt}
          else
            {next_cnt, min_dt(old_dt, sealed_at), max_dt(new_dt, sealed_at)}
          end
        else
          {cnt, old_dt, new_dt}
        end
      end)

    history_sec =
      case {oldest_sealed, newest_sealed} do
        {%DateTime{} = a, %DateTime{} = b} -> max(0, DateTime.diff(b, a, :second))
        _ -> 0
      end

    {r15m, r6h, history_sec, present_count}
  end

  defp build_retention_and_dispositions(usage, dispositions, now) do
    cutoff_24h = DateTime.shift(now, second: -@window_24h_seconds)

    recent =
      Enum.filter(dispositions, fn row ->
        case fetch_field(row, :inserted_at) do
          %DateTime{} = dt -> DateTime.compare(dt, cutoff_24h) != :lt
          _ -> true
        end
      end)

    acc =
      Enum.reduce(
        recent,
        %{ops: MapSet.new(), verified: 0, failed: 0, by_reason: %{}, failures: []},
        fn row, st ->
          accumulate_disposition_row(row, st)
        end
      )

    %{
      active_hold_count: usage.holds.active_hold_count,
      held_archive_bytes: usage.holds.held_archive_bytes,
      held_local_pinned_bytes: usage.holds.held_local_pinned_bytes,
      held_archive_missing_count: usage.holds.held_archive_missing_count,
      recent_dispositions_24h: length(recent),
      recent_operations_24h: MapSet.size(acc.ops),
      verified_absent_24h: acc.verified,
      failed_dispositions_24h: acc.failed,
      by_reason_24h: acc.by_reason,
      recent_failures_24h: acc.failures |> Enum.reverse() |> Enum.take(20),
      object_retention_enforced?: usage.object_retention_enforced?,
      object_projection: usage.object_projection
    }
  end

  defp accumulate_disposition_row(row, st) do
    step = fetch_field(row, :step)
    reason = fetch_field(row, :reason)
    op_id = fetch_field(row, :operation_id)
    next_ops = if is_nil(op_id), do: st.ops, else: MapSet.put(st.ops, to_string(op_id))
    verified? = step in [:verified_absent, "verified_absent"]
    failed? = step in [:failed, "failed"]

    next_by_reason =
      if is_nil(reason) do
        st.by_reason
      else
        Map.update(st.by_reason, reason, 1, &(&1 + 1))
      end

    next_failures =
      if failed? do
        [
          %{
            operation_id: op_id && to_string(op_id),
            catalog_entry_id: fetch_field(row, :catalog_entry_id),
            storage_id: fetch_field(row, :storage_id),
            block_key: fetch_field(row, :block_key),
            copy: fetch_field(row, :copy),
            reason: reason,
            error_class: fetch_field(row, :error_class),
            inserted_at: fetch_field(row, :inserted_at)
          }
          | st.failures
        ]
      else
        st.failures
      end

    %{
      ops: next_ops,
      verified: st.verified + if(verified?, do: 1, else: 0),
      failed: st.failed + if(failed?, do: 1, else: 0),
      by_reason: next_by_reason,
      failures: next_failures
    }
  end

  defp load_full_catalog_entries(loaders) do
    case Map.get(loaders, :catalog_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ when map_size(loaders) > 0 ->
        {:ok, []}

      _ ->
        RecordingCatalogEntry
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.select([
          :id,
          :camera_source_id,
          :stream_profile_id,
          :storage_id,
          :block_key,
          :timeline_start_us,
          :timeline_end_us,
          :local_state,
          :local_state_at,
          :quarantine_reason,
          :quarantine_receipt,
          :quarantined_bytes,
          :quarantine_evidence,
          :operator_disposition_state,
          :operator_decision,
          :archive_state,
          :archive_state_at,
          :archive_binding_id,
          :quarantine_binding_id,
          :archive_last_error_class,
          :media_bytes,
          :sealed_at,
          :archived_at,
          :inserted_at
        ])
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_retained_binding_ids(loaders) do
    cond do
      is_function(Map.get(loaders, :bindings_loader), 0) ->
        with {:ok, rows} <- loaders.bindings_loader.() do
          ids =
            rows
            |> Enum.map(&fetch_field(&1, :id))
            |> Enum.reject(&is_nil/1)
            |> MapSet.new(&to_string/1)

          {:ok, ids}
        end

      map_size(loaders) > 0 ->
        {:ok, :unverified_in_loader}

      true ->
        ArchiveBinding
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.select([:id])
        |> Ash.read(actor: @system_actor)
        |> case do
          {:ok, rows} ->
            {:ok, MapSet.new(rows, &to_string(&1.id))}

          {:error, _} = error ->
            error
        end
    end
  end

  defp default_reservations_summary do
    %{
      total_count: 0,
      unresolved_count: 0,
      adopted_count: 0,
      block_absent_count: 0,
      unrecoverable_count: 0,
      unrecoverable_journal_count: 0,
      by_state: %{
        unresolved: 0,
        adopted: 0,
        block_absent: 0,
        unrecoverable_journal: 0
      },
      by_storage: %{}
    }
  end

  defp zero_storage_reservations do
    %{
      total_count: 0,
      unresolved_count: 0,
      adopted_count: 0,
      block_absent_count: 0,
      unrecoverable_count: 0,
      unrecoverable_journal_count: 0
    }
  end

  defp load_reservations_summary(loaders) do
    cond do
      is_function(Map.get(loaders, :reservations_loader), 0) ->
        with {:ok, raw} <- loaders.reservations_loader.() do
          {:ok, normalize_reservations_input(raw)}
        end

      is_function(Map.get(loaders, :blocks_loader), 0) ->
        with {:ok, blocks} <- loaders.blocks_loader.() do
          {:ok, summarize_reservation_rows(blocks)}
        end

      map_size(loaders) > 0 ->
        {:ok, default_reservations_summary()}

      true ->
        query_reservations_summary()
    end
  end

  defp normalize_reservations_input(%{by_state: _} = summary), do: summary

  defp normalize_reservations_input(rows) when is_list(rows) do
    summarize_reservation_rows(rows)
  end

  defp normalize_reservations_input(counts) when is_map(counts) do
    unresolved =
      int_or_zero(fetch_field(counts, :unresolved_count) || fetch_field(counts, :unresolved))

    adopted = int_or_zero(fetch_field(counts, :adopted_count) || fetch_field(counts, :adopted))

    absent =
      int_or_zero(fetch_field(counts, :block_absent_count) || fetch_field(counts, :block_absent))

    unrecoverable =
      int_or_zero(
        fetch_field(counts, :unrecoverable_count) ||
          fetch_field(counts, :unrecoverable_journal_count) ||
          fetch_field(counts, :unrecoverable_journal)
      )

    %{
      total_count: unresolved + adopted + absent + unrecoverable,
      unresolved_count: unresolved,
      adopted_count: adopted,
      block_absent_count: absent,
      unrecoverable_count: unrecoverable,
      unrecoverable_journal_count: unrecoverable,
      by_state: %{
        unresolved: unresolved,
        adopted: adopted,
        block_absent: absent,
        unrecoverable_journal: unrecoverable
      },
      by_storage: fetch_field(counts, :by_storage) || %{}
    }
  end

  defp normalize_reservations_input(_), do: default_reservations_summary()

  defp summarize_reservation_rows(rows) when is_list(rows) do
    grouped =
      Enum.reduce(rows, %{}, fn row, acc ->
        sid =
          case fetch_field(row, :storage_id) do
            nil -> "unknown"
            val -> to_string(val)
          end

        state = normalize_reconciliation_state(fetch_field(row, :reconciliation_state))
        cnt = max(1, int_or_zero(fetch_field(row, :count)))
        Map.update(acc, {sid, state}, cnt, &(&1 + cnt))
      end)

    build_reservations_from_grouped(grouped)
  end

  defp query_reservations_summary do
    import Ecto.Query, only: [from: 2]

    rows =
      ServiceRadar.Repo.all(
        from(b in {"camera_recording_blocks", RecordingBlock},
          prefix: "platform",
          group_by: [b.storage_id, b.reconciliation_state],
          select: {b.storage_id, b.reconciliation_state, count(b.id)}
        )
      )

    grouped =
      Enum.reduce(rows, %{}, fn {sid, raw_state, cnt}, acc ->
        sid_str = if is_nil(sid), do: "unknown", else: to_string(sid)
        state = normalize_reconciliation_state(raw_state)
        Map.update(acc, {sid_str, state}, cnt, &(&1 + cnt))
      end)

    {:ok, build_reservations_from_grouped(grouped)}
  rescue
    _ -> {:ok, default_reservations_summary()}
  end

  defp build_reservations_from_grouped(grouped) when is_map(grouped) do
    by_storage =
      grouped
      |> Enum.reduce(%{}, fn {{sid, state}, cnt}, acc ->
        current = Map.get(acc, sid, zero_storage_reservations())
        updated = add_reservation_count(current, state, cnt)
        Map.put(acc, sid, updated)
      end)
      |> Map.delete("unknown")

    totals =
      Enum.reduce(grouped, zero_storage_reservations(), fn {{_sid, state}, cnt}, acc ->
        add_reservation_count(acc, state, cnt)
      end)

    %{
      total_count: totals.total_count,
      unresolved_count: totals.unresolved_count,
      adopted_count: totals.adopted_count,
      block_absent_count: totals.block_absent_count,
      unrecoverable_count: totals.unrecoverable_count,
      unrecoverable_journal_count: totals.unrecoverable_journal_count,
      by_state: %{
        unresolved: totals.unresolved_count,
        adopted: totals.adopted_count,
        block_absent: totals.block_absent_count,
        unrecoverable_journal: totals.unrecoverable_journal_count
      },
      by_storage: by_storage
    }
  end

  defp add_reservation_count(bucket, :adopted, cnt) do
    %{bucket | total_count: bucket.total_count + cnt, adopted_count: bucket.adopted_count + cnt}
  end

  defp add_reservation_count(bucket, :block_absent, cnt) do
    %{
      bucket
      | total_count: bucket.total_count + cnt,
        block_absent_count: bucket.block_absent_count + cnt
    }
  end

  defp add_reservation_count(bucket, :unrecoverable_journal, cnt) do
    %{
      bucket
      | total_count: bucket.total_count + cnt,
        unrecoverable_count: bucket.unrecoverable_count + cnt,
        unrecoverable_journal_count: bucket.unrecoverable_journal_count + cnt
    }
  end

  defp add_reservation_count(bucket, _unresolved, cnt) do
    %{
      bucket
      | total_count: bucket.total_count + cnt,
        unresolved_count: bucket.unresolved_count + cnt
    }
  end

  defp normalize_reconciliation_state(val) when is_atom(val) do
    if val in RecordingBlock.reconciliation_states(), do: val, else: :unresolved
  end

  defp normalize_reconciliation_state(val) when is_binary(val) do
    Enum.find(RecordingBlock.reconciliation_states(), &(Atom.to_string(&1) == val)) || :unresolved
  end

  defp normalize_reconciliation_state(_), do: :unresolved

  defp normalize_quarantine_reason(val) when is_atom(val) do
    if val in RecordingCatalogEntry.quarantine_reasons(), do: val
  end

  defp normalize_quarantine_reason(val) when is_binary(val) do
    Enum.find(RecordingCatalogEntry.quarantine_reasons(), &(Atom.to_string(&1) == val))
  end

  defp normalize_quarantine_reason(_), do: nil

  defp resolve_quarantine_evidence(entry, receipt) do
    case fetch_field(entry, :quarantine_evidence) do
      ev when is_map(ev) and map_size(ev) > 0 ->
        ev

      _ ->
        if is_map(receipt) and is_map(fetch_field(receipt, :evidence)) do
          fetch_field(receipt, :evidence)
        else
          %{}
        end
    end
  end

  defp resolve_quarantine_disposition_state(entry, local_state) do
    raw = fetch_field(entry, :operator_disposition_state)

    cond do
      local_state == :reclaimed ->
        :disposed

      local_state == :reclaiming ->
        :delete_requested

      raw in [:awaiting_operator, :export_requested, :delete_requested, :disposed] ->
        raw

      is_binary(raw) ->
        Enum.find(
          RecordingCatalogEntry.operator_disposition_states(),
          &(Atom.to_string(&1) == raw)
        ) || :awaiting_operator

      true ->
        :awaiting_operator
    end
  end

  defp format_quarantine_evidence_summary(q_reason, evidence) do
    reason_label =
      case q_reason do
        :unattributable -> "Unattributable"
        :unrecoverable_journal -> "Unrecoverable journal"
        :binding_without_history -> "Binding absent from retained history"
        :binding_compromised -> "Binding ended as compromised"
        other -> to_string(other || "Quarantined")
      end

    detail =
      fetch_field(evidence, :reason) || fetch_field(evidence, :detail_class) ||
        fetch_field(evidence, :verification_class)

    if is_binary(detail) and detail != "" and detail != to_string(q_reason) do
      "#{reason_label}: #{detail}"
    else
      reason_label
    end
  end

  defp load_accepted_holds(loaders) do
    case Map.get(loaders, :holds_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ when map_size(loaders) > 0 ->
        {:ok, []}

      _ ->
        RecordingHold
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.filter(state == :accepted)
        |> Ash.Query.select([
          :id,
          :camera_source_id,
          :stream_profile_id,
          :start_us,
          :end_us,
          :kind,
          :state,
          :unavailable_blocks
        ])
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_policies(loaders) do
    case Map.get(loaders, :policies_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ when map_size(loaders) > 0 ->
        {:ok, []}

      _ ->
        CameraRecordingPolicy
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.load(
          stream_profile: [:id, :camera_source_id, :profile_name, :relay_eligible, :metadata]
        )
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_storage_settings(loaders) do
    case Map.get(loaders, :storage_settings_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ when map_size(loaders) > 0 ->
        {:ok, []}

      _ ->
        NVRStorageSettings
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.sort(storage_id: :asc)
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_local_storage_bindings(loaders) do
    case Map.get(loaders, :local_storage_bindings_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ when map_size(loaders) > 0 ->
        {:ok, []}

      _ ->
        # Read using Ecto query on platform.camera_local_storage_bindings or empty fallback
        # since LocalStorageBinding policy restricts Ash reads to nvr_storage_purpose actors.
        read_distinct_local_binding_storage_ids()
    end
  end

  defp read_distinct_local_binding_storage_ids do
    import Ecto.Query, only: [from: 2]

    rows =
      ServiceRadar.Repo.all(
        from(b in {"camera_local_storage_bindings", LocalStorageBinding},
          prefix: "platform",
          distinct: b.storage_id,
          select: %{storage_id: b.storage_id}
        )
      )

    {:ok, rows}
  rescue
    _ -> {:ok, []}
  end

  defp load_recent_and_open_gaps(now, loaders) do
    case Map.get(loaders, :gaps_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ when map_size(loaders) > 0 ->
        {:ok, []}

      _ ->
        cutoff_us =
          DateTime.to_unix(now, :microsecond) - @window_24h_seconds * @microseconds_per_second

        RecordingGap
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.filter(is_nil(end_us) or start_us >= ^cutoff_us or end_us >= ^cutoff_us)
        |> Ash.Query.sort(start_us: :desc, id: :desc)
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_recent_dispositions(now, loaders) do
    case Map.get(loaders, :dispositions_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ when map_size(loaders) > 0 ->
        {:ok, []}

      _ ->
        cutoff = DateTime.shift(now, second: -@window_24h_seconds)

        RecordingDisposition
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.filter(inserted_at >= ^cutoff)
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_active_alerts(loaders) do
    cond do
      is_function(Map.get(loaders, :alerts_loader), 0) ->
        with {:ok, rows} <- loaders.alerts_loader.() do
          {:ok, Enum.map(rows, &normalize_alert_item/1)}
        end

      is_function(Map.get(loaders, :health_events_loader), 0) ->
        with {:ok, events} <- loaders.health_events_loader.() do
          {:ok, filter_active_recording_alerts(events)}
        end

      map_size(loaders) > 0 ->
        {:ok, []}

      true ->
        query_active_recording_health_events()
    end
  end

  defp query_active_recording_health_events do
    HealthEvent
    |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
    |> Ash.Query.filter(
      entity_type == :core and
        (fragment("? LIKE 'storage.recordings.%'", entity_id) or
           fragment("? LIKE 'nvr.%'", entity_id))
    )
    |> Ash.Query.sort(event_sequence: :desc)
    |> Ash.Query.limit(@health_events_limit)
    |> Ash.read(actor: @system_actor)
    |> case do
      {:ok, events} -> {:ok, filter_active_recording_alerts(events)}
      _ -> {:ok, []}
    end
  rescue
    _ -> {:ok, []}
  end

  defp filter_active_recording_alerts(events) when is_list(events) do
    events
    |> Enum.filter(&recording_alert_entity?/1)
    |> Enum.uniq_by(&to_string(fetch_field(&1, :entity_id)))
    |> Enum.filter(fn event ->
      state = fetch_field(event, :new_state) || fetch_field(event, :state)
      state not in [:healthy, "healthy", nil]
    end)
    |> Enum.map(&normalize_alert_item/1)
  end

  defp recording_alert_entity?(event) when is_map(event) do
    id = to_string(fetch_field(event, :entity_id) || fetch_field(event, :check_id) || "")

    String.starts_with?(id, "storage.recordings.") or
      String.starts_with?(id, "nvr.")
  end

  defp normalize_alert_item(item) when is_map(item) do
    check_id = to_string(fetch_field(item, :check_id) || fetch_field(item, :entity_id) || "")
    metadata = fetch_field(item, :metadata) || %{}
    state = fetch_field(item, :state) || fetch_field(item, :new_state) || :unhealthy
    severity = fetch_field(item, :severity) || fetch_field(metadata, :severity) || :warning

    %{
      check_id: check_id,
      entity_type: fetch_field(item, :entity_type) || :core,
      state: state,
      severity: severity,
      reason: fetch_field(item, :reason),
      metadata: metadata,
      recorded_at: fetch_field(item, :recorded_at)
    }
  end

  defp entry_protected_by_hold?(hold, entry) when is_map(hold) and is_map(entry) do
    normalized_hold =
      if is_nil(fetch_field(hold, :state)),
        do: Map.put(hold, :state, :accepted),
        else: hold

    RecordingHolds.hold_protects_entry?(normalized_hold, entry)
  end

  defp normalize_catalog_state(val) when is_atom(val), do: val

  defp normalize_catalog_state(val) when is_binary(val) do
    Enum.find(
      RecordingCatalogEntry.local_states() ++ RecordingCatalogEntry.archive_states(),
      &(Atom.to_string(&1) == val)
    )
  end

  defp normalize_catalog_state(_), do: nil

  defp normalize_gap_reason(val) when is_atom(val) do
    if val in RecordingGap.reasons(), do: val
  end

  defp normalize_gap_reason(val) when is_binary(val) do
    Enum.find(RecordingGap.reasons(), &(Atom.to_string(&1) == val))
  end

  defp normalize_gap_reason(_), do: nil

  defp int_or_zero(val) when is_integer(val), do: val
  defp int_or_zero(val) when is_float(val), do: trunc(val)
  defp int_or_zero(_), do: 0

  defp min_dt(nil, %DateTime{} = dt), do: dt
  defp min_dt(%DateTime{} = dt, nil), do: dt
  defp min_dt(%DateTime{} = a, %DateTime{} = b), do: if(DateTime.after?(a, b), do: b, else: a)
  defp min_dt(a, _b), do: a

  defp max_dt(nil, %DateTime{} = dt), do: dt
  defp max_dt(%DateTime{} = dt, nil), do: dt
  defp max_dt(%DateTime{} = a, %DateTime{} = b), do: if(DateTime.before?(a, b), do: b, else: a)
  defp max_dt(a, _b), do: a

  defp fetch_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
