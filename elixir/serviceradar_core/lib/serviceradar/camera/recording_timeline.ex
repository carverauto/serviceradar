defmodule ServiceRadar.Camera.RecordingTimeline do
  @moduledoc """
  Core query, copy-resolution planning, integrity-failure state transition, and
  access-audit service for unified per-camera timeline playback (`D.3`, `D.4`,
  `design.md` `D1`–`D8`, `T`, `R2`, `spec.md:135-165, 614-677`).

  Supports both live CNPG execution and `:loaders` injection for `:db_free` unit
  suites in `serviceradar_core` and `web-ng`.
  """

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveCredentialResolver
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingAccessAudit
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingGap
  alias ServiceRadar.Camera.RecordingHold
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Camera.RecordingOperation
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query
  require Logger

  defmodule RedactedCredential do
    @moduledoc """
    Per-request archive reader credential wrapper (`design.md` `D6`, `spec.md:652-666`).

    Implements `@derive {Inspect, except: [...]}` so secret material can never be
    logged, inspected, or leaked into exception messages.
    """

    @derive {Inspect,
             except: [
               :access_key_id,
               :secret_access_key,
               :session_token,
               :headers,
               :credential
             ]}

    defstruct [
      :reference,
      :generation,
      :role,
      :secret_id,
      :access_key_id,
      :secret_access_key,
      :session_token,
      :headers,
      :credential
    ]

    @type t :: %__MODULE__{
            reference: String.t() | nil,
            generation: pos_integer() | nil,
            role: :reader | nil,
            secret_id: String.t() | nil,
            access_key_id: String.t() | nil,
            secret_access_key: String.t() | nil,
            session_token: String.t() | nil,
            headers: map() | list() | nil,
            credential: map() | nil
          }
  end

  @hex64 ~r/\A[0-9a-f]{64}\z/
  @system_actor SystemActor.system(:camera_recording_timeline)

  @max_coverage_span_us 31 * 86_400 * 1_000_000
  @default_bucket_count 120
  @max_bucket_count 1_440

  @max_playlist_window_us 3_600_000_000
  @max_playlist_segments 2_048

  @max_init_bytes 1_048_576
  @max_fragment_bytes 4_194_304
  @max_fragment_index 4_095

  @operator_deadline_seconds 300

  @read_permissions [
    "devices.cameras.recordings.view",
    "settings.recording.view",
    "settings.recording.manage",
    "settings.recording.operate"
  ]

  @type source_mode :: :auto | :local | :archive
  @type selector :: :init | {:fragment, non_neg_integer()}

  @doc """
  Fast boolean check whether `camera_source_id` has any `RecordingCatalogEntry`,
  `RecordingGap`, `RecordingHold`, or `CameraRecordingPolicy` rows (`D.5`).
  """
  @spec has_timeline_data?(String.t(), keyword()) :: boolean()
  def has_timeline_data?(camera_source_id, opts \\ [])
      when is_binary(camera_source_id) and is_list(opts) do
    with {:ok, camera_uuid} <- cast_uuid(camera_source_id, :invalid_camera_source_id),
         :ok <- authorize_optional_caller(opts) do
      loaders = Keyword.get(opts, :loaders, %{})
      check_has_timeline_data(camera_uuid, loaders)
    else
      _ -> false
    end
  end

  @doc """
  Computes bounded timeline coverage (`<= 31 days`, `1..1_440` buckets) for
  `camera_source_id` (`D1`, `D4`, `D8`, `T`, `R2`).

  Quarantined catalog entries (`local_state == :quarantined`) are strictly
  excluded from `blocks` and `buckets`; their intervals appear only via
  `RecordingGap` rows with `reason == :quarantined` when camera and media
  interval were known (`R2`).
  """
  @spec coverage(String.t(), map() | keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def coverage(camera_source_id, params \\ %{}, opts \\ [])
      when is_binary(camera_source_id) and (is_map(params) or is_list(params)) and is_list(opts) do
    attrs = to_map(params)
    loaders = Keyword.get(opts, :loaders, %{})

    with :ok <- authorize_optional_caller(opts),
         {:ok, camera_uuid} <- cast_uuid(camera_source_id, :invalid_camera_source_id),
         {:ok, profile_uuid} <- parse_optional_profile_id(attrs),
         {:ok, from_us, to_us} <- parse_coverage_window(attrs),
         {:ok, bucket_count} <- parse_bucket_count(attrs),
         {:ok, raw_entries} <-
           load_window_catalog_entries(camera_uuid, profile_uuid, from_us, to_us, false, loaders),
         {:ok, gaps} <- load_window_gaps(camera_uuid, profile_uuid, from_us, to_us, loaders),
         {:ok, holds} <- load_camera_holds(camera_uuid, profile_uuid, from_us, to_us, loaders),
         {:ok, policies} <- load_camera_policies(camera_uuid, profile_uuid, loaders),
         entries =
           filter_non_quarantined_sealed(raw_entries, camera_uuid, profile_uuid, from_us, to_us),
         {:ok, registered_sids} <- load_registered_storage_ids(entries, loaders) do
      accepted_holds = Enum.filter(holds, &(normalize_atom(fetch_val(&1, :state)) == :accepted))
      scheduled_continuous? = Enum.any?(policies, &continuous_policy?/1)

      {blocks, reanchors} =
        project_coverage_blocks_and_reanchors(entries, gaps, accepted_holds, registered_sids)

      formatted_gaps = Enum.map(gaps, &format_gap_item(&1, to_us))
      formatted_holds = Enum.map(holds, &format_hold_item(&1, entries))
      {time_basis, time_uncertainty} = summarize_time_basis(entries)

      buckets =
        aggregate_coverage_buckets(
          from_us,
          to_us,
          bucket_count,
          blocks,
          formatted_gaps,
          accepted_holds,
          reanchors,
          scheduled_continuous?
        )

      {:ok,
       %{
         camera_source_id: camera_uuid,
         stream_profile_id: profile_uuid,
         from_us: from_us,
         to_us: to_us,
         bucket_count: bucket_count,
         scheduled_continuous?: scheduled_continuous?,
         time_basis: time_basis,
         time_uncertainty: time_uncertainty,
         buckets: buckets,
         blocks: blocks,
         gaps: formatted_gaps,
         holds: formatted_holds,
         reanchors: reanchors
       }}
    end
  end

  @doc """
  Classifies a non-quarantined `RecordingCatalogEntry`'s copy state for timeline
  coverage (`D8`, `C1`, `spec.md:284-290, 517-524, 622`).
  """
  @spec copy_state(map()) ::
          :local_and_archived
          | :archive_only
          | :pending_archive
          | :local_only
          | :local_only_after_archive
          | :deleted_by_retention
          | :quarantined
          | :unavailable
  def copy_state(entry) when is_map(entry) do
    local_state = normalize_atom(fetch_val(entry, :local_state))
    archive_state = normalize_atom(fetch_val(entry, :archive_state))
    archive_binding_id = fetch_val(entry, :archive_binding_id)
    q_reason = fetch_val(entry, :quarantine_reason)

    cond do
      local_state == :quarantined or not is_nil(q_reason) ->
        :quarantined

      local_state == :present and archive_state == :verified ->
        :local_and_archived

      local_state == :present and
          (archive_state == :deleted or
             (archive_state == :not_required and not is_nil(archive_binding_id))) ->
        :local_only_after_archive

      local_state == :present and archive_state == :not_required and is_nil(archive_binding_id) ->
        :local_only

      local_state == :present ->
        :pending_archive

      archive_state == :verified ->
        :archive_only

      local_state == :reclaimed and archive_state in [:deleted, :not_required] ->
        :deleted_by_retention

      true ->
        :unavailable
    end
  end

  @doc """
  Loads playable non-quarantined catalog entries (with frozen descriptors) and
  intersecting gaps across `[from_us, to_us)` (`<= 60 minutes`) for HLS VOD
  playlist construction, and appends one `RecordingAccessAudit` row
  (`event_kind: :playlist_window`) when `Keyword.get(opts, :record_audit?, true)`
  is true (`D2`, `D7`).
  """
  @spec issue_playlist_window(String.t(), map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def issue_playlist_window(camera_source_id, params \\ %{}, opts \\ [])
      when is_binary(camera_source_id) and (is_map(params) or is_list(params)) and is_list(opts) do
    attrs = to_map(params)
    loaders = Keyword.get(opts, :loaders, %{})
    record_audit? = Keyword.get(opts, :record_audit?, true)

    with :ok <- authorize_optional_caller(opts),
         {:ok, camera_uuid} <- cast_uuid(camera_source_id, :invalid_camera_source_id),
         {:ok, profile_uuid} <- parse_optional_profile_id(attrs),
         {:ok, from_us, to_us} <- parse_playlist_window(attrs),
         {:ok, source_mode} <- parse_source_mode(fetch_source_mode_param(attrs)),
         {:ok, raw_entries} <-
           load_window_catalog_entries(camera_uuid, profile_uuid, from_us, to_us, true, loaders),
         {:ok, gaps} <- load_window_gaps(camera_uuid, profile_uuid, from_us, to_us, loaders),
         playable_entries =
           filter_playable_for_source_mode(
             raw_entries,
             camera_uuid,
             profile_uuid,
             from_us,
             to_us,
             source_mode
           ),
         {:ok, registered_sids} <- load_registered_storage_ids(playable_entries, loaders),
         projected_entries = project_playlist_entries(playable_entries, registered_sids),
         segment_count = count_window_segments(projected_entries, from_us, to_us),
         basis_atom = primary_time_basis_atom(playable_entries),
         {:ok, audit} <-
           maybe_write_playlist_audit(
             record_audit?,
             attrs,
             opts,
             loaders,
             %{
               camera_source_id: camera_uuid,
               stream_profile_id: profile_uuid,
               from_us: from_us,
               to_us: to_us,
               source_mode: source_mode,
               time_basis: basis_atom,
               segment_count: segment_count,
               entry_count: length(projected_entries)
             }
           ) do
      {time_basis_str, time_uncertainty_str} = summarize_time_basis(playable_entries)

      {:ok,
       %{
         camera_source_id: camera_uuid,
         stream_profile_id: profile_uuid,
         from_us: from_us,
         to_us: to_us,
         source_mode: source_mode,
         time_basis: basis_atom,
         time_basis_label: time_basis_str,
         time_uncertainty: time_uncertainty_str,
         segment_count: segment_count,
         entries: projected_entries,
         gaps: Enum.map(gaps, &format_gap_item(&1, to_us)),
         audit: audit
       }}
    end
  end

  @doc """
  Appends a `:playlist_window` `RecordingAccessAudit` row explicitly (useful when
  callers pass `record_audit?: false` to `issue_playlist_window/3` and record
  audit only after playlist serialization succeeds).
  """
  @spec record_playlist_audit(map() | keyword(), keyword()) ::
          {:ok, RecordingAccessAudit.t() | map()} | {:error, term()}
  def record_playlist_audit(attrs, opts \\ [])
      when (is_map(attrs) or is_list(attrs)) and is_list(opts) do
    params = to_map(attrs)
    loaders = Keyword.get(opts, :loaders, %{})

    with {:ok, actor_id} <- resolve_audit_actor_id(params, opts) do
      audit_params = %{
        event_kind: :playlist_window,
        actor_id: actor_id,
        camera_source_id: fetch_val(params, :camera_source_id),
        stream_profile_id: fetch_val(params, :stream_profile_id),
        window_start_us: fetch_val(params, :window_start_us) || fetch_val(params, :from_us),
        window_end_us: fetch_val(params, :window_end_us) || fetch_val(params, :to_us),
        source_mode: fetch_val(params, :source_mode) || :auto,
        time_basis: fetch_val(params, :time_basis) || :received,
        segment_count: fetch_val(params, :segment_count) || 0,
        details: fetch_val(params, :details) || %{}
      }

      case Map.get(loaders, :audit_writer) do
        writer when is_function(writer, 1) -> writer.(audit_params)
        _ -> RecordingAccessAudit.record(audit_params)
      end
    end
  end

  @doc """
  Resolves ordered read candidate plans (`:local` and/or `:archive`) for an
  initialization object (`:init`) or media fragment (`{:fragment, index}`)
  against a frozen `RecordingCatalogEntry` (`D3`, `D5`, `D6`).

  - Quarantined entries (`local_state == :quarantined`) are strictly refused with
    `{:error, :recording_unavailable}`.
  - Forced source modes (`:local` or `:archive`) never include a fallback plan.
  - Archive reader credentials are wrapped in `%RedactedCredential{}` so secret
    material can never be logged or inspected (`spec.md:652-666`).
  """
  @spec resolve_read_plans(
          String.t(),
          String.t(),
          selector(),
          source_mode() | String.t(),
          keyword()
        ) ::
          {:ok, [map()]} | {:error, term()}
  def resolve_read_plans(camera_source_id, entry_id, selector, source_mode \\ :auto, opts \\ [])
      when is_binary(camera_source_id) and is_binary(entry_id) and is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    with :ok <- authorize_optional_caller(opts),
         {:ok, camera_uuid} <- cast_uuid(camera_source_id, :invalid_camera_source_id),
         {:ok, entry_uuid} <- cast_uuid(entry_id, :invalid_entry_id),
         :ok <- validate_selector(selector),
         {:ok, mode} <- parse_source_mode(source_mode),
         {:ok, entry} <- load_entry_for_read(entry_uuid, loaders),
         :ok <- verify_entry_belongs_to_camera(entry, camera_uuid),
         :ok <- ensure_entry_not_quarantined(entry),
         {:ok, descriptor} <- extract_frozen_descriptor(entry, loaders),
         {:ok, slice} <- resolve_descriptor_slice(descriptor, selector) do
      build_candidate_plans(entry, selector, slice, mode, opts, loaders)
    end
  end

  @doc """
  Locks `entry_id` `FOR UPDATE`, transitions `local_state: :present -> :missing`
  when local bytes fail SHA-256 or byte-length verification against the frozen
  descriptor (`D3`, `spec.md:629-633`), records `"local_integrity"`, and reports
  whether a verified archive copy is available to serve instead.
  """
  @spec mark_local_integrity_failure(String.t(), keyword()) ::
          {:ok, %{entry: RecordingCatalogEntry.t() | map(), archive_verified?: boolean()}}
          | {:error, term()}
  def mark_local_integrity_failure(entry_id, opts \\ [])
      when is_binary(entry_id) and is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- authorize_optional_caller(opts),
         {:ok, entry_uuid} <- cast_uuid(entry_id, :invalid_entry_id) do
      case Map.get(loaders, :mark_local_integrity_failure) do
        fun when is_function(fun, 2) ->
          fun.(entry_uuid, opts)

        fun when is_function(fun, 1) ->
          fun.(entry_uuid)

        _ when map_size(loaders) > 0 ->
          mark_local_integrity_with_loader(entry_uuid, now, loaders)

        _ ->
          mark_local_integrity_in_db(entry_uuid, now, opts)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: has_timeline_data?
  # ---------------------------------------------------------------------------

  defp check_has_timeline_data(camera_uuid, loaders) when map_size(loaders) > 0 do
    cond do
      is_function(Map.get(loaders, :has_timeline_data_loader), 1) ->
        loaders.has_timeline_data_loader.(camera_uuid) == true

      is_function(Map.get(loaders, :has_timeline_data_loader), 0) ->
        loaders.has_timeline_data_loader.() == true

      true ->
        loader_has_camera_rows?(loaders, :catalog_loader, camera_uuid) or
          loader_has_camera_rows?(loaders, :gaps_loader, camera_uuid) or
          loader_has_camera_rows?(loaders, :holds_loader, camera_uuid) or
          loader_has_camera_rows?(loaders, :policies_loader, camera_uuid)
    end
  end

  defp check_has_timeline_data(camera_uuid, _loaders) do
    ash_exists_for_camera?(RecordingCatalogEntry, camera_uuid) or
      ash_exists_for_camera?(RecordingGap, camera_uuid) or
      ash_exists_for_camera?(RecordingHold, camera_uuid) or
      ash_exists_for_camera?(CameraRecordingPolicy, camera_uuid)
  end

  defp loader_has_camera_rows?(loaders, key, camera_uuid) do
    rows =
      case Map.get(loaders, key) do
        fun when is_function(fun, 1) -> unwrap_ok_list(fun.(camera_uuid))
        fun when is_function(fun, 0) -> unwrap_ok_list(fun.())
        _ -> []
      end

    Enum.any?(rows, fn row ->
      to_string(fetch_val(row, :camera_source_id) || "") == camera_uuid
    end)
  end

  defp ash_exists_for_camera?(resource, camera_uuid) do
    resource
    |> Ash.Query.filter(camera_source_id == ^camera_uuid)
    |> Ash.exists(actor: @system_actor)
    |> Kernel.==({:ok, true})
  end

  # ---------------------------------------------------------------------------
  # Private: Coverage & Playlist Window Loading + Projection
  # ---------------------------------------------------------------------------

  defp load_window_catalog_entries(
         camera_uuid,
         profile_uuid,
         from_us,
         to_us,
         preload_block?,
         loaders
       ) do
    cond do
      is_function(Map.get(loaders, :catalog_loader), 4) ->
        loaders.catalog_loader.(camera_uuid, profile_uuid, from_us, to_us)

      is_function(Map.get(loaders, :catalog_loader), 1) ->
        loaders.catalog_loader.(camera_uuid)

      is_function(Map.get(loaders, :catalog_loader), 0) ->
        loaders.catalog_loader.()

      map_size(loaders) > 0 ->
        {:ok, []}

      true ->
        query =
          RecordingCatalogEntry
          |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
          |> Ash.Query.filter(
            camera_source_id == ^camera_uuid and
              local_state != :quarantined and
              is_nil(quarantine_reason) and
              not is_nil(recording_block_id) and
              not is_nil(timeline_start_us) and
              not is_nil(timeline_end_us) and
              timeline_end_us > ^from_us and
              timeline_start_us < ^to_us
          )
          |> maybe_filter_profile_query(profile_uuid)
          |> Ash.Query.sort(timeline_start_us: :asc, block_key: :asc)

        query =
          if preload_block? do
            Ash.Query.load(query, recording_block: [:id, :descriptor, :descriptor_sha256, :clock])
          else
            query
          end

        Ash.read(query, actor: @system_actor)
    end
  end

  defp load_window_gaps(camera_uuid, profile_uuid, from_us, to_us, loaders) do
    cond do
      is_function(Map.get(loaders, :gaps_loader), 4) ->
        with {:ok, rows} <- loaders.gaps_loader.(camera_uuid, profile_uuid, from_us, to_us) do
          {:ok, filter_gaps_in_memory(rows, camera_uuid, profile_uuid, from_us, to_us)}
        end

      is_function(Map.get(loaders, :gaps_loader), 1) ->
        with {:ok, rows} <- loaders.gaps_loader.(camera_uuid) do
          {:ok, filter_gaps_in_memory(rows, camera_uuid, profile_uuid, from_us, to_us)}
        end

      is_function(Map.get(loaders, :gaps_loader), 0) ->
        with {:ok, rows} <- loaders.gaps_loader.() do
          {:ok, filter_gaps_in_memory(rows, camera_uuid, profile_uuid, from_us, to_us)}
        end

      map_size(loaders) > 0 ->
        {:ok, []}

      true ->
        RecordingGap
        |> Ash.Query.for_read(
          :for_camera_window,
          %{
            camera_source_id: camera_uuid,
            stream_profile_id: profile_uuid,
            from_us: from_us,
            to_us: to_us
          },
          actor: @system_actor
        )
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_camera_holds(camera_uuid, profile_uuid, from_us, to_us, loaders) do
    cond do
      is_function(Map.get(loaders, :holds_loader), 4) ->
        with {:ok, rows} <- loaders.holds_loader.(camera_uuid, profile_uuid, from_us, to_us) do
          {:ok, filter_holds_in_memory(rows, camera_uuid, profile_uuid, from_us, to_us)}
        end

      is_function(Map.get(loaders, :holds_loader), 1) ->
        with {:ok, rows} <- loaders.holds_loader.(camera_uuid) do
          {:ok, filter_holds_in_memory(rows, camera_uuid, profile_uuid, from_us, to_us)}
        end

      is_function(Map.get(loaders, :holds_loader), 0) ->
        with {:ok, rows} <- loaders.holds_loader.() do
          {:ok, filter_holds_in_memory(rows, camera_uuid, profile_uuid, from_us, to_us)}
        end

      map_size(loaders) > 0 ->
        {:ok, []}

      true ->
        query =
          RecordingHold
          |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
          |> Ash.Query.filter(
            camera_source_id == ^camera_uuid and
              start_us < ^to_us and
              end_us > ^from_us
          )

        query =
          if is_nil(profile_uuid) do
            query
          else
            Ash.Query.filter(
              query,
              is_nil(stream_profile_id) or stream_profile_id == ^profile_uuid
            )
          end

        query
        |> Ash.Query.sort(start_us: :asc, id: :asc)
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_camera_policies(camera_uuid, profile_uuid, loaders) do
    cond do
      is_function(Map.get(loaders, :policies_loader), 1) ->
        with {:ok, rows} <- loaders.policies_loader.(camera_uuid) do
          {:ok, filter_policies_in_memory(rows, camera_uuid, profile_uuid)}
        end

      is_function(Map.get(loaders, :policies_loader), 0) ->
        with {:ok, rows} <- loaders.policies_loader.() do
          {:ok, filter_policies_in_memory(rows, camera_uuid, profile_uuid)}
        end

      map_size(loaders) > 0 ->
        {:ok, []}

      true ->
        CameraRecordingPolicy
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.filter(camera_source_id == ^camera_uuid)
        |> maybe_filter_profile_query(profile_uuid)
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_registered_storage_ids(entries, loaders) do
    storage_uuids =
      for entry <- entries,
          normalize_atom(fetch_val(entry, :local_state)) == :present,
          sid = fetch_val(entry, :storage_id),
          not is_nil(sid),
          {:ok, uuid} <- [Ecto.UUID.cast(to_string(sid))],
          uniq: true,
          do: uuid

    cond do
      is_list(Map.get(loaders, :registered_storage_ids)) ->
        {:ok, MapSet.new(loaders.registered_storage_ids, &to_string/1)}

      match?(%MapSet{}, Map.get(loaders, :registered_storage_ids)) ->
        {:ok, MapSet.new(loaders.registered_storage_ids, &to_string/1)}

      is_function(Map.get(loaders, :local_storage_bindings_loader), 1) ->
        with {:ok, rows} <- loaders.local_storage_bindings_loader.(storage_uuids) do
          {:ok, extract_storage_id_set(rows)}
        end

      is_function(Map.get(loaders, :local_storage_bindings_loader), 0) ->
        with {:ok, rows} <- loaders.local_storage_bindings_loader.() do
          {:ok, extract_storage_id_set(rows)}
        end

      map_size(loaders) > 0 ->
        {:ok, MapSet.new()}

      storage_uuids == [] ->
        {:ok, MapSet.new()}

      true ->
        query_registered_storage_ids(storage_uuids)
    end
  end

  defp query_registered_storage_ids(storage_uuids) do
    import Ecto.Query, only: [from: 2]

    dumped = Enum.map(storage_uuids, &Ecto.UUID.dump!/1)

    rows =
      ServiceRadar.Repo.all(
        from(b in {"camera_local_storage_bindings", LocalStorageBinding},
          prefix: "platform",
          where: b.storage_id in ^dumped,
          distinct: b.storage_id,
          select: b.storage_id
        )
      )

    loaded =
      Enum.map(rows, fn
        <<_::128>> = bin -> Ecto.UUID.load!(bin)
        other -> to_string(other)
      end)

    {:ok, MapSet.new(loaded)}
  end

  defp extract_storage_id_set(rows) when is_list(rows) do
    rows
    |> Enum.map(fn
      sid when is_binary(sid) -> sid
      row when is_map(row) -> fetch_val(row, :storage_id)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new(&to_string/1)
  end

  defp filter_non_quarantined_sealed(entries, camera_uuid, profile_uuid, from_us, to_us) do
    entries
    |> Enum.filter(fn entry ->
      cam = fetch_val(entry, :camera_source_id)
      prof = fetch_val(entry, :stream_profile_id)
      local_state = normalize_atom(fetch_val(entry, :local_state))
      q_reason = fetch_val(entry, :quarantine_reason)
      block_id = fetch_val(entry, :recording_block_id)
      t_start = fetch_val(entry, :timeline_start_us)
      t_end = fetch_val(entry, :timeline_end_us)

      not is_nil(block_id) and
        local_state != :quarantined and
        is_nil(q_reason) and
        to_string(cam || "") == camera_uuid and
        (is_nil(profile_uuid) or to_string(prof || "") == profile_uuid) and
        is_integer(t_start) and is_integer(t_end) and
        t_end > from_us and t_start < to_us
    end)
    |> Enum.sort_by(fn entry ->
      {fetch_val(entry, :timeline_start_us), to_string(fetch_val(entry, :block_key) || "")}
    end)
  end

  defp filter_playable_for_source_mode(
         entries,
         camera_uuid,
         profile_uuid,
         from_us,
         to_us,
         source_mode
       ) do
    entries
    |> filter_non_quarantined_sealed(camera_uuid, profile_uuid, from_us, to_us)
    |> Enum.filter(&playable_in_mode?(&1, source_mode))
  end

  defp playable_in_mode?(entry, source_mode) do
    local_state = normalize_atom(fetch_val(entry, :local_state))
    archive_state = normalize_atom(fetch_val(entry, :archive_state))

    if local_state == :quarantined or not is_nil(fetch_val(entry, :quarantine_reason)) do
      false
    else
      case source_mode do
        :auto -> local_state == :present or archive_state == :verified
        :local -> local_state == :present
        :archive -> archive_state == :verified
      end
    end
  end

  defp project_coverage_blocks_and_reanchors(entries, gaps, accepted_holds, registered_sids) do
    {blocks_rev, reanchors_rev, _prev} =
      Enum.reduce(entries, {[], [], nil}, fn entry, {b_acc, r_acc, prev} ->
        local_state = normalize_atom(fetch_val(entry, :local_state))
        archive_state = normalize_atom(fetch_val(entry, :archive_state))
        sid_str = to_string(fetch_val(entry, :storage_id) || "")
        provisional? = local_state == :present and not MapSet.member?(registered_sids, sid_str)
        c_state = copy_state(entry)
        playable? = local_state == :present or archive_state == :verified
        hold_summary = RecordingHolds.summarize_entry(entry, accepted_holds)
        t_basis = normalize_time_basis(fetch_val(entry, :time_basis))
        t_unc_us = fetch_val(entry, :time_uncertainty_us)

        reanchored? =
          reanchored_boundary?(entry, prev) and
            not gap_at_boundary?(gaps, fetch_val(entry, :timeline_start_us))

        block_item = %{
          id: fetch_val(entry, :id),
          entry_id: fetch_val(entry, :id),
          recording_block_id: fetch_val(entry, :recording_block_id),
          camera_source_id: fetch_val(entry, :camera_source_id),
          stream_profile_id: fetch_val(entry, :stream_profile_id),
          storage_id: fetch_val(entry, :storage_id),
          block_key: fetch_val(entry, :block_key),
          clock_epoch: fetch_val(entry, :clock_epoch),
          run_id: fetch_val(entry, :run_id),
          anchor_id: fetch_val(entry, :anchor_id),
          timeline_start_us: fetch_val(entry, :timeline_start_us),
          timeline_end_us: fetch_val(entry, :timeline_end_us),
          media_start_ns: fetch_val(entry, :media_start_ns),
          media_end_ns: fetch_val(entry, :media_end_ns),
          fragment_count: fetch_val(entry, :fragment_count),
          media_bytes: fetch_val(entry, :media_bytes),
          local_state: local_state,
          archive_state: archive_state,
          archive_deleted_reason: fetch_val(entry, :archive_deleted_reason),
          copy_state: c_state,
          playable?: playable?,
          provisional?: provisional?,
          reanchored?: reanchored?,
          contiguous_with_previous?: fetch_val(entry, :contiguous_with_previous) == true,
          time_basis: Atom.to_string(t_basis),
          time_uncertainty: format_time_uncertainty(t_basis, t_unc_us),
          time_uncertainty_us: if(t_basis == :received, do: nil, else: t_unc_us),
          hold_summary: hold_summary
        }

        next_reanchors =
          if reanchored? do
            [
              %{
                entry_id: block_item.id,
                at_us: block_item.timeline_start_us,
                anchor_id: block_item.anchor_id,
                stream_profile_id: block_item.stream_profile_id,
                time_basis: block_item.time_basis
              }
              | r_acc
            ]
          else
            r_acc
          end

        {[block_item | b_acc], next_reanchors, entry}
      end)

    {Enum.reverse(blocks_rev), Enum.reverse(reanchors_rev)}
  end

  defp reanchored_boundary?(entry, prev) do
    cond do
      fetch_val(entry, :reanchored) == true ->
        true

      is_map(prev) and
        fetch_val(entry, :contiguous_with_previous) == true and
        not is_nil(fetch_val(entry, :anchor_id)) and
        not is_nil(fetch_val(prev, :anchor_id)) and
          fetch_val(entry, :anchor_id) != fetch_val(prev, :anchor_id) ->
        true

      true ->
        false
    end
  end

  defp gap_at_boundary?(gaps, at_us) when is_integer(at_us) do
    Enum.any?(gaps, fn gap ->
      g_start = fetch_val(gap, :start_us)
      g_end = fetch_val(gap, :end_us)
      is_integer(g_start) and g_start <= at_us and (is_nil(g_end) or g_end >= at_us)
    end)
  end

  defp gap_at_boundary?(_gaps, _at_us), do: false

  defp aggregate_coverage_buckets(
         from_us,
         to_us,
         bucket_count,
         blocks,
         gaps,
         accepted_holds,
         reanchors,
         scheduled_continuous?
       ) do
    span_us = to_us - from_us

    Enum.map(0..(bucket_count - 1), fn idx ->
      b_start = from_us + div(idx * span_us, bucket_count)

      b_end =
        if idx == bucket_count - 1 do
          to_us
        else
          from_us + div((idx + 1) * span_us, bucket_count)
        end

      b_end = max(b_end, b_start + 1)

      b_blocks =
        Enum.filter(blocks, fn b ->
          b.timeline_end_us > b_start and b.timeline_start_us < b_end
        end)

      b_gaps =
        Enum.filter(gaps, fn g ->
          g.start_us < b_end and g.effective_end_us > b_start
        end)

      held? =
        Enum.any?(accepted_holds, fn h ->
          fetch_val(h, :start_us) < b_end and fetch_val(h, :end_us) > b_start
        end)

      reanchored? =
        Enum.any?(reanchors, fn r ->
          r.at_us >= b_start and r.at_us < b_end
        end)

      provisional? = Enum.any?(b_blocks, &(&1.provisional? == true))
      block_states = b_blocks |> Enum.map(& &1.copy_state) |> Enum.uniq()
      gap_reasons = b_gaps |> Enum.map(& &1.reason) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      states = Enum.uniq(block_states ++ if(b_gaps == [], do: [], else: [:gap]))

      primary_state = pick_bucket_state(block_states, b_gaps != [], scheduled_continuous?)

      %{
        index: idx,
        start_us: b_start,
        end_us: b_end,
        state: primary_state,
        states: if(states == [], do: [primary_state], else: states),
        block_count: length(b_blocks),
        gap_count: length(b_gaps),
        gap_reasons: gap_reasons,
        provisional?: provisional?,
        reanchored?: reanchored?,
        held?: held?
      }
    end)
  end

  defp pick_bucket_state(block_states, has_gaps?, _scheduled_continuous?) do
    playable_priority = [
      :pending_archive,
      :local_only_after_archive,
      :local_only,
      :local_and_archived,
      :archive_only
    ]

    case Enum.find(playable_priority, &(&1 in block_states)) do
      nil ->
        cond do
          has_gaps? -> :gap
          :deleted_by_retention in block_states -> :deleted_by_retention
          true -> :not_scheduled
        end

      playable_state ->
        playable_state
    end
  end

  defp project_playlist_entries(entries, registered_sids) do
    Enum.map(entries, fn entry ->
      block = fetch_val(entry, :recording_block)

      descriptor =
        fetch_val(entry, :frozen_descriptor) || fetch_val(entry, :descriptor) ||
          fetch_val(block || %{}, :descriptor)

      local_state = normalize_atom(fetch_val(entry, :local_state))
      archive_state = normalize_atom(fetch_val(entry, :archive_state))
      sid_str = to_string(fetch_val(entry, :storage_id) || "")
      provisional? = local_state == :present and not MapSet.member?(registered_sids, sid_str)
      t_basis = normalize_time_basis(fetch_val(entry, :time_basis))

      %{
        id: fetch_val(entry, :id),
        entry_id: fetch_val(entry, :id),
        recording_block_id: fetch_val(entry, :recording_block_id),
        camera_source_id: fetch_val(entry, :camera_source_id),
        stream_profile_id: fetch_val(entry, :stream_profile_id),
        storage_id: fetch_val(entry, :storage_id),
        block_key: fetch_val(entry, :block_key),
        clock_epoch: fetch_val(entry, :clock_epoch),
        run_id: fetch_val(entry, :run_id),
        anchor_id: fetch_val(entry, :anchor_id),
        reanchored: fetch_val(entry, :reanchored) == true,
        contiguous_with_previous: fetch_val(entry, :contiguous_with_previous) == true,
        timeline_start_us: fetch_val(entry, :timeline_start_us),
        timeline_end_us: fetch_val(entry, :timeline_end_us),
        media_start_ns: fetch_val(entry, :media_start_ns),
        media_end_ns: fetch_val(entry, :media_end_ns),
        fragment_count: fetch_val(entry, :fragment_count),
        media_bytes: fetch_val(entry, :media_bytes),
        init_sha256: fetch_val(entry, :init_sha256),
        descriptor_sha256: fetch_val(entry, :descriptor_sha256),
        local_state: local_state,
        archive_state: archive_state,
        copy_state: copy_state(entry),
        provisional?: provisional?,
        time_basis: t_basis,
        frozen_descriptor: descriptor,
        descriptor: descriptor
      }
    end)
  end

  defp count_window_segments(projected_entries, from_us, to_us) do
    Enum.reduce(projected_entries, 0, fn entry, acc ->
      acc + entry_overlapping_fragment_count(entry, from_us, to_us)
    end)
  end

  defp entry_overlapping_fragment_count(entry, from_us, to_us) do
    t_start = entry.timeline_start_us
    base_ns = entry.media_start_ns || 0
    fragments = get_in(entry.frozen_descriptor || %{}, ["fragments"])

    if is_list(fragments) and is_integer(t_start) do
      Enum.count(fragments, fn frag ->
        frag_start_ns = Map.get(frag, "start_ns", 0)
        frag_dur_ns = Map.get(frag, "duration_ns", 0)
        frag_start_us = t_start + div(max(0, frag_start_ns - base_ns), 1_000)
        frag_end_us = frag_start_us + max(1, div(max(0, frag_dur_ns), 1_000))
        frag_end_us > from_us and frag_start_us < to_us
      end)
    else
      0
    end
  end

  defp maybe_write_playlist_audit(false, _attrs, _opts, _loaders, _summary), do: {:ok, nil}

  defp maybe_write_playlist_audit(true, attrs, opts, loaders, summary) do
    audit_empty? = Keyword.get(opts, :audit_empty?, false)

    cond do
      summary.segment_count == 0 and not audit_empty? ->
        {:ok, nil}

      summary.segment_count > @max_playlist_segments ->
        {:ok, nil}

      map_size(loaders) > 0 and not is_function(Map.get(loaders, :audit_writer), 1) ->
        {:ok, nil}

      true ->
        details = %{
          "entry_count" => summary.entry_count
        }

        record_playlist_audit(
          %{
            actor_id: fetch_val(attrs, :actor_id),
            camera_source_id: summary.camera_source_id,
            stream_profile_id: summary.stream_profile_id,
            window_start_us: summary.from_us,
            window_end_us: summary.to_us,
            source_mode: summary.source_mode,
            time_basis: summary.time_basis,
            segment_count: summary.segment_count,
            details: details
          },
          opts
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Read Plan Resolution (`D3`, `D5`, `D6`)
  # ---------------------------------------------------------------------------

  defp load_entry_for_read(entry_uuid, loaders) do
    cond do
      is_function(Map.get(loaders, :entry_loader), 1) ->
        case loaders.entry_loader.(entry_uuid) do
          {:ok, nil} -> {:error, :catalog_entry_not_found}
          {:ok, entry} when is_map(entry) -> {:ok, entry}
          {:error, _} = err -> err
        end

      is_function(Map.get(loaders, :catalog_loader), 0) ->
        with {:ok, rows} <- loaders.catalog_loader.() do
          case Enum.find(rows, &(to_string(fetch_val(&1, :id) || "") == entry_uuid)) do
            nil -> {:error, :catalog_entry_not_found}
            entry -> {:ok, entry}
          end
        end

      map_size(loaders) > 0 ->
        {:error, :catalog_entry_not_found}

      true ->
        RecordingCatalogEntry
        |> Ash.Query.filter(id == ^entry_uuid)
        |> Ash.Query.load([:recording_block, :archive_binding, :nvr_archive_receipt])
        |> Ash.read_one(actor: @system_actor)
        |> case do
          {:ok, %RecordingCatalogEntry{} = entry} -> {:ok, entry}
          {:ok, nil} -> {:error, :catalog_entry_not_found}
          {:error, _} = err -> err
        end
    end
  end

  defp verify_entry_belongs_to_camera(entry, camera_uuid) do
    if to_string(fetch_val(entry, :camera_source_id) || "") == camera_uuid do
      :ok
    else
      {:error, :catalog_entry_not_found}
    end
  end

  defp ensure_entry_not_quarantined(entry) do
    local_state = normalize_atom(fetch_val(entry, :local_state))
    q_reason = fetch_val(entry, :quarantine_reason)
    block_id = fetch_val(entry, :recording_block_id)

    if local_state == :quarantined or not is_nil(q_reason) or is_nil(block_id) do
      {:error, :recording_unavailable}
    else
      :ok
    end
  end

  defp extract_frozen_descriptor(entry, loaders) do
    direct =
      fetch_val(entry, :frozen_descriptor) ||
        fetch_val(entry, :descriptor) ||
        fetch_val(fetch_val(entry, :recording_block) || %{}, :descriptor)

    cond do
      is_map(direct) ->
        {:ok, direct}

      is_function(Map.get(loaders, :block_loader), 1) ->
        case loaders.block_loader.(fetch_val(entry, :recording_block_id)) do
          {:ok, %{descriptor: desc}} when is_map(desc) -> {:ok, desc}
          _ -> {:error, :recording_unavailable}
        end

      map_size(loaders) == 0 and not is_nil(fetch_val(entry, :recording_block_id)) ->
        case Ash.get(RecordingBlock, fetch_val(entry, :recording_block_id),
               actor: @system_actor,
               not_found_error?: false
             ) do
          {:ok, %RecordingBlock{descriptor: desc}} when is_map(desc) -> {:ok, desc}
          _ -> {:error, :recording_unavailable}
        end

      true ->
        {:error, :recording_unavailable}
    end
  end

  defp resolve_descriptor_slice(descriptor, :init) when is_map(descriptor) do
    case Map.get(descriptor, "init") do
      %{"length" => length, "sha256" => sha256}
      when is_integer(length) and is_binary(sha256) ->
        cond do
          length <= 0 or not Regex.match?(@hex64, sha256) ->
            {:error, :invalid_recording_range}

          length > @max_init_bytes ->
            {:error, :recording_range_too_large}

          true ->
            {:ok, %{object_name: "init.mp4", offset: 0, length: length, sha256: sha256}}
        end

      _ ->
        {:error, :invalid_recording_range}
    end
  end

  defp resolve_descriptor_slice(descriptor, {:fragment, index}) when is_map(descriptor) do
    fragments = Map.get(descriptor, "fragments")

    fragment =
      if is_list(fragments) do
        Enum.find(fragments, &(Map.get(&1, "sequence") == index))
      end

    case fragment do
      %{"offset" => offset, "length" => length, "sha256" => sha256}
      when is_integer(offset) and offset >= 0 and is_integer(length) and is_binary(sha256) ->
        cond do
          length <= 0 or not Regex.match?(@hex64, sha256) ->
            {:error, :invalid_recording_range}

          length > @max_fragment_bytes ->
            {:error, :recording_range_too_large}

          true ->
            {:ok, %{object_name: "media.m4s", offset: offset, length: length, sha256: sha256}}
        end

      nil ->
        {:error, :fragment_not_found}

      _ ->
        {:error, :invalid_recording_range}
    end
  end

  defp build_candidate_plans(entry, selector, slice, mode, opts, loaders) do
    candidate_modes =
      case mode do
        :auto -> [:local, :archive]
        :local -> [:local]
        :archive -> [:archive]
      end

    {:ok, registered_sids} = load_registered_storage_ids([entry], loaders)

    {plans_rev, last_err} =
      Enum.reduce(candidate_modes, {[], nil}, fn copy, {acc, err_acc} ->
        case build_single_copy_plan(copy, entry, selector, slice, registered_sids, opts, loaders) do
          {:ok, plan} -> {[plan | acc], err_acc}
          :skip -> {acc, err_acc}
          {:error, reason} -> {acc, reason}
        end
      end)

    plans = Enum.reverse(plans_rev)

    cond do
      plans != [] ->
        {:ok, plans}

      not is_nil(last_err) ->
        {:error, last_err}

      true ->
        {:error, :recording_unavailable}
    end
  end

  defp build_single_copy_plan(:local, entry, selector, slice, registered_sids, _opts, _loaders) do
    if normalize_atom(fetch_val(entry, :local_state)) == :present do
      sid_str = to_string(fetch_val(entry, :storage_id) || "")
      provisional? = not MapSet.member?(registered_sids, sid_str)

      {:ok,
       %{
         copy: :local,
         provisional?: provisional?,
         recording_copy_header: if(provisional?, do: "local; provisional", else: "local"),
         camera_source_id: fetch_val(entry, :camera_source_id),
         entry_id: fetch_val(entry, :id),
         recording_block_id: fetch_val(entry, :recording_block_id),
         storage_id: fetch_val(entry, :storage_id),
         block_key: fetch_val(entry, :block_key),
         selector: selector,
         first: slice.offset,
         last: slice.offset + slice.length - 1,
         expected_length: slice.length,
         expected_sha256: slice.sha256,
         descriptor_sha256: fetch_val(entry, :descriptor_sha256)
       }}
    else
      :skip
    end
  end

  defp build_single_copy_plan(:archive, entry, selector, slice, _registered_sids, opts, loaders) do
    if normalize_atom(fetch_val(entry, :archive_state)) == :verified do
      with {:ok, binding} <- resolve_archive_binding(entry, loaders),
           {:ok, receipt} <- resolve_archive_receipt(entry, binding, loaders),
           {:ok, object} <- verify_receipt_object(entry, binding, receipt, selector, slice) do
        {redacted_cred, cred_err} = resolve_reader_credential(binding, opts, loaders)

        {:ok,
         %{
           copy: :archive,
           provisional?: false,
           recording_copy_header: "archive",
           camera_source_id: fetch_val(entry, :camera_source_id),
           entry_id: fetch_val(entry, :id),
           recording_block_id: fetch_val(entry, :recording_block_id),
           storage_id: fetch_val(entry, :storage_id),
           block_key: fetch_val(entry, :block_key),
           selector: selector,
           binding_id: fetch_val(binding, :id),
           destination_sha256: fetch_val(binding, :destination_sha256),
           endpoint: fetch_val(binding, :endpoint),
           region: fetch_val(binding, :region),
           bucket: fetch_val(binding, :bucket),
           namespace: fetch_val(binding, :namespace),
           destination: %{
             "provider" => fetch_val(binding, :provider),
             "endpoint" => fetch_val(binding, :endpoint),
             "region" => fetch_val(binding, :region),
             "bucket" => fetch_val(binding, :bucket),
             "namespace" => fetch_val(binding, :namespace),
             "required_encryption" => fetch_val(binding, :required_encryption),
             "destination_sha256" => fetch_val(binding, :destination_sha256)
           },
           object_name: slice.object_name,
           key: object["key"],
           object_key: object["key"],
           etag: object["etag"],
           version_id: Map.get(object, "version_id"),
           object_size: object["length"],
           object_sha256: object["sha256"],
           first: slice.offset,
           last: slice.offset + slice.length - 1,
           expected_length: slice.length,
           expected_sha256: slice.sha256,
           descriptor_sha256: fetch_val(entry, :descriptor_sha256),
           credential: redacted_cred,
           credential_error: cred_err
         }}
      end
    else
      :skip
    end
  end

  defp resolve_archive_binding(entry, loaders) do
    preloaded = fetch_val(entry, :archive_binding)
    binding_id = fetch_val(entry, :archive_binding_id)

    cond do
      is_map(preloaded) and not is_struct(preloaded, Ash.NotLoaded) and
          not is_nil(fetch_val(preloaded, :id)) ->
        {:ok, preloaded}

      is_nil(binding_id) ->
        {:error, :recording_unavailable}

      is_function(Map.get(loaders, :binding_loader), 1) ->
        case loaders.binding_loader.(binding_id) do
          {:ok, binding} when is_map(binding) -> {:ok, binding}
          _ -> {:error, :recording_unavailable}
        end

      map_size(loaders) > 0 ->
        {:error, :recording_unavailable}

      true ->
        case Ash.get(ArchiveBinding, binding_id, actor: @system_actor, not_found_error?: false) do
          {:ok, %ArchiveBinding{} = binding} -> {:ok, binding}
          _ -> {:error, :recording_unavailable}
        end
    end
  end

  defp resolve_archive_receipt(entry, binding, loaders) do
    preloaded = fetch_val(entry, :nvr_archive_receipt)
    receipt_id = fetch_val(entry, :nvr_archive_receipt_id)
    sid = fetch_val(entry, :storage_id)
    bkey = fetch_val(entry, :block_key)
    binding_id = fetch_val(binding, :id)

    cond do
      is_map(preloaded) and not is_struct(preloaded, Ash.NotLoaded) and
          is_list(fetch_val(preloaded, :objects)) ->
        {:ok, preloaded}

      is_function(Map.get(loaders, :receipt_loader), 1) ->
        case loaders.receipt_loader.(entry) do
          {:ok, receipt} when is_map(receipt) -> {:ok, receipt}
          _ -> {:error, :recording_unavailable}
        end

      map_size(loaders) > 0 ->
        {:error, :recording_unavailable}

      not is_nil(receipt_id) ->
        case Ash.get(NVRArchiveReceipt, receipt_id, actor: @system_actor, not_found_error?: false) do
          {:ok, %NVRArchiveReceipt{} = receipt} -> {:ok, receipt}
          _ -> {:error, :recording_unavailable}
        end

      true ->
        NVRArchiveReceipt
        |> Ash.Query.filter(
          storage_id == ^sid and block_key == ^bkey and archive_binding_id == ^binding_id
        )
        |> Ash.read_one(actor: @system_actor)
        |> case do
          {:ok, %NVRArchiveReceipt{} = receipt} -> {:ok, receipt}
          _ -> {:error, :recording_unavailable}
        end
    end
  end

  defp verify_receipt_object(entry, binding, receipt, selector, slice) do
    namespace = fetch_val(binding, :namespace)
    sid = to_string(fetch_val(entry, :storage_id))
    bkey = to_string(fetch_val(entry, :block_key))
    expected_key = Enum.join([namespace, sid, bkey, slice.object_name], "/")
    objects = fetch_val(receipt, :objects) || []

    object =
      Enum.find(objects, fn obj ->
        (obj["name"] || Map.get(obj, :name)) == slice.object_name
      end)

    case normalize_receipt_object(object) do
      nil ->
        {:error, :recording_unavailable}

      %{"key" => key, "length" => obj_len, "sha256" => obj_sha} = norm ->
        cond do
          key != expected_key ->
            {:error, :archive_key_family_mismatch}

          selector == :init and (obj_len != slice.length or obj_sha != slice.sha256) ->
            {:error, :archive_receipt_mismatch}

          slice.offset + slice.length > obj_len ->
            {:error, :invalid_recording_range}

          true ->
            {:ok, norm}
        end
    end
  end

  defp normalize_receipt_object(nil), do: nil

  defp normalize_receipt_object(obj) when is_map(obj) do
    %{
      "name" => fetch_val(obj, :name),
      "key" => fetch_val(obj, :key),
      "length" => fetch_val(obj, :length),
      "sha256" => fetch_val(obj, :sha256),
      "etag" => fetch_val(obj, :etag),
      "version_id" => fetch_val(obj, :version_id)
    }
  end

  defp resolve_reader_credential(binding, opts, loaders) do
    custom_resolver =
      Keyword.get(opts, :credential_resolver) || Map.get(loaders, :credential_resolver)

    cond do
      is_function(custom_resolver, 2) ->
        wrap_credential_result(custom_resolver.(binding, :reader))

      is_function(custom_resolver, 1) ->
        wrap_credential_result(custom_resolver.(binding))

      map_size(loaders) > 0 ->
        resolve_reader_credential_with_loaders(binding, opts, loaders)

      true ->
        resolve_reader_credential_from_cnpg(binding, opts)
    end
  end

  defp resolve_reader_credential_with_loaders(binding, opts, loaders) do
    case Map.get(loaders, :settings_loader) do
      fun when is_function(fun, 0) ->
        case fun.() do
          {:ok, settings} ->
            secret_id = reader_or_writer_secret_id(settings)

            if is_nil(secret_id) do
              {nil, {:credential_error, :archive_reader_credential_not_configured}}
            else
              {nil, {:credential_error, :credential_resolver_not_configured}}
            end

          {:error, reason} ->
            {nil, {:credential_error, reason}}
        end

      _ ->
        _ = {binding, opts}
        {nil, {:credential_error, :credential_resolver_not_configured}}
    end
  end

  defp resolve_reader_credential_from_cnpg(binding, opts) do
    case RecordingArchiveSettings.get_settings(actor: @system_actor) do
      {:ok, settings} ->
        case reader_or_writer_secret_id(settings) do
          nil ->
            {nil, {:credential_error, :archive_reader_credential_not_configured}}

          secret_id ->
            resolver_opts =
              opts
              |> Keyword.take([
                :now,
                :ttl_seconds,
                :secret_loader,
                :grant_issuer,
                :broker,
                :audit?
              ])
              |> Keyword.put_new(:actor, @system_actor)

            binding
            |> ArchiveCredentialResolver.resolve_for_binding(:reader, secret_id, resolver_opts)
            |> wrap_credential_result(secret_id)
        end

      {:error, reason} ->
        {nil, {:credential_error, reason}}
    end
  end

  defp reader_or_writer_secret_id(settings) when is_map(settings) do
    fetch_val(settings, :reader_credential_secret_id) ||
      fetch_val(settings, :writer_credential_secret_id)
  end

  defp wrap_credential_result(result, default_secret_id \\ nil)

  defp wrap_credential_result({:ok, %RedactedCredential{} = cred}, _default_secret_id) do
    {cred, nil}
  end

  defp wrap_credential_result({:ok, doc}, default_secret_id) when is_map(doc) do
    cred = %RedactedCredential{
      reference: fetch_val(doc, :reference),
      generation: fetch_val(doc, :generation),
      role: :reader,
      secret_id: fetch_val(doc, :secret_id) || default_secret_id,
      access_key_id: fetch_val(doc, :access_key_id),
      secret_access_key: fetch_val(doc, :secret_access_key),
      session_token: fetch_val(doc, :session_token),
      headers: fetch_val(doc, :headers),
      credential: doc
    }

    {cred, nil}
  end

  defp wrap_credential_result({:error, reason}, _default_secret_id) do
    {nil, {:credential_error, reason}}
  end

  defp wrap_credential_result(other, _default_secret_id) do
    {nil, {:credential_error, other}}
  end

  # ---------------------------------------------------------------------------
  # Private: Local Integrity Failure (`D3`, `spec.md:629-633`)
  # ---------------------------------------------------------------------------

  defp mark_local_integrity_with_loader(entry_uuid, now, loaders) do
    with {:ok, entry} <- load_entry_for_read(entry_uuid, loaders) do
      local_state = normalize_atom(fetch_val(entry, :local_state))
      archive_state = normalize_atom(fetch_val(entry, :archive_state))

      case local_state do
        :present ->
          updated = Map.merge(entry, %{local_state: :missing, local_state_at: now})
          {:ok, %{entry: updated, archive_verified?: archive_state == :verified}}

        :missing ->
          {:ok, %{entry: entry, archive_verified?: archive_state == :verified}}

        other ->
          {:error, {:invalid_local_state, other}}
      end
    end
  end

  defp mark_local_integrity_in_db(entry_uuid, now, opts) do
    actor_id =
      case resolve_audit_actor_id(%{}, opts) do
        {:ok, id} -> id
        _ -> "system"
      end

    transact([RecordingCatalogEntry, RecordingOperation], fn ->
      case lock_catalog_entry(entry_uuid) do
        {:ok, %RecordingCatalogEntry{local_state: :present} = entry} ->
          Logger.warning(
            "Camera local recording copy failed integrity verification",
            block_key: entry.block_key,
            storage_id: entry.storage_id,
            reason: :local_integrity
          )

          with {:ok, updated} <-
                 entry
                 |> Ash.Changeset.for_update(:mark_local_missing, %{local_state_at: now})
                 |> Ash.update(actor: @system_actor),
               {:ok, _op} <- record_local_integrity_operation(updated, actor_id, now) do
            {:ok, %{entry: updated, archive_verified?: updated.archive_state == :verified}}
          end

        {:ok, %RecordingCatalogEntry{local_state: :missing} = entry} ->
          {:ok, %{entry: entry, archive_verified?: entry.archive_state == :verified}}

        {:ok, %RecordingCatalogEntry{local_state: other}} ->
          {:error, {:invalid_local_state, other}}

        {:error, _} = err ->
          err
      end
    end)
  end

  defp lock_catalog_entry(entry_uuid) do
    RecordingCatalogEntry
    |> Ash.Query.filter(id == ^entry_uuid)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: @system_actor)
    |> case do
      {:ok, %RecordingCatalogEntry{} = entry} -> {:ok, entry}
      {:ok, nil} -> {:error, :catalog_entry_not_found}
      {:error, _} = err -> err
    end
  end

  defp record_local_integrity_operation(%RecordingCatalogEntry{} = entry, actor_id, now) do
    summary = %{
      "catalog_entry_id" => entry.id,
      "error_class" => "local_integrity",
      "archive_verified" => entry.archive_state == :verified
    }

    start_params = %{
      kind: :local_check,
      actor_id: String.slice(actor_id, 0, 128),
      camera_source_id: entry.camera_source_id,
      stream_profile_id: entry.stream_profile_id,
      recording_block_id: entry.recording_block_id,
      block_key: entry.block_key,
      storage_id: entry.storage_id,
      archive_binding_id: entry.archive_binding_id,
      result_summary: summary,
      started_at: now,
      deadline_at: DateTime.shift(now, second: @operator_deadline_seconds)
    }

    with {:ok, op} <-
           RecordingOperation
           |> Ash.Changeset.for_create(:start, start_params, actor: @system_actor)
           |> Ash.create(actor: @system_actor) do
      op
      |> Ash.Changeset.for_update(
        :complete,
        %{
          state: :failed,
          error_class: "local_integrity",
          result_summary: summary,
          finished_at: now
        },
        actor: @system_actor
      )
      |> Ash.update(actor: @system_actor)
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Parsing, Formatting, Authorization & Helpers
  # ---------------------------------------------------------------------------

  defp authorize_optional_caller(opts) do
    if Keyword.has_key?(opts, :actor) or Keyword.has_key?(opts, :scope) do
      actor = resolve_actor(opts)

      permitted? =
        match?(%{role: :system}, actor) or
          Enum.any?(@read_permissions, fn perm ->
            ActorHasPermission.match?(actor, [permission: perm], %{})
          end)

      if permitted?, do: :ok, else: {:error, Forbidden.exception([])}
    else
      :ok
    end
  end

  defp resolve_actor(opts) do
    case Keyword.get(opts, :actor) do
      nil -> opts |> Keyword.get(:scope) |> actor_from_scope()
      explicit -> explicit
    end
  end

  defp actor_from_scope(%{user: user, permissions: %MapSet{} = permissions})
       when not is_nil(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id, :partition_id])
    |> Map.put(:permissions, permissions)
  end

  defp actor_from_scope(%{actor: actor, permissions: %MapSet{} = permissions})
       when is_map(actor) do
    Map.put(actor, :permissions, permissions)
  end

  defp actor_from_scope(%{user: user}) when not is_nil(user), do: user
  defp actor_from_scope(%{actor: actor}) when not is_nil(actor), do: actor
  defp actor_from_scope(_), do: nil

  defp resolve_audit_actor_id(params, opts) do
    actor = resolve_actor(opts)
    explicit = fetch_val(params, :actor_id) || Keyword.get(opts, :actor_id)

    raw =
      cond do
        is_binary(explicit) and String.trim(explicit) != "" ->
          explicit

        is_map(actor) ->
          Map.get(actor, :id) ||
            get_in(actor, [:user, :id]) ||
            Map.get(actor, :email) ||
            if(Map.get(actor, :role) == :system, do: "system")

        true ->
          nil
      end

    case raw do
      nil ->
        {:error, :unidentified_actor}

      val ->
        trimmed = val |> to_string() |> String.trim()

        if trimmed == "" or byte_size(trimmed) > 255 do
          {:error, :unidentified_actor}
        else
          {:ok, trimmed}
        end
    end
  end

  defp parse_coverage_window(attrs) do
    with {:ok, from_us} <- parse_int(fetch_from_param(attrs)),
         {:ok, to_us} <- parse_int(fetch_to_param(attrs)) do
      cond do
        from_us < 0 or to_us <= from_us ->
          {:error, :invalid_timeline_window}

        to_us - from_us > @max_coverage_span_us ->
          {:error, :timeline_window_too_large}

        true ->
          {:ok, from_us, to_us}
      end
    else
      _ -> {:error, :invalid_timeline_window}
    end
  end

  defp parse_playlist_window(attrs) do
    with {:ok, from_us} <- parse_int(fetch_from_param(attrs)),
         {:ok, to_us} <- parse_int(fetch_to_param(attrs)) do
      cond do
        from_us < 0 or to_us <= from_us ->
          {:error, :invalid_playlist_window}

        to_us - from_us > @max_playlist_window_us ->
          {:error, :playlist_window_too_large}

        true ->
          {:ok, from_us, to_us}
      end
    else
      _ -> {:error, :invalid_playlist_window}
    end
  end

  defp parse_bucket_count(attrs) do
    case fetch_val(attrs, :bucket_count) do
      nil ->
        {:ok, @default_bucket_count}

      raw ->
        case parse_int(raw) do
          {:ok, n} when n in 1..@max_bucket_count -> {:ok, n}
          _ -> {:error, :invalid_bucket_count}
        end
    end
  end

  defp parse_optional_profile_id(attrs) do
    raw =
      case fetch_val(attrs, :stream_profile_id) do
        nil -> fetch_val(attrs, :profile)
        val -> val
      end

    cond do
      is_nil(raw) or raw in ["", "all"] ->
        {:ok, nil}

      is_binary(raw) ->
        cast_uuid(raw, :invalid_stream_profile_id)

      true ->
        {:error, :invalid_stream_profile_id}
    end
  end

  defp parse_source_mode(val) when val in [nil, "", :auto, "auto"], do: {:ok, :auto}
  defp parse_source_mode(val) when val in [:local, "local"], do: {:ok, :local}
  defp parse_source_mode(val) when val in [:archive, "archive"], do: {:ok, :archive}
  defp parse_source_mode(_), do: {:error, :invalid_source_mode}

  defp validate_selector(:init), do: :ok

  defp validate_selector({:fragment, index})
       when is_integer(index) and index in 0..@max_fragment_index, do: :ok

  defp validate_selector(_), do: {:error, :invalid_selector}

  defp fetch_from_param(attrs) do
    case fetch_val(attrs, :from_us) do
      nil -> fetch_val(attrs, :from)
      val -> val
    end
  end

  defp fetch_to_param(attrs) do
    case fetch_val(attrs, :to_us) do
      nil -> fetch_val(attrs, :to)
      val -> val
    end
  end

  defp fetch_source_mode_param(attrs) do
    case fetch_val(attrs, :source_mode) do
      nil -> fetch_val(attrs, :source)
      val -> val
    end
  end

  defp format_gap_item(gap, window_to_us) do
    start_us = fetch_val(gap, :start_us)
    end_us = fetch_val(gap, :end_us)
    basis = normalize_time_basis(fetch_val(gap, :time_basis))
    unc_us = fetch_val(gap, :time_uncertainty_us)
    reason = normalize_gap_reason(fetch_val(gap, :reason))

    %{
      id: fetch_val(gap, :id),
      camera_source_id: fetch_val(gap, :camera_source_id),
      stream_profile_id: fetch_val(gap, :stream_profile_id),
      storage_id: fetch_val(gap, :storage_id),
      run_id: fetch_val(gap, :run_id),
      clock_epoch: fetch_val(gap, :clock_epoch),
      start_us: start_us,
      end_us: end_us,
      effective_end_us: end_us || max(window_to_us, start_us + 1),
      open?: is_nil(end_us),
      media_gap_ns: fetch_val(gap, :media_gap_ns),
      reason: reason,
      detail_class: fetch_val(gap, :detail_class),
      time_basis: Atom.to_string(basis),
      time_uncertainty: format_time_uncertainty(basis, unc_us)
    }
  end

  defp format_hold_item(hold, entries) do
    state = normalize_atom(fetch_val(hold, :state))
    covered = Enum.filter(entries, &RecordingHolds.hold_protects_entry?(hold, &1))

    pinned_copies =
      covered
      |> Enum.map(&RecordingHolds.pinned_copy_for_entry/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    pinned_copy =
      cond do
        state != :accepted -> nil
        :local in pinned_copies -> :local
        :archive in pinned_copies -> :archive
        true -> nil
      end

    archive_missing? =
      state == :accepted and
        Enum.any?(covered, &(normalize_atom(fetch_val(&1, :archive_state)) == :missing))

    %{
      id: fetch_val(hold, :id),
      camera_source_id: fetch_val(hold, :camera_source_id),
      stream_profile_id: fetch_val(hold, :stream_profile_id),
      start_us: fetch_val(hold, :start_us),
      end_us: fetch_val(hold, :end_us),
      kind: fetch_val(hold, :kind),
      state: state,
      reason: fetch_val(hold, :reason),
      created_by_id: fetch_val(hold, :created_by_id),
      accepted_at: fetch_val(hold, :accepted_at),
      released_by_id: fetch_val(hold, :released_by_id),
      released_at: fetch_val(hold, :released_at),
      release_reason: fetch_val(hold, :release_reason),
      unavailable_blocks: fetch_val(hold, :unavailable_blocks) || [],
      pinned_copy: pinned_copy,
      archive_missing?: archive_missing?
    }
  end

  defp summarize_time_basis([]), do: {"received", "unmeasured"}

  defp summarize_time_basis(entries) do
    bases =
      entries
      |> Enum.map(&normalize_time_basis(fetch_val(&1, :time_basis)))
      |> Enum.uniq()

    if bases == [:camera_reported] do
      uncertainties = Enum.map(entries, &fetch_val(&1, :time_uncertainty_us))

      if Enum.all?(uncertainties, &(is_integer(&1) and &1 >= 0)) do
        max_unc = Enum.max(uncertainties)
        {"camera_reported", "#{max_unc}us"}
      else
        {"camera_reported", "unmeasured"}
      end
    else
      {"received", "unmeasured"}
    end
  end

  defp primary_time_basis_atom([]), do: :received

  defp primary_time_basis_atom(entries) do
    bases =
      entries
      |> Enum.map(&normalize_time_basis(fetch_val(&1, :time_basis)))
      |> Enum.uniq()

    if bases == [:camera_reported], do: :camera_reported, else: :received
  end

  defp format_time_uncertainty(:received, _unc_us), do: "unmeasured"
  defp format_time_uncertainty(_basis, nil), do: "unmeasured"

  defp format_time_uncertainty(_basis, unc_us) when is_integer(unc_us) and unc_us >= 0,
    do: "#{unc_us}us"

  defp format_time_uncertainty(_basis, _), do: "unmeasured"

  defp normalize_time_basis(val) when val in [:camera_reported, "camera_reported"],
    do: :camera_reported

  defp normalize_time_basis(_), do: :received

  defp normalize_gap_reason(val) when is_atom(val) do
    if val in RecordingGap.reasons(), do: val
  end

  defp normalize_gap_reason(val) when is_binary(val) do
    Enum.find(RecordingGap.reasons(), &(Atom.to_string(&1) == val))
  end

  defp normalize_gap_reason(_), do: nil

  defp continuous_policy?(policy) do
    fetch_val(policy, :mode) in [:continuous, "continuous"]
  end

  defp filter_gaps_in_memory(rows, camera_uuid, profile_uuid, from_us, to_us) do
    rows
    |> Enum.filter(fn row ->
      cam = to_string(fetch_val(row, :camera_source_id) || "")
      prof = fetch_val(row, :stream_profile_id)
      s = fetch_val(row, :start_us)
      e = fetch_val(row, :end_us)

      cam == camera_uuid and
        (is_nil(profile_uuid) or to_string(prof || "") == profile_uuid) and
        is_integer(s) and s < to_us and (is_nil(e) or e > from_us)
    end)
    |> Enum.sort_by(&{fetch_val(&1, :start_us), to_string(fetch_val(&1, :id) || "")})
  end

  defp filter_holds_in_memory(rows, camera_uuid, profile_uuid, from_us, to_us) do
    rows
    |> Enum.filter(fn row ->
      cam = to_string(fetch_val(row, :camera_source_id) || "")
      prof = fetch_val(row, :stream_profile_id)
      s = fetch_val(row, :start_us)
      e = fetch_val(row, :end_us)

      cam == camera_uuid and
        (is_nil(profile_uuid) or is_nil(prof) or to_string(prof) == profile_uuid) and
        is_integer(s) and is_integer(e) and s < to_us and e > from_us
    end)
    |> Enum.sort_by(&{fetch_val(&1, :start_us), to_string(fetch_val(&1, :id) || "")})
  end

  defp filter_policies_in_memory(rows, camera_uuid, profile_uuid) do
    Enum.filter(rows, fn row ->
      cam = to_string(fetch_val(row, :camera_source_id) || "")
      prof = fetch_val(row, :stream_profile_id)

      cam == camera_uuid and
        (is_nil(profile_uuid) or to_string(prof || "") == profile_uuid)
    end)
  end

  defp maybe_filter_profile_query(query, nil), do: query

  defp maybe_filter_profile_query(query, profile_uuid) do
    Ash.Query.filter(query, stream_profile_id == ^profile_uuid)
  end

  defp normalize_atom(val) when is_atom(val), do: val

  defp normalize_atom(val) when is_binary(val) do
    allowed =
      RecordingCatalogEntry.local_states() ++
        RecordingCatalogEntry.archive_states() ++
        RecordingHold.states()

    Enum.find(allowed, &(Atom.to_string(&1) == val))
  end

  defp normalize_atom(_), do: nil

  defp cast_uuid(val, err_atom) when is_binary(val) do
    case Ecto.UUID.cast(val) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, err_atom}
    end
  end

  defp cast_uuid(_val, err_atom), do: {:error, err_atom}

  defp parse_int(val) when is_integer(val), do: {:ok, val}

  defp parse_int(val) when is_binary(val) do
    trimmed = String.trim(val)

    case Integer.parse(trimmed) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_int(_), do: :error

  defp unwrap_ok_list({:ok, list}) when is_list(list), do: list
  defp unwrap_ok_list(list) when is_list(list), do: list
  defp unwrap_ok_list(_), do: []

  defp transact(resources, fun) do
    resources
    |> Ash.transact(fn ->
      case fun.() do
        {:error, %_{}} = ash_error ->
          ash_error

        {:error, reason} ->
          {:error,
           InvalidArgument.exception(
             field: :recording_timeline,
             value: reason,
             message: "recording timeline transaction refused"
           )}

        other ->
          other
      end
    end)
    |> case do
      {:ok, {:ok, _} = ok_tuple} ->
        ok_tuple

      {:ok, result} ->
        {:ok, result}

      {:error, %InvalidArgument{field: :recording_timeline, value: reason}} ->
        {:error, reason}

      {:error,
       %Ash.Error.Invalid{errors: [%InvalidArgument{field: :recording_timeline, value: reason}]}} ->
        {:error, reason}

      {:error, _} = error ->
        error
    end
  end

  defp to_map(val) when is_map(val), do: val
  defp to_map(val) when is_list(val), do: Map.new(val)

  defp fetch_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
