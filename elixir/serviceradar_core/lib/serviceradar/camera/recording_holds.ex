defmodule ServiceRadar.Camera.RecordingHolds do
  @moduledoc """
  Transactional domain service for camera recording holds (`C.2`, `C4`, `PD5`)
  and copy deletion intents (`C.3`, `C6`, `C7`).

  Serializes hold acceptance and copy deletion intents by locking covered
  `RecordingCatalogEntry` rows (`SELECT ... FOR UPDATE` in deterministic primary-key
  order) inside a single CNPG transaction:

  - **`place_hold/2`**: authorizes `devices.cameras.recordings.hold` and camera
    `Source` scope, locks covered catalog entries intersecting `[start_us, end_us)`,
    classifies blocks that already had a committed deletion intent with no
    surviving pinnable copy into `unavailable_blocks` (`"unavailable, deletion in progress"`),
    and commits the `:accepted` `RecordingHold` (audited via `AshPaperTrail`).
  - **`PD5` pinned-copy rule (`pinned_copy_for_entry/1`)**:
    - When `archive_state == :verified` (non-quarantined): pinned copy is `:archive`,
      and the `:local` copy stays evictable by local budget and age rules.
    - Otherwise, when `local_state == :present` (non-quarantined): pinned copy is
      `:local` (local-only, unarchived, archive already deleted, or archive `:missing`).
    - Otherwise: `nil`.
  - **`begin_copy_deletion_intent/4`**: locks the `RecordingCatalogEntry` row
    `FOR UPDATE`, evaluates active `:accepted` holds under `PD5` (refusing `:local`
    deletion when `:local` is pinned, refusing `:archive` deletion when `:archive`
    is pinned, and ALLOWING `:local` eviction when `archive_state == :verified`
    even while held), transitions `local_state -> :reclaiming` or
    `archive_state -> :deleting`, and appends the `:requested`
    `RecordingDisposition` row in the SAME transaction.
  - **`mark_archive_verified_and_move_pin/3`** and
    **`mark_archive_missing_and_fallback_pin/3`**: transition archive verification
    or missing state under the `RecordingCatalogEntry` row lock, moving any active
    hold's pin to `:archive` on verification and back to `:local` (when
    `local_state == :present`) + returning affected holds when a held archive copy
    becomes `:missing`.
  - **`release_hold/3`**: explicit audited hold release under
    `devices.cameras.recordings.hold` and `Source` scope.
  """

  import Ash.Expr

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.RecordingAccessAudit
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingDisposition
  alias ServiceRadar.Camera.RecordingHold
  alias ServiceRadar.Camera.RecordingOperation
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query

  @system_actor SystemActor.system(:camera_recording_holds)
  @unavailable_status "unavailable, deletion in progress"
  @operator_deadline_seconds 300

  @read_permissions [
    "settings.recording.view",
    "settings.recording.manage",
    "settings.recording.operate",
    "devices.cameras.recordings.view",
    "devices.cameras.recordings.hold"
  ]

  @intent_permissions [
    "settings.recording.manage",
    "settings.recording.operate"
  ]

  @kind_c_pinned_archive_states [
    :awaiting_binding,
    :pending,
    :failed_retryable,
    :failed_terminal,
    :deleting,
    :missing
  ]

  @type hold_summary :: %{
          pinned_copy: :archive | :local | nil,
          hold_count: non_neg_integer(),
          kinds: [:investigation | :export],
          hold_ids: [String.t()],
          archive_missing?: boolean()
        }

  @doc """
  Places and accepts a `RecordingHold` over `[start_us, end_us)` after authorizing
  `devices.cameras.recordings.hold` and camera `Source` scope, locking covered
  `RecordingCatalogEntry` rows `FOR UPDATE` in `id` order so concurrent deletion
  intents serialize cleanly (`C.2`, `C4`).
  """
  @spec place_hold(map() | keyword(), keyword()) :: {:ok, RecordingHold.t()} | {:error, term()}
  def place_hold(attrs, opts \\ []) when (is_map(attrs) or is_list(attrs)) and is_list(opts) do
    params = to_map(attrs)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, actor} <- authorize_hold_actor(opts),
         {:ok, created_by_id} <- resolve_actor_id(actor, fetch_val(params, :created_by_id)),
         {:ok, camera_source_id} <-
           cast_required_uuid(fetch_val(params, :camera_source_id), :camera_source_id),
         {:ok, stream_profile_id} <-
           cast_optional_uuid(fetch_val(params, :stream_profile_id), :stream_profile_id),
         {:ok, start_us, end_us} <- parse_hold_window(params),
         {:ok, kind} <- parse_hold_kind(fetch_val(params, :kind)),
         {:ok, reason} <- parse_required_reason(fetch_val(params, :reason)),
         :ok <- authorize_camera_source_scope(camera_source_id, stream_profile_id, actor, opts) do
      write_opts = hold_write_opts(actor, opts)

      transact([RecordingCatalogEntry, RecordingHold, RecordingAccessAudit], fn ->
        covered =
          lock_covered_catalog_entries(
            camera_source_id,
            stream_profile_id,
            start_us,
            end_us
          )

        unavailable_blocks = build_unavailable_blocks(covered)

        create_params = %{
          camera_source_id: camera_source_id,
          stream_profile_id: stream_profile_id,
          start_us: start_us,
          end_us: end_us,
          kind: kind,
          reason: reason,
          created_by_id: created_by_id,
          accepted_at: now,
          unavailable_blocks: unavailable_blocks
        }

        with {:ok, hold} <-
               RecordingHold
               |> Ash.Changeset.for_create(:accept, create_params, write_opts)
               |> Ash.create(write_opts),
             {:ok, _audit} <-
               record_hold_access_audit(:hold_placed, hold, created_by_id, %{
                 "kind" => to_string(hold.kind),
                 "covered_block_count" => length(covered),
                 "unavailable_block_count" => length(unavailable_blocks)
               }) do
          {:ok, hold}
        end
      end)
    end
  end

  @doc """
  Explicitly releases an `:accepted` `RecordingHold` with PaperTrail actor audit
  after authorizing `devices.cameras.recordings.hold` and camera `Source` scope.
  """
  @spec release_hold(String.t(), map() | keyword(), keyword()) ::
          {:ok, RecordingHold.t()} | {:error, term()}
  def release_hold(hold_id, attrs \\ %{}, opts \\ [])
      when is_binary(hold_id) and (is_map(attrs) or is_list(attrs)) and is_list(opts) do
    params = to_map(attrs)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, actor} <- authorize_hold_actor(opts),
         {:ok, hold_uuid} <- cast_required_uuid(hold_id, :hold_id),
         {:ok, released_by_id} <- resolve_actor_id(actor, fetch_val(params, :released_by_id)),
         {:ok, release_reason} <-
           parse_optional_reason(fetch_val(params, :release_reason) || fetch_val(params, :reason)) do
      write_opts = hold_write_opts(actor, opts)

      transact([RecordingHold, RecordingAccessAudit], fn ->
        with {:ok, hold} <- lock_hold(hold_uuid),
             :ok <- authorize_camera_source_scope(hold.camera_source_id, nil, actor, opts),
             :ok <- ensure_hold_accepted(hold),
             {:ok, released} <-
               hold
               |> Ash.Changeset.for_update(
                 :release,
                 %{
                   released_by_id: released_by_id,
                   released_at: now,
                   release_reason: release_reason
                 },
                 write_opts
               )
               |> Ash.Changeset.filter(expr(state == :accepted))
               |> Ash.update(write_opts),
             {:ok, _audit} <-
               record_hold_access_audit(:hold_released, released, released_by_id, %{
                 "kind" => to_string(released.kind),
                 "had_release_reason" => not is_nil(released.release_reason)
               }) do
          {:ok, released}
        end
      end)
    end
  end

  @doc """
  Lists `RecordingHold` rows for `camera_source_id` (newest first) after
  authorizing recording read/hold access and camera `Source` scope.
  """
  @spec list_holds(String.t(), keyword()) :: {:ok, [RecordingHold.t()]} | {:error, term()}
  def list_holds(camera_source_id, opts \\ [])
      when is_binary(camera_source_id) and is_list(opts) do
    actor = resolve_actor(opts)

    with :ok <- authorize_hold_read(actor),
         {:ok, camera_uuid} <- cast_required_uuid(camera_source_id, :camera_source_id),
         :ok <- authorize_camera_source_scope(camera_uuid, nil, actor, opts) do
      RecordingHold
      |> Ash.Query.for_read(:for_camera, %{camera_source_id: camera_uuid}, actor: @system_actor)
      |> Ash.read(actor: @system_actor)
    end
  end

  @doc """
  Computes per-entry `PD5` hold summaries (`%{entry_id => %{pinned_copy, hold_count, kinds, hold_ids, archive_missing?}}`)
  for a list of `RecordingCatalogEntry` structs or maps (`C.2`, `PD5`, `C4`).

  Supports `:loaders` for `:db_free` unit tests:
  - `:holds_for_entries_loader` (`fn entries -> {:ok, summary_map} end`)
  - `:holds_loader` (`fn -> {:ok, holds} end` or `fn camera_ids -> {:ok, holds} end`)
  When `:loaders` is a non-empty map without a hold loader, returns zero active
  holds without touching Postgres so existing `:db_free` unit suites remain pure.
  """
  @spec for_catalog_entries([map()], keyword()) ::
          {:ok, %{String.t() => hold_summary()}} | {:error, term()}
  def for_catalog_entries(entries, opts \\ []) when is_list(entries) and is_list(opts) do
    actor = resolve_actor(opts)

    with :ok <- authorize_hold_read(actor) do
      if entries == [] do
        {:ok, %{}}
      else
        resolve_summaries_for_entries(entries, opts)
      end
    end
  end

  @doc """
  Pure `PD5` pinned-copy rule for a covered `RecordingCatalogEntry` struct or map:
  - `:archive` when `archive_state == :verified` (and `local_state != :quarantined`);
  - `:local` when `archive_state != :verified` and `local_state == :present`;
  - `nil` otherwise (quarantined, or neither a verified archive copy nor a present
    local copy remains).
  """
  @spec pinned_copy_for_entry(map()) :: :archive | :local | nil
  def pinned_copy_for_entry(entry) when is_map(entry) do
    local_state = normalize_atom(fetch_val(entry, :local_state))
    archive_state = normalize_atom(fetch_val(entry, :archive_state))

    cond do
      local_state == :quarantined -> nil
      archive_state == :verified -> :archive
      local_state == :present -> :local
      true -> nil
    end
  end

  @doc """
  Returns `true` when `hold` is in `:accepted` state, intersects `entry`'s
  `[timeline_start_us, timeline_end_us)` on matching `camera_source_id` (and
  optional `stream_profile_id`), `entry` is non-quarantined, and `entry` was NOT
  recorded in `hold.unavailable_blocks`.
  """
  @spec hold_protects_entry?(map(), map()) :: boolean()
  def hold_protects_entry?(hold, entry) when is_map(hold) and is_map(entry) do
    state = normalize_atom(fetch_val(hold, :state))
    local_state = normalize_atom(fetch_val(entry, :local_state))
    entry_id = fetch_val(entry, :id)
    entry_cam = fetch_val(entry, :camera_source_id)
    hold_cam = fetch_val(hold, :camera_source_id)
    hold_prof = fetch_val(hold, :stream_profile_id)
    entry_prof = fetch_val(entry, :stream_profile_id)
    t_start = fetch_val(entry, :timeline_start_us)
    t_end = fetch_val(entry, :timeline_end_us)
    h_start = fetch_val(hold, :start_us)
    h_end = fetch_val(hold, :end_us)

    state == :accepted and
      local_state != :quarantined and
      not is_nil(entry_cam) and
      not is_nil(hold_cam) and
      to_string(entry_cam) == to_string(hold_cam) and
      (is_nil(hold_prof) or
         (not is_nil(entry_prof) and to_string(hold_prof) == to_string(entry_prof))) and
      is_integer(t_start) and is_integer(t_end) and
      is_integer(h_start) and is_integer(h_end) and
      t_end > h_start and t_start < h_end and
      not entry_listed_unavailable?(hold, entry_id)
  end

  @doc """
  Computes the `PD5` hold summary for a single `entry` against a collection of
  accepted `holds`.
  """
  @spec summarize_entry(map(), [map()]) :: hold_summary()
  def summarize_entry(entry, holds) when is_map(entry) and is_list(holds) do
    covering = Enum.filter(holds, &hold_protects_entry?(&1, entry))

    if covering == [] do
      %{
        pinned_copy: nil,
        hold_count: 0,
        kinds: [],
        hold_ids: [],
        archive_missing?: false
      }
    else
      kinds =
        covering
        |> Enum.map(&normalize_hold_kind(fetch_val(&1, :kind)))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      hold_ids =
        covering
        |> Enum.map(&fetch_val(&1, :id))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&to_string/1)

      archive_state = normalize_atom(fetch_val(entry, :archive_state))

      %{
        pinned_copy: pinned_copy_for_entry(entry),
        hold_count: length(covering),
        kinds: kinds,
        hold_ids: hold_ids,
        archive_missing?: archive_state == :missing
      }
    end
  end

  @doc """
  Locks `catalog_entry_id` `FOR UPDATE`, evaluates active `:accepted` holds under
  `PD5`, transitions `local_state -> :reclaiming` or `archive_state -> :deleting`,
  and inserts the `:requested` `RecordingDisposition` row in one CNPG transaction
  (`C.2`, `C.3`, `C6`, `C7`).
  """
  @spec begin_copy_deletion_intent(
          String.t(),
          :local | :archive,
          map() | keyword(),
          keyword()
        ) ::
          {:ok, %{entry: RecordingCatalogEntry.t(), disposition: RecordingDisposition.t()}}
          | {:error, term()}
  def begin_copy_deletion_intent(catalog_entry_id, copy, disposition_attrs \\ %{}, opts \\ [])
      when is_binary(catalog_entry_id) and copy in [:local, :archive] and
             (is_map(disposition_attrs) or is_list(disposition_attrs)) and is_list(opts) do
    attrs = to_map(disposition_attrs)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    actor = resolve_actor(opts)

    with {:ok, reason} <- parse_disposition_reason(fetch_val(attrs, :reason)),
         :ok <- authorize_intent_for_reason(actor, reason),
         {:ok, entry_uuid} <- cast_required_uuid(catalog_entry_id, :catalog_entry_id),
         {:ok, operation_id} <- resolve_operation_id(fetch_val(attrs, :operation_id)),
         {:ok, actor_id} <- resolve_intent_actor_id(actor, fetch_val(attrs, :actor_id)) do
      transact([RecordingCatalogEntry, RecordingHold, RecordingDisposition], fn ->
        with {:ok, entry} <- lock_catalog_entry(entry_uuid),
             :ok <- check_copy_deletable(entry, copy, reason),
             {:ok, hold_check_result} <- evaluate_hold_guard_locked(entry, copy),
             {:ok, updated_entry} <- transition_entry_for_intent(entry, copy, now),
             {:ok, disposition} <-
               insert_requested_disposition(
                 entry,
                 copy,
                 reason,
                 operation_id,
                 actor_id,
                 attrs,
                 hold_check_result
               ) do
          {:ok, %{entry: updated_entry, disposition: disposition}}
        end
      end)
    end
  end

  @doc """
  Appends a follow-up `RecordingDisposition` step (`:executed`, `:verified_absent`,
  or `:failed` with `:error_class`) sharing the `operation_id` and identity of an
  earlier `:requested` disposition (`C.3`, `C7`).
  """
  @spec record_disposition_step(
          RecordingDisposition.t() | map(),
          :executed | :verified_absent | :failed,
          map() | keyword(),
          keyword()
        ) :: {:ok, RecordingDisposition.t()} | {:error, term()}
  def record_disposition_step(base, step, extra_attrs \\ %{}, opts \\ [])
      when is_map(base) and step in [:executed, :verified_absent, :failed] and
             (is_map(extra_attrs) or is_list(extra_attrs)) and is_list(opts) do
    actor = resolve_actor(opts)
    extra = to_map(extra_attrs)

    with :ok <- authorize_deletion_intent(actor),
         {:ok, actor_id} <-
           resolve_intent_actor_id(
             actor,
             fetch_val(extra, :actor_id) || fetch_val(base, :actor_id)
           ) do
      params = %{
        operation_id: fetch_val(base, :operation_id),
        catalog_entry_id: fetch_val(base, :catalog_entry_id),
        storage_id: fetch_val(base, :storage_id),
        block_key: fetch_val(base, :block_key),
        copy: fetch_val(base, :copy),
        reason: fetch_val(base, :reason),
        settings_revision: fetch_val(base, :settings_revision),
        effective_settings: fetch_val(base, :effective_settings) || %{},
        hold_check_result: fetch_val(base, :hold_check_result) || %{},
        local_copy_remained:
          case fetch_val(extra, :local_copy_remained) do
            nil -> fetch_val(base, :local_copy_remained)
            explicit -> explicit
          end,
        step: step,
        error_class: if(step == :failed, do: fetch_val(extra, :error_class)),
        actor_id: actor_id
      }

      RecordingDisposition
      |> Ash.Changeset.for_create(:record, params, actor: @system_actor)
      |> Ash.create(actor: @system_actor)
    end
  end

  @doc """
  Locks `catalog_entry_id` `FOR UPDATE`, transitions `archive_state` to `:verified`,
  and moves any active `:accepted` hold's pinned copy to `:archive` (`PD5`, `C4`).
  """
  @spec mark_archive_verified_and_move_pin(String.t(), map() | keyword(), keyword()) ::
          {:ok,
           %{
             entry: RecordingCatalogEntry.t(),
             pinned_copy: :archive | :local | nil,
             holds: [RecordingHold.t()]
           }}
          | {:error, term()}
  def mark_archive_verified_and_move_pin(catalog_entry_id, verification_attrs \\ %{}, opts \\ [])
      when is_binary(catalog_entry_id) and
             (is_map(verification_attrs) or is_list(verification_attrs)) and is_list(opts) do
    attrs = to_map(verification_attrs)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    actor = resolve_actor(opts)

    with :ok <- authorize_deletion_intent(actor),
         {:ok, entry_uuid} <- cast_required_uuid(catalog_entry_id, :catalog_entry_id) do
      transact([RecordingCatalogEntry, RecordingHold], fn ->
        with {:ok, entry} <- lock_catalog_entry(entry_uuid),
             :ok <- ensure_archive_not_deleted(entry) do
          update_params = %{
            archive_state: :verified,
            archive_state_at: now,
            archived_at: fetch_val(attrs, :archived_at) || entry.archived_at || now,
            nvr_archive_receipt_id:
              fetch_val(attrs, :nvr_archive_receipt_id) || entry.nvr_archive_receipt_id,
            archive_binding_id: fetch_val(attrs, :archive_binding_id) || entry.archive_binding_id,
            quarantine_binding_id:
              fetch_val(attrs, :quarantine_binding_id) || entry.quarantine_binding_id,
            archive_last_error_class: nil
          }

          with {:ok, updated} <-
                 entry
                 |> Ash.Changeset.for_update(:transition_archive_state, update_params)
                 |> Ash.update(actor: @system_actor) do
            covering = load_covering_holds_for_entry(updated)
            pinned = if covering == [], do: nil, else: pinned_copy_for_entry(updated)
            {:ok, %{entry: updated, pinned_copy: pinned, holds: covering}}
          end
        end
      end)
    end
  end

  @doc """
  Locks `catalog_entry_id` `FOR UPDATE`, marks `archive_state = :missing`, moves
  any active `:accepted` hold's pin back to `:local` when `local_state == :present`,
  and returns the affected holds (`C4`, `PD5`).
  """
  @spec mark_archive_missing_and_fallback_pin(String.t(), map() | keyword(), keyword()) ::
          {:ok,
           %{
             entry: RecordingCatalogEntry.t(),
             pinned_copy: :archive | :local | nil,
             holds: [RecordingHold.t()],
             held_archive_missing?: boolean()
           }}
          | {:error, term()}
  def mark_archive_missing_and_fallback_pin(catalog_entry_id, missing_attrs \\ %{}, opts \\ [])
      when is_binary(catalog_entry_id) and (is_map(missing_attrs) or is_list(missing_attrs)) and
             is_list(opts) do
    attrs = to_map(missing_attrs)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    actor = resolve_actor(opts)

    with :ok <- authorize_deletion_intent(actor),
         {:ok, entry_uuid} <- cast_required_uuid(catalog_entry_id, :catalog_entry_id) do
      transact([RecordingCatalogEntry, RecordingHold], fn ->
        with {:ok, entry} <- lock_catalog_entry(entry_uuid),
             :ok <- ensure_archive_not_deleted(entry) do
          error_class =
            fetch_val(attrs, :error_class) ||
              fetch_val(attrs, :archive_last_error_class) ||
              "archive_missing"

          update_params = %{
            archive_state: :missing,
            archive_state_at: now,
            archive_last_error_class: error_class
          }

          with {:ok, updated} <-
                 entry
                 |> Ash.Changeset.for_update(:transition_archive_state, update_params)
                 |> Ash.update(actor: @system_actor) do
            covering = load_covering_holds_for_entry(updated)
            pinned = if covering == [], do: nil, else: pinned_copy_for_entry(updated)

            {:ok,
             %{
               entry: updated,
               pinned_copy: pinned,
               holds: covering,
               held_archive_missing?: covering != []
             }}
          end
        end
      end)
    end
  end

  @doc """
  Audited operator delete intent on a quarantined or unattributable
  `RecordingCatalogEntry` (`R.10`, `R2`, `R6`, `C7`).

  Strictly requires `settings.recording.operate` (or system actor) and explicit
  confirmation (`confirm: true`). Locks the catalog entry `FOR UPDATE`, transitions
  `local_state: :quarantined -> :reclaiming` and
  `operator_disposition_state: :delete_requested`, creates a `RecordingOperation`
  (`kind: :quarantine_delete`), and appends a `:requested` `RecordingDisposition`
  row with `reason: :operator_quarantine` in one CNPG transaction.
  """
  @spec request_quarantine_delete(String.t(), map() | keyword(), keyword()) ::
          {:ok,
           %{
             entry: RecordingCatalogEntry.t(),
             disposition: RecordingDisposition.t(),
             operation: RecordingOperation.t()
           }}
          | {:error, term()}
  def request_quarantine_delete(catalog_entry_id, attrs \\ %{}, opts \\ [])
      when is_binary(catalog_entry_id) and (is_map(attrs) or is_list(attrs)) and is_list(opts) do
    params = to_map(attrs)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    actor = resolve_actor(opts)
    require_confirm? = Keyword.get(opts, :require_confirmation?, true)

    with :ok <- authorize_operate_actor(actor),
         :ok <- verify_explicit_confirmation(params, require_confirm?),
         {:ok, entry_uuid} <- cast_required_uuid(catalog_entry_id, :catalog_entry_id),
         {:ok, actor_id} <- resolve_intent_actor_id(actor, fetch_val(params, :actor_id)),
         {:ok, note} <- parse_operator_note(params, "operator_quarantine_delete") do
      transact([RecordingCatalogEntry, RecordingDisposition, RecordingOperation], fn ->
        execute_quarantine_delete_intent(entry_uuid, actor_id, note, params, now)
      end)
    end
  end

  @doc """
  Audited operator export / preserve intent on a quarantined or unattributable
  `RecordingCatalogEntry` (`R.10`, `R4` step 6).

  Strictly requires `settings.recording.operate` (or system actor). Keeps
  `local_state == :quarantined` (pinned, never evicted), sets
  `operator_disposition_state = :export_requested`, and records a `RecordingOperation`
  (`kind: :quarantine_export`) in one CNPG transaction.
  """
  @spec request_quarantine_export(String.t(), map() | keyword(), keyword()) ::
          {:ok, %{entry: RecordingCatalogEntry.t(), operation: RecordingOperation.t()}}
          | {:error, term()}
  def request_quarantine_export(catalog_entry_id, attrs \\ %{}, opts \\ [])
      when is_binary(catalog_entry_id) and (is_map(attrs) or is_list(attrs)) and is_list(opts) do
    params = to_map(attrs)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    actor = resolve_actor(opts)

    with :ok <- authorize_operate_actor(actor),
         {:ok, entry_uuid} <- cast_required_uuid(catalog_entry_id, :catalog_entry_id),
         {:ok, actor_id} <- resolve_intent_actor_id(actor, fetch_val(params, :actor_id)),
         {:ok, note} <- parse_operator_note(params, "operator_quarantine_export") do
      transact([RecordingCatalogEntry, RecordingOperation], fn ->
        execute_quarantine_export_intent(entry_uuid, actor_id, note, now)
      end)
    end
  end

  @doc """
  Audited operator acceptance of a `:missing` archive copy loss (`A6` Transition 9,
  `E.3`, `R.10`, `d0797c8bc8`).

  Strictly requires `settings.recording.operate`, AND when any active `:accepted`
  `RecordingHold` covers the entry, ALSO requires `devices.cameras.recordings.hold`
  (refusing otherwise and leaving `archive_state == :missing`). Transitions
  `archive_state -> :not_required` (keeping `archive_binding_id`), records a
  succeeded `RecordingOperation` (`kind: :archive_loss_acceptance`), and appends a
  `RecordingDisposition` row with `reason: :archive_loss_accepted` in one CNPG
  transaction.
  """
  @spec accept_missing_archive_loss(String.t(), map() | keyword(), keyword()) ::
          {:ok,
           %{
             entry: RecordingCatalogEntry.t(),
             disposition: RecordingDisposition.t(),
             operation: RecordingOperation.t()
           }}
          | {:error, term()}
  def accept_missing_archive_loss(catalog_entry_id, attrs \\ %{}, opts \\ [])
      when is_binary(catalog_entry_id) and (is_map(attrs) or is_list(attrs)) and is_list(opts) do
    params = to_map(attrs)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    actor = resolve_actor(opts)
    require_confirm? = Keyword.get(opts, :require_confirmation?, false)

    with :ok <- authorize_operate_actor(actor),
         :ok <- verify_optional_confirmation(params, require_confirm?),
         {:ok, entry_uuid} <- cast_required_uuid(catalog_entry_id, :catalog_entry_id),
         {:ok, actor_id} <- resolve_intent_actor_id(actor, fetch_val(params, :actor_id)),
         {:ok, note} <- parse_operator_note(params, "operator_accepted_archive_loss") do
      transact(
        [RecordingCatalogEntry, RecordingHold, RecordingDisposition, RecordingOperation],
        fn ->
          execute_accept_missing_archive_loss(
            entry_uuid,
            actor,
            actor_id,
            note,
            params,
            now,
            opts
          )
        end
      )
    end
  end

  @doc """
  Audited operator re-archive request on a `:missing` archive copy whose local copy
  is still `:present` (`A6` Transition 8, `E.3`, `d0797c8bc8`).

  Strictly requires `settings.recording.operate`, returns `archive_state` to `:pending`
  under its recorded `archive_binding_id`, and records a `RecordingOperation`
  (`kind: :missing_rearchive`) in one CNPG transaction.
  """
  @spec request_missing_archive_rearchive(String.t(), map() | keyword(), keyword()) ::
          {:ok, %{entry: RecordingCatalogEntry.t(), operation: RecordingOperation.t()}}
          | {:error, term()}
  def request_missing_archive_rearchive(catalog_entry_id, attrs \\ %{}, opts \\ [])
      when is_binary(catalog_entry_id) and (is_map(attrs) or is_list(attrs)) and is_list(opts) do
    params = to_map(attrs)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    actor = resolve_actor(opts)

    with :ok <- authorize_operate_actor(actor),
         {:ok, entry_uuid} <- cast_required_uuid(catalog_entry_id, :catalog_entry_id),
         {:ok, actor_id} <- resolve_intent_actor_id(actor, fetch_val(params, :actor_id)),
         {:ok, note} <- parse_operator_note(params, "operator_requested_rearchive") do
      transact([RecordingCatalogEntry, RecordingOperation, ArchiveBinding], fn ->
        execute_missing_archive_rearchive(entry_uuid, actor_id, note, now)
      end)
    end
  end

  defp resolve_summaries_for_entries(entries, opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    case Map.get(loaders, :holds_for_entries_loader) do
      loader when is_function(loader, 1) ->
        loader.(entries)

      _ ->
        with {:ok, holds} <- load_holds_for_entries(entries, loaders) do
          summaries =
            for entry <- entries,
                id = fetch_val(entry, :id),
                not is_nil(id),
                into: %{} do
              {to_string(id), summarize_entry(entry, holds)}
            end

          {:ok, summaries}
        end
    end
  end

  defp load_holds_for_entries(entries, loaders) do
    camera_ids =
      for entry <- entries,
          cid = fetch_val(entry, :camera_source_id),
          not is_nil(cid),
          {:ok, uuid} <- [Ecto.UUID.cast(to_string(cid))],
          uniq: true,
          do: uuid

    cond do
      is_function(Map.get(loaders, :holds_loader), 1) ->
        loaders.holds_loader.(camera_ids)

      is_function(Map.get(loaders, :holds_loader), 0) ->
        loaders.holds_loader.()

      map_size(loaders) > 0 ->
        {:ok, []}

      camera_ids == [] ->
        {:ok, []}

      true ->
        {min_start, max_end} = timeline_span(entries)

        query =
          RecordingHold
          |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
          |> Ash.Query.filter(state == :accepted and camera_source_id in ^camera_ids)

        query =
          if is_integer(min_start) and is_integer(max_end) do
            Ash.Query.filter(query, end_us > ^min_start and start_us < ^max_end)
          else
            query
          end

        Ash.read(query, actor: @system_actor)
    end
  end

  defp timeline_span(entries) do
    Enum.reduce(entries, {nil, nil}, fn entry, {min_s, max_e} ->
      s = fetch_val(entry, :timeline_start_us)
      e = fetch_val(entry, :timeline_end_us)

      next_s =
        cond do
          not is_integer(s) -> min_s
          is_nil(min_s) -> s
          true -> min(min_s, s)
        end

      next_e =
        cond do
          not is_integer(e) -> max_e
          is_nil(max_e) -> e
          true -> max(max_e, e)
        end

      {next_s, next_e}
    end)
  end

  defp lock_covered_catalog_entries(camera_source_id, stream_profile_id, start_us, end_us) do
    query =
      RecordingCatalogEntry
      |> Ash.Query.filter(
        camera_source_id == ^camera_source_id and
          not is_nil(timeline_start_us) and
          not is_nil(timeline_end_us) and
          timeline_end_us > ^start_us and
          timeline_start_us < ^end_us
      )
      |> maybe_filter_profile(stream_profile_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock(:for_update)

    Ash.read!(query, actor: @system_actor)
  end

  defp maybe_filter_profile(query, nil), do: query

  defp maybe_filter_profile(query, profile_id) do
    Ash.Query.filter(query, stream_profile_id == ^profile_id)
  end

  defp build_unavailable_blocks(covered_entries) do
    covered_entries
    |> Enum.filter(fn entry ->
      entry.local_state != :quarantined and is_nil(pinned_copy_for_entry(entry))
    end)
    |> Enum.map(fn entry ->
      %{
        "catalog_entry_id" => entry.id,
        "storage_id" => to_string(entry.storage_id),
        "block_key" => entry.block_key,
        "timeline_start_us" => entry.timeline_start_us,
        "timeline_end_us" => entry.timeline_end_us,
        "local_state" => to_string(entry.local_state),
        "archive_state" => to_string(entry.archive_state),
        "status" => @unavailable_status
      }
    end)
  end

  defp entry_listed_unavailable?(_hold, nil), do: false

  defp entry_listed_unavailable?(hold, entry_id) do
    entry_id_str = to_string(entry_id)

    hold
    |> fetch_val(:unavailable_blocks)
    |> List.wrap()
    |> Enum.any?(fn item ->
      is_map(item) and
        to_string(fetch_val(item, :catalog_entry_id) || "") == entry_id_str
    end)
  end

  defp lock_hold(hold_id) do
    RecordingHold
    |> Ash.Query.filter(id == ^hold_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: @system_actor)
    |> case do
      {:ok, %RecordingHold{} = hold} -> {:ok, hold}
      {:ok, nil} -> {:error, :hold_not_found}
      {:error, _} = error -> error
    end
  end

  defp ensure_hold_accepted(%RecordingHold{state: :accepted}), do: :ok

  defp ensure_hold_accepted(%RecordingHold{state: :released}),
    do: {:error, :hold_already_released}

  defp ensure_hold_accepted(%RecordingHold{state: state}),
    do: {:error, {:invalid_hold_state, state}}

  defp lock_catalog_entry(entry_id) do
    RecordingCatalogEntry
    |> Ash.Query.filter(id == ^entry_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: @system_actor)
    |> case do
      {:ok, %RecordingCatalogEntry{} = entry} -> {:ok, entry}
      {:ok, nil} -> {:error, :catalog_entry_not_found}
      {:error, _} = error -> error
    end
  end

  defp ensure_archive_not_deleted(%RecordingCatalogEntry{archive_state: :deleted}) do
    {:error, :archive_already_deleted}
  end

  defp ensure_archive_not_deleted(_entry), do: :ok

  defp check_copy_deletable(%RecordingCatalogEntry{local_state: :quarantined}, _copy, reason)
       when reason != :operator_quarantine do
    {:error, :quarantined_entry_pinned}
  end

  defp check_copy_deletable(%RecordingCatalogEntry{} = entry, :local, :operator_quarantine) do
    if entry.local_state == :quarantined do
      :ok
    else
      {:error, {:local_copy_not_deletable, entry.local_state}}
    end
  end

  defp check_copy_deletable(%RecordingCatalogEntry{} = entry, :local, _reason) do
    cond do
      entry.local_state != :present ->
        {:error, {:local_copy_not_deletable, entry.local_state}}

      entry.archive_state in @kind_c_pinned_archive_states ->
        {:error, {:pinned_by_archive_state, entry.archive_state}}

      true ->
        :ok
    end
  end

  defp check_copy_deletable(%RecordingCatalogEntry{} = entry, :archive, _reason) do
    if entry.archive_state == :verified do
      :ok
    else
      {:error, {:archive_copy_not_deletable, entry.archive_state}}
    end
  end

  defp evaluate_hold_guard_locked(%RecordingCatalogEntry{} = entry, copy) do
    covering = load_covering_holds_for_entry(entry)

    if covering == [] do
      {:ok,
       %{
         "held" => false,
         "pinned_copy" => nil,
         "hold_count" => 0,
         "hold_ids" => [],
         "decision" => "allowed_unheld"
       }}
    else
      pinned = pinned_copy_for_entry(entry)
      hold_ids = Enum.map(covering, & &1.id)

      if pinned == copy do
        {:error,
         {:blocked_by_hold,
          %{
            pinned_copy: pinned,
            hold_count: length(covering),
            hold_ids: hold_ids
          }}}
      else
        {:ok,
         %{
           "held" => true,
           "pinned_copy" => if(pinned, do: to_string(pinned)),
           "hold_count" => length(covering),
           "hold_ids" => hold_ids,
           "decision" => "allowed_local_eviction_archive_pinned"
         }}
      end
    end
  end

  defp load_covering_holds_for_entry(%RecordingCatalogEntry{
         camera_source_id: cam_id,
         timeline_start_us: t_start,
         timeline_end_us: t_end
       })
       when is_nil(cam_id) or not is_integer(t_start) or not is_integer(t_end) do
    []
  end

  defp load_covering_holds_for_entry(%RecordingCatalogEntry{} = entry) do
    cam_id = entry.camera_source_id
    t_start = entry.timeline_start_us
    t_end = entry.timeline_end_us

    RecordingHold
    |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
    |> Ash.Query.filter(
      state == :accepted and
        camera_source_id == ^cam_id and
        end_us > ^t_start and
        start_us < ^t_end
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(actor: @system_actor)
    |> Enum.filter(&hold_protects_entry?(&1, entry))
  end

  defp transition_entry_for_intent(entry, :local, now) do
    params =
      if is_nil(entry.quarantine_reason) do
        %{local_state: :reclaiming, local_state_at: now}
      else
        %{
          local_state: :reclaiming,
          local_state_at: now,
          operator_disposition_state: :delete_requested
        }
      end

    entry
    |> Ash.Changeset.for_update(:transition_local_state, params)
    |> Ash.update(actor: @system_actor)
  end

  defp transition_entry_for_intent(entry, :archive, now) do
    entry
    |> Ash.Changeset.for_update(:transition_archive_state, %{
      archive_state: :deleting,
      archive_state_at: now
    })
    |> Ash.update(actor: @system_actor)
  end

  defp insert_requested_disposition(
         entry,
         copy,
         reason,
         operation_id,
         actor_id,
         attrs,
         hold_check_result
       ) do
    local_remained =
      if copy == :archive do
        case fetch_val(attrs, :local_copy_remained) do
          val when is_boolean(val) -> val
          _ -> entry.local_state == :present
        end
      end

    params = %{
      operation_id: operation_id,
      catalog_entry_id: entry.id,
      storage_id: entry.storage_id,
      block_key: entry.block_key,
      copy: copy,
      reason: reason,
      settings_revision: fetch_val(attrs, :settings_revision),
      effective_settings: fetch_val(attrs, :effective_settings) || %{},
      hold_check_result: hold_check_result,
      local_copy_remained: local_remained,
      step: :requested,
      error_class: nil,
      actor_id: actor_id
    }

    RecordingDisposition
    |> Ash.Changeset.for_create(:record, params, actor: @system_actor)
    |> Ash.create(actor: @system_actor)
  end

  defp authorize_hold_actor(opts) do
    actor = resolve_actor(opts)

    if match?(%{role: :system}, actor) or
         ActorHasPermission.match?(
           actor,
           [permission: "devices.cameras.recordings.hold"],
           %{}
         ) do
      {:ok, actor}
    else
      {:error, Forbidden.exception([])}
    end
  end

  defp authorize_hold_read(actor) do
    permitted? =
      match?(%{role: :system}, actor) or
        Enum.any?(@read_permissions, fn perm ->
          ActorHasPermission.match?(actor, [permission: perm], %{})
        end)

    if permitted?, do: :ok, else: {:error, Forbidden.exception([])}
  end

  defp authorize_intent_for_reason(actor, :operator_quarantine),
    do: authorize_operate_actor(actor)

  defp authorize_intent_for_reason(actor, _reason), do: authorize_deletion_intent(actor)

  defp authorize_operate_actor(actor) do
    permitted? =
      match?(%{role: :system}, actor) or
        ActorHasPermission.match?(actor, [permission: "settings.recording.operate"], %{})

    if permitted?, do: :ok, else: {:error, Forbidden.exception([])}
  end

  defp authorize_deletion_intent(actor) do
    permitted? =
      match?(%{role: :system}, actor) or
        Enum.any?(@intent_permissions, fn perm ->
          ActorHasPermission.match?(actor, [permission: perm], %{})
        end)

    if permitted?, do: :ok, else: {:error, Forbidden.exception([])}
  end

  defp verify_explicit_confirmation(_params, false), do: :ok

  defp verify_explicit_confirmation(params, true) do
    if fetch_val(params, :confirm) in [true, "true"] do
      :ok
    else
      {:error, :confirmation_required}
    end
  end

  defp verify_optional_confirmation(params, true), do: verify_explicit_confirmation(params, true)

  defp verify_optional_confirmation(params, false) do
    case fetch_val(params, :confirm) do
      val when val in [false, "false"] -> {:error, :confirmation_required}
      _ -> :ok
    end
  end

  defp parse_operator_note(params, default_note) do
    raw = fetch_val(params, :note) || fetch_val(params, :reason)

    cond do
      is_nil(raw) ->
        {:ok, default_note}

      is_binary(raw) ->
        trimmed = String.trim(raw)

        cond do
          trimmed == "" -> {:ok, default_note}
          byte_size(trimmed) > 1024 -> {:error, :invalid_operator_note}
          true -> {:ok, trimmed}
        end

      true ->
        {:error, :invalid_operator_note}
    end
  end

  defp execute_quarantine_delete_intent(entry_uuid, actor_id, note, params, now) do
    with {:ok, entry} <- lock_catalog_entry(entry_uuid),
         :ok <- ensure_quarantined_deletable(entry),
         {:ok, operation} <-
           start_operator_operation(:quarantine_delete, entry, actor_id, now, %{
             "catalog_entry_id" => entry.id,
             "quarantine_reason" => to_string(entry.quarantine_reason),
             "intent" => "delete_quarantined_block",
             "operator_note" => note
           }),
         decision = %{
           "action" => "delete_intent",
           "actor_id" => actor_id,
           "note" => note,
           "operation_id" => operation.id,
           "decided_at" => DateTime.to_iso8601(now)
         },
         {:ok, updated_entry} <-
           entry
           |> Ash.Changeset.for_update(:record_operator_decision, %{
             local_state: :reclaiming,
             local_state_at: now,
             operator_disposition_state: :delete_requested,
             operator_decision: decision
           })
           |> Ash.update(actor: @system_actor),
         {:ok, disposition} <-
           insert_requested_disposition(
             entry,
             :local,
             :operator_quarantine,
             operation.id,
             actor_id,
             Map.put_new(params, :effective_settings, %{
               "quarantine_reason" => to_string(entry.quarantine_reason),
               "operator_note" => note
             }),
             %{
               "held" => false,
               "pinned_copy" => nil,
               "hold_count" => 0,
               "hold_ids" => [],
               "decision" => "operator_quarantine_delete"
             }
           ) do
      {:ok, %{entry: updated_entry, disposition: disposition, operation: operation}}
    end
  end

  defp ensure_quarantined_deletable(%RecordingCatalogEntry{quarantine_reason: nil} = entry) do
    {:error, {:not_quarantined, entry.local_state}}
  end

  defp ensure_quarantined_deletable(%RecordingCatalogEntry{local_state: :quarantined}), do: :ok

  defp ensure_quarantined_deletable(%RecordingCatalogEntry{local_state: :reclaiming}) do
    {:error, :quarantine_delete_already_requested}
  end

  defp ensure_quarantined_deletable(%RecordingCatalogEntry{local_state: :reclaimed}) do
    {:error, :quarantine_already_disposed}
  end

  defp ensure_quarantined_deletable(%RecordingCatalogEntry{local_state: state}) do
    {:error, {:not_quarantined, state}}
  end

  defp execute_quarantine_export_intent(entry_uuid, actor_id, note, now) do
    with {:ok, entry} <- lock_catalog_entry(entry_uuid),
         :ok <- ensure_quarantined_exportable(entry),
         {:ok, operation} <-
           start_operator_operation(:quarantine_export, entry, actor_id, now, %{
             "catalog_entry_id" => entry.id,
             "quarantine_reason" => to_string(entry.quarantine_reason),
             "intent" => "export_for_inspection",
             "operator_note" => note
           }),
         decision = %{
           "action" => "export_intent",
           "actor_id" => actor_id,
           "note" => note,
           "operation_id" => operation.id,
           "decided_at" => DateTime.to_iso8601(now)
         },
         {:ok, updated_entry} <-
           entry
           |> Ash.Changeset.for_update(:record_operator_decision, %{
             local_state: entry.local_state,
             local_state_at: entry.local_state_at,
             operator_disposition_state: :export_requested,
             operator_decision: decision
           })
           |> Ash.update(actor: @system_actor) do
      {:ok, %{entry: updated_entry, operation: operation}}
    end
  end

  defp ensure_quarantined_exportable(%RecordingCatalogEntry{
         quarantine_reason: reason,
         local_state: :quarantined
       })
       when not is_nil(reason), do: :ok

  defp ensure_quarantined_exportable(%RecordingCatalogEntry{local_state: state}) do
    {:error, {:quarantine_not_exportable, state}}
  end

  defp execute_accept_missing_archive_loss(entry_uuid, actor, actor_id, note, params, now, opts) do
    with {:ok, entry} <- lock_catalog_entry(entry_uuid),
         :ok <- ensure_archive_is_missing(entry),
         covering = load_covering_holds_for_entry(entry),
         :ok <- verify_hold_authority_for_missing_loss(covering, entry, actor, opts),
         {:ok, operation} <-
           record_completed_operator_operation(
             :archive_loss_acceptance,
             entry,
             actor_id,
             now,
             %{
               "catalog_entry_id" => entry.id,
               "action" => "accept_missing_archive_loss",
               "held" => covering != [],
               "hold_count" => length(covering),
               "local_copy_remained" => entry.local_state == :present,
               "operator_note" => note
             }
           ),
         {:ok, updated_entry} <-
           entry
           |> Ash.Changeset.for_update(:transition_archive_state, %{
             archive_state: :not_required,
             archive_state_at: now,
             archive_last_error_class: nil
           })
           |> Ash.update(actor: @system_actor),
         {:ok, disposition} <-
           insert_archive_loss_disposition(entry, operation.id, actor_id, note, params, covering) do
      {:ok, %{entry: updated_entry, disposition: disposition, operation: operation}}
    end
  end

  defp ensure_archive_is_missing(%RecordingCatalogEntry{archive_state: :missing}), do: :ok

  defp ensure_archive_is_missing(%RecordingCatalogEntry{archive_state: state}) do
    {:error, {:archive_not_missing, state}}
  end

  defp verify_hold_authority_for_missing_loss([], _entry, _actor, _opts), do: :ok

  defp verify_hold_authority_for_missing_loss(_covering, entry, actor, opts) do
    has_hold_perm? =
      match?(%{role: :system}, actor) or
        ActorHasPermission.match?(actor, [permission: "devices.cameras.recordings.hold"], %{})

    if has_hold_perm? do
      if is_nil(entry.camera_source_id) do
        :ok
      else
        authorize_camera_source_scope(entry.camera_source_id, nil, actor, opts)
      end
    else
      {:error, Forbidden.exception([])}
    end
  end

  defp insert_archive_loss_disposition(entry, operation_id, actor_id, note, params, covering) do
    hold_ids = Enum.map(covering, & &1.id)
    held? = covering != []

    eff_settings =
      params
      |> fetch_val(:effective_settings)
      |> case do
        m when is_map(m) -> m
        _ -> %{}
      end
      |> Map.merge(%{
        "operator_note" => note,
        "previous_archive_state" => "missing"
      })

    disp_params = %{
      operation_id: operation_id,
      catalog_entry_id: entry.id,
      storage_id: entry.storage_id,
      block_key: entry.block_key,
      copy: :archive,
      reason: :archive_loss_accepted,
      settings_revision: fetch_val(params, :settings_revision),
      effective_settings: eff_settings,
      hold_check_result: %{
        "held" => held?,
        "hold_count" => length(covering),
        "hold_ids" => hold_ids,
        "decision" => if(held?, do: "accepted_with_hold_authority", else: "accepted_unheld")
      },
      local_copy_remained: entry.local_state == :present,
      step: :verified_absent,
      error_class: nil,
      actor_id: actor_id
    }

    RecordingDisposition
    |> Ash.Changeset.for_create(:record, disp_params, actor: @system_actor)
    |> Ash.create(actor: @system_actor)
  end

  defp execute_missing_archive_rearchive(entry_uuid, actor_id, note, now) do
    with {:ok, entry} <- lock_catalog_entry(entry_uuid),
         :ok <- ensure_archive_is_missing(entry),
         {:ok, owed_binding_id} <- ensure_rearchive_eligible(entry),
         {:ok, operation} <-
           start_operator_operation(
             :missing_rearchive,
             entry,
             actor_id,
             now,
             %{
               "catalog_entry_id" => entry.id,
               "action" => "rearchive_missing_copy",
               "owed_copy_kind" =>
                 if(entry.local_state == :quarantined, do: "quarantine", else: "archive"),
               "operator_note" => note
             },
             owed_binding_id
           ),
         {:ok, updated_entry} <-
           entry
           |> Ash.Changeset.for_update(:transition_archive_state, %{
             archive_state: :pending,
             archive_state_at: now,
             archive_last_error_class: nil
           })
           |> Ash.update(actor: @system_actor) do
      {:ok, %{entry: updated_entry, operation: operation}}
    end
  end

  defp ensure_rearchive_eligible(%RecordingCatalogEntry{local_state: :present} = entry) do
    verify_retained_archive_binding(entry.archive_binding_id)
  end

  defp ensure_rearchive_eligible(
         %RecordingCatalogEntry{local_state: :quarantined, quarantine_reason: reason} = entry
       )
       when not is_nil(reason) do
    verify_retained_archive_binding(entry.quarantine_binding_id)
  end

  defp ensure_rearchive_eligible(%RecordingCatalogEntry{local_state: state}) do
    {:error, {:local_copy_not_present, state}}
  end

  defp verify_retained_archive_binding(nil), do: {:error, :archive_binding_not_retained}

  defp verify_retained_archive_binding(binding_id) do
    case Ash.get(ArchiveBinding, binding_id, actor: @system_actor, not_found_error?: false) do
      {:ok, %ArchiveBinding{id: id}} -> {:ok, id}
      {:ok, nil} -> {:error, :archive_binding_not_retained}
      {:error, _} = error -> error
    end
  end

  defp record_hold_access_audit(event_kind, %RecordingHold{} = hold, actor_id, details) do
    RecordingAccessAudit.record(%{
      event_kind: event_kind,
      actor_id: actor_id,
      camera_source_id: hold.camera_source_id,
      stream_profile_id: hold.stream_profile_id,
      recording_hold_id: hold.id,
      window_start_us: hold.start_us,
      window_end_us: hold.end_us,
      details: details
    })
  end

  defp start_operator_operation(
         kind,
         %RecordingCatalogEntry{} = entry,
         actor_id,
         now,
         summary,
         explicit_binding_id \\ nil
       ) do
    resolved_binding_id =
      case explicit_binding_id do
        nil -> entry.archive_binding_id || entry.quarantine_binding_id
        explicit -> explicit
      end

    op_params = %{
      kind: kind,
      actor_id: actor_id,
      camera_source_id: entry.camera_source_id,
      stream_profile_id: entry.stream_profile_id,
      recording_block_id: entry.recording_block_id,
      block_key: entry.block_key,
      storage_id: entry.storage_id,
      archive_binding_id: resolved_binding_id,
      result_summary: summary,
      started_at: now,
      deadline_at: DateTime.shift(now, second: @operator_deadline_seconds)
    }

    RecordingOperation
    |> Ash.Changeset.for_create(:start, op_params, actor: @system_actor)
    |> Ash.create(actor: @system_actor)
  end

  defp record_completed_operator_operation(kind, entry, actor_id, now, summary) do
    with {:ok, op} <- start_operator_operation(kind, entry, actor_id, now, summary) do
      op
      |> Ash.Changeset.for_update(
        :complete,
        %{
          state: :succeeded,
          result_summary: summary,
          finished_at: now
        },
        actor: @system_actor
      )
      |> Ash.update(actor: @system_actor)
    end
  end

  defp authorize_camera_source_scope(camera_source_id, stream_profile_id, actor, opts) do
    read_opts =
      case Keyword.get(opts, :scope) do
        nil -> [actor: actor, not_found_error?: false]
        scope -> [scope: scope, not_found_error?: false]
      end

    with {:ok, source} <- Source.get_by_id(camera_source_id, read_opts),
         :ok <- if(is_nil(source), do: {:error, :camera_source_not_found}, else: :ok) do
      verify_optional_profile(camera_source_id, stream_profile_id)
    end
  end

  defp verify_optional_profile(_camera_source_id, nil), do: :ok

  defp verify_optional_profile(camera_source_id, stream_profile_id) do
    StreamProfile
    |> Ash.Query.filter(id == ^stream_profile_id and camera_source_id == ^camera_source_id)
    |> Ash.exists(actor: @system_actor)
    |> case do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :stream_profile_not_found}
      {:error, _} = error -> error
    end
  end

  defp hold_write_opts(actor, opts) do
    base = [actor: actor]

    case Keyword.get(opts, :context) do
      ctx when is_map(ctx) -> Keyword.put(base, :context, ctx)
      _ -> base
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

  defp resolve_actor_id(%{role: :system} = actor, explicit) do
    cond do
      is_binary(explicit) and String.trim(explicit) != "" ->
        {:ok, String.trim(explicit)}

      is_binary(Map.get(actor, :id)) and String.trim(actor.id) != "" ->
        {:ok, String.trim(actor.id)}

      true ->
        {:ok, "system"}
    end
  end

  defp resolve_actor_id(actor, _explicit) when is_map(actor) do
    raw =
      Map.get(actor, :id) ||
        get_in(actor, [:user, :id]) ||
        Map.get(actor, :email)

    case raw do
      nil ->
        {:error, :unidentified_actor}

      val ->
        trimmed = String.trim(to_string(val))
        if trimmed == "", do: {:error, :unidentified_actor}, else: {:ok, trimmed}
    end
  end

  defp resolve_actor_id(_, _), do: {:error, :unidentified_actor}

  defp resolve_intent_actor_id(actor, explicit) do
    cond do
      is_binary(explicit) and String.trim(explicit) != "" ->
        {:ok, String.trim(explicit)}

      match?(%{role: :system}, actor) ->
        resolve_actor_id(actor, nil)

      true ->
        resolve_actor_id(actor, nil)
    end
  end

  defp cast_required_uuid(val, field) when is_binary(val) do
    case Ecto.UUID.cast(val) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_uuid, field}}
    end
  end

  defp cast_required_uuid(_val, field), do: {:error, {:invalid_uuid, field}}

  defp cast_optional_uuid(nil, _field), do: {:ok, nil}
  defp cast_optional_uuid("", _field), do: {:ok, nil}
  defp cast_optional_uuid(val, field), do: cast_required_uuid(val, field)

  defp resolve_operation_id(nil), do: {:ok, Ash.UUIDv7.generate()}
  defp resolve_operation_id(val), do: cast_required_uuid(val, :operation_id)

  defp parse_hold_window(params) do
    start_us = fetch_val(params, :start_us)
    end_us = fetch_val(params, :end_us)

    if is_integer(start_us) and is_integer(end_us) and end_us > start_us do
      {:ok, start_us, end_us}
    else
      {:error, :invalid_hold_window}
    end
  end

  defp parse_hold_kind(val) when val in [:investigation, "investigation"],
    do: {:ok, :investigation}

  defp parse_hold_kind(val) when val in [:export, "export"], do: {:ok, :export}
  defp parse_hold_kind(_), do: {:error, :invalid_hold_kind}

  defp normalize_hold_kind(val) when val in [:investigation, "investigation"], do: :investigation
  defp normalize_hold_kind(val) when val in [:export, "export"], do: :export
  defp normalize_hold_kind(_), do: nil

  defp parse_required_reason(val) when is_binary(val) do
    trimmed = String.trim(val)

    cond do
      trimmed == "" -> {:error, :invalid_hold_reason}
      byte_size(trimmed) > 1024 -> {:error, :invalid_hold_reason}
      true -> {:ok, trimmed}
    end
  end

  defp parse_required_reason(_), do: {:error, :invalid_hold_reason}

  defp parse_optional_reason(nil), do: {:ok, nil}

  defp parse_optional_reason(val) when is_binary(val) do
    trimmed = String.trim(val)

    cond do
      trimmed == "" -> {:ok, nil}
      byte_size(trimmed) > 1024 -> {:error, :invalid_release_reason}
      true -> {:ok, trimmed}
    end
  end

  defp parse_optional_reason(_), do: {:error, :invalid_release_reason}

  defp parse_disposition_reason(val) when is_atom(val) do
    if val in RecordingDisposition.reasons() do
      {:ok, val}
    else
      {:error, {:invalid_disposition_reason, val}}
    end
  end

  defp parse_disposition_reason(val) when is_binary(val) do
    case Enum.find(RecordingDisposition.reasons(), &(Atom.to_string(&1) == val)) do
      nil -> {:error, {:invalid_disposition_reason, val}}
      atom -> {:ok, atom}
    end
  end

  defp parse_disposition_reason(other), do: {:error, {:invalid_disposition_reason, other}}

  defp normalize_atom(val) when is_atom(val), do: val

  defp normalize_atom(val) when is_binary(val) do
    allowed =
      RecordingCatalogEntry.local_states() ++
        RecordingCatalogEntry.archive_states() ++
        RecordingHold.states()

    Enum.find(allowed, &(Atom.to_string(&1) == val))
  end

  defp normalize_atom(_), do: nil

  defp transact(resources, fun) do
    resources
    |> Ash.transact(fn ->
      case fun.() do
        {:error, %_{}} = ash_error ->
          ash_error

        {:error, reason} ->
          {:error,
           InvalidArgument.exception(
             field: :recording_hold,
             value: reason,
             message: "recording hold transaction refused"
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

      {:error, %InvalidArgument{field: :recording_hold, value: reason}} ->
        {:error, reason}

      {:error,
       %Ash.Error.Invalid{errors: [%InvalidArgument{field: :recording_hold, value: reason}]}} ->
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
