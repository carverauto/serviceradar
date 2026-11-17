defmodule ServiceRadar.Storage.StorageEntitlements do
  @moduledoc """
  Runtime SaaS storage entitlement validation, row-locked singleton application,
  effective bounds evaluation, `pending` decrease projection/application at DB
  `clock_timestamp()`, archive job holding, and `C3a` object-capacity reaping
  (`F.3`, `F.4`, `F.5`, `F.7`, `F.9`, `design.md` `F1`–`F4`, `F8`).
  """

  alias Ash.Error.Query.InvalidArgument
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveCanonicalJSON
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingControlState
  alias ServiceRadar.Camera.RecordingHold
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Camera.RetentionCalculator
  alias ServiceRadar.Repo
  alias ServiceRadar.Storage.StorageEntitlement

  require Ash.Query

  @maximum 9_223_372_036_854_775_807
  @max_retention_days 36_500
  @system_actor SystemActor.system(:storage_entitlements)

  @allowed_top_keys ~w(schema_version deployment_ref revision issued_at consumers)
  @allowed_consumer_keys ~w(recordings warehouse)
  @allowed_consumer_entry_keys ~w(
    enabled
    allocation_bytes
    overage
    capacity_policy
    retention
    limits
    pending
  )
  @allowed_retention_keys ~w(max_days default_days)
  @allowed_limits_keys ~w(
    max_recording_cameras
    visual_indexing_enabled
    visual_index_enabled
    max_visual_index_cameras
  )
  @allowed_pending_keys ~w(effective_at allocation_bytes retention)
  @allowed_pending_retention_keys ~w(max_days)

  @doc """
  Returns `true` when the deployment runs under the hosted runtime contract.

  Checks `opts[:hosted_install?]` first, then `:hosted_runtime_contract_version`
  in `:serviceradar_core` application config, then the
  `SERVICERADAR_HOSTED_RUNTIME_CONTRACT_VERSION` environment variable.
  """
  @spec hosted_install?(keyword()) :: boolean()
  def hosted_install?(opts \\ []) when is_list(opts) do
    case Keyword.fetch(opts, :hosted_install?) do
      {:ok, value} ->
        value == true

      :error ->
        contract =
          Application.get_env(:serviceradar_core, :hosted_runtime_contract_version) ||
            System.get_env("SERVICERADAR_HOSTED_RUNTIME_CONTRACT_VERSION")

        non_empty_string?(contract)
    end
  end

  @doc """
  Computes the canonical lowercase SHA-256 digest of an entitlement JSON document.
  """
  @spec canonical_sha256(map()) :: String.t()
  def canonical_sha256(document) when is_map(document) do
    bytes = ArchiveCanonicalJSON.encode(document)
    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end

  @doc """
  Validates a schema v1 storage entitlement document strictly, refusing unknown
  fields at every nesting level (`design.md` `F1`, `spec.md:707-714`).
  """
  @spec validate_document(term()) :: {:ok, map()} | {:error, :invalid_storage_entitlement}
  def validate_document(document) when is_map(document) do
    with :ok <- ensure_only_keys(document, @allowed_top_keys),
         :ok <- ensure_required_keys(document, @allowed_top_keys),
         1 <- document["schema_version"],
         {:ok, deployment_ref} <- parse_deployment_ref(document["deployment_ref"]),
         {:ok, revision} <- parse_positive_int(document["revision"]),
         {:ok, issued_at} <- parse_iso8601_utc(document["issued_at"]),
         {:ok, consumers} <- validate_consumers(document["consumers"]) do
      {:ok,
       %{
         schema_version: 1,
         deployment_ref: deployment_ref,
         revision: revision,
         issued_at: issued_at,
         document_sha256: canonical_sha256(document),
         recordings: consumers.recordings,
         warehouse: consumers.warehouse
       }}
    else
      _ -> {:error, :invalid_storage_entitlement}
    end
  end

  def validate_document(_), do: {:error, :invalid_storage_entitlement}

  @doc """
  Validates and applies a storage entitlement document under row lock on the
  `"deployment"` singleton (`PUT /v1/storage/entitlement`, `F.3`, `F.4`).
  """
  @spec apply_document(map(), term(), keyword()) :: {:ok, map()} | {:error, atom()}
  def apply_document(installation, document, opts \\ []) when is_list(opts) do
    with :ok <- validate_submitter(opts),
         {:ok, inst} <- validate_installation(installation),
         :ok <- ensure_hosted_for_apply(opts),
         {:ok, parsed} <- validate_document_for_installation(document, inst),
         :ok <- ensure_outside_transaction() do
      actor = Keyword.get(opts, :actor, @system_actor)

      fn ->
        apply_locked(inst, parsed, actor, opts)
      end
      |> transact_entitlement(opts)
      |> bounded_result()
    end
  end

  @doc """
  Returns the current control-plane entitlement projection (`GET /v1/storage/entitlement`).
  """
  @spec status(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def status(installation, opts \\ []) when is_list(opts) do
    with :ok <- validate_submitter(opts),
         {:ok, inst} <- validate_installation(installation) do
      loaders = Keyword.get(opts, :loaders, %{})
      hosted? = hosted_install?(opts)

      case load_entitlement_row(loaders, true) do
        {:ok, nil} ->
          {held?, hold_reason} = resolve_archive_hold(hosted?, nil, opts, loaders)
          {:ok, unconfigured_projection(inst, hosted?, held?, hold_reason)}

        {:ok, %StorageEntitlement{} = row} ->
          with :ok <- verify_origin(row, inst) do
            now = resolve_evaluation_now(row, opts, loaders)
            {held?, hold_reason} = resolve_archive_hold(hosted?, row, opts, loaders)
            {:ok, applied_projection(row, hosted?, held?, hold_reason, now, opts)}
          end

        {:error, _} ->
          {:error, :storage_entitlement_unavailable}
      end
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :storage_entitlement_unavailable}
  end

  @doc """
  Evaluates the deployment's effective entitlement state for internal settings,
  retention calculators, reaper gates, and operator UIs (`F.4`, `F.5`, `F.7`, `F.9`).

  - Self-hosted (`hosted_install? == false`): returns
    `%{hosted?: false, applied?: false, waiting_for_entitlement?: false, archive_jobs_held?: held?}`
    and leaves operator settings completely unbounded by entitlements.
  - Hosted before first entitlement: returns
    `%{hosted?: true, applied?: false, waiting_for_entitlement?: true, archive_jobs_held?: true}`.
  - Hosted with applied entitlement: evaluates `pending` against DB `clock_timestamp()`
    (`opts[:now]` overrideable in tests), applying `pending` automatically when
    `now >= effective_at` and computing `pending_projection` before `effective_at`.
  """
  @spec effective_state(keyword()) :: map()
  def effective_state(opts \\ []) when is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    hosted? = hosted_install?(opts)

    if hosted? do
      case load_entitlement_row(loaders, true) do
        {:ok, %StorageEntitlement{} = row} ->
          now = resolve_evaluation_now(row, opts, loaders)
          {held?, hold_reason} = resolve_archive_hold(true, row, opts, loaders)
          build_effective_applied_state(row, held?, hold_reason, now, opts)

        _ ->
          {stopped?, _} = check_recording_stopped(loaders)
          reason = if stopped?, do: :recording_suspended, else: :waiting_for_entitlement

          %{
            hosted?: true,
            applied?: false,
            waiting_for_entitlement?: true,
            archive_jobs_held?: true,
            archive_jobs_hold_reason: reason,
            applied_revision: nil,
            document_sha256: nil,
            issued_at: nil,
            applied_at: nil,
            recordings: nil,
            warehouse: nil,
            pending: nil,
            pending_projection: nil
          }
      end
    else
      {stopped?, _} = check_recording_stopped(loaders)

      %{
        hosted?: false,
        applied?: false,
        waiting_for_entitlement?: false,
        archive_jobs_held?: stopped?,
        archive_jobs_hold_reason: if(stopped?, do: :recording_suspended),
        applied_revision: nil,
        document_sha256: nil,
        issued_at: nil,
        applied_at: nil,
        recordings: nil,
        warehouse: nil,
        pending: nil,
        pending_projection: nil
      }
    end
  end

  @doc """
  Returns `{true, reason}` when new archive upload jobs must be held as A6
  "Held jobs" states (`:recording_suspended`, `:waiting_for_entitlement`, or
  `:recordings_consumer_disabled`), or `{false, nil}` when archive uploads may proceed.
  """
  @spec archive_uploads_held?(keyword()) ::
          {true, :recording_suspended | :waiting_for_entitlement | :recordings_consumer_disabled}
          | {false, nil}
  def archive_uploads_held?(opts \\ []) when is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    hosted? = hosted_install?(opts)

    if hosted? do
      case load_entitlement_row(loaders, false) do
        {:ok, %StorageEntitlement{} = row} ->
          resolve_archive_hold(true, row, opts, loaders)

        _ ->
          resolve_archive_hold(true, nil, opts, loaders)
      end
    else
      case check_recording_stopped(loaders) do
        {true, _} -> {true, :recording_suspended}
        {false, _} -> {false, nil}
      end
    end
  end

  @doc """
  Computes the `F4` / `F5` pending decrease consequence projection given the
  active recordings entitlement map, raw `pending` map, and optional rate/usage
  inputs (`:policies`, `:usage_bytes`, `:non_reapable_bytes`, `:low_water_percent`,
  `:high_water_percent`).
  """
  @spec project_pending_impact(map(), map() | nil, map() | keyword()) :: map() | nil
  def project_pending_impact(_current_rec, nil, _inputs), do: nil

  def project_pending_impact(current_rec, pending, inputs)
      when is_map(current_rec) and is_map(pending) do
    opts = if is_list(inputs), do: Map.new(inputs), else: inputs
    {:ok, effective_at} = parse_iso8601_utc(pending["effective_at"])

    new_alloc =
      case Map.fetch(pending, "allocation_bytes") do
        {:ok, bytes} when is_integer(bytes) and bytes >= 0 -> bytes
        _ -> current_rec.allocation_bytes
      end

    new_max_days =
      case pending["retention"] do
        %{"max_days" => md} -> md
        _ -> current_rec.retention_max_days
      end

    new_hard_limit =
      resolve_hard_limit(
        current_rec.overage_mode,
        current_rec.overage_cap_bytes,
        new_alloc,
        Map.has_key?(pending, "allocation_bytes")
      )

    low_pct = Map.get(opts, :object_low_water_percent, 80)
    high_pct = Map.get(opts, :object_high_water_percent, 90)
    non_reapable = Map.get(opts, :non_reapable_bytes, 0)
    usage_bytes = Map.get(opts, :usage_bytes, 0)
    policies = normalize_projection_policies(Map.get(opts, :policies, []), current_rec)

    current_calc =
      RetentionCalculator.calculate_object_retention(policies, %{
        object_budget_mode: :limited,
        hard_limit_bytes: current_rec.hard_limit_bytes,
        object_high_water_percent: high_pct,
        object_low_water_percent: low_pct,
        object_capacity_policy: current_rec.capacity_policy,
        non_reapable_bytes: non_reapable,
        usage_bytes: usage_bytes
      })

    pending_policies =
      Enum.map(policies, fn pol ->
        capped_ret = cap_retention_days(pol.retention_days, new_max_days)
        %{pol | retention_days: capped_ret}
      end)

    projected_calc =
      RetentionCalculator.calculate_object_retention(pending_policies, %{
        object_budget_mode: :limited,
        hard_limit_bytes: new_hard_limit,
        object_high_water_percent: high_pct,
        object_low_water_percent: low_pct,
        object_capacity_policy: current_rec.capacity_policy,
        non_reapable_bytes: non_reapable,
        usage_bytes: usage_bytes
      })

    current_eff_days = summarize_effective_days(current_calc.policies)
    projected_eff_days = summarize_effective_days(projected_calc.policies)
    current_steady_bytes = steady_state_bytes(current_calc)
    projected_steady_bytes = steady_state_bytes(projected_calc)
    baseline_bytes = max(usage_bytes, trunc(current_steady_bytes))
    bytes_to_delete = max(0, trunc(baseline_bytes - projected_steady_bytes))

    %{
      effective_at: effective_at,
      effective_at_iso8601: DateTime.to_iso8601(effective_at),
      allocation_bytes: new_alloc,
      hard_limit_bytes: new_hard_limit,
      retention_max_days: new_max_days,
      current_cutoff_days: current_calc.capacity_days,
      projected_cutoff_days: projected_calc.capacity_days,
      current_effective_days: current_eff_days,
      projected_effective_days: projected_eff_days,
      projected_bytes_to_delete: bytes_to_delete
    }
  end

  @doc """
  Executes one `C3a` object-capacity reaper pass (`F.7`, `F.9`).

  Enabled when `reaper_enabled?` holds (either from an applied hosted entitlement
  setting `capacity_policy = :reap_oldest`, recording `entitlement:<revision>` on
  each `RecordingDisposition`, or on a self-hosted install with
  `object_budget_mode == :limited`, `object_capacity_policy == :reap_oldest`, and
  `reaper_enabled: true`). Continues running under a durable recording stop (`F.9`),
  never reaps held archive copies (`PD5`), and leaves any remaining `:present`
  local copy untouched as local-only-after-archive-reaping (`C1`/`C3a`).
  """
  @spec reap_object_capacity(keyword()) :: {:ok, map()} | {:error, term()}
  def reap_object_capacity(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    eff = effective_state(Keyword.put(opts, :now, now))

    with {:ok, base_settings} <- RecordingArchiveSettings.get_settings(actor: @system_actor) do
      reap_spec = resolve_reaper_spec(base_settings, eff, opts)

      if reap_spec.enabled? do
        run_reaper_pass(base_settings, reap_spec, now, opts)
      else
        {:ok, %{reaper_enabled?: false, reaped_count: 0, reaped_bytes: 0, entries: []}}
      end
    end
  end

  ## Internal lock & apply

  defp apply_locked(inst, parsed, actor, opts) do
    current = lock_singleton()
    db_now = Keyword.get(opts, :now) || fetch_db_clock_timestamp()

    case current do
      nil ->
        attrs = build_entitlement_attrs(inst, parsed, db_now)

        with {:ok, created} <-
               StorageEntitlement
               |> Ash.Changeset.for_create(:create_entitlement, attrs, actor: actor)
               |> Ash.create(actor: actor) do
          {held?, hold_reason} = resolve_archive_hold(true, created, opts, %{})
          {:ok, applied_projection(created, true, held?, hold_reason, db_now, opts)}
        end

      %StorageEntitlement{} = row ->
        apply_against_existing(row, inst, parsed, actor, db_now, opts)
    end
  end

  defp apply_against_existing(row, inst, parsed, actor, db_now, opts) do
    with :ok <- verify_origin(row, inst),
         :ok <- verify_revision(row, parsed) do
      if parsed.revision == row.revision and parsed.document_sha256 == row.document_sha256 do
        {held?, hold_reason} = resolve_archive_hold(true, row, opts, %{})
        {:ok, applied_projection(row, true, held?, hold_reason, db_now, opts)}
      else
        attrs = build_entitlement_attrs(inst, parsed, db_now)

        with {:ok, updated} <-
               row
               |> Ash.Changeset.for_update(:apply_entitlement, attrs, actor: actor)
               |> Ash.update(actor: actor) do
          {held?, hold_reason} = resolve_archive_hold(true, updated, opts, %{})
          {:ok, applied_projection(updated, true, held?, hold_reason, db_now, opts)}
        end
      end
    end
  end

  defp lock_singleton do
    StorageEntitlement
    |> Ash.Query.filter(id == "deployment")
    |> Ash.Query.load([:database_now])
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(actor: @system_actor)
  end

  defp verify_origin(row, inst) do
    cond do
      row.deployment_ref != inst.deployment_ref ->
        {:error, :entitlement_deployment_mismatch}

      inst.generation < row.generation ->
        {:error, :entitlement_generation_stale}

      true ->
        :ok
    end
  end

  defp verify_revision(row, parsed) do
    cond do
      parsed.revision < row.revision ->
        {:error, :entitlement_revision_stale}

      parsed.revision == row.revision and parsed.document_sha256 != row.document_sha256 ->
        {:error, :entitlement_revision_conflict}

      true ->
        :ok
    end
  end

  defp build_entitlement_attrs(inst, parsed, db_now) do
    rec = parsed.recordings
    wh = parsed.warehouse

    %{
      schema_version: 1,
      deployment_ref: inst.deployment_ref,
      generation: inst.generation,
      revision: parsed.revision,
      document_sha256: parsed.document_sha256,
      issued_at: parsed.issued_at,
      applied_at: db_now,
      recordings_present: rec.present?,
      recordings_enabled: rec.enabled,
      recordings_allocation_bytes: rec.allocation_bytes,
      recordings_overage_mode: rec.overage_mode,
      recordings_overage_cap_bytes: rec.overage_cap_bytes,
      recordings_capacity_policy: rec.capacity_policy,
      recordings_retention_max_days: rec.retention_max_days,
      recordings_retention_default_days: rec.retention_default_days,
      recordings_max_cameras: rec.max_recording_cameras,
      recordings_visual_indexing_enabled: rec.visual_indexing_enabled,
      recordings_max_visual_index_cameras: rec.max_visual_index_cameras,
      recordings_pending: rec.pending,
      warehouse_present: wh.present?,
      warehouse_enabled: wh.enabled,
      warehouse_consumer: wh.raw
    }
  end

  ## Effective state & projections

  defp build_effective_applied_state(row, held?, hold_reason, now, opts) do
    {active_alloc, active_max_days, active_pending, pending_applied?} =
      evaluate_pending_window(row, now)

    hard_limit =
      if row.recordings_enabled do
        resolve_hard_limit(
          row.recordings_overage_mode,
          row.recordings_overage_cap_bytes,
          active_alloc,
          pending_applied? and has_pending_allocation?(row.recordings_pending)
        )
      else
        0
      end

    reaper_enabled? =
      row.recordings_enabled and row.recordings_capacity_policy == :reap_oldest

    recordings_state = %{
      present?: row.recordings_present,
      enabled: row.recordings_enabled,
      allocation_bytes: active_alloc,
      hard_limit_bytes: hard_limit,
      overage_mode: row.recordings_overage_mode,
      overage_cap_bytes: row.recordings_overage_cap_bytes,
      capacity_policy: row.recordings_capacity_policy,
      capacity_policy_source: "entitlement:#{row.revision}",
      entitlement_revision: row.revision,
      reaper_enabled?: reaper_enabled?,
      retention_max_days: active_max_days,
      retention_default_days: row.recordings_retention_default_days,
      max_recording_cameras: row.recordings_max_cameras,
      visual_indexing_enabled: Map.get(row, :recordings_visual_indexing_enabled),
      max_visual_index_cameras: Map.get(row, :recordings_max_visual_index_cameras),
      limits: %{
        max_recording_cameras: row.recordings_max_cameras,
        visual_indexing_enabled: Map.get(row, :recordings_visual_indexing_enabled),
        max_visual_index_cameras: Map.get(row, :recordings_max_visual_index_cameras)
      },
      pending_applied?: pending_applied?
    }

    pending_proj =
      if row.recordings_enabled and not is_nil(active_pending) do
        proj_inputs = Keyword.get(opts, :projection_inputs, %{})
        project_pending_impact(recordings_state, active_pending, proj_inputs)
      end

    warehouse_state = %{
      present?: row.warehouse_present,
      enabled: row.warehouse_enabled,
      consumer: row.warehouse_consumer
    }

    %{
      hosted?: true,
      applied?: true,
      waiting_for_entitlement?: false,
      archive_jobs_held?: held?,
      archive_jobs_hold_reason: hold_reason,
      deployment_ref: row.deployment_ref,
      generation: row.generation,
      applied_revision: row.revision,
      document_sha256: row.document_sha256,
      issued_at: row.issued_at,
      applied_at: row.applied_at,
      recordings: recordings_state,
      warehouse: warehouse_state,
      pending: active_pending,
      pending_projection: pending_proj
    }
  end

  defp evaluate_pending_window(%StorageEntitlement{recordings_pending: nil} = row, _now) do
    {row.recordings_allocation_bytes, row.recordings_retention_max_days, nil, false}
  end

  defp evaluate_pending_window(%StorageEntitlement{recordings_pending: pending} = row, now)
       when is_map(pending) do
    case parse_iso8601_utc(pending["effective_at"]) do
      {:ok, effective_at} ->
        if DateTime.before?(now, effective_at) do
          {row.recordings_allocation_bytes, row.recordings_retention_max_days, pending, false}
        else
          alloc =
            case Map.fetch(pending, "allocation_bytes") do
              {:ok, bytes} when is_integer(bytes) and bytes >= 0 -> bytes
              _ -> row.recordings_allocation_bytes
            end

          max_days =
            case pending["retention"] do
              %{"max_days" => md} -> md
              _ -> row.recordings_retention_max_days
            end

          {alloc, max_days, nil, true}
        end

      _ ->
        {row.recordings_allocation_bytes, row.recordings_retention_max_days, nil, false}
    end
  end

  defp has_pending_allocation?(%{"allocation_bytes" => bytes}) when is_integer(bytes), do: true
  defp has_pending_allocation?(_), do: false

  defp resolve_hard_limit(:metered, cap_bytes, alloc_bytes, false)
       when is_integer(cap_bytes) and cap_bytes > 0 do
    max(cap_bytes, alloc_bytes)
  end

  defp resolve_hard_limit(:metered, cap_bytes, alloc_bytes, true)
       when is_integer(cap_bytes) and cap_bytes > 0 do
    if alloc_bytes < cap_bytes, do: alloc_bytes, else: cap_bytes
  end

  defp resolve_hard_limit(_mode, _cap_bytes, alloc_bytes, _pending_alloc_override?) do
    alloc_bytes
  end

  defp unconfigured_projection(inst, hosted?, held?, hold_reason) do
    %{
      "schema_version" => 1,
      "status" => "unconfigured",
      "hosted" => hosted?,
      "waiting_for_entitlement" => hosted?,
      "archive_jobs_held" => held?,
      "archive_jobs_hold_reason" => if(hold_reason, do: Atom.to_string(hold_reason)),
      "deployment_ref" => inst.deployment_ref,
      "generation" => inst.generation,
      "applied_revision" => nil,
      "document_sha256" => nil,
      "issued_at" => nil,
      "applied_at" => nil,
      "consumers" => %{
        "recordings" => %{
          "present" => false,
          "enabled" => false,
          "waiting_for_entitlement" => hosted?
        },
        "warehouse" => %{
          "present" => false,
          "enabled" => false
        }
      }
    }
  end

  defp applied_projection(row, hosted?, held?, hold_reason, now, opts) do
    eff = build_effective_applied_state(row, held?, hold_reason, now, opts)
    rec = eff.recordings

    overage_json =
      case rec.overage_mode do
        :metered -> %{"mode" => "metered", "cap_bytes" => rec.overage_cap_bytes}
        :off -> %{"mode" => "off"}
      end

    pending_proj_json =
      case eff.pending_projection do
        nil ->
          nil

        proj ->
          %{
            "effective_at" => proj.effective_at_iso8601,
            "allocation_bytes" => proj.allocation_bytes,
            "hard_limit_bytes" => proj.hard_limit_bytes,
            "retention_max_days" => proj.retention_max_days,
            "current_cutoff_days" => json_cutoff(proj.current_cutoff_days),
            "projected_cutoff_days" => json_cutoff(proj.projected_cutoff_days),
            "current_effective_days" => json_cutoff(proj.current_effective_days),
            "projected_effective_days" => json_cutoff(proj.projected_effective_days),
            "projected_bytes_to_delete" => proj.projected_bytes_to_delete
          }
      end

    %{
      "schema_version" => 1,
      "status" => "applied",
      "hosted" => hosted?,
      "waiting_for_entitlement" => false,
      "archive_jobs_held" => held?,
      "archive_jobs_hold_reason" => if(hold_reason, do: Atom.to_string(hold_reason)),
      "deployment_ref" => row.deployment_ref,
      "generation" => row.generation,
      "applied_revision" => row.revision,
      "document_sha256" => row.document_sha256,
      "issued_at" => DateTime.to_iso8601(row.issued_at),
      "applied_at" => DateTime.to_iso8601(row.applied_at),
      "consumers" => %{
        "recordings" => %{
          "present" => rec.present?,
          "enabled" => rec.enabled,
          "allocation_bytes" => rec.allocation_bytes,
          "hard_limit_bytes" => rec.hard_limit_bytes,
          "overage" => overage_json,
          "capacity_policy" => Atom.to_string(rec.capacity_policy),
          "capacity_policy_source" => rec.capacity_policy_source,
          "reaper_enabled" => rec.reaper_enabled?,
          "retention" => %{
            "max_days" => rec.retention_max_days,
            "default_days" => rec.retention_default_days
          },
          "limits" => build_limits_json(rec),
          "pending" => eff.pending,
          "pending_projection" => pending_proj_json
        },
        "warehouse" => %{
          "present" => row.warehouse_present,
          "enabled" => row.warehouse_enabled,
          "consumer" => row.warehouse_consumer
        }
      }
    }
  end

  defp json_cutoff(:infinity), do: nil
  defp json_cutoff(:unlimited), do: nil
  defp json_cutoff(val), do: val

  defp build_limits_json(rec) do
    %{"max_recording_cameras" => rec.max_recording_cameras}
    |> maybe_put_limit_json("visual_indexing_enabled", Map.get(rec, :visual_indexing_enabled))
    |> maybe_put_limit_json("max_visual_index_cameras", Map.get(rec, :max_visual_index_cameras))
  end

  defp maybe_put_limit_json(map, _key, nil), do: map
  defp maybe_put_limit_json(map, key, val), do: Map.put(map, key, val)

  ## Strict schema v1 parsing

  defp validate_document_for_installation(document, inst) when is_map(document) do
    case Map.fetch(document, "deployment_ref") do
      {:ok, ref} when is_binary(ref) and ref != inst.deployment_ref ->
        with :ok <- ensure_only_keys(document, @allowed_top_keys),
             {:ok, _} <- parse_deployment_ref(ref) do
          {:error, :entitlement_deployment_mismatch}
        else
          _ -> {:error, :invalid_storage_entitlement}
        end

      _ ->
        validate_document(document)
    end
  end

  defp validate_document_for_installation(_document, _inst) do
    {:error, :invalid_storage_entitlement}
  end

  defp validate_consumers(consumers) when is_map(consumers) do
    with :ok <- ensure_only_keys(consumers, @allowed_consumer_keys),
         {:ok, recordings} <- parse_recordings_consumer(Map.fetch(consumers, "recordings")),
         {:ok, warehouse} <- parse_warehouse_consumer(Map.fetch(consumers, "warehouse")) do
      {:ok, %{recordings: recordings, warehouse: warehouse}}
    end
  end

  defp validate_consumers(_), do: :error

  defp parse_recordings_consumer(:error) do
    {:ok,
     %{
       present?: false,
       enabled: false,
       allocation_bytes: 0,
       overage_mode: :off,
       overage_cap_bytes: nil,
       capacity_policy: :reap_oldest,
       retention_max_days: nil,
       retention_default_days: nil,
       max_recording_cameras: nil,
       visual_indexing_enabled: nil,
       max_visual_index_cameras: nil,
       pending: nil
     }}
  end

  defp parse_recordings_consumer({:ok, entry}) when is_map(entry) do
    with :ok <- ensure_only_keys(entry, @allowed_consumer_entry_keys),
         {:ok, enabled} <- fetch_bool(entry, "enabled") do
      parse_consumer_body(entry, enabled)
    end
  end

  defp parse_recordings_consumer(_), do: :error

  defp parse_warehouse_consumer(:error) do
    {:ok, %{present?: false, enabled: false, raw: nil}}
  end

  defp parse_warehouse_consumer({:ok, entry}) when is_map(entry) do
    with :ok <- ensure_only_keys(entry, @allowed_consumer_entry_keys),
         {:ok, enabled} <- fetch_bool(entry, "enabled"),
         {:ok, _validated} <- parse_consumer_body(entry, enabled) do
      {:ok, %{present?: true, enabled: enabled, raw: entry}}
    end
  end

  defp parse_warehouse_consumer(_), do: :error

  defp parse_consumer_body(entry, enabled) do
    with {:ok, alloc} <- parse_allocation(entry, enabled),
         {:ok, {ov_mode, ov_cap}} <- parse_overage(entry, alloc, enabled),
         {:ok, cap_policy} <- parse_capacity_policy(entry, enabled),
         {:ok, {max_days, def_days}} <- parse_retention(entry, enabled),
         {:ok, limits_parsed} <- parse_limits(Map.fetch(entry, "limits")),
         {:ok, pending} <- parse_pending(Map.fetch(entry, "pending")) do
      {:ok,
       %{
         present?: true,
         enabled: enabled,
         allocation_bytes: alloc,
         overage_mode: ov_mode,
         overage_cap_bytes: ov_cap,
         capacity_policy: cap_policy,
         retention_max_days: max_days,
         retention_default_days: def_days,
         max_recording_cameras: limits_parsed.max_recording_cameras,
         visual_indexing_enabled: limits_parsed.visual_indexing_enabled,
         max_visual_index_cameras: limits_parsed.max_visual_index_cameras,
         pending: pending
       }}
    end
  end

  defp parse_allocation(entry, enabled) do
    case Map.fetch(entry, "allocation_bytes") do
      {:ok, bytes} when is_integer(bytes) and bytes >= 0 and bytes <= @maximum ->
        {:ok, bytes}

      :error when not enabled ->
        {:ok, 0}

      _ ->
        :error
    end
  end

  defp parse_overage(entry, alloc, enabled) do
    case Map.fetch(entry, "overage") do
      {:ok, %{"mode" => "off"} = ov} when map_size(ov) == 1 ->
        {:ok, {:off, nil}}

      {:ok, %{"mode" => "metered", "cap_bytes" => cap} = ov}
      when map_size(ov) == 2 and is_integer(cap) and cap > 0 and cap >= alloc and
             cap <= @maximum ->
        {:ok, {:metered, cap}}

      :error when not enabled ->
        {:ok, {:off, nil}}

      _ ->
        :error
    end
  end

  defp parse_capacity_policy(entry, enabled) do
    case Map.fetch(entry, "capacity_policy") do
      {:ok, "reap_oldest"} -> {:ok, :reap_oldest}
      {:ok, "stop_archiving"} -> {:ok, :stop_archiving}
      :error when not enabled -> {:ok, :reap_oldest}
      _ -> :error
    end
  end

  defp parse_retention(entry, enabled) do
    case Map.fetch(entry, "retention") do
      {:ok, ret} when is_map(ret) ->
        with :ok <- ensure_only_keys(ret, @allowed_retention_keys),
             {:ok, max_d} <- parse_optional_days(Map.get(ret, "max_days")),
             {:ok, def_d} <- parse_optional_days(Map.get(ret, "default_days")),
             true <- valid_default_vs_max?(def_d, max_d) do
          {:ok, {max_d, def_d}}
        else
          _ -> :error
        end

      :error when not enabled ->
        {:ok, {nil, nil}}

      _ ->
        :error
    end
  end

  defp valid_default_vs_max?(def_d, max_d) when is_integer(def_d) and is_integer(max_d),
    do: def_d <= max_d

  defp valid_default_vs_max?(_def_d, _max_d), do: true

  defp parse_limits(:error), do: {:ok, empty_limits()}
  defp parse_limits({:ok, nil}), do: {:ok, empty_limits()}

  defp parse_limits({:ok, limits}) when is_map(limits) do
    with :ok <- ensure_only_keys(limits, @allowed_limits_keys),
         {:ok, max_cams} <- parse_optional_camera_cap(Map.get(limits, "max_recording_cameras")),
         {:ok, vi_enabled} <- parse_optional_visual_enabled(limits),
         {:ok, max_vi_cams} <-
           parse_optional_camera_cap(Map.get(limits, "max_visual_index_cameras")) do
      {:ok,
       %{
         max_recording_cameras: max_cams,
         visual_indexing_enabled: vi_enabled,
         max_visual_index_cameras: max_vi_cams
       }}
    end
  end

  defp parse_limits(_), do: :error

  defp empty_limits do
    %{
      max_recording_cameras: nil,
      visual_indexing_enabled: nil,
      max_visual_index_cameras: nil
    }
  end

  defp parse_optional_camera_cap(nil), do: {:ok, nil}

  defp parse_optional_camera_cap(n) when is_integer(n) and n >= 0 and n <= 100_000, do: {:ok, n}

  defp parse_optional_camera_cap(_), do: :error

  defp parse_optional_visual_enabled(limits) do
    has_vi? = Map.has_key?(limits, "visual_indexing_enabled")
    has_legacy? = Map.has_key?(limits, "visual_index_enabled")

    cond do
      has_vi? and has_legacy? and
          limits["visual_indexing_enabled"] != limits["visual_index_enabled"] ->
        :error

      has_vi? ->
        parse_nullable_bool(limits["visual_indexing_enabled"])

      has_legacy? ->
        parse_nullable_bool(limits["visual_index_enabled"])

      true ->
        {:ok, nil}
    end
  end

  defp parse_nullable_bool(nil), do: {:ok, nil}
  defp parse_nullable_bool(val) when is_boolean(val), do: {:ok, val}
  defp parse_nullable_bool(_), do: :error

  defp parse_pending(:error), do: {:ok, nil}
  defp parse_pending({:ok, nil}), do: {:ok, nil}

  defp parse_pending({:ok, pending}) when is_map(pending) do
    with :ok <- ensure_only_keys(pending, @allowed_pending_keys),
         {:ok, eff_dt} <- parse_iso8601_utc(pending["effective_at"]),
         {:ok, alloc_part} <- parse_pending_alloc(Map.fetch(pending, "allocation_bytes")),
         {:ok, ret_part} <- parse_pending_retention(Map.fetch(pending, "retention")),
         true <- alloc_part != :absent or ret_part != :absent do
      normalized =
        %{"effective_at" => DateTime.to_iso8601(eff_dt)}
        |> maybe_put_pending("allocation_bytes", alloc_part)
        |> maybe_put_pending("retention", ret_part)

      {:ok, normalized}
    else
      _ -> :error
    end
  end

  defp parse_pending(_), do: :error

  defp parse_pending_alloc(:error), do: {:ok, :absent}

  defp parse_pending_alloc({:ok, bytes})
       when is_integer(bytes) and bytes >= 0 and bytes <= @maximum,
       do: {:ok, {:present, bytes}}

  defp parse_pending_alloc(_), do: :error

  defp parse_pending_retention(:error), do: {:ok, :absent}

  defp parse_pending_retention({:ok, ret}) when is_map(ret) do
    with :ok <- ensure_only_keys(ret, @allowed_pending_retention_keys),
         true <- Map.has_key?(ret, "max_days"),
         {:ok, max_d} <- parse_optional_days(ret["max_days"]) do
      {:ok, {:present, %{"max_days" => max_d}}}
    else
      _ -> :error
    end
  end

  defp parse_pending_retention(_), do: :error

  defp maybe_put_pending(map, _key, :absent), do: map
  defp maybe_put_pending(map, key, {:present, val}), do: Map.put(map, key, val)

  ## C3a object reaper pass

  defp resolve_reaper_spec(settings, %{hosted?: true, applied?: true, recordings: rec}, _opts)
       when is_map(rec) do
    %{
      enabled?: rec.reaper_enabled? == true and rec.hard_limit_bytes > 0,
      hard_limit_bytes: rec.hard_limit_bytes,
      low_water_percent: settings.object_low_water_percent || 80,
      high_water_percent: settings.object_high_water_percent || 90,
      settings_revision: "entitlement:#{rec.entitlement_revision}",
      effective_settings: %{
        "capacity_policy" => "reap_oldest",
        "entitlement_revision" => rec.entitlement_revision,
        "hard_limit_bytes" => rec.hard_limit_bytes,
        "low_water_percent" => settings.object_low_water_percent || 80,
        "high_water_percent" => settings.object_high_water_percent || 90
      }
    }
  end

  defp resolve_reaper_spec(settings, _eff, opts) do
    flag_on? =
      Keyword.get(
        opts,
        :self_hosted_reaper_enabled?,
        Application.get_env(:serviceradar_core, :camera_object_reaper_enabled, false) == true
      )

    enabled? =
      flag_on? and
        settings.object_budget_mode == :limited and
        is_integer(settings.object_budget_bytes) and settings.object_budget_bytes > 0 and
        settings.object_capacity_policy == :reap_oldest

    hard_limit = settings.object_budget_bytes || 0

    %{
      enabled?: enabled?,
      hard_limit_bytes: hard_limit,
      low_water_percent: settings.object_low_water_percent || 80,
      high_water_percent: settings.object_high_water_percent || 90,
      settings_revision: "operator:deployment",
      effective_settings: %{
        "capacity_policy" => "reap_oldest",
        "hard_limit_bytes" => hard_limit,
        "low_water_percent" => settings.object_low_water_percent || 80,
        "high_water_percent" => settings.object_high_water_percent || 90
      }
    }
  end

  defp run_reaper_pass(settings, reap_spec, now, opts) do
    high_water = trunc(reap_spec.hard_limit_bytes * reap_spec.high_water_percent / 100)
    low_water = trunc(reap_spec.hard_limit_bytes * reap_spec.low_water_percent / 100)

    with {:ok, summary} <- RetentionCalculator.usage_summary(actor: @system_actor, now: now) do
      used_bytes = summary.archive.archive_used_bytes

      if used_bytes <= high_water do
        {:ok,
         %{
           reaper_enabled?: true,
           used_bytes: used_bytes,
           high_water_bytes: high_water,
           low_water_bytes: low_water,
           reaped_count: 0,
           reaped_bytes: 0,
           entries: []
         }}
      else
        bytes_needed = max(0, used_bytes - low_water)
        reap_candidates_until_target(settings, reap_spec, bytes_needed, now, opts)
      end
    end
  end

  defp reap_candidates_until_target(settings, reap_spec, bytes_needed, now, opts) do
    entries = load_verified_reap_candidates(settings.active_archive_binding_id)
    holds = load_active_holds()
    receipts_by_id = load_receipts_map()
    complete_delete? = Keyword.get(opts, :complete_deletion?, false)

    {reaped_entries, reaped_bytes, _remaining} =
      Enum.reduce_while(entries, {[], 0, bytes_needed}, fn entry, {acc, sum_b, rem_b} ->
        if rem_b <= 0 do
          {:halt, {acc, sum_b, 0}}
        else
          maybe_reap_single_entry(
            entry,
            holds,
            receipts_by_id,
            reap_spec,
            complete_delete?,
            now,
            {acc, sum_b, rem_b}
          )
        end
      end)

    {:ok,
     %{
       reaper_enabled?: true,
       settings_revision: reap_spec.settings_revision,
       reaped_count: length(reaped_entries),
       reaped_bytes: reaped_bytes,
       entries: Enum.reverse(reaped_entries)
     }}
  end

  defp maybe_reap_single_entry(
         entry,
         holds,
         receipts_by_id,
         reap_spec,
         complete_delete?,
         now,
         {acc, sum_b, rem_b}
       ) do
    held? = Enum.any?(holds, &RecordingHolds.hold_protects_entry?(&1, entry))
    blocked? = entry.archive_last_error_class == "blocked_by_provider"

    if held? or blocked? do
      {:cont, {acc, sum_b, rem_b}}
    else
      bytes = entry_archive_bytes(entry, receipts_by_id)
      local_remained? = entry.local_state == :present

      intent_attrs = %{
        reason: :object_capacity,
        settings_revision: reap_spec.settings_revision,
        effective_settings: reap_spec.effective_settings,
        local_copy_remained: local_remained?,
        actor_id: "system:object_capacity_reaper"
      }

      case RecordingHolds.begin_copy_deletion_intent(
             entry.id,
             :archive,
             intent_attrs,
             actor: @system_actor,
             now: now
           ) do
        {:ok, %{entry: deleting_entry, disposition: disp}} ->
          final_entry =
            maybe_complete_archive_reap(deleting_entry, disp, complete_delete?, now)

          {:cont, {[final_entry | acc], sum_b + bytes, rem_b - bytes}}

        {:error, _} ->
          {:cont, {acc, sum_b, rem_b}}
      end
    end
  end

  defp maybe_complete_archive_reap(entry, _disp, false, _now), do: entry

  defp maybe_complete_archive_reap(entry, disp, true, now) do
    {:ok, _} =
      RecordingHolds.record_disposition_step(disp, :executed, %{}, actor: @system_actor)

    {:ok, _} =
      RecordingHolds.record_disposition_step(disp, :verified_absent, %{}, actor: @system_actor)

    {:ok, deleted} =
      entry
      |> Ash.Changeset.for_update(:transition_archive_state, %{
        archive_state: :deleted,
        archive_deleted_reason: :object_capacity,
        archive_state_at: now
      })
      |> Ash.update(actor: @system_actor)

    deleted
  end

  defp load_verified_reap_candidates(active_binding_id) do
    same_bucket_ids = same_bucket_binding_ids(active_binding_id)

    query =
      RecordingCatalogEntry
      |> Ash.Query.filter(local_state != :quarantined and archive_state == :verified)
      |> Ash.Query.sort(timeline_start_us: :asc, sealed_at: :asc, id: :asc)

    query =
      if same_bucket_ids == [] do
        query
      else
        Ash.Query.filter(query, archive_binding_id in ^same_bucket_ids)
      end

    Ash.read!(query, actor: @system_actor)
  end

  defp same_bucket_binding_ids(nil), do: []

  defp same_bucket_binding_ids(active_id) do
    bindings = Ash.read!(ArchiveBinding, actor: @system_actor)

    case Enum.find(bindings, &(to_string(&1.id) == to_string(active_id))) do
      nil ->
        [active_id]

      active ->
        bindings
        |> Enum.filter(&(&1.endpoint == active.endpoint and &1.bucket == active.bucket))
        |> Enum.map(& &1.id)
    end
  end

  defp load_active_holds do
    RecordingHold
    |> Ash.Query.filter(state == :accepted)
    |> Ash.read!(actor: @system_actor)
  end

  defp load_receipts_map do
    NVRArchiveReceipt
    |> Ash.read!(actor: @system_actor)
    |> Map.new(&{to_string(&1.id), &1})
  end

  defp entry_archive_bytes(entry, receipts_by_id) do
    case entry.nvr_archive_receipt_id &&
           Map.get(receipts_by_id, to_string(entry.nvr_archive_receipt_id)) do
      %NVRArchiveReceipt{objects: objects} when is_list(objects) ->
        Enum.reduce(objects, 0, fn obj, acc ->
          len = if is_map(obj), do: obj["length"] || obj[:length] || 0, else: 0
          acc + max(0, len)
        end)

      _ ->
        max(0, entry.media_bytes || 0)
    end
  end

  ## Helpers & DB loading

  defp load_entitlement_row(loaders, with_clock?) do
    case Map.get(loaders, :entitlement_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ when map_size(loaders) > 0 ->
        {:ok, nil}

      _ ->
        query = Ash.Query.for_read(StorageEntitlement, :get_singleton, %{}, actor: @system_actor)
        query = if with_clock?, do: Ash.Query.load(query, [:database_now]), else: query
        Ash.read_one(query, actor: @system_actor)
    end
  end

  defp resolve_archive_hold(hosted?, row, _opts, loaders) do
    case check_recording_stopped(loaders) do
      {true, _} ->
        {true, :recording_suspended}

      {false, _} ->
        cond do
          hosted? and is_nil(row) ->
            {true, :waiting_for_entitlement}

          hosted? and not row.recordings_enabled ->
            {true, :recordings_consumer_disabled}

          true ->
            {false, nil}
        end
    end
  end

  defp check_recording_stopped(loaders) do
    case Map.get(loaders, :recording_control_loader) do
      loader when is_function(loader, 0) ->
        case loader.() do
          {:ok, %{stopped: true} = state} -> {true, state}
          _ -> {false, nil}
        end

      _ when map_size(loaders) > 0 ->
        {false, nil}

      _ ->
        case Ash.read_one(
               Ash.Query.filter(RecordingControlState, id == "deployment"),
               actor: @system_actor
             ) do
          {:ok, %RecordingControlState{stopped: true} = state} -> {true, state}
          _ -> {false, nil}
        end
    end
  rescue
    _ -> {false, nil}
  end

  defp resolve_evaluation_now(row, opts, loaders) do
    cond do
      match?(%DateTime{}, Keyword.get(opts, :now)) ->
        Keyword.get(opts, :now)

      match?(%DateTime{}, Map.get(row, :database_now)) ->
        row.database_now

      map_size(loaders) > 0 ->
        DateTime.utc_now()

      true ->
        fetch_db_clock_timestamp()
    end
  end

  defp fetch_db_clock_timestamp do
    case SQL.query(Repo, "SELECT clock_timestamp()", []) do
      {:ok, %{rows: [[%DateTime{} = dt]]}} -> dt
      _ -> DateTime.utc_now()
    end
  rescue
    _ -> DateTime.utc_now()
  end

  defp normalize_projection_policies([], current_rec) do
    default_ret = current_rec.retention_max_days || current_rec.retention_default_days || 30
    [%{id: "default", rate_bytes_per_day: 0.0, retention_days: default_ret}]
  end

  defp normalize_projection_policies(policies, current_rec) when is_list(policies) do
    Enum.map(policies, fn pol ->
      rate =
        Map.get(pol, :rate_bytes_per_day) ||
          Map.get(pol, "rate_bytes_per_day") ||
          Map.get(pol, :bytes_per_day) || 0.0

      raw_ret =
        Map.get(pol, :retention_days) ||
          Map.get(pol, :configured_days) ||
          current_rec.retention_default_days || 30

      %{
        id: to_string(Map.get(pol, :id) || Map.get(pol, "id") || "policy"),
        rate_bytes_per_day: rate * 1.0,
        retention_days: cap_retention_days(raw_ret, current_rec.retention_max_days)
      }
    end)
  end

  defp cap_retention_days(:unlimited, max_days) when is_integer(max_days), do: max_days
  defp cap_retention_days(:unlimited, _), do: :unlimited

  defp cap_retention_days(days, max_days) when is_number(days) and is_integer(max_days),
    do: min(days, max_days)

  defp cap_retention_days(days, _max_days), do: days

  defp summarize_effective_days([]), do: :unlimited

  defp summarize_effective_days(policies) do
    finite =
      policies
      |> Enum.map(& &1.effective_days)
      |> Enum.filter(&is_number/1)

    if finite == [] do
      :unlimited
    else
      Enum.max(finite)
    end
  end

  defp steady_state_bytes(%{policies: policies}) do
    Enum.reduce(policies, 0.0, fn pol, acc ->
      case pol.effective_days do
        days when is_number(days) and days > 0 -> acc + pol.rate_bytes_per_day * days
        _ -> acc
      end
    end)
  end

  defp ensure_only_keys(map, allowed) do
    if Enum.all?(Map.keys(map), &(is_binary(&1) and &1 in allowed)), do: :ok, else: :error
  end

  defp ensure_required_keys(map, required) do
    if Enum.all?(required, &Map.has_key?(map, &1)), do: :ok, else: :error
  end

  defp fetch_bool(map, key) do
    case Map.fetch(map, key) do
      {:ok, val} when is_boolean(val) -> {:ok, val}
      _ -> :error
    end
  end

  defp parse_optional_days(nil), do: {:ok, nil}

  defp parse_optional_days(days) when is_integer(days) and days in 1..@max_retention_days,
    do: {:ok, days}

  defp parse_optional_days(_), do: :error

  defp parse_positive_int(val) when is_integer(val) and val in 1..@maximum, do: {:ok, val}
  defp parse_positive_int(_), do: :error

  defp parse_deployment_ref(ref) when is_binary(ref) and byte_size(ref) in 1..128 do
    if String.valid?(ref) and String.trim(ref) == ref and
         not String.contains?(ref, [<<0>>, "\r", "\n", " ", "\t"]) do
      {:ok, ref}
    else
      :error
    end
  end

  defp parse_deployment_ref(_), do: :error

  defp parse_iso8601_utc(value) when is_binary(value) and byte_size(value) in 10..64 do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt.microsecond |> elem(0) |> then(&%{dt | microsecond: {&1, 6}})}

      _ ->
        :error
    end
  end

  defp parse_iso8601_utc(_), do: :error

  defp validate_submitter(opts) do
    case Keyword.get(opts, :actor) do
      %{role: :system, id: id} when is_binary(id) and byte_size(id) in 1..128 ->
        if String.valid?(id) and String.trim(id) == id and
             not String.contains?(id, [<<0>>, "\r", "\n"]),
           do: :ok,
           else: {:error, :invalid_entitlement_submitter}

      _ ->
        {:error, :invalid_entitlement_submitter}
    end
  end

  defp validate_installation(%{deployment_ref: ref, generation: gen}) do
    with {:ok, valid_ref} <- parse_deployment_ref(ref),
         {:ok, valid_gen} <- parse_generation(gen) do
      {:ok, %{deployment_ref: valid_ref, generation: valid_gen}}
    else
      _ -> {:error, :invalid_entitlement_installation}
    end
  end

  defp validate_installation(_), do: {:error, :invalid_entitlement_installation}

  defp parse_generation(gen) when is_integer(gen) and gen in 1..@maximum, do: {:ok, gen}

  defp parse_generation(gen) when is_binary(gen) and byte_size(gen) in 1..19 do
    case Integer.parse(gen) do
      {n, ""} when n in 1..@maximum ->
        if Integer.to_string(n) == gen, do: {:ok, n}, else: :error

      _ ->
        :error
    end
  end

  defp parse_generation(_), do: :error

  defp ensure_hosted_for_apply(opts) do
    if hosted_install?(opts), do: :ok, else: {:error, :self_hosted_install}
  end

  defp ensure_outside_transaction do
    if Repo.in_transaction?(), do: {:error, :ambient_transaction}, else: :ok
  end

  defp transact_entitlement(fun, opts) do
    [StorageEntitlement]
    |> Ash.transact(
      fn ->
        case fun.() do
          {:error, reason} when is_atom(reason) ->
            {:error,
             InvalidArgument.exception(
               field: :storage_entitlement,
               value: reason,
               message: "storage entitlement operation refused"
             )}

          other ->
            other
        end
      end,
      Keyword.take(opts, [:timeout])
    )
    |> unwrap_transaction_result()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :storage_entitlement_unavailable}
  end

  defp unwrap_transaction_result({:ok, result}), do: result

  defp unwrap_transaction_result({:error, %Ash.Error.Invalid{errors: [error]}}),
    do: unwrap_transaction_result({:error, error})

  defp unwrap_transaction_result(
         {:error, %{__struct__: type, field: :storage_entitlement, value: reason}}
       )
       when type in [InvalidArgument, Ash.Error.Changes.InvalidArgument] and is_atom(reason),
       do: {:error, reason}

  defp unwrap_transaction_result(other), do: other

  defp bounded_result({:ok, _} = ok), do: ok
  defp bounded_result({:error, reason} = err) when is_atom(reason), do: err
  defp bounded_result(_), do: {:error, :storage_entitlement_unavailable}

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_), do: false
end
