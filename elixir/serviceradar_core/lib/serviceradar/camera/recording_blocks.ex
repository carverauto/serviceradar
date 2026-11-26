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
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.IngestOwner
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingDisposition
  alias ServiceRadar.Camera.RecordingGap
  alias ServiceRadar.Camera.RecordingPubSub
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Repo
  alias ServiceRadarRecordingControl.RecoveryGate
  alias ServiceRadarRecordingMetadata.Descriptor

  require Ash.Query

  @max_epoch 9_223_372_036_854_775_807
  @max_wire_rotation_blocks 255
  @operator_page_limit 25
  @unresolved_default_limit 100
  @unresolved_max_limit 500
  @operator_page_actor SystemActor.system(:camera_recording_blocks_operator_page)
  @catalog_actor SystemActor.system(:camera_recording_blocks_catalog)
  @catalog_attr_keys [
    :first_unit_pts,
    :first_unit_received_at,
    :timeline_start_us,
    :timeline_end_us,
    :start_us,
    :end_us,
    :time_basis,
    :time_uncertainty_us,
    :policy_id,
    :run_id,
    :anchor_id,
    :reanchored,
    :contiguous_with_previous,
    :policy_storage,
    :storage
  ]

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

  A closed recovery gate refuses admission. Closure observed after commit returns
  `{:error, :nvr_recovery_closed_after_freeze}`.

  Exact retries with identical descriptor and catalog attributes return the
  existing `RecordingCatalogEntry` without touching copy states; conflicting
  descriptors or catalog attributes return `{:error, :recording_descriptor_conflict}`.

  After a successful commit, broadcasts a best-effort `:block_cataloged`
  notification via `ServiceRadar.Camera.RecordingPubSub`.
  """
  def freeze_and_catalog(ingest, claim, block, descriptor, catalog_attrs, opts \\ []) do
    with {:ok, bytes} <- Descriptor.encode(descriptor),
         {:ok, prepared} <- prepare_catalog_params(descriptor, bytes, catalog_attrs) do
      freeze = fn owner, current ->
        with {:ok, retained} <- lock(block.id, opts),
             true <-
               original_recorder?(retained, owner, current) ||
                 {:error, :recording_block_mismatch},
             true <-
               descriptor["identity"] == RecordingBlock.identity(retained) ||
                 {:error, :recording_block_mismatch},
             {:ok, frozen} <-
               freeze_and_mark_adopted(
                 retained,
                 descriptor,
                 prepared.descriptor_sha256,
                 %{"source" => "live_freeze"},
                 opts
               ) do
          ensure_catalog_entry(frozen, retained.database_now, prepared)
        end
      end

      result =
        with_recovery(:nvr_recovery_closed_after_freeze, fn ->
          RecorderOwnership.with_current(ingest, claim, freeze, opts)
        end)

      case result do
        {:ok, %RecordingCatalogEntry{camera_source_id: camera_source_id}} ->
          RecordingPubSub.broadcast_updated(camera_source_id, :block_cataloged)

        _ ->
          :ok
      end

      result
    end
  end

  @doc """
  Reconciler-only historical freeze (`R.1`, `design.md` `R3`): system actor only.

  Runs every check of live `freeze_and_catalog/6` EXCEPT claim liveness, replacing
  claim liveness with **writer retirement** (the block's `RecorderClaim` / epoch is
  released, superseded, or lease-expired by database `clock_timestamp()`). Acquires
  the same `IngestOwner -> RecorderClaim -> RecordingBlock` `FOR UPDATE` row locks
  as live `freeze_and_catalog/6`, freezes the canonical descriptor, marks the
  reservation `:adopted`, and inserts the `RecordingCatalogEntry` in one CNPG
  transaction with zero network I/O.
  """
  @spec freeze_historical(
          RecordingBlock.t() | String.t(),
          map(),
          map() | keyword(),
          keyword()
        ) :: {:ok, RecordingCatalogEntry.t()} | {:error, term()}
  def freeze_historical(block_or_id, descriptor, catalog_attrs_or_opts \\ [], opts \\ []) do
    {catalog_attrs, call_opts} = split_catalog_attrs_and_opts(catalog_attrs_or_opts, opts)

    with :ok <- authorize_system_reconciler(call_opts),
         :ok <- check_history_reconciliation_ready(call_opts),
         {:ok, bytes} <- Descriptor.encode(descriptor) do
      with_recovery(fn ->
        transaction(fn ->
          execute_freeze_historical(block_or_id, descriptor, bytes, catalog_attrs, call_opts)
        end)
      end)
    end
  end

  @doc """
  System-actor reconciler primitive that adopts an unreserved block the NVR rotated
  into (`R.2`, `PD1`, `design.md` `R3`) **only** when every `PD1` continuation proof
  holds against an adopted/sealed predecessor `RecordingBlock` in one CNPG transaction.

  Supports both `(predecessor, candidate_block_key, candidate_descriptor, opts)` and
  `(predecessor, candidate_descriptor, opts)`. Any failed `PD1` check rolls back and
  returns `{:error, {:unattributable_block, reason, evidence}}` without cataloging
  unverified bytes.
  """
  @spec adopt_rotated_block(
          RecordingBlock.t() | String.t(),
          String.t() | map(),
          map() | keyword(),
          keyword()
        ) ::
          {:ok, RecordingCatalogEntry.t()}
          | {:error, {:unattributable_block, atom(), map()} | term()}
  def adopt_rotated_block(predecessor_or_id, key_or_descriptor, desc_or_opts \\ [], opts \\ [])

  def adopt_rotated_block(predecessor_or_id, candidate_block_key, candidate_descriptor, opts)
      when is_binary(candidate_block_key) and is_map(candidate_descriptor) and is_list(opts) do
    {catalog_attrs, call_opts} = extract_opts_catalog_attrs(opts)

    run_adopt_rotated_block(
      predecessor_or_id,
      candidate_block_key,
      candidate_descriptor,
      catalog_attrs,
      call_opts
    )
  end

  def adopt_rotated_block(predecessor_or_id, candidate_descriptor, catalog_attrs_or_opts, opts)
      when is_map(candidate_descriptor) do
    {catalog_attrs, call_opts} = split_catalog_attrs_and_opts(catalog_attrs_or_opts, opts)

    explicit_key =
      fetch_catalog_val(catalog_attrs, :block_key) || Keyword.get(call_opts, :block_key)

    candidate_key = resolve_implicit_candidate_key(explicit_key, candidate_descriptor)

    run_adopt_rotated_block(
      predecessor_or_id,
      candidate_key,
      candidate_descriptor,
      catalog_attrs,
      call_opts
    )
  end

  def adopt_rotated_block(_predecessor_or_id, candidate_block_key, candidate_descriptor, opts)
      when is_list(opts) do
    with :ok <- authorize_system_reconciler(opts),
         :ok <- check_history_reconciliation_ready(opts) do
      {:error,
       {:unattributable_block, :invalid_descriptor,
        %{
          "reason" => "invalid_descriptor",
          "candidate_block_key" => to_string(candidate_block_key || ""),
          "descriptor_valid" => is_map(candidate_descriptor)
        }}}
    end
  end

  @doc """
  Lists `RecordingBlock` reservations whose `reconciliation_state` is `:unresolved`
  (oldest first, bounded 1..500, default 100), excluding reservations already resolved
  as `:adopted`, `:block_absent`, or `:unrecoverable_journal` (`R.3`).
  """
  @spec list_unresolved_reservations(map() | keyword(), keyword()) ::
          {:ok, [RecordingBlock.t()]} | {:error, term()}
  def list_unresolved_reservations(filters_or_opts \\ [], opts \\ []) do
    {filters, call_opts} = split_filters_and_opts(filters_or_opts, opts)

    with :ok <- authorize_operator_page(call_opts),
         {:ok, storage_id} <- parse_optional_uuid_filter(fetch_catalog_val(filters, :storage_id)),
         {:ok, camera_id} <-
           parse_optional_uuid_filter(fetch_catalog_val(filters, :camera_source_id)),
         {:ok, limit} <- parse_unresolved_limit(fetch_catalog_val(filters, :limit)) do
      args = %{storage_id: storage_id, camera_source_id: camera_id, limit: limit}

      RecordingBlock
      |> Ash.Query.for_read(:unresolved_reservations, args, actor: @catalog_actor)
      |> Ash.read(actor: @catalog_actor)
    end
  end

  @doc """
  Resolves an `:open_local` `RecordingBlock` reservation whose block is absent on the
  NVR volume once its writer is retired (`R.3`, `design.md` `R4`), marking
  `reconciliation_state = :block_absent` and recording a `:block_absent` `RecordingGap`
  in one CNPG transaction.
  """
  @spec resolve_reservation_absent(
          RecordingBlock.t() | String.t(),
          map() | keyword(),
          keyword()
        ) :: {:ok, %{block: RecordingBlock.t(), gap: RecordingGap.t() | nil}} | {:error, term()}
  def resolve_reservation_absent(block_or_id, attrs_or_opts \\ %{}, opts \\ []) do
    {attrs, call_opts} = split_filters_and_opts(attrs_or_opts, opts)

    with :ok <- authorize_system_reconciler(call_opts),
         :ok <- check_history_reconciliation_ready(call_opts) do
      with_recovery(fn ->
        transaction(fn ->
          execute_resolve_absent(block_or_id, attrs, call_opts)
        end)
      end)
    end
  end

  @doc """
  Resolves an `:open_local` `RecordingBlock` reservation whose incomplete journal failed
  explicit recovery once its writer is retired (`R.3`, `design.md` `R2`, `R4` step 5).

  Marks `reconciliation_state = :unrecoverable_journal`, optionally registers the
  never-frozen `:unrecoverable_journal` quarantined `RecordingCatalogEntry` when
  `:quarantine_receipt` and `:quarantined_bytes` are supplied, and records a
  `:quarantined` `RecordingGap` in the same transaction **only** when the block's own
  media/timeline interval (`:start_us` and `:end_us`) is explicitly supplied (`R2`
  quarantined-gap rule: no other interval is ever substituted).
  """
  @spec resolve_reservation_unrecoverable(
          RecordingBlock.t() | String.t(),
          map() | keyword(),
          keyword()
        ) ::
          {:ok,
           %{
             block: RecordingBlock.t(),
             gap: RecordingGap.t() | nil,
             quarantined_entry: RecordingCatalogEntry.t() | nil
           }}
          | {:error, term()}
  def resolve_reservation_unrecoverable(block_or_id, attrs_or_opts \\ %{}, opts \\ []) do
    {attrs, call_opts} = split_filters_and_opts(attrs_or_opts, opts)

    with :ok <- authorize_system_reconciler(call_opts),
         :ok <- check_history_reconciliation_ready(call_opts) do
      with_recovery(fn ->
        transaction(fn ->
          execute_resolve_unrecoverable(block_or_id, attrs, call_opts)
        end)
      end)
    end
  end

  @doc """
  Quarantines a block on an NVR volume that has no Core reservation authority (`R.3`,
  `R4` step 6, `R2`), registering a never-frozen `RecordingCatalogEntry` with
  `quarantine_reason = :unattributable`, structured `quarantine_evidence`, and
  `operator_disposition_state = :awaiting_operator`, and recording a `:quarantined`
  `RecordingGap` only when `camera_source_id` and explicit `[start_us, end_us]` are known.
  """
  @spec quarantine_unattributable_block(map() | keyword(), keyword()) ::
          {:ok, %{entry: RecordingCatalogEntry.t(), gap: RecordingGap.t() | nil}}
          | {:error, term()}
  def quarantine_unattributable_block(attrs, opts \\ [])
      when (is_map(attrs) or is_list(attrs)) and is_list(opts) do
    attrs_map = if is_map(attrs), do: attrs, else: Map.new(attrs)

    with :ok <- authorize_system_reconciler(opts),
         :ok <- check_history_reconciliation_ready(opts) do
      with_recovery(fn ->
        transaction(fn ->
          execute_quarantine_unattributable(attrs_map)
        end)
      end)
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

  defp freeze_and_mark_adopted(%{state: :open_local} = block, descriptor, sha, detail, opts) do
    params = %{
      descriptor: descriptor,
      descriptor_sha256: sha,
      reconciled_at: block.database_now,
      reconciliation_detail: detail
    }

    block
    |> Ash.Changeset.for_update(:freeze_and_adopt, params)
    |> Ash.Changeset.filter(expr(state == :open_local and reconciliation_state == :unresolved))
    |> Ash.update(Keyword.put(opts, :load, [:database_now]))
  end

  defp freeze_and_mark_adopted(
         %{descriptor: descriptor, descriptor_sha256: sha, reconciliation_state: :unresolved} =
           block,
         descriptor,
         sha,
         detail,
         opts
       ) do
    params = %{
      reconciled_at: block.database_now,
      reconciliation_detail: detail
    }

    block
    |> Ash.Changeset.for_update(:mark_adopted, params)
    |> Ash.Changeset.filter(expr(reconciliation_state == :unresolved))
    |> Ash.update(Keyword.put(opts, :load, [:database_now]))
  end

  defp freeze_and_mark_adopted(
         %{descriptor: descriptor, descriptor_sha256: sha, reconciliation_state: :adopted} = block,
         descriptor,
         sha,
         _detail,
         _opts
       ),
       do: {:ok, block}

  defp freeze_and_mark_adopted(_, _, _, _, _), do: {:error, :recording_descriptor_conflict}

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

  defp with_recovery(closed_after_work \\ :nvr_recovery_closed, fun) do
    if Repo.in_transaction?() do
      {:error, :ambient_transaction}
    else
      gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)
      RecoveryGate.with_ready(gate, closed_after_work, fun)
    end
  end

  defp authorize_system_reconciler(opts) when is_list(opts) do
    actor =
      case Keyword.get(opts, :actor) do
        nil -> opts |> Keyword.get(:scope) |> actor_from_scope()
        explicit -> explicit
      end

    if match?(%{role: :system}, actor) do
      :ok
    else
      {:error, Forbidden.exception([])}
    end
  end

  defp check_history_reconciliation_ready(opts) when is_list(opts) do
    if Keyword.get(opts, :awaiting_history_reconciliation?, false) == true do
      {:error, :storage_awaiting_history_reconciliation}
    else
      :ok
    end
  end

  defp split_catalog_attrs_and_opts(attrs, opts) when is_map(attrs) and is_list(opts) do
    {attrs_from_opts, clean_opts} = extract_opts_catalog_attrs(opts)
    {Map.merge(attrs_from_opts, attrs), clean_opts}
  end

  defp split_catalog_attrs_and_opts(opts_arg, []) when is_list(opts_arg) do
    extract_opts_catalog_attrs(opts_arg)
  end

  defp split_catalog_attrs_and_opts(attrs_list, opts)
       when is_list(attrs_list) and is_list(opts) do
    split_catalog_attrs_and_opts(Map.new(attrs_list), opts)
  end

  defp split_catalog_attrs_and_opts(_, opts) when is_list(opts), do: {%{}, opts}

  defp extract_opts_catalog_attrs(opts) when is_list(opts) do
    explicit_map =
      case Keyword.get(opts, :catalog_attrs) do
        m when is_map(m) -> m
        l when is_list(l) -> Map.new(l)
        _ -> %{}
      end

    inline_attrs =
      Enum.reduce(@catalog_attr_keys, %{}, fn key, acc ->
        case Keyword.fetch(opts, key) do
          {:ok, val} -> Map.put(acc, key, val)
          :error -> acc
        end
      end)

    {Map.merge(inline_attrs, explicit_map), opts}
  end

  defp split_filters_and_opts(filters, opts) when is_map(filters) and is_list(opts),
    do: {filters, opts}

  defp split_filters_and_opts(opts_arg, []) when is_list(opts_arg) do
    {Map.new(opts_arg), opts_arg}
  end

  defp split_filters_and_opts(filters_list, opts) when is_list(filters_list) and is_list(opts) do
    {Map.new(filters_list), opts}
  end

  defp split_filters_and_opts(_, opts) when is_list(opts), do: {%{}, opts}

  defp parse_optional_uuid_filter(nil), do: {:ok, nil}
  defp parse_optional_uuid_filter(""), do: {:ok, nil}

  defp parse_optional_uuid_filter(val) when is_binary(val) do
    case Ecto.UUID.cast(val) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid_filter}
    end
  end

  defp parse_optional_uuid_filter(_), do: {:error, :invalid_uuid_filter}

  defp parse_unresolved_limit(nil), do: {:ok, @unresolved_default_limit}

  defp parse_unresolved_limit(limit) when is_integer(limit) and limit >= 1 do
    {:ok, min(limit, @unresolved_max_limit)}
  end

  defp parse_unresolved_limit(_), do: {:error, :invalid_page_limit}

  defp resolve_implicit_candidate_key(explicit_key, _descriptor) when is_binary(explicit_key),
    do: explicit_key

  defp resolve_implicit_candidate_key(_explicit_key, %{"identity" => identity})
       when is_map(identity) do
    if Descriptor.valid_identity?(identity), do: Descriptor.block_key(identity), else: ""
  end

  defp resolve_implicit_candidate_key(_explicit_key, _descriptor), do: ""

  defp execute_freeze_historical(block_or_id, descriptor, bytes, catalog_attrs, call_opts) do
    sys_opts = [actor: @catalog_actor]

    with {:ok, target} <- load_block_unlocked(block_or_id, sys_opts),
         {:ok, _owner, claim, retained} <-
           lock_owner_claim_and_block(target, sys_opts),
         :ok <- verify_writer_retired(retained, claim, call_opts),
         :ok <-
           verify_historical_reservation_fence(retained, descriptor, catalog_attrs, call_opts),
         effective_attrs =
           default_historical_timeline_attrs(catalog_attrs, descriptor, retained),
         {:ok, prepared} <- prepare_catalog_params(descriptor, bytes, effective_attrs),
         {:ok, frozen} <-
           freeze_and_mark_adopted(
             retained,
             descriptor,
             prepared.descriptor_sha256,
             %{"source" => "historical_freeze"},
             sys_opts
           ) do
      ensure_historical_catalog_entry(frozen, retained.database_now, prepared, catalog_attrs)
    end
  end

  defp load_block_unlocked(%RecordingBlock{} = block, _sys_opts), do: {:ok, block}

  defp load_block_unlocked(block_id, sys_opts) when is_binary(block_id) do
    case Ecto.UUID.cast(block_id) do
      {:ok, uuid} ->
        RecordingBlock
        |> Ash.Query.filter(id == ^uuid)
        |> Ash.read_one(sys_opts)
        |> case do
          {:ok, %RecordingBlock{} = block} -> {:ok, block}
          {:ok, nil} -> {:error, :recording_block_not_found}
          {:error, _} = error -> error
        end

      :error ->
        {:error, :recording_block_not_found}
    end
  end

  defp load_block_unlocked(_, _sys_opts), do: {:error, :recording_block_not_found}

  defp lock_owner_claim_and_block(%RecordingBlock{} = target, sys_opts) do
    owner_id = target.ingest_owner_id
    claim_id = target.recorder_claim_id

    with {:ok, owner} <- lock_ingest_owner(owner_id, sys_opts),
         {:ok, claim} <- lock_recorder_claim(claim_id, sys_opts),
         {:ok, retained} <- lock(target.id, sys_opts) do
      {:ok, owner, claim, retained}
    end
  end

  defp lock_ingest_owner(owner_id, sys_opts) do
    IngestOwner
    |> Ash.Query.filter(id == ^owner_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(sys_opts)
    |> case do
      {:ok, %IngestOwner{} = owner} -> Ash.load(owner, :database_now, sys_opts)
      {:ok, nil} -> {:error, :ingest_owner_not_found}
      {:error, _} = error -> error
    end
  end

  defp lock_recorder_claim(claim_id, sys_opts) do
    RecorderClaim
    |> Ash.Query.filter(id == ^claim_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(sys_opts)
    |> case do
      {:ok, %RecorderClaim{} = claim} -> Ash.load(claim, :database_now, sys_opts)
      {:ok, nil} -> {:error, :recorder_claim_not_found}
      {:error, _} = error -> error
    end
  end

  defp verify_writer_retired(%RecordingBlock{} = block, %RecorderClaim{} = claim, opts) do
    cond do
      Keyword.get(opts, :active_source_session?, false) == true ->
        {:error, :writer_not_retired}

      claim.recorder_epoch < block.recorder_epoch ->
        {:error, :recording_block_mismatch}

      writer_claim_live?(block, claim) ->
        {:error, :writer_not_retired}

      true ->
        :ok
    end
  end

  defp writer_claim_live?(%RecordingBlock{} = block, %RecorderClaim{} = claim) do
    claim.id == block.recorder_claim_id and
      claim.recorder_epoch == block.recorder_epoch and
      claim.state == :active and
      match?(%DateTime{}, claim.lease_expires_at) and
      DateTime.after?(claim.lease_expires_at, claim.database_now)
  end

  defp verify_historical_reservation_fence(retained, descriptor, catalog_attrs, call_opts) do
    expected_storage =
      fetch_catalog_val(catalog_attrs, :storage_id) || Keyword.get(call_opts, :storage_id)

    expected_key =
      fetch_catalog_val(catalog_attrs, :block_key) || Keyword.get(call_opts, :block_key)

    cond do
      retained.reconciliation_state in [:block_absent, :unrecoverable_journal] ->
        {:error, {:reservation_already_resolved, retained.reconciliation_state}}

      not is_nil(expected_storage) and
          to_string(expected_storage) != to_string(retained.storage_id) ->
        {:error, :recording_block_mismatch}

      not is_nil(expected_key) and to_string(expected_key) != retained.block_key ->
        {:error, :recording_block_mismatch}

      Descriptor.block_key(descriptor["identity"]) != retained.block_key ->
        {:error, :recording_block_mismatch}

      descriptor["identity"] != RecordingBlock.identity(retained) ->
        {:error, :recording_block_mismatch}

      true ->
        ensure_not_tombstoned(retained.storage_id, retained.block_key)
    end
  end

  defp ensure_not_tombstoned(storage_id, block_key) do
    has_catalog? =
      RecordingCatalogEntry
      |> Ash.Query.filter(storage_id == ^storage_id and block_key == ^block_key)
      |> Ash.exists(actor: @catalog_actor)

    case has_catalog? do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        tombstoned? =
          RecordingDisposition
          |> Ash.Query.filter(
            storage_id == ^storage_id and block_key == ^block_key and copy == :local and
              step in [:requested, :executed, :verified_absent]
          )
          |> Ash.exists(actor: @catalog_actor)

        case tombstoned? do
          {:ok, true} -> {:error, :recording_block_tombstoned}
          {:ok, false} -> :ok
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp default_historical_timeline_attrs(attrs, descriptor, %RecordingBlock{} = retained) do
    has_timeline? =
      not is_nil(fetch_catalog_val(attrs, :timeline_start_us)) or
        not is_nil(fetch_catalog_val(attrs, :start_us)) or
        not is_nil(fetch_catalog_val(attrs, :first_unit_received_at)) or
        is_map(get_in(descriptor, ["identity", "clock", "utc_mapping"]))

    if has_timeline? do
      attrs
    else
      fallback_start_us = DateTime.to_unix(retained.inserted_at, :microsecond)
      Map.put(attrs, :timeline_start_us, fallback_start_us)
    end
  end

  defp ensure_historical_catalog_entry(frozen, now, prepared, explicit_attrs) do
    storage_id = frozen.storage_id
    block_key = frozen.block_key

    existing_query =
      RecordingCatalogEntry
      |> Ash.Query.filter(storage_id == ^storage_id and block_key == ^block_key)
      |> Ash.Query.lock(:for_update)

    case Ash.read_one(existing_query, actor: @catalog_actor) do
      {:ok, %RecordingCatalogEntry{} = existing} ->
        verify_historical_catalog_retry(existing, frozen, prepared, explicit_attrs)

      {:ok, nil} ->
        insert_sealed_catalog_entry(frozen, now, prepared)

      {:error, _} = error ->
        error
    end
  end

  defp verify_historical_catalog_retry(existing, frozen, prepared, explicit_attrs) do
    same_descriptor? =
      existing.recording_block_id == frozen.id and
        existing.descriptor_sha256 == prepared.descriptor_sha256 and
        existing.camera_source_id == frozen.camera_source_id and
        existing.stream_profile_id == frozen.stream_profile_id

    cond do
      not same_descriptor? ->
        {:error, :recording_descriptor_conflict}

      explicit_catalog_conflict?(existing, prepared, explicit_attrs) ->
        {:error, :recording_descriptor_conflict}

      true ->
        {:ok, existing}
    end
  end

  defp explicit_catalog_conflict?(existing, prepared, explicit_attrs) do
    checks = [
      {:policy_id, existing.policy_id == prepared.policy_id},
      {:run_id, existing.run_id == prepared.run_id},
      {:first_unit_pts, existing.first_unit_pts == prepared.first_unit_pts},
      {:first_unit_received_at,
       equal_optional_datetime?(existing.first_unit_received_at, prepared.first_unit_received_at)},
      {:timeline_start_us, existing.timeline_start_us == prepared.timeline_start_us},
      {:start_us, existing.timeline_start_us == prepared.timeline_start_us},
      {:timeline_end_us, existing.timeline_end_us == prepared.timeline_end_us},
      {:end_us, existing.timeline_end_us == prepared.timeline_end_us},
      {:time_basis, existing.time_basis == prepared.time_basis},
      {:anchor_id, existing.anchor_id == prepared.anchor_id},
      {:reanchored, existing.reanchored == prepared.reanchored},
      {:contiguous_with_previous,
       existing.contiguous_with_previous == prepared.contiguous_with_previous}
    ]

    Enum.any?(checks, fn {key, matches?} ->
      explicit_attr_present?(explicit_attrs, key) and not matches?
    end)
  end

  defp explicit_attr_present?(attrs, key) when is_map(attrs) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end

  defp run_adopt_rotated_block(
         predecessor_or_id,
         candidate_block_key,
         candidate_descriptor,
         catalog_attrs,
         call_opts
       ) do
    with :ok <- authorize_system_reconciler(call_opts),
         :ok <- check_history_reconciliation_ready(call_opts) do
      case Descriptor.encode(candidate_descriptor) do
        {:ok, bytes} ->
          with_recovery(fn ->
            transaction(fn ->
              execute_adopt_rotated_block(
                predecessor_or_id,
                candidate_block_key,
                candidate_descriptor,
                bytes,
                catalog_attrs,
                call_opts
              )
            end)
          end)

        {:error, _} ->
          {:error,
           unattributable_error(:invalid_descriptor, %{
             "candidate_block_key" => candidate_block_key
           })}
      end
    end
  end

  defp execute_adopt_rotated_block(
         predecessor_or_id,
         candidate_block_key,
         candidate_descriptor,
         bytes,
         catalog_attrs,
         call_opts
       ) do
    sys_opts = [actor: @catalog_actor]

    case load_block_unlocked(predecessor_or_id, sys_opts) do
      {:ok, pred_unlocked} ->
        with {:ok, _owner, claim, pred} <- lock_owner_claim_and_block(pred_unlocked, sys_opts),
             {:ok, next_seq, expected_key} <-
               verify_pd1_predecessor_and_identity(
                 pred,
                 claim,
                 candidate_block_key,
                 candidate_descriptor,
                 catalog_attrs,
                 call_opts
               ) do
          persist_rotated_continuation(
            pred,
            claim,
            next_seq,
            expected_key,
            candidate_descriptor,
            bytes,
            catalog_attrs,
            sys_opts
          )
        end

      {:error, :recording_block_not_found} ->
        {:error,
         unattributable_error(:predecessor_not_found, %{
           "candidate_block_key" => candidate_block_key
         })}

      {:error, _} = error ->
        error
    end
  end

  defp verify_pd1_predecessor_and_identity(
         pred,
         claim,
         candidate_block_key,
         candidate_descriptor,
         catalog_attrs,
         call_opts
       ) do
    next_seq = pred.block_sequence + 1
    expected_identity = Map.put(RecordingBlock.identity(pred), "block_sequence", next_seq)
    expected_key = Descriptor.block_key(expected_identity)
    candidate_identity = candidate_descriptor["identity"]

    requested_storage =
      fetch_catalog_val(catalog_attrs, :storage_id) || Keyword.get(call_opts, :storage_id)

    base_evidence = %{
      "predecessor_block_id" => pred.id,
      "storage_id" => to_string(pred.storage_id),
      "candidate_block_key" => candidate_block_key,
      "expected_block_key" => expected_key,
      "predecessor_sequence" => pred.block_sequence,
      "expected_sequence" => next_seq,
      "candidate_sequence" => candidate_identity["block_sequence"],
      "expected_clock_epoch" => pred.clock["clock_epoch"],
      "candidate_clock_epoch" => get_in(candidate_identity, ["clock", "clock_epoch"])
    }

    with :ok <- check_pd1_predecessor_adopted(pred, base_evidence),
         :ok <- check_pd1_writer_retired(pred, claim, call_opts, base_evidence),
         :ok <- check_pd1_storage(pred, requested_storage, base_evidence),
         :ok <- check_pd1_sequence_and_identity(pred, next_seq, candidate_identity, base_evidence),
         :ok <-
           check_pd1_block_key(
             candidate_block_key,
             candidate_identity,
             expected_key,
             base_evidence
           ) do
      {:ok, next_seq, expected_key}
    end
  end

  defp check_pd1_predecessor_adopted(%RecordingBlock{} = pred, evidence) do
    cond do
      pred.state not in [:sealed, :uploading] ->
        {:error, unattributable_error(:predecessor_not_adopted, evidence)}

      pred.reconciliation_state == :adopted ->
        :ok

      predecessor_has_sealed_catalog_entry?(pred.id) ->
        :ok

      true ->
        {:error, unattributable_error(:predecessor_not_adopted, evidence)}
    end
  end

  defp predecessor_has_sealed_catalog_entry?(pred_id) do
    RecordingCatalogEntry
    |> Ash.Query.filter(recording_block_id == ^pred_id and local_state != :quarantined)
    |> Ash.exists(actor: @catalog_actor)
    |> case do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp check_pd1_writer_retired(pred, claim, call_opts, evidence) do
    case verify_writer_retired(pred, claim, call_opts) do
      :ok ->
        :ok

      {:error, :writer_not_retired} ->
        {:error, unattributable_error(:writer_not_retired, evidence)}

      {:error, reason} ->
        {:error, unattributable_error(reason, evidence)}
    end
  end

  defp check_pd1_storage(_pred, nil, _evidence), do: :ok

  defp check_pd1_storage(pred, requested_storage, evidence) do
    if to_string(requested_storage) == to_string(pred.storage_id) do
      :ok
    else
      {:error,
       unattributable_error(
         :storage_mismatch,
         Map.put(evidence, "requested_storage_id", to_string(requested_storage))
       )}
    end
  end

  defp check_pd1_sequence_and_identity(pred, next_seq, candidate_identity, evidence) do
    cond do
      next_seq > @max_epoch or next_seq > @max_wire_rotation_blocks ->
        {:error, unattributable_error(:rotation_bound_exceeded, evidence)}

      candidate_identity["source_id"] != pred.camera_source_id ->
        {:error, unattributable_error(:camera_source_mismatch, evidence)}

      candidate_identity["profile"] != pred.stream_profile_id ->
        {:error, unattributable_error(:stream_profile_mismatch, evidence)}

      candidate_identity["recorder_epoch"] != pred.recorder_epoch ->
        {:error, unattributable_error(:recorder_epoch_mismatch, evidence)}

      candidate_identity["clock"] != pred.clock ->
        {:error, unattributable_error(:clock_epoch_mismatch, evidence)}

      candidate_identity["block_sequence"] != next_seq ->
        {:error, unattributable_error(:sequence_mismatch, evidence)}

      true ->
        :ok
    end
  end

  defp check_pd1_block_key(candidate_block_key, candidate_identity, expected_key, evidence) do
    derived_from_candidate = Descriptor.block_key(candidate_identity)

    if candidate_block_key == expected_key and derived_from_candidate == expected_key do
      :ok
    else
      {:error, unattributable_error(:block_key_mismatch, evidence)}
    end
  end

  defp persist_rotated_continuation(
         pred,
         claim,
         next_seq,
         expected_key,
         candidate_descriptor,
         bytes,
         catalog_attrs,
         sys_opts
       ) do
    sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    evidence = %{
      "predecessor_block_id" => pred.id,
      "storage_id" => to_string(pred.storage_id),
      "expected_block_key" => expected_key,
      "expected_sequence" => next_seq
    }

    case lookup_existing_continuation_block(pred, next_seq, expected_key, sys_opts) do
      {:ok, nil} ->
        create_and_catalog_rotated_continuation(
          pred,
          claim,
          next_seq,
          expected_key,
          candidate_descriptor,
          bytes,
          catalog_attrs,
          sys_opts,
          evidence
        )

      {:ok, %RecordingBlock{} = existing} ->
        handle_existing_continuation_block(
          existing,
          pred,
          candidate_descriptor,
          bytes,
          sha,
          catalog_attrs,
          evidence
        )

      {:error, _} = error ->
        error
    end
  end

  defp lookup_existing_continuation_block(pred, next_seq, expected_key, sys_opts) do
    cam_id = pred.camera_source_id
    prof_id = pred.stream_profile_id
    rec_epoch = pred.recorder_epoch

    RecordingBlock
    |> Ash.Query.filter(
      block_key == ^expected_key or
        (camera_source_id == ^cam_id and stream_profile_id == ^prof_id and
           recorder_epoch == ^rec_epoch and block_sequence == ^next_seq)
    )
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(sys_opts)
  end

  defp handle_existing_continuation_block(
         %RecordingBlock{} = existing,
         pred,
         candidate_descriptor,
         bytes,
         sha,
         catalog_attrs,
         evidence
       ) do
    same_rotated_adoption? =
      existing.reconciliation_state == :adopted and
        get_in(existing.reconciliation_detail || %{}, ["source"]) == "rotated_adoption" and
        get_in(existing.reconciliation_detail || %{}, ["predecessor_block_id"]) == pred.id

    cond do
      not same_rotated_adoption? ->
        {:error, unattributable_error(:sequence_already_reserved, evidence)}

      existing.descriptor_sha256 != sha ->
        {:error, unattributable_error(:descriptor_conflict, evidence)}

      true ->
        effective_attrs =
          default_historical_timeline_attrs(catalog_attrs, candidate_descriptor, existing)

        with {:ok, prepared} <-
               prepare_catalog_params(candidate_descriptor, bytes, effective_attrs),
             {:ok, loaded} <- Ash.load(existing, :database_now, actor: @catalog_actor) do
          ensure_historical_catalog_entry(loaded, loaded.database_now, prepared, catalog_attrs)
        end
    end
  end

  defp create_and_catalog_rotated_continuation(
         pred,
         claim,
         next_seq,
         expected_key,
         candidate_descriptor,
         bytes,
         catalog_attrs,
         sys_opts,
         evidence
       ) do
    case ensure_not_tombstoned(pred.storage_id, expected_key) do
      {:error, :recording_block_tombstoned} ->
        {:error, unattributable_error(:block_tombstoned, evidence)}

      {:error, _} = error ->
        error

      :ok ->
        with {:ok, _claim} <-
               maybe_advance_claim_sequence(claim, pred.recorder_epoch, next_seq, sys_opts),
             {:ok, created} <- insert_continuation_block(pred, next_seq, expected_key, sys_opts),
             {:ok, retained} <- Ash.load(created, :database_now, sys_opts),
             effective_attrs =
               default_historical_timeline_attrs(catalog_attrs, candidate_descriptor, retained),
             {:ok, prepared} <-
               prepare_catalog_params(candidate_descriptor, bytes, effective_attrs),
             {:ok, frozen} <-
               freeze_and_mark_adopted(
                 retained,
                 candidate_descriptor,
                 prepared.descriptor_sha256,
                 %{
                   "source" => "rotated_adoption",
                   "predecessor_block_id" => pred.id,
                   "predecessor_sequence" => pred.block_sequence
                 },
                 sys_opts
               ) do
          ensure_historical_catalog_entry(frozen, retained.database_now, prepared, catalog_attrs)
        end
    end
  end

  defp maybe_advance_claim_sequence(%RecorderClaim{} = claim, pred_epoch, next_seq, sys_opts) do
    if claim.recorder_epoch == pred_epoch and claim.next_block_sequence <= next_seq do
      claim
      |> Ash.Changeset.for_update(:transition, %{next_block_sequence: next_seq + 1})
      |> Ash.Changeset.filter(expr(recorder_epoch == ^pred_epoch))
      |> Ash.update(sys_opts)
    else
      {:ok, claim}
    end
  end

  defp insert_continuation_block(pred, next_seq, expected_key, sys_opts) do
    attrs = %{
      block_key: expected_key,
      camera_source_id: pred.camera_source_id,
      stream_profile_id: pred.stream_profile_id,
      ingest_owner_id: pred.ingest_owner_id,
      ingest_epoch: pred.ingest_epoch,
      recorder_claim_id: pred.recorder_claim_id,
      recorder_epoch: pred.recorder_epoch,
      block_sequence: next_seq,
      relay_session_id: pred.relay_session_id,
      media_ingest_id: pred.media_ingest_id,
      storage_id: pred.storage_id,
      clock: pred.clock
    }

    RecordingBlock
    |> Ash.Changeset.for_create(:reserve, attrs)
    |> Ash.create(sys_opts)
  end

  defp unattributable_error(reason, evidence) when is_atom(reason) and is_map(evidence) do
    {:unattributable_block, reason, Map.put_new(evidence, "reason", Atom.to_string(reason))}
  end

  defp execute_resolve_absent(block_or_id, attrs, call_opts) do
    sys_opts = [actor: @catalog_actor]

    with {:ok, target} <- load_block_unlocked(block_or_id, sys_opts),
         {:ok, _owner, claim, retained} <- lock_owner_claim_and_block(target, sys_opts),
         :ok <- verify_writer_retired(retained, claim, call_opts) do
      resolve_locked_absent(retained, attrs, sys_opts)
    end
  end

  defp resolve_locked_absent(
         %RecordingBlock{reconciliation_state: :block_absent} = retained,
         _attrs,
         _sys_opts
       ) do
    {:ok, %{block: retained, gap: nil}}
  end

  defp resolve_locked_absent(%RecordingBlock{} = retained, attrs, sys_opts) do
    cond do
      retained.state != :open_local ->
        {:error, :recording_block_already_sealed}

      retained.reconciliation_state != :unresolved ->
        {:error, {:reservation_already_resolved, retained.reconciliation_state}}

      true ->
        detail = build_resolution_detail(attrs, "block_absent")

        update_params = %{
          reconciliation_state: :block_absent,
          reconciled_at: retained.database_now,
          reconciliation_detail: detail
        }

        with {:ok, resolved} <-
               retained
               |> Ash.Changeset.for_update(:resolve_reconciliation, update_params)
               |> Ash.Changeset.filter(
                 expr(state == :open_local and reconciliation_state == :unresolved)
               )
               |> Ash.update(sys_opts),
             {:ok, gap} <- maybe_record_absent_gap(retained, attrs, sys_opts) do
          {:ok, %{block: resolved, gap: gap}}
        end
    end
  end

  defp maybe_record_absent_gap(retained, attrs, sys_opts) do
    if fetch_catalog_val(attrs, :record_gap?) == false do
      {:ok, nil}
    else
      default_start_us = DateTime.to_unix(retained.inserted_at, :microsecond)
      start_us = fetch_catalog_val(attrs, :start_us) || default_start_us

      end_us =
        case fetch_catalog_val(attrs, :end_us) do
          explicit when is_integer(explicit) -> explicit
          _ -> max(start_us, DateTime.to_unix(retained.database_now, :microsecond))
        end

      gap_params = %{
        camera_source_id: retained.camera_source_id,
        stream_profile_id: retained.stream_profile_id,
        policy_id: fetch_catalog_val(attrs, :policy_id),
        storage_id: retained.storage_id,
        run_id: fetch_catalog_val(attrs, :run_id),
        clock_epoch: retained.clock["clock_epoch"],
        start_us: start_us,
        end_us: end_us,
        media_gap_ns: fetch_catalog_val(attrs, :media_gap_ns),
        time_basis: fetch_catalog_val(attrs, :time_basis) || :received,
        time_uncertainty_us: fetch_catalog_val(attrs, :time_uncertainty_us),
        reason: :block_absent,
        detail_class: fetch_catalog_val(attrs, :detail_class) || "reservation_block_absent"
      }

      RecordingGap
      |> Ash.Changeset.for_create(:record, gap_params)
      |> Ash.create(sys_opts)
    end
  end

  defp execute_resolve_unrecoverable(block_or_id, attrs, call_opts) do
    sys_opts = [actor: @catalog_actor]

    with {:ok, target} <- load_block_unlocked(block_or_id, sys_opts),
         {:ok, _owner, claim, retained} <- lock_owner_claim_and_block(target, sys_opts),
         :ok <- verify_writer_retired(retained, claim, call_opts) do
      resolve_locked_unrecoverable(retained, attrs, sys_opts)
    end
  end

  defp resolve_locked_unrecoverable(
         %RecordingBlock{reconciliation_state: :unrecoverable_journal} = retained,
         _attrs,
         _sys_opts
       ) do
    {:ok, %{block: retained, gap: nil, quarantined_entry: nil}}
  end

  defp resolve_locked_unrecoverable(%RecordingBlock{} = retained, attrs, sys_opts) do
    cond do
      retained.state != :open_local ->
        {:error, :recording_block_already_sealed}

      retained.reconciliation_state != :unresolved ->
        {:error, {:reservation_already_resolved, retained.reconciliation_state}}

      true ->
        detail = build_resolution_detail(attrs, "unrecoverable_journal")

        update_params = %{
          reconciliation_state: :unrecoverable_journal,
          reconciled_at: retained.database_now,
          reconciliation_detail: detail
        }

        with {:ok, resolved} <-
               retained
               |> Ash.Changeset.for_update(:resolve_reconciliation, update_params)
               |> Ash.Changeset.filter(
                 expr(state == :open_local and reconciliation_state == :unresolved)
               )
               |> Ash.update(sys_opts),
             {:ok, q_entry} <-
               maybe_register_unrecoverable_quarantine(retained, attrs, detail, sys_opts),
             {:ok, gap} <-
               maybe_record_quarantined_gap(
                 retained.camera_source_id,
                 retained.stream_profile_id,
                 retained.storage_id,
                 retained.clock["clock_epoch"],
                 attrs,
                 sys_opts
               ) do
          {:ok, %{block: resolved, gap: gap, quarantined_entry: q_entry}}
        end
    end
  end

  defp maybe_register_unrecoverable_quarantine(retained, attrs, detail, sys_opts) do
    receipt = fetch_catalog_val(attrs, :quarantine_receipt)
    q_bytes = fetch_catalog_val(attrs, :quarantined_bytes)

    if is_map(receipt) and is_integer(q_bytes) and q_bytes >= 0 do
      q_attrs = %{
        camera_source_id: retained.camera_source_id,
        stream_profile_id: retained.stream_profile_id,
        policy_id: fetch_catalog_val(attrs, :policy_id),
        storage_id: retained.storage_id,
        block_key: retained.block_key,
        clock_epoch: retained.clock["clock_epoch"],
        run_id: fetch_catalog_val(attrs, :run_id),
        timeline_start_us:
          fetch_catalog_val(attrs, :start_us) || fetch_catalog_val(attrs, :timeline_start_us),
        timeline_end_us:
          fetch_catalog_val(attrs, :end_us) || fetch_catalog_val(attrs, :timeline_end_us),
        time_basis: fetch_catalog_val(attrs, :time_basis),
        quarantine_reason: :unrecoverable_journal,
        quarantine_receipt: receipt,
        quarantined_bytes: q_bytes,
        quarantine_evidence: fetch_catalog_val(attrs, :quarantine_evidence) || detail,
        policy_storage: fetch_catalog_val(attrs, :policy_storage)
      }

      RecordingCatalogEntry.register_quarantined(
        q_attrs,
        Keyword.put(sys_opts, :now, retained.database_now)
      )
    else
      {:ok, nil}
    end
  end

  defp execute_quarantine_unattributable(attrs) do
    sys_opts = [actor: @catalog_actor]

    q_attrs =
      attrs
      |> Map.put(:quarantine_reason, :unattributable)
      |> Map.put_new(:quarantine_evidence, %{
        "reason" => to_string(fetch_catalog_val(attrs, :reason) || "unattributable")
      })

    with {:ok, entry} <- RecordingCatalogEntry.register_quarantined(q_attrs, sys_opts),
         {:ok, gap} <-
           maybe_record_quarantined_gap(
             entry.camera_source_id,
             entry.stream_profile_id,
             entry.storage_id,
             entry.clock_epoch,
             attrs,
             sys_opts
           ) do
      {:ok, %{entry: entry, gap: gap}}
    end
  end

  # Quarantined-gap rule (`design.md` `R2`): a quarantined gap is recorded ONLY when
  # that block's camera AND its own media/timeline interval are known; no other
  # interval is ever substituted.
  defp maybe_record_quarantined_gap(
         camera_id,
         profile_id,
         storage_id,
         clock_epoch,
         attrs,
         sys_opts
       ) do
    start_us = fetch_catalog_val(attrs, :start_us) || fetch_catalog_val(attrs, :timeline_start_us)
    end_us = fetch_catalog_val(attrs, :end_us) || fetch_catalog_val(attrs, :timeline_end_us)

    if not is_nil(camera_id) and is_integer(start_us) and is_integer(end_us) and
         end_us >= start_us do
      gap_params = %{
        camera_source_id: camera_id,
        stream_profile_id: profile_id,
        policy_id: fetch_catalog_val(attrs, :policy_id),
        storage_id: storage_id,
        run_id: fetch_catalog_val(attrs, :run_id),
        clock_epoch: clock_epoch,
        start_us: start_us,
        end_us: end_us,
        media_gap_ns: fetch_catalog_val(attrs, :media_gap_ns),
        time_basis: fetch_catalog_val(attrs, :time_basis) || :received,
        time_uncertainty_us: fetch_catalog_val(attrs, :time_uncertainty_us),
        reason: :quarantined,
        detail_class:
          fetch_catalog_val(attrs, :detail_class) ||
            fetch_catalog_val(attrs, :verification_class) ||
            "quarantined_block"
      }

      RecordingGap
      |> Ash.Changeset.for_create(:record, gap_params)
      |> Ash.create(sys_opts)
    else
      {:ok, nil}
    end
  end

  defp build_resolution_detail(attrs, default_reason) do
    case fetch_catalog_val(attrs, :reconciliation_detail) || fetch_catalog_val(attrs, :detail) do
      detail when is_map(detail) ->
        Map.put_new(detail, "reason", default_reason)

      _ ->
        base = %{"reason" => default_reason}

        case fetch_catalog_val(attrs, :detail_class) ||
               fetch_catalog_val(attrs, :verification_class) do
          cls when is_binary(cls) and cls != "" -> Map.put(base, "detail_class", cls)
          _ -> base
        end
    end
  end

  defp transaction(fun) do
    [
      IngestOwner,
      RecorderClaim,
      RecordingBlock,
      RecordingCatalogEntry,
      RecordingGap,
      RecordingDisposition,
      LocalStorageBinding,
      CameraRecordingPolicy
    ]
    |> Ash.transact(fn ->
      case fun.() do
        {:error, %_{}} = ash_error ->
          ash_error

        {:error, reason} ->
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
