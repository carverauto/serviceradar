defmodule ServiceRadar.DeclarativeChecks.PostureEvaluators do
  @moduledoc """
  Closed compile-time registry of first-party Core `platform_posture` evaluators
  shipping Built-in Pack #1 (`io.serviceradar.storage-and-nvr-health`) for PR #6760 (`2.3`).

  Evaluators:
  1. `storage.entitlement_utilization`
  2. `storage.hold_pin_pressure`
  3. `storage.archive_credential_and_usage_health`
  4. `camera.continuous_recording_silence`

  Every evaluator is read-only, runs under a narrow system actor when querying CNPG,
  accepts injectable `:loaders` for hermetic `:db_free` unit tests, and NEVER
  returns secret material or raw camera stream URLs.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingControlState
  alias ServiceRadar.Camera.RecordingHold
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Storage.StorageEntitlements
  alias ServiceRadar.Storage.StorageUsageDailyReport
  alias ServiceRadar.Storage.StorageUsageReports

  require Ash.Query

  @system_actor SystemActor.system(:declarative_check_posture)

  @evaluators %{
    "storage.entitlement_utilization" => :entitlement_utilization,
    "storage.hold_pin_pressure" => :hold_pin_pressure,
    "storage.archive_credential_and_usage_health" => :archive_credential_and_usage_health,
    "camera.continuous_recording_silence" => :continuous_recording_silence
  }

  @doc "Returns the closed list of supported posture evaluator identifiers."
  @spec supported_evaluators() :: [String.t()]
  def supported_evaluators, do: @evaluators |> Map.keys() |> Enum.sort()

  @doc """
  Executes a registered `platform_posture` evaluator by slug.
  """
  @spec evaluate(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def evaluate(config, opts \\ []) when is_map(config) and is_list(opts) do
    evaluator = to_string(Map.get(config, "evaluator") || Map.get(config, :evaluator) || "")

    case Map.fetch(@evaluators, evaluator) do
      {:ok, :entitlement_utilization} ->
        evaluate_entitlement_utilization(config, opts)

      {:ok, :hold_pin_pressure} ->
        evaluate_hold_pin_pressure(config, opts)

      {:ok, :archive_credential_and_usage_health} ->
        evaluate_archive_credential_and_usage_health(config, opts)

      {:ok, :continuous_recording_silence} ->
        evaluate_continuous_recording_silence(config, opts)

      :error ->
        {:error, {:unsupported_posture_evaluator, evaluator}}
    end
  end

  ## 1. storage.entitlement_utilization

  defp evaluate_entitlement_utilization(_config, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    loaders = Keyword.get(opts, :loaders, %{})
    eff = resolve_effective_entitlement(opts, loaders, now)

    with {:ok, gauges} <- resolve_gauges(opts, loaders, now),
         {:ok, settings} <- resolve_archive_settings(loaders) do
      billable_bytes = max(0, trunc(Map.get(gauges, :used_bytes, 0)))

      cond do
        eff.hosted? and not eff.applied? ->
          {:ok,
           %{
             status: :unknown,
             value: nil,
             observed_at: now,
             payload: %{
               "evaluator" => "storage.entitlement_utilization",
               "mode" => "waiting_for_entitlement",
               "hosted" => true,
               "applied" => false,
               "billable_bytes" => billable_bytes,
               "plan_bytes" => nil,
               "hard_limit_bytes" => nil,
               "utilization_percent" => nil,
               "hard_cap_active" => false,
               "verdict" => "entitlement_unconfigured",
               "summary" => "Hosted storage entitlement has not been applied yet"
             }
           }}

        eff.hosted? and eff.applied? and is_map(eff.recordings) ->
          rec = eff.recordings

          plan_bytes =
            max(
              0,
              trunc(
                Map.get(rec, :allocation_bytes) || Map.get(rec, :included_bytes) ||
                  Map.get(rec, :plan_bytes) || 0
              )
            )

          hard_limit_bytes = max(0, trunc(Map.get(rec, :hard_limit_bytes, plan_bytes)))

          util_pct =
            cond do
              plan_bytes > 0 -> Float.round(billable_bytes * 100.0 / plan_bytes, 2)
              billable_bytes > 0 -> 100.0
              true -> 0.0
            end

          hold_reason = Map.get(eff, :archive_jobs_hold_reason)

          hard_cap_active? =
            Map.get(rec, :hard_cap_active) == true or
              Map.get(rec, :enabled) == false or
              util_pct >= 100.0 or
              (hard_limit_bytes > 0 and billable_bytes >= hard_limit_bytes) or
              hold_reason in [:recordings_consumer_disabled, :entitlement_cap_exceeded]

          {:ok,
           %{
             status: :healthy,
             value: util_pct,
             observed_at: now,
             payload: %{
               "evaluator" => "storage.entitlement_utilization",
               "mode" => "hosted_entitlement",
               "hosted" => true,
               "applied" => true,
               "billable_bytes" => billable_bytes,
               "plan_bytes" => plan_bytes,
               "hard_limit_bytes" => hard_limit_bytes,
               "utilization_percent" => util_pct,
               "hard_cap_active" => hard_cap_active?
             }
           }}

        Map.get(settings, :object_budget_mode) in [:limited, "limited"] and
          is_integer(Map.get(settings, :object_budget_bytes)) and
            Map.get(settings, :object_budget_bytes) > 0 ->
          budget = Map.get(settings, :object_budget_bytes)
          util_pct = Float.round(billable_bytes * 100.0 / budget, 2)
          hard_cap_active? = billable_bytes >= budget or util_pct >= 100.0

          {:ok,
           %{
             status: :healthy,
             value: util_pct,
             observed_at: now,
             payload: %{
               "evaluator" => "storage.entitlement_utilization",
               "mode" => "limited_self_hosted",
               "hosted" => false,
               "applied" => false,
               "billable_bytes" => billable_bytes,
               "plan_bytes" => budget,
               "hard_limit_bytes" => budget,
               "utilization_percent" => util_pct,
               "hard_cap_active" => hard_cap_active?
             }
           }}

        true ->
          {:ok,
           %{
             status: :healthy,
             value: 0.0,
             observed_at: now,
             payload: %{
               "evaluator" => "storage.entitlement_utilization",
               "mode" => "unbounded_self_hosted",
               "hosted" => false,
               "applied" => false,
               "billable_bytes" => billable_bytes,
               "plan_bytes" => nil,
               "hard_limit_bytes" => nil,
               "utilization_percent" => 0.0,
               "hard_cap_active" => false
             }
           }}
      end
    end
  end

  ## 2. storage.hold_pin_pressure

  defp evaluate_hold_pin_pressure(_config, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    loaders = Keyword.get(opts, :loaders, %{})
    eff = resolve_effective_entitlement(opts, loaders, now)

    with {:ok, gauges} <- resolve_gauges(opts, loaders, now),
         {:ok, settings} <- resolve_archive_settings(loaders),
         {:ok, active_hold_count} <- resolve_active_hold_count(loaders) do
      held_bytes = max(0, trunc(Map.get(gauges, :held_bytes, 0)))

      budget_bytes =
        cond do
          eff.hosted? and eff.applied? and is_map(eff.recordings) ->
            max(0, trunc(Map.get(eff.recordings, :hard_limit_bytes, 0)))

          Map.get(gauges, :hard_limit_bytes, 0) > 0 ->
            trunc(Map.get(gauges, :hard_limit_bytes, 0))

          Map.get(settings, :object_budget_mode) in [:limited, "limited"] and
              is_integer(Map.get(settings, :object_budget_bytes)) ->
            max(0, Map.get(settings, :object_budget_bytes))

          true ->
            0
        end

      held_share_pct =
        if budget_bytes > 0 do
          Float.round(held_bytes * 100.0 / budget_bytes, 2)
        else
          0.0
        end

      raw_cutoff = Map.get(gauges, :raw_cutoff_days, Map.get(gauges, :cutoff_days, :infinity))

      projected_cutoff_days =
        case raw_cutoff do
          n when is_number(n) -> Float.round(n * 1.0, 2)
          _ -> nil
        end

      retention_starved? =
        budget_bytes > 0 and
          (held_bytes >= budget_bytes or
             (held_bytes > 0 and is_number(projected_cutoff_days) and projected_cutoff_days <= 0.0))

      {:ok,
       %{
         status: :healthy,
         value: held_share_pct,
         observed_at: now,
         payload: %{
           "evaluator" => "storage.hold_pin_pressure",
           "held_bytes" => held_bytes,
           "budget_bytes" => if(budget_bytes > 0, do: budget_bytes),
           "held_share_percent" => held_share_pct,
           "active_hold_count" => active_hold_count,
           "projected_cutoff_days" => projected_cutoff_days,
           "retention_starved" => retention_starved?
         }
       }}
    end
  end

  ## 3. storage.archive_credential_and_usage_health

  defp evaluate_archive_credential_and_usage_health(config, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    loaders = Keyword.get(opts, :loaders, %{})
    eff = resolve_effective_entitlement(opts, loaders, now)
    max_age_hours = number_param(config, "max_report_age_hours", 36.0)

    with {:ok, settings} <- resolve_archive_settings(loaders),
         {:ok, policies} <- resolve_policies(loaders) do
      has_archive_policy? =
        Enum.any?(policies, fn p ->
          field_val(p, :mode) in [:continuous, "continuous"] and
            field_val(p, :storage) in [:local_and_archive, "local_and_archive"]
        end)

      archive_required? =
        field_val(settings, :archive_enabled) == true or has_archive_policy?

      report_expected? = eff.hosted? or archive_required?

      with {:ok, unhealthy_roles} <-
             inspect_archive_credentials(archive_required?, settings, loaders),
           {:ok, report_age_hours, report_stale?} <-
             inspect_usage_report_freshness(report_expected?, max_age_hours, loaders, now) do
        credential_failure? = unhealthy_roles != []

        {:ok,
         %{
           status: :healthy,
           value: report_age_hours,
           observed_at: now,
           payload: %{
             "evaluator" => "storage.archive_credential_and_usage_health",
             "archive_required" => archive_required?,
             "report_expected" => report_expected?,
             "unhealthy_roles" => unhealthy_roles,
             "unhealthy_role_count" => length(unhealthy_roles),
             "credential_failure" => credential_failure?,
             "report_age_hours" => report_age_hours,
             "max_report_age_hours" => max_age_hours,
             "report_stale" => report_stale?
           }
         }}
      end
    end
  end

  defp inspect_archive_credentials(false, _settings, _loaders), do: {:ok, []}

  defp inspect_archive_credentials(true, settings, loaders) do
    role_slots = [
      {"uploader", field_val(settings, :writer_credential_secret_id)},
      {"reader", field_val(settings, :reader_credential_secret_id)},
      {"retention", field_val(settings, :retention_credential_secret_id)}
    ]

    secret_ids =
      role_slots
      |> Enum.map(&elem(&1, 1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    with {:ok, secrets_by_id} <- load_redacted_secrets(secret_ids, loaders) do
      unhealthy =
        role_slots
        |> Enum.filter(fn {_role_name, secret_id} ->
          secret_unhealthy?(secret_id, secrets_by_id)
        end)
        |> Enum.map(&elem(&1, 0))

      {:ok, unhealthy}
    end
  end

  defp secret_unhealthy?(nil, _secrets_by_id), do: true
  defp secret_unhealthy?("", _secrets_by_id), do: true

  defp secret_unhealthy?(secret_id, secrets_by_id) do
    case Map.get(secrets_by_id, to_string(secret_id)) do
      nil ->
        true

      secret ->
        rot_state = field_val(secret, :rotation_state)
        res_status = field_val(secret, :last_resolution_status)
        meta = field_val(secret, :metadata) || %{}
        dest_status = is_map(meta) && get_in(meta, ["destination_test", "status"])

        rot_state not in [:active, "active"] or
          res_status in [:failed, "failed"] or
          dest_status == "failed"
    end
  end

  defp inspect_usage_report_freshness(false, _max_age_hours, _loaders, _now) do
    {:ok, 0.0, false}
  end

  defp inspect_usage_report_freshness(true, max_age_hours, loaders, now) do
    with {:ok, latest_report} <- load_latest_usage_report(loaders) do
      case latest_report do
        nil ->
          age = Float.round(max_age_hours + 24.0, 2)
          {:ok, age, true}

        report ->
          computed_at = field_val(report, :computed_at)

          case computed_at do
            %DateTime{} = dt ->
              age_hours = Float.round(max(0, DateTime.diff(now, dt, :second)) / 3_600.0, 2)
              {:ok, age_hours, age_hours > max_age_hours}

            _ ->
              age = Float.round(max_age_hours + 24.0, 2)
              {:ok, age, true}
          end
      end
    end
  end

  ## 4. camera.continuous_recording_silence

  defp evaluate_continuous_recording_silence(config, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    loaders = Keyword.get(opts, :loaders, %{})
    window_minutes = config |> int_param("silence_window_minutes", 15) |> max(1) |> min(1_440)
    cutoff = DateTime.shift(now, second: -(window_minutes * 60))

    with {:ok, stopped?} <- resolve_recording_stopped(loaders),
         {:ok, policies} <- resolve_policies(loaders) do
      continuous =
        Enum.filter(policies, fn p ->
          field_val(p, :mode) in [:continuous, "continuous"]
        end)

      if stopped? or continuous == [] do
        {:ok,
         %{
           status: :healthy,
           value: 0,
           observed_at: now,
           payload: %{
             "evaluator" => "camera.continuous_recording_silence",
             "suspended" => stopped?,
             "silence_window_minutes" => window_minutes,
             "active_continuous_policy_count" => length(continuous),
             "silent_policy_count" => 0,
             "silent_policy_refs" => []
           }
         }}
      else
        with {:ok, active_pairs} <- resolve_recent_sealed_pairs(cutoff, loaders) do
          silent_refs =
            continuous
            |> Enum.filter(fn pol ->
              pair = {
                to_string(field_val(pol, :camera_source_id) || ""),
                to_string(field_val(pol, :stream_profile_id) || "")
              }

              not MapSet.member?(active_pairs, pair)
            end)
            |> Enum.map(&StorageUsageReports.opaque_policy_ref/1)
            |> Enum.sort()

          {:ok,
           %{
             status: :healthy,
             value: length(silent_refs),
             observed_at: now,
             payload: %{
               "evaluator" => "camera.continuous_recording_silence",
               "suspended" => false,
               "silence_window_minutes" => window_minutes,
               "active_continuous_policy_count" => length(continuous),
               "silent_policy_count" => length(silent_refs),
               "silent_policy_refs" => Enum.take(silent_refs, 16)
             }
           }}
        end
      end
    end
  end

  ## Loaders & CNPG Fallback Helpers

  defp resolve_effective_entitlement(opts, loaders, now) do
    case Map.get(loaders, :entitlement_state_loader) do
      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        ent_opts =
          opts
          |> Keyword.take([:hosted_install?, :loaders])
          |> Keyword.put(:now, now)

        StorageEntitlements.effective_state(ent_opts)
    end
  end

  defp resolve_gauges(opts, loaders, now) do
    case Map.get(loaders, :gauges_loader) do
      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        gauge_opts =
          opts
          |> Keyword.take([:hosted_install?, :loaders])
          |> Keyword.put(:now, now)

        StorageUsageReports.current_gauges(gauge_opts)
    end
  end

  defp resolve_archive_settings(loaders) do
    case Map.get(loaders, :settings_loader) do
      fun when is_function(fun, 0) ->
        fun.()

      _ when map_size(loaders) > 0 ->
        {:ok, RecordingArchiveSettings.default_settings()}

      _ ->
        RecordingArchiveSettings.get_settings(actor: @system_actor)
    end
  end

  defp resolve_active_hold_count(loaders) do
    case Map.get(loaders, :holds_loader) do
      fun when is_function(fun, 0) ->
        with {:ok, rows} <- fun.() do
          {:ok, Enum.count(rows, &(field_val(&1, :state) in [:accepted, "accepted"]))}
        end

      _ when map_size(loaders) > 0 ->
        {:ok, 0}

      _ ->
        query = Ash.Query.filter(RecordingHold, state == :accepted)
        Ash.count(query, actor: @system_actor, domain: ServiceRadar.Camera)
    end
  end

  defp resolve_policies(loaders) do
    case Map.get(loaders, :policies_loader) do
      fun when is_function(fun, 0) ->
        fun.()

      _ when map_size(loaders) > 0 ->
        {:ok, []}

      _ ->
        CameraRecordingPolicy
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.read(actor: @system_actor, domain: ServiceRadar.Camera)
    end
  end

  defp load_redacted_secrets([], _loaders), do: {:ok, %{}}

  defp load_redacted_secrets(secret_ids, loaders) do
    case Map.get(loaders, :secrets_loader) do
      fun when is_function(fun, 1) ->
        with {:ok, rows} <- fun.(secret_ids) do
          {:ok, Map.new(rows, &{to_string(field_val(&1, :id)), &1})}
        end

      _ when map_size(loaders) > 0 ->
        {:ok, %{}}

      _ ->
        query =
          NetworkCredentialSecret
          |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
          |> Ash.Query.filter(id in ^secret_ids)
          |> Ash.Query.select([:id, :rotation_state, :last_resolution_status, :metadata])

        with {:ok, rows} <-
               Ash.read(query, actor: @system_actor, domain: ServiceRadar.Credentials) do
          {:ok, Map.new(rows, &{to_string(&1.id), &1})}
        end
    end
  end

  defp load_latest_usage_report(loaders) do
    case Map.get(loaders, :latest_usage_report_loader) do
      fun when is_function(fun, 0) ->
        fun.()

      _ when map_size(loaders) > 0 ->
        {:ok, nil}

      _ ->
        query =
          StorageUsageDailyReport
          |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
          |> Ash.Query.sort(computed_at: :desc)
          |> Ash.Query.limit(1)

        case Ash.read(query, actor: @system_actor, domain: ServiceRadar.Camera) do
          {:ok, [latest | _]} -> {:ok, latest}
          {:ok, []} -> {:ok, nil}
          {:error, _} = err -> err
        end
    end
  end

  defp resolve_recording_stopped(loaders) do
    case Map.get(loaders, :control_state_loader) do
      fun when is_function(fun, 0) ->
        case fun.() do
          {:ok, nil} -> {:ok, false}
          {:ok, state} -> {:ok, field_val(state, :stopped) == true}
          {:error, _} = err -> err
        end

      _ when map_size(loaders) > 0 ->
        {:ok, false}

      _ ->
        query =
          RecordingControlState
          |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
          |> Ash.Query.filter(id == "deployment")

        case Ash.read_one(query, actor: @system_actor, domain: ServiceRadar.Camera) do
          {:ok, nil} -> {:ok, false}
          {:ok, row} -> {:ok, row.stopped == true}
          {:error, _} = err -> err
        end
    end
  end

  defp resolve_recent_sealed_pairs(cutoff, loaders) do
    case Map.get(loaders, :catalog_loader) do
      fun when is_function(fun, 0) ->
        with {:ok, entries} <- fun.() do
          pairs =
            entries
            |> Enum.filter(&recent_sealed_entry?(&1, cutoff))
            |> MapSet.new(fn e ->
              {
                to_string(field_val(e, :camera_source_id) || ""),
                to_string(field_val(e, :stream_profile_id) || "")
              }
            end)

          {:ok, pairs}
        end

      _ when map_size(loaders) > 0 ->
        {:ok, MapSet.new()}

      _ ->
        query =
          RecordingCatalogEntry
          |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
          |> Ash.Query.filter(
            not is_nil(recording_block_id) and local_state != :quarantined and
              not is_nil(sealed_at) and sealed_at >= ^cutoff
          )
          |> Ash.Query.select([:camera_source_id, :stream_profile_id])

        with {:ok, rows} <- Ash.read(query, actor: @system_actor, domain: ServiceRadar.Camera) do
          pairs =
            MapSet.new(rows, fn r ->
              {to_string(r.camera_source_id || ""), to_string(r.stream_profile_id || "")}
            end)

          {:ok, pairs}
        end
    end
  end

  defp recent_sealed_entry?(entry, cutoff) do
    block_id = field_val(entry, :recording_block_id)
    local_state = field_val(entry, :local_state)
    sealed_at = field_val(entry, :sealed_at)

    not is_nil(block_id) and
      local_state not in [:quarantined, "quarantined"] and
      match?(%DateTime{}, sealed_at) and
      DateTime.compare(sealed_at, cutoff) != :lt
  end

  defp field_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp number_param(config, key, default) do
    case Map.get(config, key, Map.get(config, String.to_existing_atom(key), default)) do
      n when is_number(n) -> n * 1.0
      _ -> default * 1.0
    end
  rescue
    ArgumentError ->
      case Map.get(config, key, default) do
        n when is_number(n) -> n * 1.0
        _ -> default * 1.0
      end
  end

  defp int_param(config, key, default) do
    case Map.get(config, key, default) do
      n when is_integer(n) -> n
      f when is_float(f) -> trunc(f)
      _ -> default
    end
  end
end
