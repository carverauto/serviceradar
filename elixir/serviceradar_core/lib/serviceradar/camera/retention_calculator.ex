defmodule ServiceRadar.Camera.RetentionCalculator do
  @moduledoc """
  Shared pure retention & capacity calculators (`F.1`, `C1a`, `C3a`, `C5`, `F5`)
  and authorized CNPG usage aggregation for camera recording storage.

  Implements:
  - Piecewise common-cutoff solver `sum_i rate_i * min(limit_i, T) = available`
    used identically by object-tier retention (`C3a`/`F5`) and local-tier
    per-kind effective windows (`C1a`).
  - Per-policy archive byte-rate estimation (`rate_from_history_or_nominal/1`)
    with the `1.02` CMAF/descriptor overhead factor.
  - 3-branch `days_to_capacity/1` (`C3a`) and `archiving_paused?` rules (`V5`).
  - Disjoint pinned-bytes partition (`P1..P5`, `calculate_pinned_bytes/1`),
    local-tier effective window with block-cap detection, and pinned-growth
    `time_to_full_seconds` (`C1a`, `C5`).
  - Authorized CNPG usage summary (`usage_summary/1`) over `NVRArchiveReceipt`
    and `RecordingBlock` plus pure `project_settings/2` for LiveView what-if
    previews.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.CameraRecordingPolicies
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingHold
  alias ServiceRadar.Camera.RecordingHolds

  require Ash.Query

  @seconds_per_day 86_400
  @cmaf_overhead_factor 1.02
  @default_local_budget_bytes 1_073_741_824
  @default_avg_block_bytes 12_582_912
  @window_15m_seconds 900
  @window_6h_seconds 21_600
  @window_24h_seconds 86_400
  @window_7d_seconds 604_800
  @system_actor SystemActor.system(:camera_retention_calculator)

  @type retention_limit :: number() | :unlimited | :infinity
  @type rate_basis :: :measured | :estimated | :unknown

  @doc """
  Solves `sum_i rate_i * min(limit_i, T) = available` piecewise for `T >= 0`.

  Entries are maps carrying `:rate` (`number() >= 0`) and `:limit`
  (`number() | :unlimited | :infinity`). Returns `0.0` when `available <= 0`,
  `:infinity` when every positive-rate entry has a finite limit and the maximum
  sum fits within `available` (or when total positive rate is `0`), and a
  non-negative `float()` otherwise.
  """
  @spec solve_cutoff([%{rate: number(), limit: retention_limit()}], number()) ::
          float() | :infinity
  def solve_cutoff(entries, available) when is_list(entries) and is_number(available) do
    if available <= 0 do
      0.0
    else
      active =
        entries
        |> Enum.map(fn entry ->
          %{
            rate: max(0.0, (fetch_val(entry, :rate) || 0) * 1.0),
            limit: normalize_limit(fetch_val(entry, :limit))
          }
        end)
        |> Enum.filter(&(&1.rate > 0.0))

      do_solve_cutoff(active, available * 1.0)
    end
  end

  defp do_solve_cutoff([], _available), do: :infinity

  defp do_solve_cutoff(active, available) do
    has_unlimited? = Enum.any?(active, &(&1.limit == :unlimited))

    max_finite_sum =
      if has_unlimited? do
        :infinity
      else
        Enum.reduce(active, 0.0, fn %{rate: r, limit: lim}, acc ->
          acc + r * max(0.0, lim * 1.0)
        end)
      end

    if max_finite_sum != :infinity and max_finite_sum <= available do
      :infinity
    else
      breakpoints =
        active
        |> Enum.flat_map(fn
          %{limit: lim} when is_number(lim) and lim > 0 -> [lim * 1.0]
          _ -> []
        end)
        |> Enum.uniq()
        |> Enum.sort()

      walk_breakpoints(breakpoints, active, available, 0.0, 0.0)
    end
  end

  defp walk_breakpoints([], active, available, prev_t, consumed) do
    unlimited_rate =
      active
      |> Enum.filter(&(&1.limit == :unlimited))
      |> Enum.reduce(0.0, &(&1.rate + &2))

    remaining = max(0.0, available - consumed)

    if unlimited_rate > 0.0 do
      prev_t + remaining / unlimited_rate
    else
      :infinity
    end
  end

  defp walk_breakpoints([bp | rest], active, available, prev_t, consumed) do
    slope =
      Enum.reduce(active, 0.0, fn
        %{rate: r, limit: :unlimited}, acc -> acc + r
        %{rate: r, limit: lim}, acc when is_number(lim) and lim > prev_t -> acc + r
        _, acc -> acc
      end)

    span = bp - prev_t
    segment_bytes = slope * span
    remaining = available - consumed

    if slope > 0.0 and segment_bytes >= remaining do
      prev_t + remaining / slope
    else
      walk_breakpoints(rest, active, available, bp, consumed + segment_bytes)
    end
  end

  @doc """
  Computes per-policy archived bytes/day (`C3a`).

  Uses `max(trailing_24h_bytes, trailing_7d_bytes / 7)` (`basis: :measured`) when
  at least 24 hours of history exist (`history_seconds >= 86_400` or
  `has_24h_history?: true`); otherwise `nominal_bitrate_bps * 86_400 / 8 * 1.02`
  (`basis: :estimated`), or `%{bytes_per_day: 0.0, basis: :unknown}` when no
  positive nominal bitrate is available.
  """
  @spec rate_from_history_or_nominal(map() | keyword()) :: %{
          bytes_per_day: float(),
          basis: rate_basis()
        }
  def rate_from_history_or_nominal(input) when is_map(input) or is_list(input) do
    opts = to_map(input)

    has_24h? =
      fetch_val(opts, :has_24h_history?) == true or
        number_or_zero(fetch_val(opts, :history_seconds)) >= @window_24h_seconds or
        number_or_zero(fetch_val(opts, :history_hours)) >= 24

    if has_24h? do
      b24 = max(0.0, number_or_zero(fetch_val(opts, :trailing_24h_bytes)) * 1.0)

      b7_mean =
        case fetch_val(opts, :trailing_7d_daily_mean_bytes) do
          mean when is_number(mean) and mean >= 0 ->
            mean * 1.0

          _ ->
            max(0.0, number_or_zero(fetch_val(opts, :trailing_7d_bytes)) / 7.0)
        end

      %{bytes_per_day: max(b24, b7_mean), basis: :measured}
    else
      bitrate = fetch_val(opts, :nominal_bitrate_bps)

      if is_number(bitrate) and bitrate > 0 do
        bytes_per_day = bitrate * @seconds_per_day / 8.0 * @cmaf_overhead_factor
        %{bytes_per_day: bytes_per_day, basis: :estimated}
      else
        %{bytes_per_day: 0.0, basis: :unknown}
      end
    end
  end

  @doc """
  Computes object-tier `days_to_capacity` (`C3a` 3-branch formula).

  Branches strictly on `object_budget_mode` and the recorded
  `object_capacity_policy` (`nil` behaves as `:stop_archiving`), never on
  current usage.
  """
  @spec days_to_capacity(map() | keyword()) :: float() | :not_filling
  def days_to_capacity(input) when is_map(input) or is_list(input) do
    opts = to_map(input)
    budget_mode = normalize_budget_mode(opts)

    if budget_mode == :unlimited do
      :not_filling
    else
      case normalize_capacity_policy(fetch_val(opts, :object_capacity_policy)) do
        :reap_oldest ->
          growth = number_or_zero(fetch_val(opts, :non_reapable_growth_bytes_per_day)) * 1.0
          high_water = number_or_zero(fetch_val(opts, :high_water_bytes)) * 1.0
          non_reapable = number_or_zero(fetch_val(opts, :non_reapable_bytes)) * 1.0

          if growth <= 0.0 do
            :not_filling
          else
            max(0.0, (high_water - non_reapable) / growth)
          end

        :stop_archiving ->
          rate = number_or_zero(fetch_val(opts, :total_rate_bytes_per_day)) * 1.0
          hard_limit = number_or_zero(fetch_val(opts, :hard_limit_bytes)) * 1.0
          usage = number_or_zero(fetch_val(opts, :usage_bytes)) * 1.0

          if rate <= 0.0 do
            :not_filling
          else
            max(0.0, (hard_limit - usage) / rate)
          end
      end
    end
  end

  @doc """
  Calculates object-tier common cutoff `T`, per-policy effective retention and
  binding bound (`:time | :capacity | :unlimited`), `days_to_capacity`, and
  `archiving_paused?` (`C3a` & `F5`).

  `policies` is a list of maps with:
  - `:id` (optional identifier, defaults to index or `"default"`)
  - `:rate_bytes_per_day` (or `:bytes_per_day` / `:rate`)
  - `:retention_days` (or `:configured_days`: positive number or `:unlimited`)

  `budget_or_opts` accepts either direct `:available_bytes` (for `F5` vectors)
  or budget settings (`:object_budget_mode`, `:object_budget_bytes` /
  `:hard_limit_bytes`, `:object_high_water_percent`, `:object_low_water_percent`,
  `:object_capacity_policy`, `:non_reapable_bytes`, `:used_bytes` /
  `:usage_bytes`, `:non_reapable_growth_bytes_per_day`, `:next_block_bytes`).
  """
  @spec calculate_object_retention([map()], map() | keyword()) :: map()
  def calculate_object_retention(policies, budget_or_opts \\ %{})
      when is_list(policies) and (is_map(budget_or_opts) or is_list(budget_or_opts)) do
    opts = to_map(budget_or_opts)
    budget_mode = normalize_budget_mode(opts)
    normalized_policies = normalize_object_policies(policies)
    total_rate = Enum.reduce(normalized_policies, 0.0, &(&1.rate_bytes_per_day + &2))

    non_reapable = max(0, trunc_or_float(fetch_val(opts, :non_reapable_bytes) || 0))

    usage_bytes =
      max(0, trunc_or_float(fetch_val(opts, :usage_bytes) || fetch_val(opts, :used_bytes) || 0))

    next_block_bytes = max(0, trunc_or_float(fetch_val(opts, :next_block_bytes) || 0))
    recorded_policy = fetch_val(opts, :object_capacity_policy)
    effective_policy = normalize_capacity_policy(recorded_policy)

    if budget_mode == :unlimited do
      policy_results =
        Enum.map(normalized_policies, fn pol ->
          bound = if pol.configured_days == :unlimited, do: :unlimited, else: :time

          %{
            id: pol.id,
            rate_bytes_per_day: pol.rate_bytes_per_day,
            configured_days: pol.configured_days,
            effective_days: pol.configured_days,
            binding_bound: bound
          }
        end)

      %{
        object_budget_mode: :unlimited,
        hard_limit_bytes: nil,
        low_water_bytes: nil,
        high_water_bytes: nil,
        available_bytes: :infinity,
        non_reapable_bytes: non_reapable,
        usage_bytes: usage_bytes,
        total_rate_bytes_per_day: total_rate,
        capacity_days: :infinity,
        policies: policy_results,
        days_to_capacity: :not_filling,
        archiving_paused?: false
      }
    else
      {hard_limit, low_water, high_water, available} =
        resolve_object_watermarks(opts, non_reapable)

      cutoff_t =
        solve_cutoff(
          Enum.map(
            normalized_policies,
            &%{rate: &1.rate_bytes_per_day, limit: &1.configured_days}
          ),
          available
        )

      policy_results = Enum.map(normalized_policies, &project_object_policy(&1, cutoff_t))

      archiving_paused? =
        compute_object_archiving_paused?(
          effective_policy,
          hard_limit,
          high_water,
          non_reapable,
          usage_bytes,
          next_block_bytes
        )

      days_to_cap =
        if is_nil(hard_limit) do
          :not_filling
        else
          days_to_capacity(%{
            object_budget_mode: :limited,
            object_capacity_policy: recorded_policy,
            hard_limit_bytes: hard_limit,
            high_water_bytes: high_water || hard_limit,
            non_reapable_bytes: non_reapable,
            non_reapable_growth_bytes_per_day:
              fetch_val(opts, :non_reapable_growth_bytes_per_day) || 0.0,
            usage_bytes: usage_bytes,
            total_rate_bytes_per_day: total_rate
          })
        end

      %{
        object_budget_mode: :limited,
        hard_limit_bytes: hard_limit,
        low_water_bytes: low_water,
        high_water_bytes: high_water,
        available_bytes: available,
        non_reapable_bytes: non_reapable,
        usage_bytes: usage_bytes,
        total_rate_bytes_per_day: total_rate,
        capacity_days: cutoff_t,
        policies: policy_results,
        days_to_capacity: days_to_cap,
        archiving_paused?: archiving_paused?
      }
    end
  end

  defp project_object_policy(pol, :infinity) do
    bound = if pol.configured_days == :unlimited, do: :unlimited, else: :time

    %{
      id: pol.id,
      rate_bytes_per_day: pol.rate_bytes_per_day,
      configured_days: pol.configured_days,
      effective_days: pol.configured_days,
      binding_bound: bound
    }
  end

  defp project_object_policy(pol, cutoff_t) when is_number(cutoff_t) do
    case pol.configured_days do
      :unlimited ->
        %{
          id: pol.id,
          rate_bytes_per_day: pol.rate_bytes_per_day,
          configured_days: :unlimited,
          effective_days: cutoff_t,
          binding_bound: :capacity
        }

      ret when is_number(ret) ->
        if ret <= cutoff_t do
          %{
            id: pol.id,
            rate_bytes_per_day: pol.rate_bytes_per_day,
            configured_days: ret,
            effective_days: ret,
            binding_bound: :time
          }
        else
          %{
            id: pol.id,
            rate_bytes_per_day: pol.rate_bytes_per_day,
            configured_days: ret,
            effective_days: cutoff_t,
            binding_bound: :capacity
          }
        end
    end
  end

  defp compute_object_archiving_paused?(
         effective_policy,
         hard_limit,
         high_water,
         non_reapable,
         usage_bytes,
         next_block_bytes
       ) do
    held_at_high_water? =
      not is_nil(high_water) and high_water > 0 and non_reapable >= high_water

    stop_limit_reached? =
      effective_policy == :stop_archiving and not is_nil(hard_limit) and hard_limit > 0 and
        ((next_block_bytes > 0 and usage_bytes + next_block_bytes > hard_limit) or
           (next_block_bytes == 0 and usage_bytes >= hard_limit))

    held_at_high_water? or stop_limit_reached?
  end

  defp resolve_object_watermarks(opts, non_reapable) do
    hard_limit =
      fetch_val(opts, :hard_limit_bytes) ||
        fetch_val(opts, :object_budget_bytes)

    high_pct = fetch_val(opts, :object_high_water_percent) || 90
    low_pct = fetch_val(opts, :object_low_water_percent) || 80

    low_water =
      fetch_val(opts, :low_water_bytes) ||
        if(is_number(hard_limit), do: trunc(hard_limit * low_pct / 100))

    high_water =
      fetch_val(opts, :high_water_bytes) ||
        if(is_number(hard_limit), do: trunc(hard_limit * high_pct / 100))

    available =
      case fetch_val(opts, :available_bytes) do
        avail when is_number(avail) -> avail
        _ when is_number(low_water) -> low_water - non_reapable
        _ -> 0
      end

    {hard_limit, low_water, high_water, available}
  end

  @doc """
  Computes the disjoint `C1a` pinned-bytes partition (`P1 + P2 + P3 + P4 + P5`),
  counting each held block at most once (`design.md` `C1a` holds table).
  """
  @spec calculate_pinned_bytes(map() | keyword()) :: %{
          p1: non_neg_integer(),
          p2: non_neg_integer(),
          p3: non_neg_integer(),
          p4: non_neg_integer(),
          p5: non_neg_integer(),
          total_pinned_bytes: non_neg_integer()
        }
  def calculate_pinned_bytes(input) when is_map(input) or is_list(input) do
    opts = to_map(input)
    full_policy = normalize_full_policy(fetch_val(opts, :local_only_full_policy))

    p1 =
      max(0, trunc(number_or_zero(fetch_val(opts, :p1_unarchived_bytes) || fetch_val(opts, :p1))))

    p2 =
      max(
        0,
        trunc(number_or_zero(fetch_val(opts, :p2_unreconciled_bytes) || fetch_val(opts, :p2)))
      )

    kind_b_bytes =
      max(
        0,
        trunc(number_or_zero(fetch_val(opts, :kind_b_local_only_bytes) || fetch_val(opts, :p3)))
      )

    p3 = if full_policy == :stop_when_full, do: kind_b_bytes, else: 0

    held_kind_a_deleted_archive =
      max(0, trunc(number_or_zero(fetch_val(opts, :held_kind_a_local_only_bytes))))

    held_kind_b =
      max(0, trunc(number_or_zero(fetch_val(opts, :held_kind_b_bytes))))

    explicit_p4 =
      max(
        0,
        trunc(number_or_zero(fetch_val(opts, :p4_held_evictable_bytes) || fetch_val(opts, :p4)))
      )

    p4 =
      explicit_p4 + held_kind_a_deleted_archive +
        if(full_policy == :overwrite_oldest, do: held_kind_b, else: 0)

    p5 =
      max(
        0,
        trunc(number_or_zero(fetch_val(opts, :p5_quarantined_bytes) || fetch_val(opts, :p5)))
      )

    %{
      p1: p1,
      p2: p2,
      p3: p3,
      p4: p4,
      p5: p5,
      total_pinned_bytes: p1 + p2 + p3 + p4 + p5
    }
  end

  @doc """
  Computes the local-tier effective window per kind and overall, rate status
  (`:not_recording | :no_recent_ingest | :estimated | :measured`), block-cap
  binding bound, and `C5` pinned-growth `time_to_full_seconds`.
  """
  @spec calculate_local_window(map() | keyword()) :: map()
  def calculate_local_window(input) when is_map(input) or is_list(input) do
    opts = to_map(input)

    budget =
      max(
        0,
        trunc(
          number_or_zero(fetch_val(opts, :effective_budget_bytes) || @default_local_budget_bytes)
        )
      )

    high_pct = fetch_val(opts, :local_high_water_percent) || 90
    low_pct = fetch_val(opts, :local_low_water_percent) || 80

    low_water =
      case fetch_val(opts, :low_water_bytes) do
        val when is_number(val) -> val
        _ -> trunc(budget * low_pct / 100)
      end

    high_water =
      case fetch_val(opts, :high_water_bytes) do
        val when is_number(val) -> val
        _ -> trunc(budget * high_pct / 100)
      end

    pinned_bytes = resolve_pinned_bytes(opts)
    full_policy = normalize_full_policy(fetch_val(opts, :local_only_full_policy))

    {rate_status, archived_rate, local_only_rate} = resolve_local_rates(opts)
    total_rate = archived_rate + local_only_rate

    max_local_age =
      resolve_age_limit(opts, :max_local_age_mode, :max_local_age_seconds, :limited, 86_400)

    local_only_max_age =
      resolve_age_limit(
        opts,
        :local_only_max_age_mode,
        :local_only_max_age_seconds,
        :unlimited,
        nil
      )

    evictable_specs =
      build_evictable_specs(
        archived_rate,
        max_local_age,
        local_only_rate,
        local_only_max_age,
        full_policy
      )

    t_low = solve_cutoff(evictable_specs, low_water - pinned_bytes)
    t_high = solve_cutoff(evictable_specs, high_water - pinned_bytes)

    kinds =
      build_kind_windows(
        archived_rate,
        max_local_age,
        local_only_rate,
        local_only_max_age,
        full_policy,
        t_low,
        t_high
      )

    {block_cap_binds?, block_cap_seconds, kinds} =
      apply_block_cap(opts, kinds, total_rate)

    {primary_low, primary_high, primary_bound} =
      summarize_primary_window(
        rate_status,
        kinds,
        opts,
        block_cap_binds?,
        block_cap_seconds,
        low_water,
        high_water,
        pinned_bytes,
        total_rate
      )

    ttf =
      compute_local_time_to_full(
        opts,
        budget,
        pinned_bytes,
        archived_rate,
        local_only_rate,
        full_policy,
        local_only_max_age
      )

    alert_threshold =
      resolve_age_limit(
        opts,
        :local_window_alert_mode,
        :local_window_alert_seconds,
        :enabled,
        3_600
      )

    below_alert? =
      rate_status in [:measured, :estimated] and
        is_integer(alert_threshold) and
        is_number(primary_low) and
        primary_low < alert_threshold

    %{
      status: rate_status,
      rate_bytes_per_sec: total_rate,
      archived_rate_bytes_per_sec: archived_rate,
      local_only_rate_bytes_per_sec: local_only_rate,
      effective_budget_bytes: budget,
      low_water_bytes: low_water,
      high_water_bytes: high_water,
      pinned_bytes: pinned_bytes,
      window_low_seconds: primary_low,
      window_high_seconds: primary_high,
      binding_bound: primary_bound,
      block_cap_binds?: block_cap_binds?,
      block_cap_seconds: block_cap_seconds,
      below_window_alert?: below_alert?,
      time_to_full_seconds: ttf,
      kinds: kinds
    }
  end

  defp resolve_pinned_bytes(opts) do
    case fetch_val(opts, :pinned_bytes) do
      val when is_number(val) and val >= 0 ->
        val

      _ ->
        calculate_pinned_bytes(opts).total_pinned_bytes
    end
  end

  defp resolve_local_rates(opts) do
    enabled_policies = fetch_val(opts, :enabled_policy_count)
    recording_enabled? = fetch_val(opts, :recording_enabled?)

    if enabled_policies == 0 or recording_enabled? == false do
      {:not_recording, 0.0, 0.0}
    else
      do_resolve_active_local_rates(opts)
    end
  end

  defp do_resolve_active_local_rates(opts) do
    archived_explicit = fetch_val(opts, :archived_rate_bytes_per_sec)
    local_only_explicit = fetch_val(opts, :local_only_rate_bytes_per_sec)

    if is_number(archived_explicit) or is_number(local_only_explicit) do
      ar = max(0.0, number_or_zero(archived_explicit) * 1.0)
      lr = max(0.0, number_or_zero(local_only_explicit) * 1.0)
      status = if ar + lr > 0.0, do: :measured, else: :no_recent_ingest
      {status, ar, lr}
    else
      r15 = max(0.0, number_or_zero(fetch_val(opts, :r15m_bytes_per_sec)) * 1.0)
      r6h = max(0.0, number_or_zero(fetch_val(opts, :r6h_bytes_per_sec)) * 1.0)
      history_sec = fetch_val(opts, :history_seconds)
      est_bps = fetch_val(opts, :estimated_bitrate_bps) || fetch_val(opts, :nominal_bitrate_bps)
      est_rate = if is_number(est_bps) and est_bps > 0, do: est_bps / 8.0, else: 0.0

      {status, rate} =
        classify_single_rate(r15, r6h, history_sec, est_rate)

      storage_mode = fetch_val(opts, :storage_mode) || :local_only

      if storage_mode == :local_and_archive do
        {status, rate, 0.0}
      else
        {status, 0.0, rate}
      end
    end
  end

  defp classify_single_rate(r15, r6h, history_sec, est_rate) do
    short_history? = is_number(history_sec) and history_sec < @window_15m_seconds

    cond do
      short_history? and est_rate > 0.0 ->
        {:estimated, est_rate}

      r15 > 0.0 ->
        {:measured, max(r15, r6h)}

      r6h > 0.0 ->
        {:no_recent_ingest, r6h}

      est_rate > 0.0 ->
        {:estimated, est_rate}

      true ->
        {:no_recent_ingest, 0.0}
    end
  end

  defp build_evictable_specs(
         archived_rate,
         max_local_age,
         local_only_rate,
         local_only_max_age,
         full_policy
       ) do
    specs =
      if archived_rate > 0.0 do
        [%{kind: :archived, rate: archived_rate, limit: max_local_age}]
      else
        []
      end

    if full_policy == :overwrite_oldest and local_only_rate > 0.0 do
      specs ++ [%{kind: :local_only, rate: local_only_rate, limit: local_only_max_age}]
    else
      specs
    end
  end

  defp build_kind_windows(
         archived_rate,
         max_local_age,
         local_only_rate,
         local_only_max_age,
         full_policy,
         t_low,
         t_high
       ) do
    archived_map =
      if archived_rate > 0.0 do
        %{archived: evictable_kind_window(archived_rate, max_local_age, t_low, t_high)}
      else
        %{}
      end

    local_only_map =
      cond do
        local_only_rate <= 0.0 ->
          %{}

        full_policy == :overwrite_oldest ->
          %{local_only: evictable_kind_window(local_only_rate, local_only_max_age, t_low, t_high)}

        local_only_max_age == :unlimited ->
          %{
            local_only: %{
              rate_bytes_per_sec: local_only_rate,
              age_ceiling: :unlimited,
              window_low_seconds: :until_policy_or_age_changes,
              window_high_seconds: :until_policy_or_age_changes,
              binding_bound: :pinned
            }
          }

        true ->
          %{
            local_only: %{
              rate_bytes_per_sec: local_only_rate,
              age_ceiling: local_only_max_age,
              window_low_seconds: local_only_max_age * 1.0,
              window_high_seconds: local_only_max_age * 1.0,
              binding_bound: :max_age
            }
          }
      end

    Map.merge(archived_map, local_only_map)
  end

  defp evictable_kind_window(rate, age_ceiling, t_low, t_high) do
    low = cap_window(age_ceiling, t_low)
    high = cap_window(age_ceiling, t_high)

    bound =
      cond do
        age_ceiling != :unlimited and (t_low == :infinity or age_ceiling <= t_low) ->
          :max_age

        t_low == :infinity ->
          :unlimited_budget

        true ->
          :budget
      end

    %{
      rate_bytes_per_sec: rate,
      age_ceiling: age_ceiling,
      window_low_seconds: low,
      window_high_seconds: high,
      binding_bound: bound
    }
  end

  defp cap_window(:unlimited, :infinity), do: :infinity
  defp cap_window(:unlimited, t) when is_number(t), do: t * 1.0
  defp cap_window(age, :infinity) when is_number(age), do: age * 1.0
  defp cap_window(age, t) when is_number(age) and is_number(t), do: min(age * 1.0, t * 1.0)

  defp apply_block_cap(opts, kinds, total_rate) do
    max_blocks = fetch_val(opts, :max_blocks)

    if is_integer(max_blocks) and max_blocks > 0 and total_rate > 0.0 and map_size(kinds) > 0 do
      avg_block = fetch_val(opts, :avg_block_bytes) || @default_avg_block_bytes
      explicit_block_rates = fetch_val(opts, :kind_block_rates_per_sec) || %{}
      overall_block_rate = fetch_val(opts, :block_rate_per_sec)

      entries =
        Enum.map(kinds, fn {kind_key, info} ->
          br =
            cond do
              is_number(Map.get(explicit_block_rates, kind_key)) ->
                Map.get(explicit_block_rates, kind_key) * 1.0

              is_number(overall_block_rate) and map_size(kinds) == 1 ->
                overall_block_rate * 1.0

              is_number(avg_block) and avg_block > 0 ->
                info.rate_bytes_per_sec / avg_block

              true ->
                0.0
            end

          high_sec =
            case info.window_high_seconds do
              s when is_number(s) -> s
              _ -> :unlimited
            end

          plateau_blocks =
            case high_sec do
              s when is_number(s) -> br * s
              :unlimited -> :infinity
            end

          {kind_key, br, high_sec, plateau_blocks}
        end)

      projected_blocks =
        Enum.reduce(entries, 0.0, fn
          {_, _, _, :infinity}, _acc -> :infinity
          {_, _, _, _}, :infinity -> :infinity
          {_, _, _, pb}, acc -> acc + pb
        end)

      if projected_blocks == :infinity or projected_blocks > max_blocks do
        stop_seconds =
          solve_cutoff(
            Enum.map(entries, fn {_, br, high_sec, _} -> %{rate: br, limit: high_sec} end),
            max_blocks
          )

        updated_kinds =
          Map.new(kinds, fn {k, v} -> {k, %{v | binding_bound: :block_cap}} end)

        {true, stop_seconds, updated_kinds}
      else
        {false, nil, kinds}
      end
    else
      {false, nil, kinds}
    end
  end

  defp summarize_primary_window(
         :not_recording,
         _kinds,
         _opts,
         _cap_binds?,
         _cap_sec,
         _low_water,
         _high_water,
         _pinned,
         _total_rate
       ) do
    {0.0, 0.0, :not_recording}
  end

  defp summarize_primary_window(
         _status,
         kinds,
         opts,
         block_cap_binds?,
         block_cap_seconds,
         low_water,
         high_water,
         pinned_bytes,
         total_rate
       ) do
    storage_mode = fetch_val(opts, :storage_mode) || :local_only
    preferred_key = if storage_mode == :local_and_archive, do: :archived, else: :local_only

    primary =
      Map.get(kinds, preferred_key) ||
        Map.get(kinds, :archived) ||
        Map.get(kinds, :local_only)

    cond do
      block_cap_binds? ->
        low_s =
          if primary && is_number(primary.window_low_seconds),
            do: min(primary.window_low_seconds, block_cap_seconds),
            else: block_cap_seconds

        high_s =
          if primary && is_number(primary.window_high_seconds),
            do: min(primary.window_high_seconds, block_cap_seconds),
            else: block_cap_seconds

        {low_s, high_s, :block_cap}

      not is_nil(primary) ->
        {primary.window_low_seconds, primary.window_high_seconds, primary.binding_bound}

      total_rate > 0.0 ->
        {max(0.0, low_water - pinned_bytes) / total_rate,
         max(0.0, high_water - pinned_bytes) / total_rate, :budget}

      true ->
        {0.0, 0.0, :no_recent_ingest}
    end
  end

  defp compute_local_time_to_full(
         opts,
         budget,
         pinned_bytes,
         archived_rate,
         local_only_rate,
         full_policy,
         local_only_max_age
       ) do
    archive_goodput =
      case fetch_val(opts, :archive_goodput_bytes_per_sec) do
        gp when is_number(gp) and gp >= 0 -> gp * 1.0
        _ -> archived_rate
      end

    p1_growth = max(0.0, archived_rate - archive_goodput)
    p3_growth = if full_policy == :stop_when_full, do: local_only_rate, else: 0.0
    pinned_growth = p1_growth + p3_growth

    current_p3 =
      max(
        0.0,
        number_or_zero(
          fetch_val(opts, :current_p3_bytes) || fetch_val(opts, :kind_b_local_only_bytes) ||
            pinned_bytes
        ) * 1.0
      )

    ceiling_caps_growth? =
      p1_growth == 0.0 and p3_growth > 0.0 and is_number(local_only_max_age) and
        pinned_bytes - min(pinned_bytes * 1.0, current_p3) +
          max(current_p3, p3_growth * local_only_max_age) <= budget

    if pinned_growth <= 0.0 or ceiling_caps_growth? do
      :not_filling
    else
      max(0.0, (budget - pinned_bytes) / pinned_growth)
    end
  end

  @doc """
  Pure projection helper for LiveView `phx-change` what-if recalculations.

  Accepts any `RecordingArchiveSettings` struct or draft map plus optional
  usage/simulator inputs (`:archive_used_bytes`, `:trailing_24h_bytes`,
  `:trailing_7d_daily_mean_bytes`, `:history_seconds`, `:camera_count`,
  `:nominal_bitrate_bps`, `:local_budget_bytes`, `:pinned_bytes`,
  `:non_reapable_bytes`, `:max_blocks`, `:avg_block_bytes`). Performs zero DB I/O.
  """
  @spec project_settings(map(), map() | keyword()) :: map()
  def project_settings(settings_or_attrs, sim_or_usage \\ %{})
      when is_map(settings_or_attrs) and (is_map(sim_or_usage) or is_list(sim_or_usage)) do
    opts = to_map(sim_or_usage)
    camera_count = max(0, trunc(number_or_zero(fetch_val(opts, :camera_count) || 1)))
    per_camera_bps = number_or_zero(fetch_val(opts, :nominal_bitrate_bps))
    total_nominal_bps = if camera_count > 0, do: per_camera_bps * camera_count, else: 0

    rate_info =
      rate_from_history_or_nominal(%{
        history_seconds: fetch_val(opts, :history_seconds) || 0,
        trailing_24h_bytes: fetch_val(opts, :trailing_24h_bytes) || 0,
        trailing_7d_daily_mean_bytes: fetch_val(opts, :trailing_7d_daily_mean_bytes),
        trailing_7d_bytes: fetch_val(opts, :trailing_7d_bytes) || 0,
        nominal_bitrate_bps: total_nominal_bps
      })

    archive_mode = normalize_mode(fetch_val(settings_or_attrs, :archive_retention_mode), :limited)

    configured_days =
      if archive_mode == :unlimited do
        :unlimited
      else
        fetch_val(settings_or_attrs, :archive_retention_days) || 30
      end

    object_budget_mode =
      normalize_mode(fetch_val(settings_or_attrs, :object_budget_mode), :unlimited)

    object_projection =
      calculate_object_retention(
        [
          %{
            id: "deployment",
            rate_bytes_per_day: rate_info.bytes_per_day,
            retention_days: configured_days
          }
        ],
        %{
          object_budget_mode: object_budget_mode,
          object_budget_bytes: fetch_val(settings_or_attrs, :object_budget_bytes),
          object_high_water_percent:
            fetch_val(settings_or_attrs, :object_high_water_percent) || 90,
          object_low_water_percent: fetch_val(settings_or_attrs, :object_low_water_percent) || 80,
          object_capacity_policy: fetch_val(settings_or_attrs, :object_capacity_policy),
          non_reapable_bytes: fetch_val(opts, :non_reapable_bytes) || 0,
          usage_bytes: fetch_val(opts, :archive_used_bytes) || fetch_val(opts, :usage_bytes) || 0,
          non_reapable_growth_bytes_per_day:
            fetch_val(opts, :non_reapable_growth_bytes_per_day) || 0.0
        }
      )

    archive_enabled? = fetch_val(settings_or_attrs, :archive_enabled) in [true, "true"]
    has_binding? = not is_nil(fetch_val(settings_or_attrs, :active_archive_binding_id))

    storage_mode =
      fetch_val(opts, :storage_mode) ||
        if(archive_enabled? and has_binding?, do: :local_and_archive, else: :local_only)

    local_projection =
      calculate_local_window(%{
        storage_mode: storage_mode,
        effective_budget_bytes:
          fetch_val(opts, :local_budget_bytes) ||
            fetch_val(opts, :effective_budget_bytes) ||
            @default_local_budget_bytes,
        local_high_water_percent: fetch_val(settings_or_attrs, :local_high_water_percent) || 90,
        local_low_water_percent: fetch_val(settings_or_attrs, :local_low_water_percent) || 80,
        max_local_age_mode:
          normalize_mode(fetch_val(settings_or_attrs, :max_local_age_mode), :limited),
        max_local_age_seconds: fetch_val(settings_or_attrs, :max_local_age_seconds),
        local_window_alert_mode:
          normalize_mode(fetch_val(settings_or_attrs, :local_window_alert_mode), :enabled),
        local_window_alert_seconds: fetch_val(settings_or_attrs, :local_window_alert_seconds),
        local_only_full_policy: fetch_val(settings_or_attrs, :local_only_full_policy),
        local_only_max_age_mode:
          normalize_mode(fetch_val(settings_or_attrs, :local_only_max_age_mode), :unlimited),
        local_only_max_age_seconds: fetch_val(settings_or_attrs, :local_only_max_age_seconds),
        pinned_bytes: fetch_val(opts, :pinned_bytes) || 0,
        r15m_bytes_per_sec: fetch_val(opts, :r15m_bytes_per_sec) || 0.0,
        r6h_bytes_per_sec: fetch_val(opts, :r6h_bytes_per_sec) || 0.0,
        history_seconds: fetch_val(opts, :local_history_seconds) || 0,
        estimated_bitrate_bps: total_nominal_bps,
        enabled_policy_count: fetch_val(opts, :enabled_policy_count) || camera_count,
        max_blocks: fetch_val(opts, :max_blocks),
        avg_block_bytes: fetch_val(opts, :avg_block_bytes)
      })

    %{
      rate: rate_info,
      object_projection: object_projection,
      local_projection: local_projection,
      shorter_archive_than_local?:
        RecordingArchiveSettings.shorter_archive_than_local?(settings_or_attrs),
      effective_local_only_full_policy:
        RecordingArchiveSettings.effective_local_only_full_policy(settings_or_attrs),
      effective_object_capacity_policy:
        RecordingArchiveSettings.effective_object_capacity_policy(settings_or_attrs)
    }
  end

  @doc """
  Reads live CNPG `ArchiveBinding`, `RecordingCatalogEntry`, `NVRArchiveReceipt`,
  and `RecordingBlock` rows under `settings.recording.view | manage | operate`
  authorization and returns usage totals (grouped across all retained bindings
  sharing `{endpoint, bucket}` with the active binding per `C3a`, with other
  buckets reported separately) together with calculated object and local
  retention projections.
  """
  @spec usage_summary(keyword()) :: {:ok, map()} | {:error, term()}
  def usage_summary(opts \\ []) when is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- RecordingArchiveSettings.authorize_recording_read(opts),
         {:ok, settings} <- load_settings_for_summary(opts, loaders),
         {:ok, bindings} <- load_bindings_for_summary(settings.active_archive_binding_id, loaders),
         {:ok, receipts} <- load_all_receipts(settings.active_archive_binding_id, loaders),
         {:ok, catalog_entries} <- load_catalog_entries(loaders),
         {:ok, accepted_holds} <- load_accepted_holds(loaders),
         {:ok, policies} <- load_policies_for_summary(loaders),
         {:ok, blocks} <- load_reserved_blocks(loaders) do
      archive_stats =
        aggregate_object_usage(
          bindings,
          catalog_entries,
          receipts,
          accepted_holds,
          settings.active_archive_binding_id,
          now
        )

      block_stats = aggregate_blocks_and_catalog(blocks, catalog_entries, accepted_holds, now)
      avg_block_bytes = estimate_avg_block_bytes(archive_stats, block_stats)

      policy_summary =
        summarize_policies_for_usage(policies, settings, catalog_entries, receipts, now)

      {r15m_bps, r6h_bps, local_history_sec} =
        resolve_summary_local_rates(block_stats, avg_block_bytes)

      default_pinned =
        calculate_pinned_bytes(%{
          local_only_full_policy: settings.local_only_full_policy,
          p1_unarchived_bytes: block_stats.unarchived_local_bytes,
          kind_b_local_only_bytes: block_stats.kind_b_local_only_bytes,
          held_kind_b_bytes: block_stats.held_kind_b_bytes,
          held_kind_a_local_only_bytes: block_stats.held_kind_a_local_only_bytes,
          p5_quarantined_bytes: block_stats.quarantined_local_bytes
        }).total_pinned_bytes

      holds_summary = %{
        active_hold_count: count_accepted_holds(accepted_holds),
        held_archive_bytes: archive_stats.held_archive_bytes,
        held_local_pinned_bytes: block_stats.held_local_pinned_bytes,
        held_archive_missing_count: block_stats.held_archive_missing_count
      }

      has_activity? =
        policy_summary.continuous_count > 0 or
          block_stats.total_reserved_blocks > 0 or
          block_stats.cataloged_block_count > 0 or
          archive_stats.archived_block_count > 0 or
          archive_stats.uploads_in_flight_count > 0

      default_cameras =
        if policy_summary.continuous_count > 0,
          do: policy_summary.continuous_count,
          else: if(has_activity?, do: 1, else: 0)

      default_per_camera_bps =
        if policy_summary.continuous_count > 0,
          do: div(policy_summary.total_nominal_bitrate_bps, policy_summary.continuous_count),
          else: 0

      non_reapable =
        Keyword.get(opts, :non_reapable_bytes, archive_stats.catalog_non_reapable_bytes)

      sim_inputs = %{
        archive_used_bytes: archive_stats.archive_used_bytes,
        trailing_24h_bytes: archive_stats.trailing_24h_bytes,
        trailing_7d_bytes: archive_stats.trailing_7d_bytes,
        trailing_7d_daily_mean_bytes: archive_stats.trailing_7d_daily_mean_bytes,
        history_seconds: archive_stats.history_seconds,
        local_history_seconds: local_history_sec,
        r15m_bytes_per_sec: r15m_bps,
        r6h_bytes_per_sec: r6h_bps,
        camera_count: Keyword.get(opts, :camera_count, default_cameras),
        nominal_bitrate_bps: Keyword.get(opts, :nominal_bitrate_bps, default_per_camera_bps),
        local_budget_bytes: Keyword.get(opts, :local_budget_bytes, @default_local_budget_bytes),
        pinned_bytes: Keyword.get(opts, :pinned_bytes, default_pinned),
        non_reapable_bytes: non_reapable,
        max_blocks: Keyword.get(opts, :max_blocks),
        avg_block_bytes: avg_block_bytes
      }

      projected = project_settings(settings, sim_inputs)

      {object_projection, measured_rate_bpd, rate_basis} =
        maybe_apply_policy_object_projection(
          policy_summary,
          settings,
          archive_stats,
          non_reapable,
          projected,
          opts
        )

      {:ok,
       %{
         settings: settings,
         archive:
           Map.merge(archive_stats, %{
             measured_rate_bytes_per_day: measured_rate_bpd,
             rate_basis: rate_basis
           }),
         local_blocks: block_stats,
         holds: holds_summary,
         policies: Map.delete(policy_summary, :archiving_specs),
         object_projection: object_projection,
         local_projection: projected.local_projection,
         shorter_archive_than_local?: projected.shorter_archive_than_local?,
         object_retention_enforced?: not is_nil(settings.retention_credential_secret_id)
       }}
    end
  end

  defp load_settings_for_summary(opts, loaders) do
    case Keyword.get(opts, :settings) do
      %RecordingArchiveSettings{} = settings ->
        {:ok, settings}

      _ ->
        case Map.get(loaders, :settings_loader) do
          loader when is_function(loader, 0) ->
            case loader.() do
              {:ok, nil} -> {:ok, RecordingArchiveSettings.default_settings()}
              {:ok, %RecordingArchiveSettings{} = s} -> {:ok, s}
              other -> other
            end

          _ ->
            RecordingArchiveSettings.get_settings(actor: @system_actor)
        end
    end
  end

  defp load_bindings_for_summary(active_binding_id, loaders) do
    case Map.get(loaders, :bindings_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ when map_size(loaders) > 0 ->
        if is_nil(active_binding_id) do
          {:ok, []}
        else
          {:ok,
           [
             %{
               id: active_binding_id,
               endpoint: "https://objects.example.com",
               bucket: "default-bucket",
               namespace: "recordings/v1"
             }
           ]}
        end

      _ ->
        ArchiveBinding
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.select([:id, :endpoint, :bucket, :namespace, :provisioning_ref, :generation])
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_all_receipts(active_binding_id, loaders) do
    cond do
      is_function(Map.get(loaders, :all_receipts_loader), 0) ->
        loaders.all_receipts_loader.()

      is_function(Map.get(loaders, :receipts_loader), 0) ->
        loaders.receipts_loader.()

      is_function(Map.get(loaders, :receipts_loader), 1) ->
        if is_nil(active_binding_id) do
          {:ok, []}
        else
          case loaders.receipts_loader.(active_binding_id) do
            {:ok, rows} when is_list(rows) ->
              {:ok, Enum.map(rows, &ensure_receipt_binding(&1, active_binding_id))}

            other ->
              other
          end
        end

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
          :recording_block_id,
          :objects,
          :verified_at
        ])
        |> Ash.read(actor: @system_actor)
    end
  end

  defp ensure_receipt_binding(receipt, active_binding_id) when is_map(receipt) do
    if is_nil(fetch_val(receipt, :archive_binding_id)) do
      Map.put(receipt, :archive_binding_id, active_binding_id)
    else
      receipt
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
          :recording_block_id,
          :camera_source_id,
          :stream_profile_id,
          :storage_id,
          :block_key,
          :timeline_start_us,
          :timeline_end_us,
          :local_state,
          :archive_state,
          :archive_deleted_reason,
          :archive_binding_id,
          :quarantine_binding_id,
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

  defp count_accepted_holds(holds) when is_list(holds) do
    Enum.count(holds, fn hold ->
      is_map(hold) and fetch_val(hold, :state) in [:accepted, "accepted", nil]
    end)
  end

  defp load_reserved_blocks(loaders) do
    case Map.get(loaders, :blocks_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ when map_size(loaders) > 0 ->
        {:ok, []}

      _ ->
        RecordingBlock
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.select([:id, :storage_id, :state, :inserted_at])
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_policies_for_summary(loaders) do
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

  defp summarize_policies_for_usage(policies, settings, catalog_entries, receipts, now) do
    continuous =
      Enum.filter(policies, &(fetch_val(&1, :mode) in [:continuous, "continuous"]))

    archiving =
      if settings.archive_enabled do
        Enum.filter(
          continuous,
          &(fetch_val(&1, :storage) in [:local_and_archive, "local_and_archive"])
        )
      else
        []
      end

    local_only_count = length(continuous) - length(archiving)

    total_nominal_bps =
      Enum.reduce(continuous, 0, fn pol, acc ->
        est = policy_nominal_estimate(pol)
        acc + (est.bitrate_bps || 0)
      end)

    by_member =
      continuous
      |> Enum.group_by(&(fetch_val(&1, :nvr_member) || "unassigned"))
      |> Map.new(fn {member, rows} -> {member, length(rows)} end)

    receipts_by_id =
      for r <- receipts,
          id = fetch_val(r, :id),
          not is_nil(id),
          into: %{},
          do: {to_string(id), r}

    archiving_specs =
      Enum.map(archiving, fn pol ->
        est = policy_nominal_estimate(pol)

        rate_info =
          compute_policy_archive_rate(pol, est.bitrate_bps, catalog_entries, receipts_by_id, now)

        configured_days = CameraRecordingPolicies.resolve_policy_archive_retention(pol, settings)

        %{
          id: to_string(fetch_val(pol, :id) || "policy"),
          camera_source_id: fetch_val(pol, :camera_source_id),
          stream_profile_id: fetch_val(pol, :stream_profile_id),
          nvr_member: fetch_val(pol, :nvr_member),
          archive_retention_override_mode:
            fetch_val(pol, :archive_retention_override_mode) || :inherit,
          archive_retention_days_override: fetch_val(pol, :archive_retention_days_override),
          rate_bytes_per_day: rate_info.bytes_per_day,
          rate_basis: rate_info.basis,
          retention_days: configured_days
        }
      end)

    %{
      total_count: length(policies),
      continuous_count: length(continuous),
      archiving_count: length(archiving),
      local_only_count: local_only_count,
      total_nominal_bitrate_bps: total_nominal_bps,
      by_member: by_member,
      archiving_specs: archiving_specs
    }
  end

  defp policy_nominal_estimate(pol) do
    case fetch_val(pol, :nominal_bitrate_bps) || fetch_val(pol, :observed_bitrate_bps) do
      bps when is_integer(bps) and bps > 0 ->
        CameraRecordingPolicies.profile_estimate(%{nominal_bitrate_bps: bps})

      _ ->
        CameraRecordingPolicies.profile_estimate(fetch_val(pol, :stream_profile))
    end
  end

  defp compute_policy_archive_rate(pol, nominal_bps, catalog_entries, receipts_by_id, now) do
    cam_id = to_string(fetch_val(pol, :camera_source_id) || "")
    prof_id = to_string(fetch_val(pol, :stream_profile_id) || "")
    cutoff_24h = DateTime.shift(now, second: -@window_24h_seconds)
    cutoff_7d = DateTime.shift(now, second: -@window_7d_seconds)

    matching =
      Enum.filter(catalog_entries, fn entry ->
        normalize_atom_state(fetch_val(entry, :local_state)) != :quarantined and
          normalize_atom_state(fetch_val(entry, :archive_state)) in [:verified, :deleting] and
          to_string(fetch_val(entry, :camera_source_id) || "") == cam_id and
          to_string(fetch_val(entry, :stream_profile_id) || "") == prof_id
      end)

    {oldest, b24, b7} =
      Enum.reduce(matching, {nil, 0, 0}, fn entry, {old_acc, s24, s7} ->
        rid = fetch_val(entry, :nvr_archive_receipt_id)
        receipt = rid && Map.get(receipts_by_id, to_string(rid))
        {bytes, _} = receipt_or_media_bytes(receipt, fetch_val(entry, :media_bytes), 3)
        ts = fetch_val(entry, :archived_at) || fetch_val(entry, :sealed_at)
        in_24? = match?(%DateTime{}, ts) and DateTime.compare(ts, cutoff_24h) != :lt
        in_7? = match?(%DateTime{}, ts) and DateTime.compare(ts, cutoff_7d) != :lt

        {min_datetime(old_acc, ts), s24 + if(in_24?, do: bytes, else: 0),
         s7 + if(in_7?, do: bytes, else: 0)}
      end)

    history_sec =
      case oldest do
        %DateTime{} = dt -> max(0, DateTime.diff(now, dt, :second))
        _ -> 0
      end

    rate_from_history_or_nominal(%{
      history_seconds: history_sec,
      trailing_24h_bytes: b24,
      trailing_7d_bytes: b7,
      nominal_bitrate_bps: nominal_bps
    })
  end

  defp maybe_apply_policy_object_projection(
         %{archiving_specs: specs},
         settings,
         archive_stats,
         non_reapable,
         projected,
         opts
       )
       when specs != [] do
    if Keyword.has_key?(opts, :camera_count) or Keyword.has_key?(opts, :nominal_bitrate_bps) do
      {projected.object_projection, projected.rate.bytes_per_day, projected.rate.basis}
    else
      calc =
        calculate_object_retention(specs, %{
          object_budget_mode: settings.object_budget_mode,
          object_budget_bytes: settings.object_budget_bytes,
          object_high_water_percent: settings.object_high_water_percent || 90,
          object_low_water_percent: settings.object_low_water_percent || 80,
          object_capacity_policy: settings.object_capacity_policy,
          non_reapable_bytes: non_reapable,
          usage_bytes: archive_stats.archive_used_bytes,
          non_reapable_growth_bytes_per_day:
            Keyword.get(opts, :non_reapable_growth_bytes_per_day, 0.0)
        })

      specs_by_id = Map.new(specs, &{&1.id, &1})

      enriched =
        Enum.map(calc.policies, fn p ->
          meta = Map.get(specs_by_id, to_string(p.id), %{})

          Map.merge(p, %{
            camera_source_id: Map.get(meta, :camera_source_id),
            stream_profile_id: Map.get(meta, :stream_profile_id),
            nvr_member: Map.get(meta, :nvr_member),
            archive_retention_override_mode: Map.get(meta, :archive_retention_override_mode),
            archive_retention_days_override: Map.get(meta, :archive_retention_days_override),
            rate_basis: Map.get(meta, :rate_basis, :unknown)
          })
        end)

      basis =
        cond do
          Enum.any?(specs, &(&1.rate_basis == :measured)) -> :measured
          Enum.any?(specs, &(&1.rate_basis == :estimated)) -> :estimated
          true -> projected.rate.basis
        end

      total_rate =
        if calc.total_rate_bytes_per_day > 0.0,
          do: calc.total_rate_bytes_per_day,
          else: projected.rate.bytes_per_day

      {%{calc | policies: enriched}, total_rate, basis}
    end
  end

  defp maybe_apply_policy_object_projection(
         _policy_summary,
         _settings,
         _archive_stats,
         _non_reapable,
         projected,
         _opts
       ) do
    {projected.object_projection, projected.rate.bytes_per_day, projected.rate.basis}
  end

  defp aggregate_object_usage(
         bindings,
         catalog_entries,
         receipts,
         accepted_holds,
         active_binding_id,
         now
       ) do
    bindings_by_id =
      Map.new(bindings, fn b ->
        {to_string(fetch_val(b, :id)), b}
      end)

    {active_bucket, same_bucket_ids} =
      resolve_same_bucket_bindings(bindings, bindings_by_id, active_binding_id)

    items = build_object_usage_items(catalog_entries, receipts, accepted_holds)

    {same_items, other_items} =
      Enum.split_with(items, &MapSet.member?(same_bucket_ids, &1.binding_id))

    same_acc = summarize_same_bucket_items(same_items, now)
    other_buckets = summarize_other_bucket_items(other_items, bindings_by_id)
    other_used_bytes = Enum.reduce(other_buckets, 0, &(&1.used_bytes + &2))

    Map.merge(same_acc, %{
      active_archive_binding_id: active_binding_id,
      active_bucket: active_bucket,
      same_bucket_binding_ids: same_bucket_ids |> MapSet.to_list() |> Enum.sort(),
      same_bucket_binding_count: MapSet.size(same_bucket_ids),
      other_buckets: other_buckets,
      other_buckets_count: length(other_buckets),
      other_buckets_used_bytes: other_used_bytes
    })
  end

  defp resolve_same_bucket_bindings(_bindings, _bindings_by_id, nil) do
    {nil, MapSet.new()}
  end

  defp resolve_same_bucket_bindings(bindings, bindings_by_id, active_binding_id) do
    active_id_str = to_string(active_binding_id)

    case Map.get(bindings_by_id, active_id_str) do
      nil ->
        {nil, MapSet.new([active_id_str])}

      active_b ->
        endpoint = fetch_val(active_b, :endpoint)
        bucket = fetch_val(active_b, :bucket)

        if is_binary(endpoint) and is_binary(bucket) do
          matching_ids =
            for b <- bindings,
                fetch_val(b, :endpoint) == endpoint and fetch_val(b, :bucket) == bucket,
                into: MapSet.new([active_id_str]),
                do: to_string(fetch_val(b, :id))

          {%{endpoint: endpoint, bucket: bucket}, matching_ids}
        else
          {nil, MapSet.new([active_id_str])}
        end
    end
  end

  defp build_object_usage_items(catalog_entries, receipts, accepted_holds) do
    receipts_by_id =
      for r <- receipts,
          id = fetch_val(r, :id),
          not is_nil(id),
          into: %{},
          do: {to_string(id), r}

    receipts_by_copy =
      for r <- receipts,
          sid = fetch_val(r, :storage_id),
          bkey = fetch_val(r, :block_key),
          bid = fetch_val(r, :archive_binding_id),
          not is_nil(sid) and not is_nil(bkey) and not is_nil(bid),
          into: %{},
          do: {{to_string(sid), to_string(bkey), to_string(bid)}, r}

    cataloged_pairs =
      for entry <- catalog_entries,
          sid = fetch_val(entry, :storage_id),
          bkey = fetch_val(entry, :block_key),
          not is_nil(sid) and not is_nil(bkey),
          into: MapSet.new(),
          do: {to_string(sid), to_string(bkey)}

    catalog_items =
      Enum.flat_map(
        catalog_entries,
        &catalog_entry_object_items(&1, receipts_by_id, receipts_by_copy, accepted_holds)
      )

    fallback_items =
      for r <- receipts,
          not receipt_covered_by_catalog?(r, cataloged_pairs),
          bid = fetch_val(r, :archive_binding_id),
          not is_nil(bid) do
        objects = List.wrap(fetch_val(r, :objects))

        %{
          kind: :verified_or_deleting,
          binding_id: to_string(bid),
          bytes: sum_receipt_object_bytes(objects),
          object_count: length(objects),
          timestamp: fetch_val(r, :verified_at),
          blocked_by_provider?: false,
          held_archive?: false
        }
      end

    catalog_items ++ fallback_items
  end

  defp receipt_covered_by_catalog?(receipt, cataloged_pairs) do
    sid = fetch_val(receipt, :storage_id)
    bkey = fetch_val(receipt, :block_key)

    not is_nil(sid) and not is_nil(bkey) and
      MapSet.member?(cataloged_pairs, {to_string(sid), to_string(bkey)})
  end

  defp catalog_entry_object_items(entry, receipts_by_id, receipts_by_copy, accepted_holds) do
    local_state = normalize_atom_state(fetch_val(entry, :local_state))
    archive_state = normalize_atom_state(fetch_val(entry, :archive_state))

    if local_state == :quarantined do
      quarantine_entry_object_items(entry, archive_state, receipts_by_id, receipts_by_copy)
    else
      sealed_entry_object_items(
        entry,
        archive_state,
        receipts_by_id,
        receipts_by_copy,
        accepted_holds
      )
    end
  end

  defp sealed_entry_object_items(
         entry,
         archive_state,
         receipts_by_id,
         receipts_by_copy,
         accepted_holds
       ) do
    binding_id = fetch_val(entry, :archive_binding_id)

    cond do
      is_nil(binding_id) ->
        []

      archive_state in [:verified, :deleting] ->
        receipt = lookup_entry_receipt(entry, binding_id, receipts_by_id, receipts_by_copy)
        {bytes, obj_count} = receipt_or_media_bytes(receipt, fetch_val(entry, :media_bytes), 3)

        ts =
          fetch_val(entry, :archived_at) ||
            (receipt && fetch_val(receipt, :verified_at)) ||
            fetch_val(entry, :sealed_at)

        held_archive? =
          archive_state == :verified and
            Enum.any?(accepted_holds, &entity_protected_by_hold?(&1, entry))

        [
          %{
            kind: :verified_or_deleting,
            binding_id: to_string(binding_id),
            bytes: bytes,
            object_count: obj_count,
            timestamp: ts,
            blocked_by_provider?:
              fetch_val(entry, :archive_last_error_class) == "blocked_by_provider",
            held_archive?: held_archive?
          }
        ]

      archive_state in [:pending, :failed_retryable] ->
        bytes = max(0, trunc(number_or_zero(fetch_val(entry, :media_bytes))))

        [
          %{
            kind: :in_flight,
            binding_id: to_string(binding_id),
            bytes: bytes,
            object_count: 0,
            timestamp: nil,
            blocked_by_provider?: false,
            held_archive?: false
          }
        ]

      true ->
        []
    end
  end

  defp quarantine_entry_object_items(entry, archive_state, receipts_by_id, receipts_by_copy) do
    q_binding_id = fetch_val(entry, :quarantine_binding_id)
    fallback_bytes = fetch_val(entry, :quarantined_bytes) || fetch_val(entry, :media_bytes)

    cond do
      is_nil(q_binding_id) ->
        []

      archive_state in [:verified, :deleting] ->
        receipt = lookup_entry_receipt(entry, q_binding_id, receipts_by_id, receipts_by_copy)
        {bytes, obj_count} = receipt_or_media_bytes(receipt, fallback_bytes, 1)

        [
          %{
            kind: :quarantine,
            binding_id: to_string(q_binding_id),
            bytes: bytes,
            object_count: obj_count,
            timestamp: fetch_val(entry, :archived_at),
            blocked_by_provider?: false,
            held_archive?: false
          }
        ]

      archive_state in [:pending, :failed_retryable] ->
        bytes = max(0, trunc(number_or_zero(fallback_bytes)))

        [
          %{
            kind: :in_flight,
            binding_id: to_string(q_binding_id),
            bytes: bytes,
            object_count: 0,
            timestamp: nil,
            blocked_by_provider?: false,
            held_archive?: false
          }
        ]

      true ->
        []
    end
  end

  defp lookup_entry_receipt(entry, binding_id, receipts_by_id, receipts_by_copy) do
    rid = fetch_val(entry, :nvr_archive_receipt_id)
    sid = fetch_val(entry, :storage_id)
    bkey = fetch_val(entry, :block_key)

    cond do
      not is_nil(rid) and Map.has_key?(receipts_by_id, to_string(rid)) ->
        Map.get(receipts_by_id, to_string(rid))

      not is_nil(sid) and not is_nil(bkey) ->
        Map.get(receipts_by_copy, {to_string(sid), to_string(bkey), to_string(binding_id)})

      true ->
        nil
    end
  end

  defp receipt_or_media_bytes(nil, fallback_bytes, default_objects) do
    {max(0, trunc(number_or_zero(fallback_bytes))), default_objects}
  end

  defp receipt_or_media_bytes(receipt, _fallback_bytes, _default_objects) do
    objects = List.wrap(fetch_val(receipt, :objects))
    {sum_receipt_object_bytes(objects), length(objects)}
  end

  defp summarize_same_bucket_items(items, now) do
    cutoff_24h = DateTime.shift(now, second: -@window_24h_seconds)
    cutoff_7d = DateTime.shift(now, second: -@window_7d_seconds)

    acc =
      Enum.reduce(
        items,
        %{
          verified_bytes: 0,
          in_flight_bytes: 0,
          in_flight_count: 0,
          quarantine_bytes: 0,
          blocked_bytes: 0,
          held_archive_bytes: 0,
          held_archive_count: 0,
          non_reapable_verified_bytes: 0,
          block_count: 0,
          object_count: 0,
          oldest: nil,
          newest: nil,
          b24: 0,
          b7: 0
        },
        fn item, st ->
          accumulate_same_bucket_item(item, st, cutoff_24h, cutoff_7d)
        end
      )

    history_seconds =
      case acc.oldest do
        %DateTime{} = oldest -> max(0, DateTime.diff(now, oldest, :second))
        _ -> 0
      end

    total_used = acc.verified_bytes + acc.in_flight_bytes + acc.quarantine_bytes
    non_reapable = acc.non_reapable_verified_bytes + acc.in_flight_bytes + acc.quarantine_bytes

    %{
      archive_used_bytes: total_used,
      verified_and_deleting_bytes: acc.verified_bytes,
      uploads_in_flight_bytes: acc.in_flight_bytes,
      uploads_in_flight_count: acc.in_flight_count,
      quarantine_object_bytes: acc.quarantine_bytes,
      blocked_by_provider_bytes: acc.blocked_bytes,
      held_archive_bytes: acc.held_archive_bytes,
      held_archive_block_count: acc.held_archive_count,
      catalog_non_reapable_bytes: non_reapable,
      archived_block_count: acc.block_count,
      archived_object_count: acc.object_count,
      oldest_verified_at: acc.oldest,
      newest_verified_at: acc.newest,
      history_seconds: history_seconds,
      trailing_24h_bytes: acc.b24,
      trailing_7d_bytes: acc.b7,
      trailing_7d_daily_mean_bytes: acc.b7 / 7.0
    }
  end

  defp accumulate_same_bucket_item(
         %{kind: :verified_or_deleting} = item,
         st,
         cutoff_24h,
         cutoff_7d
       ) do
    ts = item.timestamp
    in_24h? = match?(%DateTime{}, ts) and DateTime.compare(ts, cutoff_24h) != :lt
    in_7d? = match?(%DateTime{}, ts) and DateTime.compare(ts, cutoff_7d) != :lt
    non_reapable_item? = item.blocked_by_provider? or item.held_archive?

    %{
      st
      | verified_bytes: st.verified_bytes + item.bytes,
        blocked_bytes: st.blocked_bytes + if(item.blocked_by_provider?, do: item.bytes, else: 0),
        held_archive_bytes:
          st.held_archive_bytes + if(item.held_archive?, do: item.bytes, else: 0),
        held_archive_count: st.held_archive_count + if(item.held_archive?, do: 1, else: 0),
        non_reapable_verified_bytes:
          st.non_reapable_verified_bytes + if(non_reapable_item?, do: item.bytes, else: 0),
        block_count: st.block_count + 1,
        object_count: st.object_count + item.object_count,
        oldest: min_datetime(st.oldest, ts),
        newest: max_datetime(st.newest, ts),
        b24: st.b24 + if(in_24h?, do: item.bytes, else: 0),
        b7: st.b7 + if(in_7d?, do: item.bytes, else: 0)
    }
  end

  defp accumulate_same_bucket_item(%{kind: :in_flight} = item, st, _cutoff_24h, _cutoff_7d) do
    %{
      st
      | in_flight_bytes: st.in_flight_bytes + item.bytes,
        in_flight_count: st.in_flight_count + 1
    }
  end

  defp accumulate_same_bucket_item(%{kind: :quarantine} = item, st, _cutoff_24h, _cutoff_7d) do
    %{
      st
      | quarantine_bytes: st.quarantine_bytes + item.bytes,
        object_count: st.object_count + item.object_count
    }
  end

  defp summarize_other_bucket_items([], _bindings_by_id), do: []

  defp summarize_other_bucket_items(other_items, bindings_by_id) do
    other_items
    |> Enum.group_by(fn item ->
      case Map.get(bindings_by_id, item.binding_id) do
        nil ->
          {"unknown", item.binding_id}

        b ->
          {fetch_val(b, :endpoint) || "unknown", fetch_val(b, :bucket) || item.binding_id}
      end
    end)
    |> Enum.map(fn {{endpoint, bucket}, bucket_items} ->
      acc =
        Enum.reduce(
          bucket_items,
          %{
            binding_ids: MapSet.new(),
            verified_bytes: 0,
            in_flight_bytes: 0,
            quarantine_bytes: 0,
            block_count: 0,
            object_count: 0
          },
          fn item, st ->
            accumulate_other_bucket_item(item, st)
          end
        )

      used = acc.verified_bytes + acc.in_flight_bytes + acc.quarantine_bytes

      %{
        endpoint: endpoint,
        bucket: bucket,
        binding_ids: acc.binding_ids |> MapSet.to_list() |> Enum.sort(),
        binding_count: MapSet.size(acc.binding_ids),
        used_bytes: used,
        verified_and_deleting_bytes: acc.verified_bytes,
        uploads_in_flight_bytes: acc.in_flight_bytes,
        quarantine_object_bytes: acc.quarantine_bytes,
        archived_block_count: acc.block_count,
        archived_object_count: acc.object_count
      }
    end)
    |> Enum.filter(&(&1.used_bytes > 0 or &1.archived_block_count > 0))
    |> Enum.sort_by(&{&1.endpoint, &1.bucket})
  end

  defp accumulate_other_bucket_item(item, st) do
    next_ids = MapSet.put(st.binding_ids, item.binding_id)

    case item.kind do
      :verified_or_deleting ->
        %{
          st
          | binding_ids: next_ids,
            verified_bytes: st.verified_bytes + item.bytes,
            block_count: st.block_count + 1,
            object_count: st.object_count + item.object_count
        }

      :in_flight ->
        %{st | binding_ids: next_ids, in_flight_bytes: st.in_flight_bytes + item.bytes}

      :quarantine ->
        %{
          st
          | binding_ids: next_ids,
            quarantine_bytes: st.quarantine_bytes + item.bytes,
            object_count: st.object_count + item.object_count
        }
    end
  end

  defp sum_receipt_object_bytes(objects) do
    Enum.reduce(objects, 0, fn obj, acc ->
      len = if is_map(obj), do: fetch_val(obj, :length) || 0, else: 0
      if is_integer(len) and len > 0, do: acc + len, else: acc
    end)
  end

  defp aggregate_blocks_and_catalog(blocks, catalog_entries, accepted_holds, now) do
    base = aggregate_blocks(blocks, now)
    catalog = aggregate_catalog_local(catalog_entries, accepted_holds, now)

    merged_by_storage =
      Map.merge(base.by_storage, catalog.by_storage, fn _sid, b_info, c_info ->
        Map.merge(b_info, c_info)
      end)

    Map.merge(base, %{
      by_storage: merged_by_storage,
      cataloged_block_count: catalog.cataloged_block_count,
      local_present_blocks: catalog.local_present_blocks,
      local_present_bytes: catalog.local_present_bytes,
      unarchived_local_count: catalog.unarchived_local_count,
      unarchived_local_bytes: catalog.unarchived_local_bytes,
      kind_b_local_only_bytes: catalog.kind_b_local_only_bytes,
      held_local_pinned_count: catalog.held_local_pinned_count,
      held_local_pinned_bytes: catalog.held_local_pinned_bytes,
      held_kind_b_bytes: catalog.held_kind_b_bytes,
      held_kind_a_local_only_bytes: catalog.held_kind_a_local_only_bytes,
      held_archive_missing_count: catalog.held_archive_missing_count,
      quarantined_local_count: catalog.quarantined_local_count,
      quarantined_local_bytes: catalog.quarantined_local_bytes,
      local_only_after_archive_count: catalog.local_only_after_archive_count,
      local_only_after_archive_bytes: catalog.local_only_after_archive_bytes,
      oldest_local_only_after_archive_at: catalog.oldest_local_only_after_archive_at,
      trailing_15m_catalog_bytes: catalog.trailing_15m_bytes,
      trailing_6h_catalog_bytes: catalog.trailing_6h_bytes,
      catalog_r15m_bytes_per_sec: catalog.trailing_15m_bytes / @window_15m_seconds,
      catalog_r6h_bytes_per_sec: catalog.trailing_6h_bytes / @window_6h_seconds,
      catalog_history_seconds: catalog.history_seconds
    })
  end

  defp aggregate_catalog_local(catalog_entries, accepted_holds, now) do
    cutoff_15m = DateTime.shift(now, second: -@window_15m_seconds)
    cutoff_6h = DateTime.shift(now, second: -@window_6h_seconds)

    acc =
      Enum.reduce(
        catalog_entries,
        %{
          count: 0,
          present_blocks: 0,
          present_bytes: 0,
          unarchived_count: 0,
          unarchived_bytes: 0,
          kind_b_bytes: 0,
          held_local_count: 0,
          held_local_bytes: 0,
          held_kind_b_bytes: 0,
          held_kind_a_bytes: 0,
          held_archive_missing_count: 0,
          quarantined_count: 0,
          quarantined_bytes: 0,
          after_archive_count: 0,
          after_archive_bytes: 0,
          oldest_after_archive: nil,
          oldest_sealed: nil,
          b15m: 0,
          b6h: 0,
          by_storage: %{}
        },
        fn entry, st ->
          accumulate_catalog_local_entry(entry, st, accepted_holds, cutoff_15m, cutoff_6h)
        end
      )

    history_seconds =
      case acc.oldest_sealed do
        %DateTime{} = oldest -> max(0, DateTime.diff(now, oldest, :second))
        _ -> 0
      end

    by_storage =
      Map.new(acc.by_storage, fn {sid, s} ->
        {sid,
         Map.merge(s, %{
           catalog_r15m_bytes_per_sec: s.trailing_15m_catalog_bytes / @window_15m_seconds,
           catalog_r6h_bytes_per_sec: s.trailing_6h_catalog_bytes / @window_6h_seconds
         })}
      end)

    %{
      cataloged_block_count: acc.count,
      local_present_blocks: acc.present_blocks,
      local_present_bytes: acc.present_bytes,
      unarchived_local_count: acc.unarchived_count,
      unarchived_local_bytes: acc.unarchived_bytes,
      kind_b_local_only_bytes: acc.kind_b_bytes,
      held_local_pinned_count: acc.held_local_count,
      held_local_pinned_bytes: acc.held_local_bytes,
      held_kind_b_bytes: acc.held_kind_b_bytes,
      held_kind_a_local_only_bytes: acc.held_kind_a_bytes,
      held_archive_missing_count: acc.held_archive_missing_count,
      quarantined_local_count: acc.quarantined_count,
      quarantined_local_bytes: acc.quarantined_bytes,
      local_only_after_archive_count: acc.after_archive_count,
      local_only_after_archive_bytes: acc.after_archive_bytes,
      oldest_local_only_after_archive_at: acc.oldest_after_archive,
      trailing_15m_bytes: acc.b15m,
      trailing_6h_bytes: acc.b6h,
      history_seconds: history_seconds,
      by_storage: by_storage
    }
  end

  defp accumulate_catalog_local_entry(entry, st, accepted_holds, cutoff_15m, cutoff_6h) do
    local_state = normalize_atom_state(fetch_val(entry, :local_state))
    archive_state = normalize_atom_state(fetch_val(entry, :archive_state))
    media_bytes = max(0, trunc(number_or_zero(fetch_val(entry, :media_bytes))))
    q_bytes = max(0, trunc(number_or_zero(fetch_val(entry, :quarantined_bytes))))
    sealed_at = fetch_val(entry, :sealed_at)
    sid = to_string(fetch_val(entry, :storage_id) || "unknown")

    in_15m? =
      local_state != :quarantined and match?(%DateTime{}, sealed_at) and
        DateTime.compare(sealed_at, cutoff_15m) != :lt

    in_6h? =
      local_state != :quarantined and match?(%DateTime{}, sealed_at) and
        DateTime.compare(sealed_at, cutoff_6h) != :lt

    present? = local_state == :present
    quarantined? = local_state == :quarantined
    held? = not quarantined? and Enum.any?(accepted_holds, &entity_protected_by_hold?(&1, entry))
    pinned_copy = if held?, do: RecordingHolds.pinned_copy_for_entry(entry)
    held_local_pinned? = present? and pinned_copy == :local
    held_kind_b? = held_local_pinned? and archive_state == :not_required
    held_kind_a_deleted? = held_local_pinned? and archive_state == :deleted
    held_archive_missing? = held? and archive_state == :missing

    pinned_kind_c? =
      present? and
        archive_state in [
          :awaiting_binding,
          :pending,
          :failed_retryable,
          :failed_terminal,
          :deleting,
          :missing
        ]

    kind_b? = present? and archive_state == :not_required
    after_archive? = present? and archive_state == :deleted

    prev_s =
      Map.get(st.by_storage, sid, %{
        total_blocks: 0,
        trailing_15m_blocks: 0,
        trailing_6h_blocks: 0,
        cataloged_blocks: 0,
        local_present_bytes: 0,
        unarchived_local_bytes: 0,
        held_local_pinned_bytes: 0,
        quarantined_local_bytes: 0,
        trailing_15m_catalog_bytes: 0,
        trailing_6h_catalog_bytes: 0
      })

    next_s =
      Map.merge(prev_s, %{
        cataloged_blocks: Map.get(prev_s, :cataloged_blocks, 0) + 1,
        local_present_bytes:
          Map.get(prev_s, :local_present_bytes, 0) + if(present?, do: media_bytes, else: 0),
        unarchived_local_bytes:
          Map.get(prev_s, :unarchived_local_bytes, 0) +
            if(pinned_kind_c?, do: media_bytes, else: 0),
        held_local_pinned_bytes:
          Map.get(prev_s, :held_local_pinned_bytes, 0) +
            if(held_local_pinned?, do: media_bytes, else: 0),
        quarantined_local_bytes:
          Map.get(prev_s, :quarantined_local_bytes, 0) + if(quarantined?, do: q_bytes, else: 0),
        trailing_15m_catalog_bytes:
          Map.get(prev_s, :trailing_15m_catalog_bytes, 0) + if(in_15m?, do: media_bytes, else: 0),
        trailing_6h_catalog_bytes:
          Map.get(prev_s, :trailing_6h_catalog_bytes, 0) + if(in_6h?, do: media_bytes, else: 0)
      })

    %{
      count: st.count + 1,
      present_blocks: st.present_blocks + if(present?, do: 1, else: 0),
      present_bytes: st.present_bytes + if(present?, do: media_bytes, else: 0),
      unarchived_count: st.unarchived_count + if(pinned_kind_c?, do: 1, else: 0),
      unarchived_bytes: st.unarchived_bytes + if(pinned_kind_c?, do: media_bytes, else: 0),
      kind_b_bytes: st.kind_b_bytes + if(kind_b?, do: media_bytes, else: 0),
      held_local_count: st.held_local_count + if(held_local_pinned?, do: 1, else: 0),
      held_local_bytes: st.held_local_bytes + if(held_local_pinned?, do: media_bytes, else: 0),
      held_kind_b_bytes: st.held_kind_b_bytes + if(held_kind_b?, do: media_bytes, else: 0),
      held_kind_a_bytes:
        st.held_kind_a_bytes + if(held_kind_a_deleted?, do: media_bytes, else: 0),
      held_archive_missing_count:
        st.held_archive_missing_count + if(held_archive_missing?, do: 1, else: 0),
      quarantined_count: st.quarantined_count + if(quarantined?, do: 1, else: 0),
      quarantined_bytes: st.quarantined_bytes + if(quarantined?, do: q_bytes, else: 0),
      after_archive_count: st.after_archive_count + if(after_archive?, do: 1, else: 0),
      after_archive_bytes: st.after_archive_bytes + if(after_archive?, do: media_bytes, else: 0),
      oldest_after_archive:
        if(after_archive?,
          do: min_datetime(st.oldest_after_archive, sealed_at),
          else: st.oldest_after_archive
        ),
      oldest_sealed:
        if(quarantined?, do: st.oldest_sealed, else: min_datetime(st.oldest_sealed, sealed_at)),
      b15m: st.b15m + if(in_15m?, do: media_bytes, else: 0),
      b6h: st.b6h + if(in_6h?, do: media_bytes, else: 0),
      by_storage: Map.put(st.by_storage, sid, next_s)
    }
  end

  defp entity_protected_by_hold?(hold, entry) when is_map(hold) and is_map(entry) do
    normalized_hold =
      if is_nil(fetch_val(hold, :state)),
        do: Map.put(hold, :state, :accepted),
        else: hold

    RecordingHolds.hold_protects_entry?(normalized_hold, entry)
  end

  defp resolve_summary_local_rates(%{cataloged_block_count: c_count} = stats, _avg_block_bytes)
       when c_count > 0 do
    {
      stats.catalog_r15m_bytes_per_sec,
      stats.catalog_r6h_bytes_per_sec,
      max(stats.history_seconds, stats.catalog_history_seconds)
    }
  end

  defp resolve_summary_local_rates(stats, avg_block_bytes) do
    {
      stats.trailing_15m_blocks * avg_block_bytes / @window_15m_seconds,
      stats.trailing_6h_blocks * avg_block_bytes / @window_6h_seconds,
      stats.history_seconds
    }
  end

  defp aggregate_blocks(blocks, now) do
    cutoff_15m = DateTime.shift(now, second: -@window_15m_seconds)
    cutoff_6h = DateTime.shift(now, second: -@window_6h_seconds)

    acc =
      Enum.reduce(
        blocks,
        %{total: 0, c15m: 0, c6h: 0, oldest: nil, by_storage: %{}},
        fn block, st ->
          inserted_at = fetch_val(block, :inserted_at)
          sid = to_string(fetch_val(block, :storage_id) || "unknown")

          in_15m? =
            match?(%DateTime{}, inserted_at) and DateTime.compare(inserted_at, cutoff_15m) != :lt

          in_6h? =
            match?(%DateTime{}, inserted_at) and DateTime.compare(inserted_at, cutoff_6h) != :lt

          prev_s =
            Map.get(st.by_storage, sid, %{
              total_blocks: 0,
              trailing_15m_blocks: 0,
              trailing_6h_blocks: 0
            })

          next_s = %{
            total_blocks: prev_s.total_blocks + 1,
            trailing_15m_blocks: prev_s.trailing_15m_blocks + if(in_15m?, do: 1, else: 0),
            trailing_6h_blocks: prev_s.trailing_6h_blocks + if(in_6h?, do: 1, else: 0)
          }

          %{
            total: st.total + 1,
            c15m: st.c15m + if(in_15m?, do: 1, else: 0),
            c6h: st.c6h + if(in_6h?, do: 1, else: 0),
            oldest: min_datetime(st.oldest, inserted_at),
            by_storage: Map.put(st.by_storage, sid, next_s)
          }
        end
      )

    history_seconds =
      case acc.oldest do
        %DateTime{} = oldest -> max(0, DateTime.diff(now, oldest, :second))
        _ -> 0
      end

    %{
      total_reserved_blocks: acc.total,
      trailing_15m_blocks: acc.c15m,
      trailing_6h_blocks: acc.c6h,
      history_seconds: history_seconds,
      by_storage: acc.by_storage
    }
  end

  defp estimate_avg_block_bytes(_archive_stats, %{
         local_present_blocks: p_count,
         local_present_bytes: p_bytes
       })
       when p_count > 0 and p_bytes > 0 do
    div(p_bytes, p_count)
  end

  defp estimate_avg_block_bytes(
         %{archived_block_count: count, verified_and_deleting_bytes: bytes},
         _block_stats
       )
       when count > 0 and bytes > 0 do
    div(bytes, count)
  end

  defp estimate_avg_block_bytes(_, _), do: @default_avg_block_bytes

  defp normalize_atom_state(val) when is_atom(val), do: val

  defp normalize_atom_state(val) when is_binary(val) do
    Enum.find(
      RecordingCatalogEntry.local_states() ++ RecordingCatalogEntry.archive_states(),
      &(Atom.to_string(&1) == val)
    )
  end

  defp normalize_atom_state(_), do: nil

  defp min_datetime(nil, %DateTime{} = dt), do: dt
  defp min_datetime(%DateTime{} = dt, nil), do: dt

  defp min_datetime(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.after?(a, b), do: b, else: a
  end

  defp min_datetime(a, _b), do: a

  defp max_datetime(nil, %DateTime{} = dt), do: dt
  defp max_datetime(%DateTime{} = dt, nil), do: dt

  defp max_datetime(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.before?(a, b), do: b, else: a
  end

  defp max_datetime(a, _b), do: a

  defp normalize_object_policies(policies) do
    policies
    |> Enum.with_index(1)
    |> Enum.map(fn {pol, idx} ->
      rate =
        fetch_val(pol, :rate_bytes_per_day) ||
          fetch_val(pol, :bytes_per_day) ||
          fetch_val(pol, :rate) || 0

      raw_ret =
        case fetch_val(pol, :retention_days) do
          nil -> fetch_val(pol, :configured_days)
          val -> val
        end

      %{
        id: fetch_val(pol, :id) || "policy-#{idx}",
        rate_bytes_per_day: max(0.0, rate * 1.0),
        configured_days: normalize_limit(raw_ret)
      }
    end)
  end

  defp resolve_age_limit(opts, mode_key, val_key, default_mode, default_val) do
    mode = normalize_mode(fetch_val(opts, mode_key), default_mode)

    if mode in [:unlimited, :disabled, :none] do
      :unlimited
    else
      case fetch_val(opts, val_key) do
        v when is_integer(v) and v > 0 -> v
        _ -> default_val || :unlimited
      end
    end
  end

  defp normalize_budget_mode(opts) do
    case fetch_val(opts, :object_budget_mode) do
      mode when mode in [:unlimited, "unlimited"] ->
        :unlimited

      mode when mode in [:limited, "limited"] ->
        :limited

      _ ->
        if is_number(fetch_val(opts, :available_bytes)) or
             is_number(fetch_val(opts, :hard_limit_bytes)) or
             is_number(fetch_val(opts, :object_budget_bytes)) do
          :limited
        else
          :unlimited
        end
    end
  end

  defp normalize_capacity_policy(val) when val in [:reap_oldest, "reap_oldest"], do: :reap_oldest
  defp normalize_capacity_policy(_), do: :stop_archiving

  defp normalize_full_policy(val) when val in [:overwrite_oldest, "overwrite_oldest"],
    do: :overwrite_oldest

  defp normalize_full_policy(_), do: :stop_when_full

  defp normalize_mode(val, _default) when val in [:limited, "limited"], do: :limited
  defp normalize_mode(val, _default) when val in [:unlimited, "unlimited"], do: :unlimited
  defp normalize_mode(val, _default) when val in [:enabled, "enabled"], do: :enabled
  defp normalize_mode(val, _default) when val in [:disabled, "disabled"], do: :disabled
  defp normalize_mode(val, _default) when val in [:target, "target"], do: :target
  defp normalize_mode(val, _default) when val in [:none, "none"], do: :none
  defp normalize_mode(_, default), do: default

  defp normalize_limit(val) when val in [:unlimited, "unlimited", :infinity, "infinity", nil],
    do: :unlimited

  defp normalize_limit(val) when is_number(val), do: val

  defp number_or_zero(val) when is_number(val), do: val
  defp number_or_zero(_), do: 0

  defp trunc_or_float(val) when is_integer(val), do: val
  defp trunc_or_float(val) when is_float(val), do: val
  defp trunc_or_float(_), do: 0

  defp to_map(val) when is_map(val), do: val
  defp to_map(val) when is_list(val), do: Map.new(val)

  defp fetch_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
