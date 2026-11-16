defmodule ServiceRadar.Camera.RecordingBlocks do
  @moduledoc """
  Freezes historical recording authority and leases work on that exact block.

  Freeze locks ingest owner, recorder claim, then block and rechecks the original
  live recorder/relay fence before commit. Upload operations lock only the frozen
  block: later recorder generations neither grant nor revoke this authority.
  Every uploader retains its fresh token; expired tokens are never refetched.

  No object I/O belongs inside these transactions. An upload lease grants work on
  the frozen descriptor, not an archive receipt, availability or reclamation.
  Unfrozen blocks cannot be recovered or uploaded by this API.

  Upload acquisition and renewal check deployment recovery before work and after
  commit, outside DB transactions. Closure withholds the successful handle but
  retains any committed token, epoch and expiry. Release remains available.
  """
  import Ash.Expr

  alias Ash.Error.Forbidden
  alias Ash.Error.Query.InvalidArgument
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Repo
  alias ServiceRadarRecordingControl.RecoveryGate
  alias ServiceRadarRecordingMetadata.Descriptor

  require Ash.Query

  @max_epoch 9_223_372_036_854_775_807
  @operator_page_limit 25
  @operator_page_actor SystemActor.system(:camera_recording_blocks_operator_page)
  @catalog_actor SystemActor.system(:camera_recording_blocks_catalog)

  def freeze(ingest, claim, block, descriptor, opts \\ []) do
    with {:ok, bytes} <- Descriptor.encode(descriptor) do
      sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

      RecorderOwnership.with_current(
        ingest,
        claim,
        fn owner, current ->
          with {:ok, retained} <- lock(block.id, opts),
               true <-
                 original_recorder?(retained, owner, current) ||
                   {:error, :recording_block_mismatch},
               true <-
                 descriptor["identity"] == RecordingBlock.identity(retained) ||
                   {:error, :recording_block_mismatch} do
            freeze_descriptor(retained, descriptor, sha, opts)
          end
        end,
        opts
      )
    end
  end

  @doc """
  Freezes the canonical `RecordingBlock` descriptor and inserts its
  `RecordingCatalogEntry` in one database transaction under
  `RecorderOwnership.with_current` with zero external I/O (`B.3`, `B2`, `A6`).

  Exact retries with identical descriptor and catalog attributes return the
  existing `RecordingCatalogEntry` without touching copy states; conflicting
  descriptors or catalog attributes return `{:error, :recording_descriptor_conflict}`.
  """
  def freeze_and_catalog(ingest, claim, block, descriptor, catalog_attrs, opts \\ []) do
    with {:ok, bytes} <- Descriptor.encode(descriptor),
         {:ok, prepared} <- prepare_catalog_params(descriptor, bytes, catalog_attrs) do
      RecorderOwnership.with_current(
        ingest,
        claim,
        fn owner, current ->
          with {:ok, retained} <- lock(block.id, opts),
               true <-
                 original_recorder?(retained, owner, current) ||
                   {:error, :recording_block_mismatch},
               true <-
                 descriptor["identity"] == RecordingBlock.identity(retained) ||
                   {:error, :recording_block_mismatch},
               {:ok, frozen} <-
                 freeze_descriptor(retained, descriptor, prepared.descriptor_sha256, opts) do
            ensure_catalog_entry(frozen, retained.database_now, prepared)
          end
        end,
        opts
      )
    end
  end

  @doc "Run metadata reconciliation under the original frozen block lock, without external I/O."
  def with_frozen(block_id, fun, opts \\ []) do
    transaction(fn ->
      with {:ok, block} <- lock(block_id, opts),
           :ok <- uploadable(block) do
        fun.(block)
      end
    end)
  end

  def acquire_upload(block_id, token, ttl_ms, opts \\ []) do
    with {:ok, token} <- Ecto.UUID.cast(token), :ok <- ttl(ttl_ms) do
      with_recovery(fn ->
        transaction(fn ->
          with {:ok, block} <- lock(block_id, opts),
               :ok <- uploadable(block),
               :ok <- not_nvr_storage(block),
               :ok <- available(block, token),
               {:ok, claimed} <-
                 update(
                   block,
                   :claim_upload,
                   %{
                     upload_token: token,
                     upload_epoch: block.upload_epoch + 1,
                     upload_expires_at: DateTime.add(block.database_now, ttl_ms, :millisecond)
                   },
                   opts
                 ) do
            current_upload(claimed, opts)
          end
        end)
      end)
    else
      :error -> {:error, :invalid_upload_token}
      {:error, _} = error -> error
    end
  end

  def renew_upload(lease, ttl_ms, opts \\ []) do
    with :ok <- ttl(ttl_ms) do
      with_recovery(fn ->
        with_current_upload(
          lease,
          fn block ->
            update(
              block,
              :renew_upload,
              %{upload_expires_at: DateTime.add(block.database_now, ttl_ms, :millisecond)},
              opts
            )
          end,
          opts
        )
      end)
    end
  end

  @doc "Bind an unqualified destination once; this grants neither upload access nor archive availability."
  def bind_archive(lease, binding_id, destination_sha256, opts \\ []) do
    with_current_upload(
      lease,
      fn block ->
        case ArchiveBinding |> Ash.Query.filter(id == ^binding_id) |> Ash.read_one(opts) do
          {:ok, %ArchiveBinding{destination_sha256: ^destination_sha256}} ->
            case block.archive_binding_id do
              nil -> update(block, :bind_archive, %{archive_binding_id: binding_id}, opts)
              ^binding_id -> {:ok, block}
              _ -> {:error, :archive_binding_conflict}
            end

          {:ok, _} ->
            {:error, :archive_binding_mismatch}

          {:error, _} = error ->
            error
        end
      end,
      opts
    )
  end

  def release_upload(lease, opts \\ []) do
    transaction(fn ->
      with {:ok, block} <- lock(lease.id, opts),
           :ok <- matches(lease, block),
           {:ok, released} <- update(block, :release_upload, %{}, opts),
           true <- live?(block, released.database_now) || {:error, :upload_lease_lost} do
        {:ok, :released}
      end
    end)
  end

  @doc """
  Fence short CNPG work; never run external I/O here. The initially locked row's
  deadline bounds this operation even if its callback renews the lease. A later
  operation may use a legitimately renewed current row under the same handle.
  """
  def with_current_upload(lease, fun, opts \\ []) when is_function(fun, 1) do
    with_upload_deadline(lease, fun, nil, opts)
  end

  @doc """
  Additionally bounds short CNPG work by a retained operation deadline. Both
  checks use database time; renewing the upload lease cannot extend this cap.
  """
  def with_current_upload(lease, fun, %DateTime{} = deadline, opts) when is_function(fun, 1) do
    with_upload_deadline(lease, fun, deadline, opts)
  end

  def with_current_upload(_lease, _fun, _deadline, _opts), do: {:error, :invalid_upload_deadline}

  @doc """
  Returns a keyset page (default and max 25, newest first) of projected
  `RecordingBlock` rows for `camera_source_id` after authorizing
  `settings.recording.view`.

  `page_or_cursor` may be `nil`, an `after` keyset cursor string, or a keyword
  list supporting `:after`, `:before`, `:limit` (`1..25`), and `:storage_ids`.
  """
  @spec operator_page(Ecto.UUID.t(), keyword() | String.t() | nil, keyword()) ::
          {:ok, Ash.Page.Keyset.t()} | {:error, term()}
  def operator_page(camera_source_id, page_or_cursor \\ [], opts \\ []) when is_list(opts) do
    with :ok <- authorize_operator_page(opts),
         {:ok, camera_uuid} <- cast_camera_source_id(camera_source_id),
         {:ok, page_opts, storage_ids} <- normalize_operator_page_opts(page_or_cursor, opts) do
      args = %{camera_source_id: camera_uuid, storage_ids: storage_ids}

      RecordingBlock
      |> Ash.Query.for_read(:operator_page, args, actor: @operator_page_actor)
      |> Ash.read(actor: @operator_page_actor, page: page_opts)
    end
  end

  defp authorize_operator_page(opts) do
    actor =
      case Keyword.get(opts, :actor) do
        nil ->
          opts
          |> Keyword.get(:scope)
          |> actor_from_scope()

        explicit ->
          explicit
      end

    if match?(%{role: :system}, actor) or
         ActorHasPermission.match?(actor, [permission: "settings.recording.view"], %{}) do
      :ok
    else
      {:error, Forbidden.exception([])}
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
  defp actor_from_scope(%{actor: scope_actor}) when not is_nil(scope_actor), do: scope_actor
  defp actor_from_scope(_), do: nil

  defp cast_camera_source_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_camera_source_id}
    end
  end

  defp cast_camera_source_id(_), do: {:error, :invalid_camera_source_id}

  defp normalize_operator_page_opts(nil, opts), do: normalize_operator_page_opts([], opts)

  defp normalize_operator_page_opts(after_cursor, opts) when is_binary(after_cursor) do
    normalize_operator_page_opts([after: after_cursor], opts)
  end

  defp normalize_operator_page_opts(page_opts, opts) when is_list(page_opts) do
    raw_limit = Keyword.get(page_opts, :limit, @operator_page_limit)
    storage_ids_raw = Keyword.get(page_opts, :storage_ids, Keyword.get(opts, :storage_ids))

    with {:ok, limit} <- clamp_page_limit(raw_limit),
         {:ok, storage_ids} <- normalize_storage_ids(storage_ids_raw) do
      keyset_opts =
        [limit: limit, count: false]
        |> maybe_put_cursor(:after, Keyword.get(page_opts, :after))
        |> maybe_put_cursor(:before, Keyword.get(page_opts, :before))

      {:ok, keyset_opts, storage_ids}
    end
  end

  defp normalize_operator_page_opts(_, _), do: {:error, :invalid_page_options}

  defp clamp_page_limit(limit) when is_integer(limit) and limit >= 1 do
    {:ok, min(limit, @operator_page_limit)}
  end

  defp clamp_page_limit(_), do: {:error, :invalid_page_limit}

  defp normalize_storage_ids(nil), do: {:ok, nil}

  defp normalize_storage_ids(ids) when is_list(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(to_string(id)) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, {:error, :invalid_storage_id}}
      end
    end)
    |> case do
      {:ok, uuids} -> {:ok, uuids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_storage_ids(_), do: {:error, :invalid_storage_id}

  defp maybe_put_cursor(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put_cursor(opts, key, value) when is_binary(value), do: Keyword.put(opts, key, value)

  defp with_upload_deadline(lease, fun, deadline, opts) do
    transaction(fn ->
      with {:ok, block} <- lock(lease.id, opts),
           :ok <- matches(lease, block),
           :ok <- before_deadline(deadline, block.database_now),
           {:ok, result} <- publication_result(fun.(block)),
           {:ok, current} <- current_upload(lease, opts),
           true <- live?(block, current.database_now) || {:error, :upload_lease_lost},
           :ok <- before_deadline(deadline, current.database_now) do
        result
      end
    end)
  end

  defp before_deadline(nil, _now), do: :ok

  defp before_deadline(deadline, now) do
    if DateTime.after?(deadline, now), do: :ok, else: {:error, :upload_dispatch_expired}
  end

  defp freeze_descriptor(%{state: :open_local} = block, descriptor, sha, opts) do
    block
    |> Ash.Changeset.for_update(:freeze, %{descriptor: descriptor, descriptor_sha256: sha})
    |> Ash.Changeset.filter(expr(state == :open_local))
    |> Ash.update(opts)
  end

  defp freeze_descriptor(
         %{descriptor: descriptor, descriptor_sha256: sha} = block,
         descriptor,
         sha,
         _opts
       ),
       do: {:ok, block}

  defp freeze_descriptor(_, _, _, _), do: {:error, :recording_descriptor_conflict}

  defp prepare_catalog_params(descriptor, bytes, raw_attrs)
       when is_map(raw_attrs) or is_list(raw_attrs) do
    attrs = if is_map(raw_attrs), do: raw_attrs, else: Map.new(raw_attrs)
    sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    fragments = descriptor["fragments"]
    first_frag = hd(fragments)
    last_frag = List.last(fragments)
    media_start_ns = first_frag["start_ns"]
    media_end_ns = last_frag["start_ns"] + last_frag["duration_ns"]
    media_duration_ns = media_end_ns - media_start_ns
    clock = get_in(descriptor, ["identity", "clock"])

    with {:ok, time_basis} <- parse_time_basis(fetch_catalog_val(attrs, :time_basis)),
         {:ok, first_pts} <- parse_optional_non_neg_int(fetch_catalog_val(attrs, :first_unit_pts)),
         {:ok, first_received_at} <-
           parse_optional_datetime(fetch_catalog_val(attrs, :first_unit_received_at)),
         {:ok, timeline_start_us, timeline_end_us} <-
           resolve_timeline_window_us(
             attrs,
             first_received_at,
             clock,
             media_start_ns,
             media_end_ns,
             media_duration_ns
           ),
         {:ok, uncertainty_us} <-
           resolve_time_uncertainty_us(attrs, time_basis, clock),
         {:ok, policy_id} <- parse_optional_uuid(fetch_catalog_val(attrs, :policy_id)),
         {:ok, run_id} <- parse_optional_tag(fetch_catalog_val(attrs, :run_id)),
         {:ok, anchor_id} <- parse_optional_tag(fetch_catalog_val(attrs, :anchor_id)),
         {:ok, policy_storage} <- parse_policy_storage(attrs) do
      {:ok,
       %{
         descriptor_sha256: sha,
         init_sha256: descriptor["init"]["sha256"],
         media_bytes: descriptor["media"]["length"],
         fragment_count: length(fragments),
         media_start_ns: media_start_ns,
         media_end_ns: media_end_ns,
         clock_epoch: clock["clock_epoch"],
         policy_id: policy_id,
         run_id: run_id,
         first_unit_pts: first_pts,
         first_unit_received_at: first_received_at,
         timeline_start_us: timeline_start_us,
         timeline_end_us: timeline_end_us,
         time_basis: time_basis,
         time_uncertainty_us: uncertainty_us,
         anchor_id: anchor_id,
         reanchored: fetch_catalog_val(attrs, :reanchored) == true,
         contiguous_with_previous: fetch_catalog_val(attrs, :contiguous_with_previous) == true,
         policy_storage: policy_storage
       }}
    end
  end

  defp prepare_catalog_params(_, _, _), do: {:error, :invalid_catalog_attributes}

  defp parse_time_basis(nil), do: {:ok, :received}
  defp parse_time_basis(val) when val in [:received, "received"], do: {:ok, :received}

  defp parse_time_basis(val) when val in [:camera_reported, "camera_reported"],
    do: {:ok, :camera_reported}

  defp parse_time_basis(_), do: {:error, :invalid_catalog_attributes}

  defp parse_optional_non_neg_int(nil), do: {:ok, nil}
  defp parse_optional_non_neg_int(val) when is_integer(val) and val >= 0, do: {:ok, val}
  defp parse_optional_non_neg_int(_), do: {:error, :invalid_catalog_attributes}

  defp parse_optional_datetime(nil), do: {:ok, nil}

  defp parse_optional_datetime(%DateTime{} = dt) do
    {usec, _precision} = dt.microsecond
    {:ok, %{dt | microsecond: {usec, 6}}}
  end

  defp parse_optional_datetime(_), do: {:error, :invalid_catalog_attributes}

  defp resolve_timeline_window_us(
         attrs,
         first_received_at,
         clock,
         media_start_ns,
         media_end_ns,
         media_duration_ns
       ) do
    raw_start =
      case fetch_catalog_val(attrs, :timeline_start_us) do
        nil -> fetch_catalog_val(attrs, :start_us)
        val -> val
      end

    raw_end =
      case fetch_catalog_val(attrs, :timeline_end_us) do
        nil -> fetch_catalog_val(attrs, :end_us)
        val -> val
      end

    cond do
      is_integer(raw_start) ->
        end_us = if is_nil(raw_end), do: raw_start + div(media_duration_ns, 1_000), else: raw_end
        validate_timeline_bounds(raw_start, end_us)

      not is_nil(raw_start) ->
        {:error, :invalid_catalog_attributes}

      match?(%DateTime{}, first_received_at) ->
        start_us = DateTime.to_unix(first_received_at, :microsecond)
        end_us = if is_nil(raw_end), do: start_us + div(media_duration_ns, 1_000), else: raw_end
        validate_timeline_bounds(start_us, end_us)

      is_map(clock["utc_mapping"]) ->
        mapping = clock["utc_mapping"]
        origin_ns = div(mapping["origin_media_ticks"] * 1_000_000_000, clock["timebase"])
        start_us = mapping["origin_utc_usec"] + div(media_start_ns - origin_ns, 1_000)
        end_us = mapping["origin_utc_usec"] + div(media_end_ns - origin_ns, 1_000)
        validate_timeline_bounds(start_us, end_us)

      true ->
        {:error, :invalid_catalog_attributes}
    end
  end

  defp validate_timeline_bounds(start_us, end_us)
       when is_integer(start_us) and is_integer(end_us) and end_us >= start_us do
    {:ok, start_us, end_us}
  end

  defp validate_timeline_bounds(_, _), do: {:error, :invalid_catalog_attributes}

  defp resolve_time_uncertainty_us(attrs, :received, _clock) do
    if is_nil(fetch_catalog_val(attrs, :time_uncertainty_us)) do
      {:ok, nil}
    else
      {:error, :invalid_catalog_attributes}
    end
  end

  defp resolve_time_uncertainty_us(attrs, :camera_reported, clock) do
    case fetch_catalog_val(attrs, :time_uncertainty_us) do
      nil ->
        case clock["utc_mapping"] do
          %{"uncertainty_usec" => u} when is_integer(u) and u >= 0 -> {:ok, u}
          _ -> {:ok, nil}
        end

      val when is_integer(val) and val >= 0 ->
        {:ok, val}

      _ ->
        {:error, :invalid_catalog_attributes}
    end
  end

  defp parse_optional_uuid(nil), do: {:ok, nil}

  defp parse_optional_uuid(val) when is_binary(val) do
    case Ecto.UUID.cast(val) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_catalog_attributes}
    end
  end

  defp parse_optional_uuid(_), do: {:error, :invalid_catalog_attributes}

  defp parse_optional_tag(nil), do: {:ok, nil}

  defp parse_optional_tag(val) when is_binary(val) and byte_size(val) in 1..128 do
    if String.valid?(val) and String.printable?(val) do
      {:ok, val}
    else
      {:error, :invalid_catalog_attributes}
    end
  end

  defp parse_optional_tag(_), do: {:error, :invalid_catalog_attributes}

  defp parse_policy_storage(attrs) do
    case fetch_catalog_val(attrs, :policy_storage) || fetch_catalog_val(attrs, :storage) do
      nil -> {:ok, nil}
      v when v in [:local_only, "local_only"] -> {:ok, :local_only}
      v when v in [:local_and_archive, "local_and_archive"] -> {:ok, :local_and_archive}
      _ -> {:error, :invalid_catalog_attributes}
    end
  end

  defp ensure_catalog_entry(frozen, now, prepared) do
    storage_id = frozen.storage_id
    block_key = frozen.block_key

    existing_query =
      RecordingCatalogEntry
      |> Ash.Query.filter(storage_id == ^storage_id and block_key == ^block_key)
      |> Ash.Query.lock(:for_update)

    case Ash.read_one(existing_query, actor: @catalog_actor) do
      {:ok, %RecordingCatalogEntry{} = existing} ->
        if matches_catalog_retry?(existing, frozen, prepared) do
          {:ok, existing}
        else
          {:error, :recording_descriptor_conflict}
        end

      {:ok, nil} ->
        insert_sealed_catalog_entry(frozen, now, prepared)

      {:error, _} = error ->
        error
    end
  end

  defp matches_catalog_retry?(existing, frozen, prepared) do
    existing.recording_block_id == frozen.id and
      existing.descriptor_sha256 == prepared.descriptor_sha256 and
      existing.camera_source_id == frozen.camera_source_id and
      existing.stream_profile_id == frozen.stream_profile_id and
      existing.policy_id == prepared.policy_id and
      existing.clock_epoch == prepared.clock_epoch and
      existing.run_id == prepared.run_id and
      existing.first_unit_pts == prepared.first_unit_pts and
      equal_optional_datetime?(existing.first_unit_received_at, prepared.first_unit_received_at) and
      existing.timeline_start_us == prepared.timeline_start_us and
      existing.timeline_end_us == prepared.timeline_end_us and
      existing.time_basis == prepared.time_basis and
      existing.time_uncertainty_us == prepared.time_uncertainty_us and
      existing.anchor_id == prepared.anchor_id and
      existing.reanchored == prepared.reanchored and
      existing.contiguous_with_previous == prepared.contiguous_with_previous
  end

  defp equal_optional_datetime?(nil, nil), do: true

  defp equal_optional_datetime?(%DateTime{} = a, %DateTime{} = b),
    do: DateTime.compare(a, b) == :eq

  defp equal_optional_datetime?(_, _), do: false

  defp insert_sealed_catalog_entry(frozen, now, prepared) do
    {archive_state, archive_binding_id} =
      resolve_sealed_archive_transition(prepared.policy_storage)

    attrs = %{
      recording_block_id: frozen.id,
      camera_source_id: frozen.camera_source_id,
      stream_profile_id: frozen.stream_profile_id,
      policy_id: prepared.policy_id,
      storage_id: frozen.storage_id,
      block_key: frozen.block_key,
      clock_epoch: prepared.clock_epoch,
      run_id: prepared.run_id,
      media_start_ns: prepared.media_start_ns,
      media_end_ns: prepared.media_end_ns,
      first_unit_pts: prepared.first_unit_pts,
      first_unit_received_at: prepared.first_unit_received_at,
      timeline_start_us: prepared.timeline_start_us,
      timeline_end_us: prepared.timeline_end_us,
      time_basis: prepared.time_basis,
      time_uncertainty_us: prepared.time_uncertainty_us,
      anchor_id: prepared.anchor_id,
      reanchored: prepared.reanchored,
      contiguous_with_previous: prepared.contiguous_with_previous,
      fragment_count: prepared.fragment_count,
      media_bytes: prepared.media_bytes,
      init_sha256: prepared.init_sha256,
      descriptor_sha256: prepared.descriptor_sha256,
      local_state_at: now,
      archive_state: archive_state,
      archive_state_at: now,
      archive_binding_id: archive_binding_id,
      sealed_at: now
    }

    RecordingCatalogEntry
    |> Ash.Changeset.for_create(:register_sealed, attrs)
    |> Ash.create(actor: @catalog_actor)
  end

  defp resolve_sealed_archive_transition(:local_only), do: {:not_required, nil}

  defp resolve_sealed_archive_transition(_) do
    case RecordingArchiveSettings.get_settings(actor: @catalog_actor) do
      {:ok, %{archive_enabled: true, active_archive_binding_id: nil}} ->
        {:awaiting_binding, nil}

      {:ok, %{archive_enabled: true, active_archive_binding_id: binding_id}} ->
        {:pending, binding_id}

      _ ->
        {:not_required, nil}
    end
  end

  defp not_nvr_storage(%RecordingBlock{id: block_id, storage_id: storage_id}) do
    guard_actor = %{
      id: "system:camera_recording_blocks_nvr_guard",
      role: :system,
      nvr_storage_id: storage_id,
      nvr_storage_purpose: :qualify
    }

    has_local_binding? =
      LocalStorageBinding
      |> Ash.Query.filter(storage_id == ^storage_id)
      |> Ash.exists(actor: guard_actor)

    case has_local_binding? do
      {:ok, true} ->
        {:error, :nvr_local_storage_block}

      {:ok, false} ->
        has_catalog_entry? =
          RecordingCatalogEntry
          |> Ash.Query.filter(recording_block_id == ^block_id)
          |> Ash.exists(actor: @catalog_actor)

        case has_catalog_entry? do
          {:ok, true} -> {:error, :nvr_local_storage_block}
          {:ok, false} -> :ok
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp fetch_catalog_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp original_recorder?(block, owner, claim) do
    block.ingest_owner_id == owner.id and block.ingest_epoch == owner.epoch and
      block.recorder_claim_id == claim.id and block.recorder_epoch == claim.recorder_epoch and
      block.relay_session_id == owner.relay_session_id and
      block.media_ingest_id == claim.media_ingest_id and
      block.storage_id == claim.storage_id and block.camera_source_id == owner.camera_source_id and
      block.stream_profile_id == owner.stream_profile_id
  end

  defp uploadable(%{state: state, descriptor: descriptor, descriptor_sha256: sha})
       when state in [:sealed, :uploading] and is_map(descriptor) and is_binary(sha), do: :ok

  defp uploadable(_), do: {:error, :recording_block_unfrozen}

  defp available(block, token) do
    cond do
      live?(block, block.database_now) -> {:error, :upload_already_owned}
      block.upload_token == token -> {:error, :upload_token_reused}
      block.upload_epoch == @max_epoch -> {:error, :upload_epoch_exhausted}
      true -> :ok
    end
  end

  defp lock(id, opts) do
    case RecordingBlock
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.lock(:for_update)
         |> Ash.read_one(opts) do
      {:ok, %RecordingBlock{} = block} -> Ash.load(block, :database_now, opts)
      {:ok, nil} -> {:error, :recording_block_not_found}
      {:error, _} = error -> error
    end
  end

  defp current_upload(lease, opts) do
    with {:ok, block} <-
           RecordingBlock
           |> Ash.Query.filter(id == ^lease.id)
           |> Ash.Query.load(:database_now)
           |> Ash.read_one(opts),
         :ok <- matches(lease, block),
         do: {:ok, block}
  end

  defp matches(lease, %RecordingBlock{} = block) do
    if lease.upload_token == block.upload_token and lease.upload_epoch == block.upload_epoch and
         lease.descriptor_sha256 == block.descriptor_sha256 and live?(block, block.database_now),
       do: :ok,
       else: {:error, :upload_lease_lost}
  end

  defp matches(_, _), do: {:error, :upload_lease_lost}

  defp live?(%{state: :uploading, upload_expires_at: %DateTime{} = expiry}, now),
    do: DateTime.after?(expiry, now)

  defp live?(_, _), do: false

  defp update(block, action, attrs, opts) do
    epoch = block.upload_epoch

    block
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.Changeset.filter(expr(upload_epoch == ^epoch))
    |> Ash.update(Keyword.put(opts, :load, [:database_now]))
  end

  defp ttl(ms) when is_integer(ms) and ms in 1..300_000, do: :ok
  defp ttl(_), do: {:error, :invalid_ttl}
  defp publication_result(:ok), do: {:ok, :ok}
  defp publication_result({:ok, _} = result), do: {:ok, result}
  defp publication_result({:error, _} = error), do: error
  defp publication_result(_), do: {:error, :invalid_recording_publication_result}

  defp with_recovery(fun) do
    if Repo.in_transaction?() do
      {:error, :ambient_transaction}
    else
      gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)
      RecoveryGate.with_ready(gate, fun)
    end
  end

  defp transaction(fun) do
    [RecordingBlock, RecordingCatalogEntry, LocalStorageBinding]
    |> Ash.transact(fn ->
      case fun.() do
        {:error, reason} when is_atom(reason) ->
          {:error,
           InvalidArgument.exception(
             field: :recording_block,
             value: reason,
             message: "block operation refused"
           )}

        result ->
          result
      end
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, %InvalidArgument{field: :recording_block, value: reason}} ->
        {:error, reason}

      {:error,
       %Ash.Error.Invalid{errors: [%InvalidArgument{field: :recording_block, value: reason}]}} ->
        {:error, reason}

      error ->
        error
    end
  end
end
