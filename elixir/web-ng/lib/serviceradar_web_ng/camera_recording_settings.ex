defmodule ServiceRadarWebNG.CameraRecordingSettings do
  @moduledoc """
  Context helpers for the Recording & Storage settings view.

  Wraps Core reads and mutations for archive bindings, archive & E1 retention
  settings, reusable `s3_compatible` credentials, CNPG usage & retention
  calculators, camera/profile pickers, and per-camera block reservations while
  keeping secret material out of `web-ng`.
  """

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveDestinations
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RetentionCalculator
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Identity.RBAC, as: CoreRBAC

  require Ash.Query

  @archive_provider "s3_compatible"
  @block_page_size 25
  @bytes_per_gib 1_073_741_824
  @operator_name_pattern ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/

  @retention_form_keys [
    "local_high_water_percent",
    "local_low_water_percent",
    "max_local_age_mode",
    "max_local_age_seconds",
    "local_window_alert_mode",
    "local_window_alert_seconds",
    "local_only_full_policy",
    "confirm_local_only_overwrite",
    "local_only_target_mode",
    "local_only_retention_target_seconds",
    "local_only_max_age_mode",
    "local_only_max_age_seconds",
    "archive_retention_mode",
    "archive_retention_days",
    "object_budget_mode",
    "object_budget_bytes",
    "object_high_water_percent",
    "object_low_water_percent",
    "object_capacity_policy",
    "confirm_reap_oldest"
  ]

  @mode_value_pairs [
    {"max_local_age_mode", "max_local_age_seconds", "limited", "86400"},
    {"local_window_alert_mode", "local_window_alert_seconds", "enabled", "3600"},
    {"local_only_target_mode", "local_only_retention_target_seconds", "target", "604800"},
    {"local_only_max_age_mode", "local_only_max_age_seconds", "limited", "86400"},
    {"archive_retention_mode", "archive_retention_days", "limited", "30"},
    {"object_budget_mode", "object_budget_bytes", "limited", "10737418240"}
  ]

  @doc """
  Lists immutable `ArchiveBinding` generations newest first under `scope`.
  """
  @spec list_archive_bindings(map()) :: [ArchiveBinding.t()]
  def list_archive_bindings(scope) do
    case ArchiveDestinations.list_bindings(actor_opts(scope)) do
      {:ok, bindings} -> bindings
      {:error, _reason} -> []
    end
  end

  @doc """
  Lists enabled `s3_compatible` opaque credentials under the caller's scope.
  Returns `[]` when the scope lacks `settings.credentials.manage`.
  """
  @spec list_enabled_s3_credentials(map()) :: [NetworkCredentialSecret.t()]
  def list_enabled_s3_credentials(scope) do
    if scope_holds?(scope, "settings.credentials.manage") do
      case NetworkCredentialSecret.list_by_provider(@archive_provider, scope: scope) do
        {:ok, secrets} ->
          Enum.filter(secrets, &enabled_s3_secret?/1)

        {:error, _reason} ->
          []
      end
    else
      []
    end
  end

  @doc """
  Loads the deployment `RecordingArchiveSettings` singleton overview and resolves
  redacted credential display labels, availability warnings, and E1 retention
  draft defaults without exposing secret payloads or requiring
  `settings.credentials.manage`.
  """
  @spec load_archive_settings_view(map(), keyword()) :: map()
  def load_archive_settings_view(scope, opts \\ []) do
    case RecordingArchiveSettings.get_overview(actor_opts(scope) ++ opts) do
      {:ok, overview} ->
        build_archive_settings_view_from_overview(overview, opts)

      {:error, _reason} ->
        default_archive_settings_view()
    end
  end

  @doc """
  Default overview structure used before connected mount or on fallback.
  """
  @spec default_archive_settings_view() :: map()
  def default_archive_settings_view do
    defaults = RecordingArchiveSettings.default_settings()

    %{
      record: nil,
      settings: defaults,
      storage_mode: :local_only,
      form: default_settings_form(),
      retention_form: default_retention_form(),
      active_binding_id: nil,
      selected_writer_label: "None selected",
      selected_reader_label: "Use writer credential (reader role)",
      selected_retention_label: "None selected (object retention not enforced)",
      object_retention_enforced?: false,
      shorter_archive_than_local?: false,
      effective_local_only_full_policy: :stop_when_full,
      effective_object_capacity_policy: :stop_archiving,
      credential_issue: nil
    }
  end

  @doc """
  Default form values for archive destination and credential selection on
  `RecordingArchiveSettings`.
  """
  @spec default_settings_form() :: map()
  def default_settings_form do
    %{
      "active_archive_binding_id" => "",
      "archive_enabled" => "false",
      "writer_credential_secret_id" => "",
      "reader_credential_secret_id" => "",
      "retention_credential_secret_id" => ""
    }
  end

  @doc """
  Default form values for E1 retention settings on `RecordingArchiveSettings`.
  Preselects `overwrite_oldest` in the draft when unset while keeping confirmation
  unchecked until the operator confirms it.
  """
  @spec default_retention_form() :: map()
  def default_retention_form do
    %{
      "local_high_water_percent" => "90",
      "local_low_water_percent" => "80",
      "max_local_age_mode" => "limited",
      "max_local_age_seconds" => "86400",
      "local_window_alert_mode" => "enabled",
      "local_window_alert_seconds" => "3600",
      "local_only_full_policy" => "overwrite_oldest",
      "confirm_local_only_overwrite" => "false",
      "local_only_target_mode" => "target",
      "local_only_retention_target_seconds" => "604800",
      "local_only_max_age_mode" => "unlimited",
      "local_only_max_age_seconds" => "",
      "archive_retention_mode" => "limited",
      "archive_retention_days" => "30",
      "object_budget_mode" => "unlimited",
      "object_budget_bytes" => "",
      "object_high_water_percent" => "90",
      "object_low_water_percent" => "80",
      "object_capacity_policy" => "",
      "confirm_reap_oldest" => "false"
    }
  end

  @doc """
  Default interactive What-If simulator form values (never persisted).
  """
  @spec default_simulator_form() :: map()
  def default_simulator_form do
    %{
      "camera_count" => "",
      "nominal_bitrate_kbps" => "",
      "local_budget_gib" => ""
    }
  end

  @doc """
  Builds the retention form map from a `RecordingArchiveSettings` struct or map.
  """
  @spec retention_form_from_settings(map()) :: map()
  def retention_form_from_settings(settings) when is_map(settings) do
    local_policy = Map.get(settings, :local_only_full_policy)
    object_mode = Map.get(settings, :object_budget_mode, :unlimited)
    object_policy = Map.get(settings, :object_capacity_policy)

    {draft_local_policy, local_confirmed} =
      case local_policy do
        p when p in [:overwrite_oldest, "overwrite_oldest"] -> {"overwrite_oldest", "true"}
        p when p in [:stop_when_full, "stop_when_full"] -> {"stop_when_full", "false"}
        _ -> {"overwrite_oldest", "false"}
      end

    {draft_object_policy, reap_confirmed} =
      case object_policy do
        p when p in [:reap_oldest, "reap_oldest"] ->
          {"reap_oldest", "true"}

        p when p in [:stop_archiving, "stop_archiving"] ->
          {"stop_archiving", "false"}

        _ ->
          preselect = if object_mode in [:limited, "limited"], do: "reap_oldest", else: ""
          {preselect, "false"}
      end

    %{
      "local_high_water_percent" => to_string(Map.get(settings, :local_high_water_percent, 90)),
      "local_low_water_percent" => to_string(Map.get(settings, :local_low_water_percent, 80)),
      "max_local_age_mode" => to_string(Map.get(settings, :max_local_age_mode, :limited)),
      "max_local_age_seconds" => to_string_or_empty(Map.get(settings, :max_local_age_seconds, 86_400)),
      "local_window_alert_mode" => to_string(Map.get(settings, :local_window_alert_mode, :enabled)),
      "local_window_alert_seconds" => to_string_or_empty(Map.get(settings, :local_window_alert_seconds, 3_600)),
      "local_only_full_policy" => draft_local_policy,
      "confirm_local_only_overwrite" => local_confirmed,
      "local_only_target_mode" => to_string(Map.get(settings, :local_only_target_mode, :target)),
      "local_only_retention_target_seconds" =>
        to_string_or_empty(Map.get(settings, :local_only_retention_target_seconds, 604_800)),
      "local_only_max_age_mode" => to_string(Map.get(settings, :local_only_max_age_mode, :unlimited)),
      "local_only_max_age_seconds" => to_string_or_empty(Map.get(settings, :local_only_max_age_seconds)),
      "archive_retention_mode" => to_string(Map.get(settings, :archive_retention_mode, :limited)),
      "archive_retention_days" => to_string_or_empty(Map.get(settings, :archive_retention_days, 30)),
      "object_budget_mode" => to_string(object_mode),
      "object_budget_bytes" => to_string_or_empty(Map.get(settings, :object_budget_bytes)),
      "object_high_water_percent" => to_string(Map.get(settings, :object_high_water_percent, 90)),
      "object_low_water_percent" => to_string(Map.get(settings, :object_low_water_percent, 80)),
      "object_capacity_policy" => draft_object_policy,
      "confirm_reap_oldest" => reap_confirmed
    }
  end

  @doc """
  DB-free baseline usage summary for disconnected mount and unit tests.
  """
  @spec default_usage_summary(map() | nil) :: map()
  def default_usage_summary(settings \\ nil) do
    base = settings || RecordingArchiveSettings.default_settings()
    projected = RetentionCalculator.project_settings(base, %{camera_count: 0})

    %{
      settings: base,
      archive: %{
        active_archive_binding_id: Map.get(base, :active_archive_binding_id),
        archive_used_bytes: 0,
        archived_block_count: 0,
        archived_object_count: 0,
        oldest_verified_at: nil,
        newest_verified_at: nil,
        history_seconds: 0,
        trailing_24h_bytes: 0,
        trailing_7d_bytes: 0,
        trailing_7d_daily_mean_bytes: 0.0,
        measured_rate_bytes_per_day: projected.rate.bytes_per_day,
        rate_basis: projected.rate.basis
      },
      local_blocks: %{
        total_reserved_blocks: 0,
        trailing_15m_blocks: 0,
        trailing_6h_blocks: 0,
        history_seconds: 0,
        by_storage: %{}
      },
      object_projection: projected.object_projection,
      local_projection: projected.local_projection,
      shorter_archive_than_local?: projected.shorter_archive_than_local?,
      object_retention_enforced?: not is_nil(Map.get(base, :retention_credential_secret_id))
    }
  end

  @doc """
  Loads real CNPG usage and calculated retention summary under `scope`.
  """
  @spec load_retention_usage_summary(map(), keyword()) :: map()
  def load_retention_usage_summary(scope, opts \\ []) do
    case RecordingArchiveSettings.usage_summary(actor_opts(scope) ++ opts) do
      {:ok, summary} -> summary
      {:error, _reason} -> default_usage_summary()
    end
  end

  @doc """
  Normalizes archive settings draft parameters during `phx-change`, respecting
  split-permission credential rules.
  """
  @spec normalize_archive_settings_form(map(), map(), boolean()) :: map()
  def normalize_archive_settings_form(params, current_form, can_manage_credentials?)
      when is_map(params) and is_map(current_form) do
    allowed =
      if can_manage_credentials? do
        [
          "active_archive_binding_id",
          "archive_enabled",
          "writer_credential_secret_id",
          "reader_credential_secret_id",
          "retention_credential_secret_id"
        ]
      else
        ["active_archive_binding_id", "archive_enabled"]
      end

    merged = Map.merge(current_form, Map.take(params, allowed))

    Map.put(
      merged,
      "archive_enabled",
      to_string(truthy?(merged["archive_enabled"]))
    )
  end

  @doc """
  Pure pre-save validation and what-if recalculation for `phx-change="preview_retention_settings"`.
  Performs zero database queries.
  """
  @spec preview_retention_settings(map(), map(), keyword()) :: %{
          retention_form: map(),
          simulator_form: map(),
          errors: %{optional(atom()) => String.t()},
          projection: map()
        }
  def preview_retention_settings(retention_params, simulator_params, opts \\ []) do
    prev_form = Keyword.get(opts, :prev_form, default_retention_form())
    prev_sim = Keyword.get(opts, :prev_simulator, default_simulator_form())
    usage_summary = Keyword.get(opts, :usage_summary, default_usage_summary())
    existing = Keyword.get(opts, :existing)
    storage_mode = Keyword.get(opts, :storage_mode, :local_only)
    scope = Keyword.get(opts, :scope)

    next_form = merge_retention_preview_form(prev_form, retention_params)
    next_sim = merge_simulator_form(prev_sim, simulator_params)

    {attrs, parse_errors} = build_retention_attrs(next_form, %{}, existing, :preview)
    changeset_errors = validate_preview_changeset(attrs, existing, scope)
    errors = Map.merge(changeset_errors, parse_errors)

    projection_attrs = build_safe_projection_attrs(next_form, existing)
    sim_inputs = build_simulator_inputs(next_sim, usage_summary, storage_mode)
    projection = RetentionCalculator.project_settings(projection_attrs, sim_inputs)

    %{
      retention_form: next_form,
      simulator_form: next_sim,
      errors: errors,
      projection: projection
    }
  end

  @doc """
  Persists deployment-wide E1 retention settings on `RecordingArchiveSettings`
  after enforcing explicit operator confirmations for `overwrite_oldest` and
  `reap_oldest` and validating all mode+value bounds.
  """
  @spec save_retention_settings(map(), map(), keyword()) ::
          {:ok, RecordingArchiveSettings.t()} | {:error, %{optional(atom()) => String.t()}}
  def save_retention_settings(scope, params, opts \\ []) when is_map(params) do
    existing =
      case RecordingArchiveSettings.get_overview(actor_opts(scope) ++ opts) do
        {:ok, %{persisted?: true, settings: settings}} -> settings
        {:ok, %{settings: settings}} -> settings
        {:error, _} -> nil
      end

    base_form =
      if existing,
        do: retention_form_from_settings(existing),
        else: default_retention_form()

    merged_form = merge_retention_submit_form(base_form, params)
    {attrs, parse_errors} = build_retention_attrs(merged_form, params, existing, :submit)
    gate_errors = confirmation_gate_errors(merged_form, existing)
    pre_errors = Map.merge(parse_errors, gate_errors)

    if pre_errors == %{} do
      save_fn =
        Keyword.get(opts, :save_fn, fn save_attrs ->
          RecordingArchiveSettings.save_settings(save_attrs, actor_opts(scope) ++ opts)
        end)

      case save_fn.(attrs) do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {:error, extract_retention_errors(reason)}
      end
    else
      {:error, pre_errors}
    end
  end

  @doc """
  Default form values for operator destination registration.
  """
  @spec default_destination_form() :: map()
  def default_destination_form do
    %{
      "name" => "",
      "endpoint" => "",
      "region" => "",
      "bucket" => "",
      "namespace" => "recordings/v1"
    }
  end

  @doc """
  Normalizes operator destination draft parameters.
  """
  @spec normalize_destination_params(map()) :: map()
  def normalize_destination_params(params) when is_map(params) do
    default_destination_form()
    |> Map.merge(Map.take(params, ["name", "endpoint", "region", "bucket", "namespace"]))
    |> Map.new(fn {k, v} -> {k, v |> to_string() |> String.trim()} end)
  end

  def normalize_destination_params(_params), do: default_destination_form()

  @doc """
  Registers a new operator destination generation through
  `ServiceRadar.Camera.ArchiveDestinations.register_operator/2`, mapping errors
  to specific input fields.
  """
  @spec register_operator_destination(map(), map(), keyword()) ::
          {:ok, ArchiveBinding.t()} | {:error, %{optional(atom()) => String.t()}}
  def register_operator_destination(scope, params, opts \\ []) do
    normalized = normalize_destination_params(params)

    case ArchiveDestinations.register_operator(normalized, actor_opts(scope) ++ opts) do
      {:ok, binding} -> {:ok, binding}
      {:error, reason} -> {:error, extract_destination_errors(reason, normalized)}
    end
  end

  @doc """
  Updates the `RecordingArchiveSettings` singleton from the Archive tab. When
  `can_manage_credentials?` is `false`, credential fields are omitted so existing
  credential bindings are preserved; an attempt to supply new credential IDs
  without `settings.credentials.manage` is rejected.
  """
  @spec save_archive_settings(map(), map(), boolean(), keyword()) ::
          {:ok, RecordingArchiveSettings.t()} | {:error, String.t()}
  def save_archive_settings(scope, params, can_manage_credentials?, opts \\ []) do
    existing =
      case RecordingArchiveSettings.get_overview(actor_opts(scope) ++ opts) do
        {:ok, %{settings: settings}} -> settings
        {:error, _} -> nil
      end

    with {:ok, attrs} <- build_archive_settings_attrs(params, existing, can_manage_credentials?),
         :ok <- ensure_credentials_rotation_active(attrs, opts) do
      save_fn =
        Keyword.get(opts, :save_fn, fn save_attrs ->
          RecordingArchiveSettings.save_settings(save_attrs, actor_opts(scope) ++ opts)
        end)

      case save_fn.(attrs) do
        {:ok, updated} -> {:ok, updated}
        {:error, error} when is_exception(error) -> {:error, Exception.message(error)}
        {:error, error} when is_binary(error) -> {:error, error}
        {:error, error} -> {:error, inspect(error)}
      end
    end
  end

  @doc """
  Lists camera sources visible under `scope`. Distinguishes missing
  `devices.view` (`{:forbidden, []}`) from an empty inventory (`{:ok, []}`).
  """
  @spec list_camera_sources(map()) :: {:ok, [Source.t()]} | {:forbidden, []}
  def list_camera_sources(scope) do
    if scope_holds?(scope, "devices.view") do
      Source
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(display_name: :asc, inserted_at: :asc)
      |> Ash.read(scope: scope)
      |> case do
        {:ok, sources} -> {:ok, sources}
        {:error, %Forbidden{}} -> {:forbidden, []}
        {:error, _reason} -> {:ok, []}
      end
    else
      {:forbidden, []}
    end
  end

  @doc """
  Lists relay-eligible stream profiles for `camera_source_id` under `scope`.
  """
  @spec list_relay_profiles(map(), String.t() | nil) :: [StreamProfile.t()]
  def list_relay_profiles(_scope, camera_source_id) when camera_source_id in [nil, ""], do: []

  def list_relay_profiles(scope, camera_source_id) do
    if scope_holds?(scope, "devices.view") and Ecto.UUID.cast(camera_source_id) != :error do
      StreamProfile
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(camera_source_id == ^camera_source_id and relay_eligible == true)
      |> Ash.Query.sort(profile_name: :asc)
      |> Ash.read(scope: scope)
      |> case do
        {:ok, profiles} -> profiles
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  @doc """
  Loads a bounded page of NVR block reservations for `camera_source_id` (and
  optional `stream_profile_id`), decorating each row with honest local-unknown
  status and any Core `NVRArchiveReceipt` record.
  """
  @spec list_camera_blocks_page(map(), String.t() | nil, keyword()) ::
          {:ok, %{rows: [map()], next_cursor: term()}}
  def list_camera_blocks_page(scope, camera_source_id, opts \\ [])

  def list_camera_blocks_page(_scope, camera_source_id, _opts) when camera_source_id in [nil, ""] do
    {:ok, %{rows: [], next_cursor: nil}}
  end

  def list_camera_blocks_page(scope, camera_source_id, opts) do
    page_opts = maybe_put_opt([limit: @block_page_size], :after, Keyword.get(opts, :cursor))

    profile_filter = blank_to_nil(Keyword.get(opts, :stream_profile_id))

    case RecordingBlocks.operator_page(camera_source_id, page_opts, actor_opts(scope)) do
      {:ok, page} ->
        {blocks, next_cursor} = unpack_operator_page(page)
        filtered = filter_blocks_by_profile(blocks, profile_filter)
        receipts_by_key = load_receipts_for_blocks(filtered)
        rows = Enum.map(filtered, &decorate_block_row(&1, receipts_by_key))
        {:ok, %{rows: rows, next_cursor: next_cursor}}

      {:error, _reason} ->
        {:ok, %{rows: [], next_cursor: nil}}
    end
  end

  @doc """
  Maps validation errors from `ArchiveDestinations.register_operator/2` or
  `ArchiveDestination.attributes/1` onto specific form fields (`:name`,
  `:endpoint`, `:region`, `:bucket`, `:namespace`, or `:base`).
  """
  @spec extract_destination_errors(term(), map()) :: %{optional(atom()) => String.t()}
  def extract_destination_errors(error, submitted \\ %{})

  def extract_destination_errors({:invalid_field, field, message}, _submitted)
      when field in [:name, :endpoint, :region, :bucket, :namespace] and is_binary(message) do
    %{field => message}
  end

  def extract_destination_errors(errors, submitted) when is_map(errors) and not is_struct(errors) do
    mapped =
      Enum.reduce(errors, %{}, fn {k, v}, acc ->
        case normalize_error_field(k) do
          nil -> acc
          field -> Map.put(acc, field, format_error_value(v))
        end
      end)

    if mapped == %{}, do: diagnose_submitted_fields(submitted, inspect(errors)), else: mapped
  end

  def extract_destination_errors(%{errors: nested_errors}, submitted) when is_list(nested_errors) do
    mapped = Enum.reduce(nested_errors, %{}, &put_nested_destination_error/2)

    if mapped == %{} do
      diagnose_submitted_fields(submitted, format_ash_errors(nested_errors))
    else
      mapped
    end
  end

  def extract_destination_errors(reason, submitted) when is_atom(reason) do
    diagnose_submitted_fields(submitted, "Invalid archive destination (#{reason}).")
  end

  def extract_destination_errors(other, submitted) do
    diagnose_submitted_fields(submitted, inspect(other))
  end

  # --- internal helpers ------------------------------------------------------

  defp enabled_s3_secret?(secret) do
    metadata = Map.get(secret, :metadata) || %{}
    meta_enabled = Map.get(metadata, "enabled", Map.get(metadata, :enabled, true))

    secret.provider == @archive_provider and
      secret.credential_kind in [:opaque, "opaque"] and
      secret.rotation_state != :disabled and
      meta_enabled != false
  end

  defp build_archive_settings_view_from_overview(overview, opts) do
    settings = overview.settings
    active_binding_id = blank_to_nil(Map.get(settings, :active_archive_binding_id))

    writer_summary = refine_credential_summary(Map.get(overview, :writer_credential), opts)
    reader_summary = refine_credential_summary(Map.get(overview, :reader_credential), opts)
    retention_summary = refine_credential_summary(Map.get(overview, :retention_credential), opts)

    {writer_label, writer_issue} =
      format_credential_summary(writer_summary, "None selected", "writer")

    {reader_label, reader_issue} =
      format_credential_summary(
        reader_summary,
        "Use writer credential (reader role)",
        "reader"
      )

    {retention_label, retention_issue} =
      format_retention_credential_summary(
        retention_summary,
        "None selected (object retention not enforced)"
      )

    storage_mode =
      Map.get_lazy(overview, :storage_mode, fn ->
        if Map.get(settings, :archive_enabled) == true and not is_nil(active_binding_id),
          do: :local_and_archive,
          else: :local_only
      end)

    object_retention_enforced? =
      not is_nil(retention_summary) and retention_summary.status == :available

    %{
      record: if(overview.persisted?, do: settings),
      settings: settings,
      storage_mode: storage_mode,
      form: %{
        "active_archive_binding_id" => to_string_or_empty(active_binding_id),
        "archive_enabled" => to_string(Map.get(settings, :archive_enabled) == true),
        "writer_credential_secret_id" => to_string_or_empty(Map.get(settings, :writer_credential_secret_id)),
        "reader_credential_secret_id" => to_string_or_empty(Map.get(settings, :reader_credential_secret_id)),
        "retention_credential_secret_id" => to_string_or_empty(Map.get(settings, :retention_credential_secret_id))
      },
      retention_form: retention_form_from_settings(settings),
      active_binding_id: if(active_binding_id, do: to_string(active_binding_id)),
      selected_writer_label: writer_label,
      selected_reader_label: reader_label,
      selected_retention_label: retention_label,
      object_retention_enforced?: object_retention_enforced?,
      shorter_archive_than_local?: RecordingArchiveSettings.shorter_archive_than_local?(settings),
      effective_local_only_full_policy: RecordingArchiveSettings.effective_local_only_full_policy(settings),
      effective_object_capacity_policy: RecordingArchiveSettings.effective_object_capacity_policy(settings),
      credential_issue: writer_issue || reader_issue || retention_issue
    }
  end

  defp refine_credential_summary(nil, _opts), do: nil

  defp refine_credential_summary(%{status: :available, id: id} = summary, opts) do
    case load_secret_for_check(id, opts) do
      {:ok, %{rotation_state: :disabled}} ->
        %{summary | status: :inactive, reason: :credential_secret_inactive}

      _ ->
        summary
    end
  end

  defp refine_credential_summary(summary, _opts), do: summary

  defp load_secret_for_check(id, opts) do
    case opts |> Keyword.get(:loaders, %{}) |> Map.get(:secret_loader) do
      loader when is_function(loader, 1) ->
        loader.(id)

      _ ->
        NetworkCredentialSecret.get_by_id(
          id,
          actor: SystemActor.system(:camera_recording_settings)
        )
    end
  end

  defp format_credential_summary(nil, empty_label, _slot_label), do: {empty_label, nil}

  defp format_credential_summary(%{status: :available, name: name}, _empty_label, _slot_label) do
    {name || "Selected credential", nil}
  end

  defp format_credential_summary(%{status: :missing}, _empty_label, slot_label) do
    {"Deleted credential",
     "Selected #{slot_label} credential is no longer available. Archive operations will not be sent to an NVR."}
  end

  defp format_credential_summary(%{status: _status, name: name}, _empty_label, slot_label) do
    display =
      if is_binary(name) and name != "", do: "#{name} (disabled)", else: "Disabled credential"

    named = if is_binary(name) and name != "", do: " \"#{name}\"", else: ""

    {display, "Selected #{slot_label} credential#{named} is disabled. Archive operations will not be sent to an NVR."}
  end

  defp format_retention_credential_summary(nil, empty_label), do: {empty_label, nil}

  defp format_retention_credential_summary(%{status: :available, name: name}, _empty_label) do
    {name || "Selected credential", nil}
  end

  defp format_retention_credential_summary(%{status: :missing}, _empty_label) do
    {"Deleted credential", "Selected retention credential is no longer available. Object retention is not enforced."}
  end

  defp format_retention_credential_summary(%{status: _status, name: name}, _empty_label) do
    display =
      if is_binary(name) and name != "", do: "#{name} (disabled)", else: "Disabled credential"

    named = if is_binary(name) and name != "", do: " \"#{name}\"", else: ""

    {display, "Selected retention credential#{named} is disabled. Object retention is not enforced."}
  end

  defp ensure_credentials_rotation_active(attrs, opts) do
    slots = [
      {:writer, Map.get(attrs, :writer_credential_secret_id)},
      {:reader, Map.get(attrs, :reader_credential_secret_id)},
      {:retention, Map.get(attrs, :retention_credential_secret_id)}
    ]

    Enum.reduce_while(slots, :ok, fn {slot, id}, :ok ->
      if is_nil(id) do
        {:cont, :ok}
      else
        case load_secret_for_check(id, opts) do
          {:ok, %{rotation_state: :disabled}} ->
            {:halt, {:error, "Selected #{slot} credential is disabled."}}

          _ ->
            {:cont, :ok}
        end
      end
    end)
  end

  defp build_archive_settings_attrs(params, existing, can_manage_credentials?) do
    base_attrs = %{
      active_archive_binding_id: blank_to_nil(params["active_archive_binding_id"]),
      archive_enabled: truthy?(params["archive_enabled"])
    }

    if can_manage_credentials? do
      {:ok,
       Map.merge(base_attrs, %{
         writer_credential_secret_id: blank_to_nil(params["writer_credential_secret_id"]),
         reader_credential_secret_id: blank_to_nil(params["reader_credential_secret_id"]),
         retention_credential_secret_id: blank_to_nil(params["retention_credential_secret_id"])
       })}
    else
      if any_credential_param_changed?(params, existing) do
        {:error, "Changing archive credentials requires settings.credentials.manage."}
      else
        {:ok, base_attrs}
      end
    end
  end

  defp any_credential_param_changed?(params, existing) do
    Enum.any?(
      [
        {"writer_credential_secret_id", :writer_credential_secret_id},
        {"reader_credential_secret_id", :reader_credential_secret_id},
        {"retention_credential_secret_id", :retention_credential_secret_id}
      ],
      fn {param_key, field_key} ->
        credential_param_changed?(params, param_key, existing, field_key)
      end
    )
  end

  defp credential_param_changed?(params, param_key, existing, field_key) do
    if Map.has_key?(params, param_key) do
      submitted = blank_to_nil(params[param_key])
      current = if existing, do: blank_to_nil(Map.get(existing, field_key))
      to_string_or_empty(submitted) != to_string_or_empty(current)
    else
      false
    end
  end

  defp merge_retention_preview_form(prev_form, params) when is_map(params) do
    sanitized =
      params
      |> Map.take(@retention_form_keys)
      |> Map.new(fn {k, v} -> {k, v |> to_string() |> String.trim()} end)

    merged = Map.merge(prev_form, sanitized)

    merged =
      Enum.reduce(@mode_value_pairs, merged, fn {mode_k, val_k, active_mode, default_str}, acc ->
        apply_preview_mode_transition(acc, prev_form, sanitized, mode_k, val_k, active_mode, default_str)
      end)

    maybe_preselect_object_policy(merged, prev_form, sanitized)
  end

  defp merge_retention_preview_form(prev_form, _params), do: prev_form

  defp apply_preview_mode_transition(acc, prev_form, sanitized, mode_k, val_k, active_mode, default_str) do
    prev_mode = prev_form[mode_k]
    next_mode = acc[mode_k]

    cond do
      next_mode != active_mode and prev_mode == active_mode ->
        Map.put(acc, val_k, "")

      next_mode == active_mode and prev_mode != active_mode and not Map.has_key?(sanitized, val_k) and
          acc[val_k] in [nil, ""] ->
        Map.put(acc, val_k, default_str)

      true ->
        acc
    end
  end

  defp maybe_preselect_object_policy(merged, prev_form, sanitized) do
    if prev_form["object_budget_mode"] != "limited" and
         merged["object_budget_mode"] == "limited" and
         not Map.has_key?(sanitized, "object_capacity_policy") and
         merged["object_capacity_policy"] in [nil, ""] do
      Map.put(merged, "object_capacity_policy", "reap_oldest")
    else
      merged
    end
  end

  defp merge_retention_submit_form(base_form, params) do
    sanitized =
      params
      |> Map.take(@retention_form_keys)
      |> Map.new(fn {k, v} -> {k, v |> to_string() |> String.trim()} end)

    merged = Map.merge(base_form, sanitized)

    Enum.reduce(@mode_value_pairs, merged, fn {mode_k, val_k, active_mode, _default_str}, acc ->
      if acc[mode_k] != active_mode and not Map.has_key?(sanitized, val_k) do
        Map.put(acc, val_k, "")
      else
        acc
      end
    end)
  end

  defp merge_simulator_form(prev_sim, sim_params) when is_map(sim_params) do
    sanitized =
      sim_params
      |> Map.take(["camera_count", "nominal_bitrate_kbps", "local_budget_gib"])
      |> Map.new(fn {k, v} -> {k, v |> to_string() |> String.trim()} end)

    Map.merge(prev_sim, sanitized)
  end

  defp merge_simulator_form(prev_sim, _sim_params), do: prev_sim

  defp build_retention_attrs(form, raw_params, _existing, phase) do
    errors = %{}

    {local_high, errors} = parse_required_int(form, "local_high_water_percent", :local_high_water_percent, errors)
    {local_low, errors} = parse_required_int(form, "local_low_water_percent", :local_low_water_percent, errors)
    {obj_high, errors} = parse_required_int(form, "object_high_water_percent", :object_high_water_percent, errors)
    {obj_low, errors} = parse_required_int(form, "object_low_water_percent", :object_low_water_percent, errors)

    {max_local_mode, errors} = parse_mode(form["max_local_age_mode"], [:limited, :unlimited], :max_local_age_mode, errors)

    {alert_mode, errors} =
      parse_mode(form["local_window_alert_mode"], [:enabled, :disabled], :local_window_alert_mode, errors)

    {target_mode, errors} = parse_mode(form["local_only_target_mode"], [:target, :none], :local_only_target_mode, errors)

    {lo_max_mode, errors} =
      parse_mode(form["local_only_max_age_mode"], [:limited, :unlimited], :local_only_max_age_mode, errors)

    {arch_ret_mode, errors} =
      parse_mode(form["archive_retention_mode"], [:limited, :unlimited], :archive_retention_mode, errors)

    {obj_budget_mode, errors} =
      parse_mode(form["object_budget_mode"], [:limited, :unlimited], :object_budget_mode, errors)

    {max_local_sec, errors} =
      parse_paired_int(
        form,
        raw_params,
        "max_local_age_seconds",
        :max_local_age_seconds,
        max_local_mode == :limited,
        phase,
        errors
      )

    {alert_sec, errors} =
      parse_paired_int(
        form,
        raw_params,
        "local_window_alert_seconds",
        :local_window_alert_seconds,
        alert_mode == :enabled,
        phase,
        errors
      )

    {target_sec, errors} =
      parse_paired_int(
        form,
        raw_params,
        "local_only_retention_target_seconds",
        :local_only_retention_target_seconds,
        target_mode == :target,
        phase,
        errors
      )

    {lo_max_sec, errors} =
      parse_paired_int(
        form,
        raw_params,
        "local_only_max_age_seconds",
        :local_only_max_age_seconds,
        lo_max_mode == :limited,
        phase,
        errors
      )

    {arch_days, errors} =
      parse_paired_int(
        form,
        raw_params,
        "archive_retention_days",
        :archive_retention_days,
        arch_ret_mode == :limited,
        phase,
        errors
      )

    {obj_bytes, errors} =
      parse_paired_int(
        form,
        raw_params,
        "object_budget_bytes",
        :object_budget_bytes,
        obj_budget_mode == :limited,
        phase,
        errors
      )

    {local_policy, errors} =
      parse_optional_policy(
        form["local_only_full_policy"],
        [:overwrite_oldest, :stop_when_full],
        :local_only_full_policy,
        errors
      )

    {object_policy, errors} =
      parse_optional_policy(
        form["object_capacity_policy"],
        [:reap_oldest, :stop_archiving],
        :object_capacity_policy,
        errors
      )

    attrs = %{
      local_high_water_percent: local_high,
      local_low_water_percent: local_low,
      max_local_age_mode: max_local_mode,
      max_local_age_seconds: max_local_sec,
      local_window_alert_mode: alert_mode,
      local_window_alert_seconds: alert_sec,
      local_only_full_policy: local_policy,
      local_only_target_mode: target_mode,
      local_only_retention_target_seconds: target_sec,
      local_only_max_age_mode: lo_max_mode,
      local_only_max_age_seconds: lo_max_sec,
      archive_retention_mode: arch_ret_mode,
      archive_retention_days: arch_days,
      object_budget_mode: obj_budget_mode,
      object_budget_bytes: obj_bytes,
      object_high_water_percent: obj_high,
      object_low_water_percent: obj_low,
      object_capacity_policy: object_policy
    }

    {attrs, errors}
  end

  defp parse_required_int(form, key, field, errors) do
    case Integer.parse(form[key] || "") do
      {val, ""} -> {val, errors}
      _ -> {nil, Map.put(errors, field, "must be a whole number")}
    end
  end

  defp parse_paired_int(form, raw_params, key, field, active?, phase, errors) do
    raw = form[key] || ""

    cond do
      not active? and phase == :preview ->
        {nil, errors}

      not active? and not explicit_non_empty_param?(raw_params, key) ->
        {nil, errors}

      raw == "" ->
        {nil, errors}

      true ->
        case Integer.parse(raw) do
          {val, ""} -> {val, errors}
          _ -> {nil, Map.put(errors, field, "must be a whole number")}
        end
    end
  end

  defp explicit_non_empty_param?(raw_params, key) when is_map(raw_params) do
    case Map.get(raw_params, key) do
      val when is_binary(val) -> String.trim(val) != ""
      val when is_integer(val) -> true
      _ -> false
    end
  end

  defp parse_mode(raw, allowed, field, errors) do
    case Enum.find(allowed, &(Atom.to_string(&1) == raw)) do
      nil -> {hd(allowed), Map.put(errors, field, "invalid selection")}
      mode -> {mode, errors}
    end
  end

  defp parse_optional_policy(raw, _allowed, _field, errors) when raw in [nil, "", "unset"] do
    {nil, errors}
  end

  defp parse_optional_policy(raw, allowed, field, errors) do
    case Enum.find(allowed, &(Atom.to_string(&1) == raw)) do
      nil -> {nil, Map.put(errors, field, "invalid policy selection")}
      pol -> {pol, errors}
    end
  end

  defp confirmation_gate_errors(form, _existing) do
    errors = %{}

    errors =
      if form["local_only_full_policy"] == "overwrite_oldest" and
           not truthy?(form["confirm_local_only_overwrite"]) do
        Map.put(
          errors,
          :local_only_full_policy,
          "Confirm overwrite_oldest before saving, or choose stop_when_full / leave unset."
        )
      else
        errors
      end

    if form["object_capacity_policy"] == "reap_oldest" and
         not truthy?(form["confirm_reap_oldest"]) do
      Map.put(
        errors,
        :object_capacity_policy,
        "Confirm reap_oldest before saving, or choose stop_archiving."
      )
    else
      errors
    end
  end

  defp validate_preview_changeset(attrs, existing, scope) do
    base_struct = coerce_settings_struct(existing)

    preview_loaders = %{
      binding_loader: fn id -> {:ok, %{id: id}} end,
      secret_loader: fn id ->
        {:ok,
         %{
           id: id,
           name: "preview",
           provider: @archive_provider,
           credential_kind: :opaque,
           rotation_state: :active,
           enabled: true,
           metadata: %{}
         }}
      end
    }

    opts =
      if is_nil(scope),
        do: [actor: SystemActor.system(:camera_recording_settings)],
        else: actor_opts(scope)

    changeset =
      RecordingArchiveSettings.preview_changeset(
        attrs,
        opts
        |> Keyword.put(:existing, base_struct)
        |> Keyword.put(:loaders, preview_loaders)
      )

    extract_changeset_field_errors(changeset.errors)
  end

  defp coerce_settings_struct(%RecordingArchiveSettings{} = s), do: s

  defp coerce_settings_struct(map) when is_map(map) do
    defaults = RecordingArchiveSettings.default_settings()
    allowed_keys = Map.keys(Map.from_struct(defaults))
    taken = Map.take(map, allowed_keys)
    struct(defaults, taken)
  end

  defp coerce_settings_struct(_), do: RecordingArchiveSettings.default_settings()

  defp extract_retention_errors(%{errors: nested}) when is_list(nested) do
    mapped = extract_changeset_field_errors(nested)
    if mapped == %{}, do: %{base: format_ash_errors(nested)}, else: mapped
  end

  defp extract_retention_errors(err) when is_exception(err) do
    %{base: Exception.message(err)}
  end

  defp extract_retention_errors(err) when is_binary(err), do: %{base: err}
  defp extract_retention_errors(err), do: %{base: inspect(err)}

  defp extract_changeset_field_errors(errors_list) when is_list(errors_list) do
    Enum.reduce(errors_list, %{}, fn err, acc ->
      field = Map.get(err, :field)
      msg = Exception.message(err)

      if is_atom(field) and not is_nil(field) do
        Map.put_new(acc, field, msg)
      else
        Map.put_new(acc, :base, msg)
      end
    end)
  end

  defp build_safe_projection_attrs(form, existing) do
    defaults = RecordingArchiveSettings.default_settings()

    %{
      active_archive_binding_id: existing && Map.get(existing, :active_archive_binding_id),
      archive_enabled: existing != nil and Map.get(existing, :archive_enabled) == true,
      local_high_water_percent: safe_int(form["local_high_water_percent"], defaults.local_high_water_percent),
      local_low_water_percent: safe_int(form["local_low_water_percent"], defaults.local_low_water_percent),
      max_local_age_mode: safe_mode(form["max_local_age_mode"], [:limited, :unlimited], :limited),
      max_local_age_seconds: safe_optional_int(form["max_local_age_seconds"]),
      local_window_alert_mode: safe_mode(form["local_window_alert_mode"], [:enabled, :disabled], :enabled),
      local_window_alert_seconds: safe_optional_int(form["local_window_alert_seconds"]),
      local_only_full_policy: safe_mode(form["local_only_full_policy"], [:overwrite_oldest, :stop_when_full], nil),
      local_only_target_mode: safe_mode(form["local_only_target_mode"], [:target, :none], :target),
      local_only_retention_target_seconds: safe_optional_int(form["local_only_retention_target_seconds"]),
      local_only_max_age_mode: safe_mode(form["local_only_max_age_mode"], [:limited, :unlimited], :unlimited),
      local_only_max_age_seconds: safe_optional_int(form["local_only_max_age_seconds"]),
      archive_retention_mode: safe_mode(form["archive_retention_mode"], [:limited, :unlimited], :limited),
      archive_retention_days: safe_optional_int(form["archive_retention_days"]),
      object_budget_mode: safe_mode(form["object_budget_mode"], [:limited, :unlimited], :unlimited),
      object_budget_bytes: safe_optional_int(form["object_budget_bytes"]),
      object_high_water_percent: safe_int(form["object_high_water_percent"], defaults.object_high_water_percent),
      object_low_water_percent: safe_int(form["object_low_water_percent"], defaults.object_low_water_percent),
      object_capacity_policy: safe_mode(form["object_capacity_policy"], [:reap_oldest, :stop_archiving], nil)
    }
  end

  defp build_simulator_inputs(sim_form, usage_summary, storage_mode) do
    archive = Map.get(usage_summary, :archive, %{})
    local_blocks = Map.get(usage_summary, :local_blocks, %{})
    local_proj = Map.get(usage_summary, :local_projection, %{})
    object_proj = Map.get(usage_summary, :object_projection, %{})

    sim_cameras = safe_optional_int(sim_form["camera_count"])
    sim_kbps = safe_optional_int(sim_form["nominal_bitrate_kbps"])
    sim_gib = safe_optional_int(sim_form["local_budget_gib"])

    sim_override_active? =
      is_integer(sim_cameras) and sim_cameras > 0 and is_integer(sim_kbps) and sim_kbps > 0

    default_cameras =
      if Map.get(local_blocks, :total_reserved_blocks, 0) > 0 or
           Map.get(archive, :archived_block_count, 0) > 0,
         do: 1,
         else: 0

    %{
      storage_mode: storage_mode,
      archive_used_bytes: Map.get(archive, :archive_used_bytes, 0),
      trailing_24h_bytes: if(sim_override_active?, do: 0, else: Map.get(archive, :trailing_24h_bytes, 0)),
      trailing_7d_bytes: if(sim_override_active?, do: 0, else: Map.get(archive, :trailing_7d_bytes, 0)),
      trailing_7d_daily_mean_bytes:
        if(sim_override_active?, do: 0.0, else: Map.get(archive, :trailing_7d_daily_mean_bytes, 0.0)),
      history_seconds: if(sim_override_active?, do: 0, else: Map.get(archive, :history_seconds, 0)),
      local_history_seconds: if(sim_override_active?, do: 0, else: Map.get(local_blocks, :history_seconds, 0)),
      r15m_bytes_per_sec: if(sim_override_active?, do: 0.0, else: Map.get(local_proj, :rate_bytes_per_sec, 0.0)),
      r6h_bytes_per_sec: 0.0,
      camera_count:
        cond do
          is_integer(sim_cameras) and sim_cameras >= 0 -> sim_cameras
          is_integer(sim_kbps) and sim_kbps > 0 -> max(default_cameras, 1)
          true -> default_cameras
        end,
      nominal_bitrate_bps: if(is_integer(sim_kbps) and sim_kbps > 0, do: sim_kbps * 1_000, else: 0),
      local_budget_bytes:
        if(is_integer(sim_gib) and sim_gib > 0,
          do: sim_gib * @bytes_per_gib,
          else: Map.get(local_proj, :effective_budget_bytes, @bytes_per_gib)
        ),
      pinned_bytes: Map.get(local_proj, :pinned_bytes, 0),
      non_reapable_bytes: Map.get(object_proj, :non_reapable_bytes, 0)
    }
  end

  defp safe_int(val, fallback) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} -> n
      _ -> fallback
    end
  end

  defp safe_int(val, _fallback) when is_integer(val), do: val
  defp safe_int(_, fallback), do: fallback

  defp safe_optional_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp safe_optional_int(val) when is_integer(val), do: val
  defp safe_optional_int(_), do: nil

  defp safe_mode(val, allowed, fallback) when is_binary(val) do
    Enum.find(allowed, fallback, &(Atom.to_string(&1) == val))
  end

  defp safe_mode(val, allowed, fallback) when is_atom(val) do
    if val in allowed, do: val, else: fallback
  end

  defp safe_mode(_, _allowed, fallback), do: fallback

  defp truthy?(val), do: val in [true, "true", "on", "1"]

  defp put_nested_destination_error(err, acc) do
    field = err |> Map.get(:field) |> normalize_error_field()
    msg = Exception.message(err)
    inferred = field || infer_field_from_message(String.downcase(msg))

    if inferred in [:name, :endpoint, :region, :bucket, :namespace] do
      Map.put_new(acc, inferred, msg)
    else
      acc
    end
  end

  defp infer_field_from_message(lower_msg) do
    cond do
      String.contains?(lower_msg, "endpoint") -> :endpoint
      String.contains?(lower_msg, "bucket") -> :bucket
      String.contains?(lower_msg, "region") -> :region
      String.contains?(lower_msg, "namespace") or String.contains?(lower_msg, "prefix") -> :namespace
      String.contains?(lower_msg, "name") -> :name
      true -> nil
    end
  end

  defp diagnose_submitted_fields(submitted, fallback_message) do
    errors =
      %{}
      |> maybe_put_endpoint_error(submitted["endpoint"])
      |> maybe_put_region_error(submitted["region"])
      |> maybe_put_bucket_error(submitted["bucket"])
      |> maybe_put_namespace_error(submitted["namespace"])
      |> maybe_put_name_error(submitted["name"])

    if errors == %{}, do: %{base: fallback_message}, else: errors
  end

  defp maybe_put_name_error(errors, name) when is_binary(name) do
    if Regex.match?(@operator_name_pattern, name) do
      errors
    else
      Map.put(errors, :name, "Name must match [a-z0-9][a-z0-9-]{0,62}.")
    end
  end

  defp maybe_put_name_error(errors, _), do: errors

  defp maybe_put_endpoint_error(errors, endpoint) when is_binary(endpoint) do
    if valid_https_dns_endpoint?(endpoint) do
      errors
    else
      Map.put(
        errors,
        :endpoint,
        "Endpoint must be https://<dns-name> on port 443 with no IP literal, path, query, or userinfo."
      )
    end
  end

  defp maybe_put_endpoint_error(errors, _), do: errors

  defp maybe_put_region_error(errors, region) when is_binary(region) do
    if Regex.match?(~r/\A[a-z0-9-]{1,40}\z/, region) do
      errors
    else
      Map.put(errors, :region, "Region must match [a-z0-9-]{1,40}.")
    end
  end

  defp maybe_put_region_error(errors, _), do: errors

  defp maybe_put_bucket_error(errors, bucket) when is_binary(bucket) do
    if valid_bucket_name?(bucket) do
      errors
    else
      Map.put(errors, :bucket, "Bucket must be a 3..63 character lowercase DNS bucket name.")
    end
  end

  defp maybe_put_bucket_error(errors, _), do: errors

  defp maybe_put_namespace_error(errors, namespace) when is_binary(namespace) do
    if valid_key_prefix?(namespace) do
      errors
    else
      Map.put(
        errors,
        :namespace,
        "Key prefix must be 1..128 bytes of [a-z0-9/_-] with no leading, trailing, or consecutive slashes."
      )
    end
  end

  defp maybe_put_namespace_error(errors, _), do: errors

  defp valid_https_dns_endpoint?(endpoint) do
    uri = URI.parse(endpoint)

    uri.scheme == "https" and
      is_binary(uri.host) and
      uri.host != "" and
      uri.port in [nil, 443] and
      endpoint == "https://" <> uri.host and
      uri.userinfo == nil and
      uri.path in [nil, ""] and
      uri.query == nil and
      uri.fragment == nil and
      dns_hostname?(uri.host)
  end

  defp dns_hostname?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, _ip} ->
        false

      {:error, :einval} ->
        byte_size(host) in 3..253 and
          String.contains?(host, ".") and
          Enum.all?(
            String.split(host, "."),
            &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)
          )
    end
  end

  defp valid_bucket_name?(bucket) do
    byte_size(bucket) in 3..63 and
      :inet.parse_strict_address(String.to_charlist(bucket)) == {:error, :einval} and
      Enum.all?(
        String.split(bucket, "."),
        &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)
      )
  end

  defp valid_key_prefix?(prefix) do
    byte_size(prefix) in 1..128 and
      Regex.match?(~r/\A[a-z0-9_-]+(?:\/[a-z0-9_-]+)*\z/, prefix)
  end

  defp normalize_error_field(field) when field in [:name, "name", :provisioning_ref, "provisioning_ref"], do: :name

  defp normalize_error_field(field) when field in [:endpoint, "endpoint"], do: :endpoint
  defp normalize_error_field(field) when field in [:region, "region"], do: :region
  defp normalize_error_field(field) when field in [:bucket, "bucket"], do: :bucket

  defp normalize_error_field(field) when field in [:namespace, "namespace", :key_prefix, "key_prefix"], do: :namespace

  defp normalize_error_field(_), do: nil

  defp format_error_value(v) when is_binary(v), do: v
  defp format_error_value(v) when is_list(v), do: Enum.map_join(v, "; ", &format_error_value/1)
  defp format_error_value(v), do: inspect(v)

  defp format_ash_errors(errors) do
    Enum.map_join(errors, "; ", &Exception.message/1)
  end

  defp unpack_operator_page(%Ash.Page.Keyset{results: results, more?: more?}) do
    cursor =
      if more? and results != [] do
        results |> List.last() |> Map.get(:__metadata__, %{}) |> Map.get(:keyset)
      end

    {results, cursor}
  end

  defp unpack_operator_page(%{items: items} = page) when is_list(items) do
    {items, Map.get(page, :next_cursor)}
  end

  defp unpack_operator_page(items) when is_list(items), do: {items, nil}
  defp unpack_operator_page(_other), do: {[], nil}

  defp filter_blocks_by_profile(blocks, nil), do: blocks

  defp filter_blocks_by_profile(blocks, profile_id) do
    Enum.filter(blocks, fn block ->
      to_string(Map.get(block, :stream_profile_id)) == to_string(profile_id)
    end)
  end

  defp load_receipts_for_blocks([]), do: %{}

  defp load_receipts_for_blocks(blocks) do
    block_keys =
      for block <- blocks, key = Map.get(block, :block_key), is_binary(key), uniq: true, do: key

    actor = SystemActor.system(:camera_recording_settings)

    if block_keys == [] do
      %{}
    else
      NVRArchiveReceipt
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(block_key in ^block_keys)
      |> Ash.read(actor: actor)
      |> case do
        {:ok, receipts} ->
          Map.new(receipts, fn r -> {{to_string(r.storage_id), to_string(r.block_key)}, r} end)

        {:error, _} ->
          %{}
      end
    end
  end

  @doc false
  @spec decorate_block_row(map(), map()) :: map()
  def decorate_block_row(block, receipts_by_key \\ %{}) do
    storage_id = to_string(Map.get(block, :storage_id) || "—")
    block_key = to_string(Map.get(block, :block_key) || Map.get(block, :id))
    receipt = Map.get(receipts_by_key, {storage_id, block_key})
    raw_state = Map.get(block, :state)

    %{
      id: to_string(Map.get(block, :id) || block_key),
      block_key: block_key,
      storage_id: storage_id,
      stream_profile_id: Map.get(block, :stream_profile_id),
      inserted_at: Map.get(block, :inserted_at),
      core_state_label: core_reservation_label(raw_state),
      local_copy_label: "Unknown (NVR lookup unavailable)",
      archive_copy_label: if(receipt, do: "Verified receipt", else: "No receipt in Core"),
      receipt: receipt,
      receipt_objects: if(receipt, do: List.wrap(Map.get(receipt, :objects)), else: [])
    }
  end

  defp core_reservation_label(state) when state in [:open_local, "open_local"], do: "Core reservation"

  defp core_reservation_label(state) when is_atom(state) and not is_nil(state), do: Atom.to_string(state)

  defp core_reservation_label(state) when is_binary(state), do: state
  defp core_reservation_label(_), do: "Core reservation"

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(val), do: val

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(val), do: to_string(val)

  defp scope_holds?(%{permissions: %MapSet{} = permissions}, permission) when is_binary(permission) do
    CoreRBAC.Catalog.holds?(permissions, permission)
  end

  defp scope_holds?(%{user: user}, permission) when not is_nil(user) and is_binary(permission) do
    CoreRBAC.has_permission?(user, permission)
  end

  defp scope_holds?(_scope, _permission), do: false

  defp actor_opts(%{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    actor =
      user
      |> Map.take([:id, :email, :role, :role_profile_id])
      |> Map.put(:permissions, permissions)

    [actor: actor]
  end

  defp actor_opts(scope), do: [scope: scope]
end
