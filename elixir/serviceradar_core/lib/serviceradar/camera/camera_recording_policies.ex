defmodule ServiceRadar.Camera.CameraRecordingPolicies do
  @moduledoc """
  Context facade for per-camera `CameraRecordingPolicy` CRUD, profile bitrate &
  block-rate estimation, and `C1a` / `C3a` pre-save What-If projections (`A.2.1`,
  `A3`, `C1a`, `C3a`, `E.1`).

  - `list_policies/1`: authorizes `settings.recording.view | manage | operate`
    and loads persisted `CameraRecordingPolicy` rows with redacted camera/profile
    summaries (plus `:loaders` seam for `:db_free` unit tests).
  - `save_policy/2`: authorizes `settings.recording.manage`, creates (`policy_revision = 1`)
    or updates (`policy_revision = policy_revision + 1` atomically) the policy row
    for `(camera_source_id, stream_profile_id)`, acting as an `A3` assignment transition.
  - `profile_estimate/1`: extracts observed or nominal bitrate (`bps`) from a
    `StreamProfile` or metadata map and computes estimated bytes/day, archive
    bytes/day (`1.02` CMAF overhead), block length, and blocks/day (`A1` bounds:
    `270 s` or `12 MiB`).
  - `what_if_preview/2`: computes pre-save `C1a` & `C3a` projections for a
    candidate policy change: projected local window on the target `nvr_member`,
    projected provider throughput needed (`~2x` archived capture rate) vs measured
    throughput/goodput, projected blocks/day vs block cap (`131,072` default),
    projected continuous sessions on the member vs session limit (`16` default),
    object-tier effective retention per policy, and non-blocking warnings.
  """

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.NVRStorageSettings
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingHold
  alias ServiceRadar.Camera.RetentionCalculator
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Storage.StorageEntitlements

  require Ash.Query

  @seconds_per_day 86_400
  @cmaf_overhead_factor 1.02
  @max_capture_seconds 270.0
  @max_capture_bytes 12 * 1_048_576
  @default_max_sessions 16
  @default_max_blocks 131_072
  @default_local_budget_bytes 1_073_741_824
  @window_15m_seconds 900
  @window_6h_seconds 21_600

  @system_actor SystemActor.system(:camera_recording_policies)

  @doc """
  Lists all persisted `CameraRecordingPolicy` rows ordered by camera/profile
  under `settings.recording.view | manage | operate`.

  Supports `loaders.policies_loader` (`fn -> {:ok, policies} end`) for `:db_free`
  unit tests.
  """
  @spec list_policies(keyword()) :: {:ok, [CameraRecordingPolicy.t() | map()]} | {:error, term()}
  def list_policies(opts \\ []) when is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    with :ok <- RecordingArchiveSettings.authorize_recording_read(opts) do
      load_policies(loaders)
    end
  end

  @doc """
  The `{camera_source_id, stream_profile_id}` pairs a recorder is recording now
  (`RecorderOwnership.recording_now/1`), under `settings.recording.view | manage | operate`.
  """
  @spec recording_now(keyword()) :: {:ok, MapSet.t()} | {:error, term()}
  def recording_now(opts \\ []) when is_list(opts) do
    with :ok <- RecordingArchiveSettings.authorize_recording_read(opts) do
      RecorderOwnership.recording_now()
    end
  end

  @doc """
  Reads a single `CameraRecordingPolicy` by `(camera_source_id, stream_profile_id)`
  under `settings.recording.view | manage | operate`.
  """
  @spec get_policy(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, CameraRecordingPolicy.t() | map() | nil} | {:error, term()}
  def get_policy(camera_source_id, stream_profile_id, opts \\ [])
      when is_binary(camera_source_id) and is_binary(stream_profile_id) and is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    with :ok <- RecordingArchiveSettings.authorize_recording_read(opts) do
      case Map.get(loaders, :policies_loader) do
        loader when is_function(loader, 0) ->
          with {:ok, rows} <- loader.() do
            {:ok, find_matching_policy(rows, nil, camera_source_id, stream_profile_id)}
          end

        _ when map_size(loaders) > 0 ->
          {:ok, nil}

        _ ->
          CameraRecordingPolicy
          |> Ash.Query.for_read(
            :by_camera_profile,
            %{camera_source_id: camera_source_id, stream_profile_id: stream_profile_id},
            actor: @system_actor
          )
          |> preload_safe_relationships()
          |> Ash.read_one(actor: @system_actor)
      end
    end
  end

  @doc """
  Validates candidate policy attributes without persisting.
  Useful for LiveView `phx-change` field error feedback.
  """
  @spec preview_changeset(map(), keyword()) :: Ash.Changeset.t()
  def preview_changeset(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    normalized = normalize_override_attrs(attrs)
    ash_opts = ash_actor_opts(opts)
    context = build_changeset_context(opts)

    case Keyword.get(opts, :existing) do
      %CameraRecordingPolicy{} = existing ->
        Ash.Changeset.for_update(
          existing,
          :update,
          normalized,
          Keyword.put(ash_opts, :context, context)
        )

      _ ->
        Ash.Changeset.for_create(
          CameraRecordingPolicy,
          :create,
          normalized,
          Keyword.put(ash_opts, :context, context)
        )
    end
  end

  @doc """
  Creates or updates a `CameraRecordingPolicy` for `(camera_source_id, stream_profile_id)`
  under `settings.recording.manage` authorization.

  Creates start at `policy_revision = 1` (defaulting `storage` to `:local_and_archive`
  when `RecordingArchiveSettings.archive_enabled` is true, else `:local_only`).
  Updates atomically increment `policy_revision` (`A3` assignment transition) and
  append a PaperTrail version row.
  """
  @spec save_policy(map(), keyword()) :: {:ok, CameraRecordingPolicy.t()} | {:error, term()}
  def save_policy(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with :ok <- authorize_manage(opts),
         {:ok, existing} <- lookup_existing_for_save(attrs) do
      normalized = normalize_override_attrs(attrs)
      ash_opts = ash_actor_opts(opts)
      context = build_changeset_context(opts)

      result =
        case existing do
          nil ->
            CameraRecordingPolicy
            |> Ash.Changeset.for_create(
              :create,
              normalized,
              Keyword.put(ash_opts, :context, context)
            )
            |> Ash.create(ash_opts)

          %CameraRecordingPolicy{} = record ->
            update_attrs = drop_identity_keys(normalized)

            record
            |> Ash.Changeset.for_update(
              :update,
              update_attrs,
              Keyword.put(ash_opts, :context, context)
            )
            |> Ash.update(ash_opts)
        end

      maybe_preload_saved(result)
    end
  end

  @doc """
  Alias for `save_policy/2` creating or updating a `CameraRecordingPolicy` for
  `(camera_source_id, stream_profile_id)` under `settings.recording.manage`.
  """
  @spec upsert_policy(map(), keyword()) :: {:ok, CameraRecordingPolicy.t()} | {:error, term()}
  def upsert_policy(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    save_policy(attrs, opts)
  end

  @doc """
  Computes estimated bitrate, bytes/day, archive bytes/day (`1.02` CMAF overhead),
  block duration (`<= 270 s` and `<= 12 MiB`), and blocks/day for a `StreamProfile`
  or metadata map (`design.md` `A1`, `C1a`, `S`).
  """
  @spec profile_estimate(map() | nil) :: %{
          bitrate_bps: pos_integer() | nil,
          basis: :observed | :nominal | :unknown,
          bytes_per_sec: float() | nil,
          bytes_per_day: float() | nil,
          archive_bytes_per_day: float() | nil,
          block_seconds: float() | nil,
          blocks_per_day: float() | nil
        }
  def profile_estimate(nil) do
    %{
      bitrate_bps: nil,
      basis: :unknown,
      bytes_per_sec: nil,
      bytes_per_day: nil,
      archive_bytes_per_day: nil,
      block_seconds: nil,
      blocks_per_day: nil
    }
  end

  def profile_estimate(profile_or_map) when is_map(profile_or_map) do
    {bitrate_bps, basis} = extract_profile_bitrate(profile_or_map)

    if is_integer(bitrate_bps) and bitrate_bps > 0 do
      bytes_per_sec = bitrate_bps / 8.0
      bytes_per_day = bytes_per_sec * @seconds_per_day
      archive_bytes_per_day = bytes_per_day * @cmaf_overhead_factor
      byte_bound_seconds = @max_capture_bytes / bytes_per_sec
      block_seconds = min(@max_capture_seconds, byte_bound_seconds)
      blocks_per_day = @seconds_per_day / block_seconds

      %{
        bitrate_bps: bitrate_bps,
        basis: basis,
        bytes_per_sec: bytes_per_sec,
        bytes_per_day: bytes_per_day,
        archive_bytes_per_day: archive_bytes_per_day,
        block_seconds: block_seconds,
        blocks_per_day: blocks_per_day
      }
    else
      profile_estimate(nil)
    end
  end

  @doc """
  Resolves the effective configured archive retention (`pos_integer() | :unlimited`)
  for a `CameraRecordingPolicy` (or map) given deployment `RecordingArchiveSettings`
  and an optional SaaS `entitlement_state` (`F.5`).
  """
  @spec resolve_policy_archive_retention(map(), map(), map() | nil) ::
          pos_integer() | :unlimited
  def resolve_policy_archive_retention(policy, settings, entitlement_state \\ nil)
      when is_map(policy) and is_map(settings) do
    effective_policy_retention_details(policy, settings, entitlement_state).effective_days
  end

  @doc """
  Returns configured vs plan-bounded effective archive retention details for a
  `CameraRecordingPolicy`, including `"configured X days, effective Y days (plan maximum)"`
  when capped by a lowered plan `max_days` (`F.5`, `spec.md:724-732`).
  """
  @spec effective_policy_retention_details(map(), map(), map() | nil) :: %{
          configured_days: pos_integer() | :unlimited,
          effective_days: pos_integer() | :unlimited,
          plan_max_days: pos_integer() | nil,
          capped_by_plan?: boolean(),
          summary_label: String.t() | nil
        }
  def effective_policy_retention_details(policy, settings, entitlement_state \\ nil)
      when is_map(policy) and is_map(settings) do
    override_mode =
      normalize_override_mode(fetch_field(policy, :archive_retention_override_mode))

    configured =
      case override_mode do
        :unlimited ->
          :unlimited

        :limited ->
          case fetch_field(policy, :archive_retention_days_override) do
            days when is_integer(days) and days > 0 -> days
            _ -> deployment_archive_retention(settings)
          end

        :inherit ->
          deployment_archive_retention(settings)
      end

    max_days = extract_plan_max_days(entitlement_state)

    cond do
      is_integer(max_days) and configured == :unlimited ->
        %{
          configured_days: :unlimited,
          effective_days: max_days,
          plan_max_days: max_days,
          capped_by_plan?: true,
          summary_label: "configured unlimited, effective #{max_days} days (plan maximum)"
        }

      is_integer(max_days) and is_integer(configured) and configured > max_days ->
        %{
          configured_days: configured,
          effective_days: max_days,
          plan_max_days: max_days,
          capped_by_plan?: true,
          summary_label:
            "configured #{configured} days, effective #{max_days} days (plan maximum)"
        }

      true ->
        %{
          configured_days: configured,
          effective_days: configured,
          plan_max_days: max_days,
          capped_by_plan?: false,
          summary_label: nil
        }
    end
  end

  defp extract_plan_max_days(%{
         hosted?: true,
         applied?: true,
         recordings: %{retention_max_days: m}
       })
       when is_integer(m) and m >= 1, do: m

  defp extract_plan_max_days(%{retention_max_days: m}) when is_integer(m) and m >= 1, do: m
  defp extract_plan_max_days(_), do: nil

  @doc """
  Computes the pre-save `C1a` & `C3a` What-If projection for `candidate_change`
  under `settings.recording.view | manage | operate` authorization.

  Supports `:loaders` (`settings_loader`, `policies_loader`, `profiles_loader` /
  `profile_loader`, `catalog_loader`, `holds_loader`, `all_receipts_loader`,
  `bindings_loader`, `storage_settings_loader`) and direct option overrides
  (`:local_budget_bytes`, `:pinned_bytes`, `:non_reapable_bytes`, `:usage_bytes`,
  `:max_sessions`, `:max_blocks`, `:measured_archive_goodput_bytes_per_sec`,
  `:storage_id_by_member`) so LiveView `phx-change="preview_policy"` and `:db_free`
  unit tests run with zero DB I/O when loaders/snapshots are supplied.
  """
  @spec what_if_preview(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def what_if_preview(candidate_change, opts \\ [])
      when is_map(candidate_change) and is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- RecordingArchiveSettings.authorize_recording_read(opts),
         {:ok, base_settings} <- load_settings(opts, loaders),
         {:ok, existing_policies} <- load_policies(loaders),
         {:ok, catalog_entries} <- load_catalog_entries(loaders),
         {:ok, holds} <- load_accepted_holds(loaders),
         {:ok, receipts} <- load_receipts(loaders) do
      entitlement = StorageEntitlements.effective_state(opts)
      settings = RecordingArchiveSettings.apply_entitlement_bounds(base_settings, entitlement)
      profiles_by_id = build_profiles_index(existing_policies, candidate_change, opts, loaders)
      candidate = normalize_candidate_policy(candidate_change, existing_policies, settings)
      merged_policies = merge_candidate_into_policies(existing_policies, candidate)

      target_member =
        candidate.nvr_member ||
          existing_member_for_candidate(existing_policies, candidate)

      member_projection =
        project_member_state(
          target_member,
          merged_policies,
          profiles_by_id,
          catalog_entries,
          holds,
          receipts,
          settings,
          opts,
          loaders,
          now
        )

      object_projection =
        project_object_state(
          merged_policies,
          profiles_by_id,
          catalog_entries,
          holds,
          receipts,
          settings,
          opts,
          loaders,
          now
        )

      candidate_obj_policy =
        Enum.find(
          object_projection.policies,
          &(to_string(&1.id) == to_string(candidate.id))
        )

      candidate_estimate =
        resolve_policy_estimate(candidate, profiles_by_id)

      warnings =
        build_what_if_warnings(
          candidate,
          candidate_estimate,
          settings,
          member_projection,
          object_projection
        )

      {:ok,
       %{
         candidate: candidate,
         candidate_estimate: candidate_estimate,
         nvr_member: target_member,
         projected_sessions: member_projection.projected_sessions,
         max_sessions: member_projection.max_sessions,
         sessions_exceed_limit?: member_projection.sessions_exceed_limit?,
         projected_blocks_per_day: member_projection.projected_blocks_per_day,
         max_blocks: member_projection.max_blocks,
         archive_capture_rate_bytes_per_sec: member_projection.archive_capture_rate_bytes_per_sec,
         local_only_capture_rate_bytes_per_sec:
           member_projection.local_only_capture_rate_bytes_per_sec,
         provider_throughput_needed_bytes_per_sec:
           member_projection.provider_throughput_needed_bytes_per_sec,
         measured_archive_goodput_bytes_per_sec:
           member_projection.measured_archive_goodput_bytes_per_sec,
         measured_provider_throughput_bytes_per_sec:
           member_projection.measured_provider_throughput_bytes_per_sec,
         throughput_exceeds_measured?: member_projection.throughput_exceeds_measured?,
         local_projection: member_projection.local_projection,
         object_projection: object_projection,
         candidate_object_policy: candidate_obj_policy,
         unknown_bitrate_policy_ids: member_projection.unknown_bitrate_policy_ids,
         warnings: warnings
       }}
    end
  end

  defp project_member_state(
         target_member,
         merged_policies,
         profiles_by_id,
         catalog_entries,
         holds,
         receipts,
         settings,
         opts,
         loaders,
         now
       ) do
    max_sessions = positive_int_or(Keyword.get(opts, :max_sessions), @default_max_sessions)
    max_blocks = positive_int_or(Keyword.get(opts, :max_blocks), @default_max_blocks)

    member_continuous =
      Enum.filter(merged_policies, fn pol ->
        normalize_mode_atom(fetch_field(pol, :mode)) == :continuous and
          not is_nil(target_member) and
          fetch_field(pol, :nvr_member) == target_member
      end)

    projected_sessions = length(member_continuous)
    sessions_exceed_limit? = projected_sessions > max_sessions

    rates_acc =
      Enum.reduce(
        member_continuous,
        %{archived_bps_sec: 0.0, local_only_bps_sec: 0.0, blocks_per_day: 0.0, unknown_ids: []},
        fn pol, acc ->
          accumulate_member_policy_rate(pol, acc, profiles_by_id, catalog_entries, settings, now)
        end
      )

    storage_id = resolve_member_storage_id(target_member, opts)
    local_budget = resolve_member_budget(storage_id, opts, loaders)
    pinned_bytes = resolve_member_pinned_bytes(storage_id, settings, catalog_entries, holds, opts)

    storage_mode =
      if settings.archive_enabled and rates_acc.archived_bps_sec >= rates_acc.local_only_bps_sec and
           rates_acc.archived_bps_sec > 0.0 do
        :local_and_archive
      else
        :local_only
      end

    measured_goodput =
      resolve_measured_goodput(storage_id, catalog_entries, receipts, opts, now)

    measured_provider_tp =
      if is_number(measured_goodput), do: measured_goodput * 2.0

    provider_tp_needed = rates_acc.archived_bps_sec * 2.0

    tp_exceeds? =
      is_number(measured_provider_tp) and measured_provider_tp > 0.0 and
        provider_tp_needed > measured_provider_tp

    local_projection =
      RetentionCalculator.calculate_local_window(
        build_member_local_window_inputs(
          settings,
          storage_mode,
          local_budget,
          pinned_bytes,
          projected_sessions,
          rates_acc,
          max_blocks,
          measured_goodput
        )
      )

    %{
      projected_sessions: projected_sessions,
      max_sessions: max_sessions,
      sessions_exceed_limit?: sessions_exceed_limit?,
      projected_blocks_per_day: rates_acc.blocks_per_day,
      max_blocks: max_blocks,
      archive_capture_rate_bytes_per_sec: rates_acc.archived_bps_sec,
      local_only_capture_rate_bytes_per_sec: rates_acc.local_only_bps_sec,
      provider_throughput_needed_bytes_per_sec: provider_tp_needed,
      measured_archive_goodput_bytes_per_sec: measured_goodput,
      measured_provider_throughput_bytes_per_sec: measured_provider_tp,
      throughput_exceeds_measured?: tp_exceeds?,
      local_projection: local_projection,
      unknown_bitrate_policy_ids: Enum.reverse(rates_acc.unknown_ids)
    }
  end

  defp build_member_local_window_inputs(
         settings,
         storage_mode,
         local_budget,
         pinned_bytes,
         projected_sessions,
         rates_acc,
         max_blocks,
         measured_goodput
       ) do
    base = %{
      storage_mode: storage_mode,
      effective_budget_bytes: local_budget,
      local_high_water_percent: settings.local_high_water_percent || 90,
      local_low_water_percent: settings.local_low_water_percent || 80,
      max_local_age_mode: settings.max_local_age_mode,
      max_local_age_seconds: settings.max_local_age_seconds,
      local_window_alert_mode: settings.local_window_alert_mode,
      local_window_alert_seconds: settings.local_window_alert_seconds,
      local_only_full_policy: settings.local_only_full_policy,
      local_only_max_age_mode: settings.local_only_max_age_mode,
      local_only_max_age_seconds: settings.local_only_max_age_seconds,
      pinned_bytes: pinned_bytes,
      enabled_policy_count: projected_sessions,
      archived_rate_bytes_per_sec: rates_acc.archived_bps_sec,
      local_only_rate_bytes_per_sec: rates_acc.local_only_bps_sec,
      max_blocks: max_blocks,
      block_rate_per_sec: rates_acc.blocks_per_day / @seconds_per_day
    }

    if is_number(measured_goodput) do
      Map.put(base, :archive_goodput_bytes_per_sec, measured_goodput)
    else
      base
    end
  end

  defp accumulate_member_policy_rate(pol, acc, profiles_by_id, catalog_entries, settings, now) do
    est = resolve_policy_estimate(pol, profiles_by_id)
    measured_bps_sec = policy_measured_local_rate(pol, catalog_entries, now)

    rate_bytes_per_sec =
      cond do
        measured_bps_sec > 0.0 -> measured_bps_sec
        is_number(est.bytes_per_sec) and est.bytes_per_sec > 0.0 -> est.bytes_per_sec
        true -> 0.0
      end

    blocks_per_day =
      if rate_bytes_per_sec > 0.0 do
        block_sec = min(@max_capture_seconds, @max_capture_bytes / rate_bytes_per_sec)
        @seconds_per_day / block_sec
      else
        0.0
      end

    archives? =
      settings.archive_enabled == true and
        normalize_storage_atom(fetch_field(pol, :storage)) == :local_and_archive

    unknown_ids =
      if rate_bytes_per_sec <= 0.0 do
        [to_string(fetch_field(pol, :id) || "candidate") | acc.unknown_ids]
      else
        acc.unknown_ids
      end

    %{
      archived_bps_sec: acc.archived_bps_sec + if(archives?, do: rate_bytes_per_sec, else: 0.0),
      local_only_bps_sec:
        acc.local_only_bps_sec + if(archives?, do: 0.0, else: rate_bytes_per_sec),
      blocks_per_day: acc.blocks_per_day + blocks_per_day,
      unknown_ids: unknown_ids
    }
  end

  defp policy_measured_local_rate(pol, catalog_entries, now) do
    cam_id = to_string(fetch_field(pol, :camera_source_id) || "")
    prof_id = to_string(fetch_field(pol, :stream_profile_id) || "")
    cutoff_15m = DateTime.shift(now, second: -@window_15m_seconds)
    cutoff_6h = DateTime.shift(now, second: -@window_6h_seconds)

    matching =
      Enum.filter(catalog_entries, fn entry ->
        fetch_field(entry, :local_state) not in [:quarantined, "quarantined"] and
          to_string(fetch_field(entry, :camera_source_id) || "") == cam_id and
          to_string(fetch_field(entry, :stream_profile_id) || "") == prof_id
      end)

    oldest_sealed =
      Enum.reduce(matching, nil, fn entry, acc ->
        case fetch_field(entry, :sealed_at) do
          %DateTime{} = ts -> if is_nil(acc) or DateTime.before?(ts, acc), do: ts, else: acc
          _ -> acc
        end
      end)

    has_15m_history? =
      match?(%DateTime{}, oldest_sealed) and
        DateTime.diff(now, oldest_sealed, :second) >= @window_15m_seconds

    if has_15m_history? do
      {b15, b6h} =
        Enum.reduce(matching, {0, 0}, fn entry, {s15, s6} ->
          bytes = max(0, int_or_zero(fetch_field(entry, :media_bytes)))
          sealed_at = fetch_field(entry, :sealed_at)

          in_15? =
            match?(%DateTime{}, sealed_at) and DateTime.compare(sealed_at, cutoff_15m) != :lt

          in_6h? =
            match?(%DateTime{}, sealed_at) and DateTime.compare(sealed_at, cutoff_6h) != :lt

          {s15 + if(in_15?, do: bytes, else: 0), s6 + if(in_6h?, do: bytes, else: 0)}
        end)

      max(b15 / @window_15m_seconds, b6h / @window_6h_seconds)
    else
      0.0
    end
  end

  defp project_object_state(
         merged_policies,
         profiles_by_id,
         catalog_entries,
         holds,
         receipts,
         settings,
         opts,
         _loaders,
         now
       ) do
    archiving_policies =
      if settings.archive_enabled do
        Enum.filter(merged_policies, fn pol ->
          normalize_mode_atom(fetch_field(pol, :mode)) == :continuous and
            normalize_storage_atom(fetch_field(pol, :storage)) == :local_and_archive
        end)
      else
        []
      end

    policy_specs =
      Enum.map(archiving_policies, fn pol ->
        est = resolve_policy_estimate(pol, profiles_by_id)
        rate_info = policy_archive_rate_info(pol, est.bitrate_bps, catalog_entries, receipts, now)
        configured_days = resolve_policy_archive_retention(pol, settings)

        %{
          id: to_string(fetch_field(pol, :id) || "candidate"),
          camera_source_id: fetch_field(pol, :camera_source_id),
          stream_profile_id: fetch_field(pol, :stream_profile_id),
          nvr_member: fetch_field(pol, :nvr_member),
          rate_bytes_per_day: rate_info.bytes_per_day,
          rate_basis: rate_info.basis,
          retention_days: configured_days
        }
      end)

    {default_usage_bytes, default_non_reapable} =
      estimate_object_usage_and_non_reapable(catalog_entries, receipts, holds)

    calc =
      RetentionCalculator.calculate_object_retention(policy_specs, %{
        object_budget_mode: settings.object_budget_mode,
        object_budget_bytes: settings.object_budget_bytes,
        object_high_water_percent: settings.object_high_water_percent || 90,
        object_low_water_percent: settings.object_low_water_percent || 80,
        object_capacity_policy: settings.object_capacity_policy,
        non_reapable_bytes: Keyword.get(opts, :non_reapable_bytes, default_non_reapable),
        usage_bytes: Keyword.get(opts, :usage_bytes, default_usage_bytes),
        non_reapable_growth_bytes_per_day:
          Keyword.get(opts, :non_reapable_growth_bytes_per_day, 0.0)
      })

    specs_by_id = Map.new(policy_specs, &{&1.id, &1})

    enriched_policies =
      Enum.map(calc.policies, fn p ->
        meta = Map.get(specs_by_id, to_string(p.id), %{})

        Map.merge(p, %{
          camera_source_id: Map.get(meta, :camera_source_id),
          stream_profile_id: Map.get(meta, :stream_profile_id),
          nvr_member: Map.get(meta, :nvr_member),
          rate_basis: Map.get(meta, :rate_basis, :unknown)
        })
      end)

    %{calc | policies: enriched_policies}
  end

  defp policy_archive_rate_info(pol, nominal_bps, catalog_entries, receipts, now) do
    cam_id = to_string(fetch_field(pol, :camera_source_id) || "")
    prof_id = to_string(fetch_field(pol, :stream_profile_id) || "")
    cutoff_24h = DateTime.shift(now, second: -@seconds_per_day)
    cutoff_7d = DateTime.shift(now, second: -7 * @seconds_per_day)

    receipts_by_id =
      for r <- receipts,
          id = fetch_field(r, :id),
          not is_nil(id),
          into: %{},
          do: {to_string(id), r}

    matching_verified =
      Enum.filter(catalog_entries, fn entry ->
        fetch_field(entry, :local_state) not in [:quarantined, "quarantined"] and
          fetch_field(entry, :archive_state) in [:verified, "verified", :deleting, "deleting"] and
          to_string(fetch_field(entry, :camera_source_id) || "") == cam_id and
          to_string(fetch_field(entry, :stream_profile_id) || "") == prof_id
      end)

    {oldest, b24, b7} =
      Enum.reduce(matching_verified, {nil, 0, 0}, fn entry, {old_acc, s24, s7} ->
        bytes = archived_entry_bytes(entry, receipts_by_id)
        ts = fetch_field(entry, :archived_at) || fetch_field(entry, :sealed_at)
        next_old = min_dt(old_acc, ts)
        in_24? = match?(%DateTime{}, ts) and DateTime.compare(ts, cutoff_24h) != :lt
        in_7? = match?(%DateTime{}, ts) and DateTime.compare(ts, cutoff_7d) != :lt
        {next_old, s24 + if(in_24?, do: bytes, else: 0), s7 + if(in_7?, do: bytes, else: 0)}
      end)

    history_seconds =
      case oldest do
        %DateTime{} = dt -> max(0, DateTime.diff(now, dt, :second))
        _ -> 0
      end

    RetentionCalculator.rate_from_history_or_nominal(%{
      history_seconds: history_seconds,
      trailing_24h_bytes: b24,
      trailing_7d_bytes: b7,
      nominal_bitrate_bps: nominal_bps
    })
  end

  defp archived_entry_bytes(entry, receipts_by_id) do
    rid = fetch_field(entry, :nvr_archive_receipt_id)

    case rid && Map.get(receipts_by_id, to_string(rid)) do
      %{} = receipt ->
        receipt
        |> fetch_field(:objects)
        |> List.wrap()
        |> Enum.reduce(0, fn obj, acc ->
          acc + max(0, int_or_zero(is_map(obj) && fetch_field(obj, :length)))
        end)

      _ ->
        max(0, int_or_zero(fetch_field(entry, :media_bytes)))
    end
  end

  defp estimate_object_usage_and_non_reapable(catalog_entries, receipts, holds) do
    receipts_by_id =
      for r <- receipts,
          id = fetch_field(r, :id),
          not is_nil(id),
          into: %{},
          do: {to_string(id), r}

    Enum.reduce(catalog_entries, {0, 0}, fn entry, {used, non_reapable} ->
      accumulate_entry_object_totals(entry, {used, non_reapable}, receipts_by_id, holds)
    end)
  end

  defp accumulate_entry_object_totals(entry, {used, non_reapable}, receipts_by_id, holds) do
    local_state = fetch_field(entry, :local_state)
    archive_state = fetch_field(entry, :archive_state)

    cond do
      local_state in [:quarantined, "quarantined"] and
          archive_state in [
            :verified,
            "verified",
            :deleting,
            "deleting",
            :pending,
            "pending",
            :failed_retryable,
            "failed_retryable"
          ] ->
        q_bytes = max(0, int_or_zero(fetch_field(entry, :quarantined_bytes)))
        {used + q_bytes, non_reapable + q_bytes}

      archive_state in [:verified, "verified", :deleting, "deleting"] ->
        bytes = archived_entry_bytes(entry, receipts_by_id)
        blocked? = fetch_field(entry, :archive_last_error_class) == "blocked_by_provider"

        held_arch? =
          archive_state in [:verified, "verified"] and
            Enum.any?(holds, fn h ->
              norm_h =
                if is_nil(fetch_field(h, :state)), do: Map.put(h, :state, :accepted), else: h

              ServiceRadar.Camera.RecordingHolds.hold_protects_entry?(norm_h, entry)
            end)

        nr_add = if blocked? or held_arch?, do: bytes, else: 0
        {used + bytes, non_reapable + nr_add}

      archive_state in [:pending, "pending", :failed_retryable, "failed_retryable"] ->
        bytes = max(0, int_or_zero(fetch_field(entry, :media_bytes)))
        {used + bytes, non_reapable + bytes}

      true ->
        {used, non_reapable}
    end
  end

  defp build_what_if_warnings(candidate, candidate_estimate, settings, member_proj, object_proj) do
    continuous? = candidate.mode == :continuous
    local_only_effective? = not settings.archive_enabled or candidate.storage == :local_only

    []
    |> maybe_warn(
      continuous? and member_proj.local_projection.below_window_alert?,
      :local_window_below_alert
    )
    |> maybe_warn(member_proj.sessions_exceed_limit?, :sessions_exceed_limit)
    |> maybe_warn(member_proj.throughput_exceeds_measured?, :provider_throughput_exceeds_measured)
    |> maybe_warn(member_proj.local_projection.block_cap_binds?, :block_cap_binds)
    |> maybe_warn(
      continuous? and local_only_effective? and is_nil(settings.local_only_full_policy),
      :local_only_without_full_policy
    )
    |> maybe_warn(
      continuous? and candidate_estimate.basis == :unknown,
      :unknown_profile_bitrate
    )
    |> maybe_warn(object_proj.archiving_paused?, :object_archiving_paused)
    |> Enum.reverse()
  end

  defp maybe_warn(list, true, code), do: [code | list]
  defp maybe_warn(list, _false, _code), do: list

  defp resolve_member_storage_id(nil, opts), do: Keyword.get(opts, :storage_id)

  defp resolve_member_storage_id(member_name, opts) do
    case Keyword.get(opts, :storage_id) do
      sid when is_binary(sid) ->
        sid

      _ ->
        opts
        |> Keyword.get(:storage_id_by_member, %{})
        |> Map.get(member_name)
    end
  end

  defp resolve_member_budget(storage_id, opts, loaders) do
    case Keyword.get(opts, :local_budget_bytes) do
      bytes when is_integer(bytes) and bytes > 0 ->
        bytes

      _ when is_binary(storage_id) ->
        case NVRStorageSettings.get_storage_settings(storage_id,
               actor: @system_actor,
               loaders: loaders
             ) do
          {:ok, %{budget_mode: :custom, budget_bytes: bytes}}
          when is_integer(bytes) and bytes > 0 ->
            bytes

          _ ->
            @default_local_budget_bytes
        end

      _ ->
        @default_local_budget_bytes
    end
  end

  defp resolve_member_pinned_bytes(storage_id, settings, catalog_entries, holds, opts) do
    case Keyword.get(opts, :pinned_bytes) do
      val when is_integer(val) and val >= 0 ->
        val

      _ when is_binary(storage_id) ->
        NVRStorageSettings.pinned_bytes_for_storage(storage_id,
          settings: settings,
          loaders: %{
            catalog_loader: fn -> {:ok, catalog_entries} end,
            holds_loader: fn -> {:ok, holds} end
          }
        ).total_pinned_bytes

      _ ->
        0
    end
  end

  defp resolve_measured_goodput(storage_id, catalog_entries, receipts, opts, now) do
    case Keyword.get(opts, :measured_archive_goodput_bytes_per_sec) do
      gp when is_number(gp) and gp >= 0 ->
        gp * 1.0

      _ ->
        compute_catalog_goodput(storage_id, catalog_entries, receipts, now)
    end
  end

  defp compute_catalog_goodput(storage_id, catalog_entries, receipts, now) do
    cutoff_15m = DateTime.shift(now, second: -@window_15m_seconds)

    receipts_by_id =
      for r <- receipts,
          id = fetch_field(r, :id),
          not is_nil(id),
          into: %{},
          do: {to_string(id), r}

    bytes_15m =
      Enum.reduce(catalog_entries, 0, fn entry, acc ->
        matches_storage? =
          is_nil(storage_id) or
            to_string(fetch_field(entry, :storage_id) || "") == to_string(storage_id)

        archived_at = fetch_field(entry, :archived_at)

        in_window? =
          matches_storage? and
            fetch_field(entry, :archive_state) in [:verified, "verified"] and
            match?(%DateTime{}, archived_at) and
            DateTime.compare(archived_at, cutoff_15m) != :lt

        if in_window? do
          acc + archived_entry_bytes(entry, receipts_by_id)
        else
          acc
        end
      end)

    if bytes_15m > 0, do: bytes_15m / @window_15m_seconds
  end

  defp build_profiles_index(existing_policies, candidate_change, opts, loaders) do
    initial =
      opts
      |> Keyword.get(:profiles, [])
      |> Enum.reduce(%{}, fn prof, acc ->
        put_profile_entry(acc, prof)
      end)

    from_policies =
      Enum.reduce(existing_policies, initial, fn pol, acc ->
        case fetch_field(pol, :stream_profile) do
          %{} = prof -> put_profile_entry(acc, prof)
          _ -> acc
        end
      end)

    candidate_prof_id = fetch_field(candidate_change, :stream_profile_id)

    if not is_nil(candidate_prof_id) and
         not Map.has_key?(from_policies, to_string(candidate_prof_id)) do
      case load_single_profile(candidate_prof_id, loaders) do
        {:ok, %{} = prof} -> put_profile_entry(from_policies, prof)
        _ -> from_policies
      end
    else
      from_policies
    end
  end

  defp put_profile_entry(acc, prof) when is_map(prof) do
    case fetch_field(prof, :id) do
      nil -> acc
      id -> Map.put(acc, to_string(id), prof)
    end
  end

  defp load_single_profile(profile_id, loaders) do
    cond do
      is_function(Map.get(loaders, :profile_loader), 1) ->
        loaders.profile_loader.(profile_id)

      is_function(Map.get(loaders, :profiles_loader), 0) ->
        with {:ok, rows} <- loaders.profiles_loader.() do
          {:ok, Enum.find(rows, &(to_string(fetch_field(&1, :id)) == to_string(profile_id)))}
        end

      map_size(loaders) > 0 ->
        {:ok, nil}

      true ->
        Ash.get(StreamProfile, profile_id, actor: @system_actor, not_found_error?: false)
    end
  end

  defp resolve_policy_estimate(policy, profiles_by_id) do
    explicit_bps =
      positive_int_or(fetch_field(policy, :nominal_bitrate_bps), nil) ||
        positive_int_or(fetch_field(policy, :observed_bitrate_bps), nil)

    if is_integer(explicit_bps) do
      profile_estimate(%{nominal_bitrate_bps: explicit_bps})
    else
      prof =
        fetch_field(policy, :stream_profile) ||
          Map.get(profiles_by_id, to_string(fetch_field(policy, :stream_profile_id) || ""))

      profile_estimate(prof)
    end
  end

  defp normalize_candidate_policy(candidate_change, existing_policies, settings) do
    id = fetch_field(candidate_change, :id)
    cam_id = fetch_field(candidate_change, :camera_source_id)
    prof_id = fetch_field(candidate_change, :stream_profile_id)
    existing = find_matching_policy(existing_policies, id, cam_id, prof_id)

    default_storage = CameraRecordingPolicy.default_storage_for_settings(settings)

    raw_mode = fetch_field(candidate_change, :mode) || (existing && fetch_field(existing, :mode))

    raw_storage =
      fetch_field(candidate_change, :storage) ||
        (existing && fetch_field(existing, :storage)) ||
        default_storage

    raw_override_mode =
      fetch_field(candidate_change, :archive_retention_override_mode) ||
        (existing && fetch_field(existing, :archive_retention_override_mode)) ||
        :inherit

    override_mode = normalize_override_mode(raw_override_mode)

    override_days =
      if override_mode == :limited do
        fetch_field(candidate_change, :archive_retention_days_override) ||
          (existing && fetch_field(existing, :archive_retention_days_override))
      end

    member =
      case fetch_field(candidate_change, :nvr_member) do
        val when is_binary(val) ->
          trimmed = String.trim(val)
          if trimmed == "", do: nil, else: trimmed

        nil ->
          if has_key?(candidate_change, :nvr_member),
            do: nil,
            else: existing && fetch_field(existing, :nvr_member)
      end

    raw_visual_mode =
      fetch_field(candidate_change, :visual_index_mode) ||
        (existing && fetch_field(existing, :visual_index_mode)) ||
        :off

    visual_interval_ms =
      positive_int_or(
        fetch_field(candidate_change, :visual_index_min_interval_ms) ||
          (existing && fetch_field(existing, :visual_index_min_interval_ms)),
        2000
      )

    visual_max_frames =
      positive_int_or(
        fetch_field(candidate_change, :visual_index_max_frames_per_block) ||
          (existing && fetch_field(existing, :visual_index_max_frames_per_block)),
        64
      )

    %{
      id: (existing && fetch_field(existing, :id)) || id || "candidate",
      camera_source_id: cam_id || (existing && fetch_field(existing, :camera_source_id)),
      stream_profile_id: prof_id || (existing && fetch_field(existing, :stream_profile_id)),
      mode: normalize_mode_atom(raw_mode),
      nvr_member: member,
      storage: normalize_storage_atom(raw_storage),
      archive_retention_override_mode: override_mode,
      archive_retention_days_override: override_days,
      visual_index_mode: normalize_visual_index_mode(raw_visual_mode),
      visual_index_min_interval_ms: visual_interval_ms,
      visual_index_max_frames_per_block: visual_max_frames,
      nominal_bitrate_bps: fetch_field(candidate_change, :nominal_bitrate_bps),
      stream_profile:
        fetch_field(candidate_change, :stream_profile) ||
          (existing && fetch_field(existing, :stream_profile))
    }
  end

  defp merge_candidate_into_policies(existing_policies, candidate) do
    {replaced?, updated} =
      Enum.reduce(existing_policies, {false, []}, fn pol, {seen?, acc} ->
        if same_policy_identity?(pol, candidate) do
          {true, [candidate | acc]}
        else
          {seen?, [pol | acc]}
        end
      end)

    list = Enum.reverse(updated)
    if replaced?, do: list, else: list ++ [candidate]
  end

  defp existing_member_for_candidate(existing_policies, candidate) do
    case Enum.find(existing_policies, &same_policy_identity?(&1, candidate)) do
      nil -> nil
      existing -> fetch_field(existing, :nvr_member)
    end
  end

  defp same_policy_identity?(pol, candidate) do
    pol_id = fetch_field(pol, :id)
    cand_id = fetch_field(candidate, :id)

    same_id? =
      not is_nil(pol_id) and not is_nil(cand_id) and cand_id != "candidate" and
        to_string(pol_id) == to_string(cand_id)

    pol_cam = fetch_field(pol, :camera_source_id)
    pol_prof = fetch_field(pol, :stream_profile_id)
    cand_cam = fetch_field(candidate, :camera_source_id)
    cand_prof = fetch_field(candidate, :stream_profile_id)

    same_pair? =
      not is_nil(pol_cam) and not is_nil(pol_prof) and
        to_string(pol_cam) == to_string(cand_cam) and
        to_string(pol_prof) == to_string(cand_prof)

    same_id? or same_pair?
  end

  defp find_matching_policy(rows, id, cam_id, prof_id) when is_list(rows) do
    Enum.find(rows, fn row ->
      same_policy_identity?(row, %{
        id: id,
        camera_source_id: cam_id,
        stream_profile_id: prof_id
      })
    end)
  end

  defp extract_profile_bitrate(profile_or_map) do
    meta =
      case fetch_field(profile_or_map, :metadata) do
        %{} = m -> m
        _ -> %{}
      end

    merged = Map.merge(meta, profile_or_map)

    observed =
      positive_bps_from(merged, [:observed_bitrate_bps, :relay_bitrate_bps]) ||
        positive_kbps_from(merged, [:observed_bitrate_kbps, :relay_bitrate_kbps])

    nominal =
      positive_bps_from(merged, [:nominal_bitrate_bps, :bitrate_bps, :target_bitrate_bps]) ||
        positive_kbps_from(merged, [:nominal_bitrate_kbps, :bitrate_kbps, :target_bitrate_kbps])

    cond do
      is_integer(observed) and observed > 0 -> {observed, :observed}
      is_integer(nominal) and nominal > 0 -> {nominal, :nominal}
      true -> {nil, :unknown}
    end
  end

  defp positive_bps_from(map, keys) do
    Enum.find_value(keys, fn key ->
      positive_int_or(fetch_field(map, key), nil)
    end)
  end

  defp positive_kbps_from(map, keys) do
    Enum.find_value(keys, fn key ->
      case positive_int_or(fetch_field(map, key), nil) do
        kbps when is_integer(kbps) -> kbps * 1_000
        nil -> nil
      end
    end)
  end

  defp deployment_archive_retention(settings) do
    mode = fetch_field(settings, :archive_retention_mode)

    if mode in [:unlimited, "unlimited"] do
      :unlimited
    else
      positive_int_or(fetch_field(settings, :archive_retention_days), 30)
    end
  end

  defp lookup_existing_for_save(attrs) do
    id = fetch_field(attrs, :id)
    cam_id = fetch_field(attrs, :camera_source_id)
    prof_id = fetch_field(attrs, :stream_profile_id)

    cond do
      is_binary(id) and String.trim(id) != "" ->
        Ash.read_one(
          Ash.Query.for_read(CameraRecordingPolicy, :by_id, %{id: id}, actor: @system_actor),
          actor: @system_actor
        )

      is_binary(cam_id) and is_binary(prof_id) and cam_id != "" and prof_id != "" ->
        Ash.read_one(
          Ash.Query.for_read(
            CameraRecordingPolicy,
            :by_camera_profile,
            %{camera_source_id: cam_id, stream_profile_id: prof_id},
            actor: @system_actor
          ),
          actor: @system_actor
        )

      true ->
        {:ok, nil}
    end
  end

  defp maybe_preload_saved({:ok, %CameraRecordingPolicy{} = saved}) do
    case Ash.load(saved, safe_preload_spec(), actor: @system_actor) do
      {:ok, loaded} -> {:ok, loaded}
      _ -> {:ok, saved}
    end
  end

  defp maybe_preload_saved(other), do: other

  defp normalize_override_attrs(attrs) when is_map(attrs) do
    mode = fetch_field(attrs, :archive_retention_override_mode)
    clear? = mode in [:inherit, "inherit", :unlimited, "unlimited"]
    has_days? = has_non_nil_key?(attrs, :archive_retention_days_override)

    if clear? and not has_days? do
      put_matching_key_style(attrs, :archive_retention_days_override, nil)
    else
      attrs
    end
  end

  defp drop_identity_keys(attrs) when is_map(attrs) do
    Map.drop(attrs, [
      :id,
      "id",
      :camera_source_id,
      "camera_source_id",
      :stream_profile_id,
      "stream_profile_id"
    ])
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
        |> preload_safe_relationships()
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ash.read(actor: @system_actor)
    end
  end

  defp preload_safe_relationships(query) do
    Ash.Query.load(query, safe_preload_spec())
  end

  defp safe_preload_spec do
    [
      camera_source: [:id, :device_uid, :display_name, :vendor, :availability_status],
      stream_profile: [
        :id,
        :camera_source_id,
        :profile_name,
        :codec_hint,
        :container_hint,
        :relay_eligible,
        :metadata
      ]
    ]
  end

  defp load_settings(opts, loaders) do
    case Keyword.get(opts, :settings) do
      %RecordingArchiveSettings{} = s ->
        {:ok, s}

      _ ->
        case Map.get(loaders, :settings_loader) do
          loader when is_function(loader, 0) ->
            case loader.() do
              {:ok, nil} -> {:ok, RecordingArchiveSettings.default_settings()}
              {:ok, %{} = s} -> {:ok, s}
              other -> other
            end

          _ when map_size(loaders) > 0 ->
            {:ok, RecordingArchiveSettings.default_settings()}

          _ ->
            RecordingArchiveSettings.get_settings(actor: @system_actor)
        end
    end
  end

  defp load_catalog_entries(loaders) do
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
          :archive_state,
          :nvr_archive_receipt_id,
          :media_bytes,
          :quarantined_bytes,
          :archive_last_error_class,
          :sealed_at,
          :archived_at
        ])
        |> Ash.read(actor: @system_actor)
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

  defp load_receipts(loaders) do
    cond do
      is_function(Map.get(loaders, :all_receipts_loader), 0) ->
        loaders.all_receipts_loader.()

      is_function(Map.get(loaders, :receipts_loader), 0) ->
        loaders.receipts_loader.()

      map_size(loaders) > 0 ->
        {:ok, []}

      true ->
        NVRArchiveReceipt
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.select([
          :id,
          :storage_id,
          :block_key,
          :archive_binding_id,
          :objects,
          :verified_at
        ])
        |> Ash.read(actor: @system_actor)
    end
  end

  defp build_changeset_context(opts) do
    context =
      case Keyword.get(opts, :loaders) do
        loaders when is_map(loaders) -> %{policy_loaders: loaders}
        _ -> %{}
      end

    context =
      case Keyword.get(opts, :now) do
        %DateTime{} = now -> Map.put(context, :policy_now, now)
        _ -> context
      end

    context =
      case Keyword.fetch(opts, :hosted_install?) do
        {:ok, val} -> Map.put(context, :hosted_install?, val)
        :error -> context
      end

    if Keyword.get(opts, :bypass_entitlement_bounds) == true do
      Map.put(context, :bypass_entitlement_bounds, true)
    else
      context
    end
  end

  defp authorize_manage(opts) do
    actor = resolve_actor(opts)

    cond do
      match?(%{role: :system}, actor) ->
        :ok

      ActorHasPermission.match?(actor, [permission: "settings.recording.manage"], %{}) ->
        :ok

      true ->
        {:error, Forbidden.exception([])}
    end
  end

  defp ash_actor_opts(opts) do
    case resolve_actor(opts) do
      nil -> Keyword.take(opts, [:scope])
      actor -> [actor: actor]
    end
  end

  defp resolve_actor(opts) do
    case Keyword.get(opts, :actor) do
      nil -> opts |> Keyword.get(:scope) |> actor_from_scope()
      actor -> actor
    end
  end

  defp actor_from_scope(%{user: user, permissions: %MapSet{} = permissions})
       when not is_nil(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp actor_from_scope(%{actor: actor, permissions: %MapSet{} = permissions})
       when is_map(actor) do
    Map.put(actor, :permissions, permissions)
  end

  defp actor_from_scope(%{user: user}) when not is_nil(user), do: user
  defp actor_from_scope(%{actor: actor}) when not is_nil(actor), do: actor
  defp actor_from_scope(_), do: nil

  defp normalize_mode_atom(val) when val in [:continuous, "continuous"], do: :continuous
  defp normalize_mode_atom(_), do: :off

  defp normalize_storage_atom(val) when val in [:local_and_archive, "local_and_archive"],
    do: :local_and_archive

  defp normalize_storage_atom(_), do: :local_only

  defp normalize_override_mode(val) when val in [:limited, "limited"], do: :limited
  defp normalize_override_mode(val) when val in [:unlimited, "unlimited"], do: :unlimited
  defp normalize_override_mode(_), do: :inherit

  defp normalize_visual_index_mode(val) when val in [:keyframes, "keyframes"], do: :keyframes
  defp normalize_visual_index_mode(_), do: :off

  defp positive_int_or(val, _fallback) when is_integer(val) and val > 0, do: val

  defp positive_int_or(val, fallback) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} when n > 0 -> n
      _ -> fallback
    end
  end

  defp positive_int_or(_, fallback), do: fallback

  defp int_or_zero(val) when is_integer(val), do: val
  defp int_or_zero(val) when is_float(val), do: trunc(val)
  defp int_or_zero(_), do: 0

  defp min_dt(nil, %DateTime{} = dt), do: dt
  defp min_dt(%DateTime{} = dt, nil), do: dt
  defp min_dt(%DateTime{} = a, %DateTime{} = b), do: if(DateTime.after?(a, b), do: b, else: a)
  defp min_dt(a, _b), do: a

  defp has_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end

  defp has_non_nil_key?(attrs, key) do
    str_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> not is_nil(Map.get(attrs, key))
      Map.has_key?(attrs, str_key) -> not is_nil(Map.get(attrs, str_key))
      true -> false
    end
  end

  defp put_matching_key_style(attrs, key, val) do
    if Enum.any?(Map.keys(attrs), &is_binary/1) and not Map.has_key?(attrs, key) do
      Map.put(attrs, Atom.to_string(key), val)
    else
      Map.put(attrs, key, val)
    end
  end

  defp fetch_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
