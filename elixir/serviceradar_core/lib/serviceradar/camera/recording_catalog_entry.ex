defmodule ServiceRadar.Camera.RecordingCatalogEntry do
  @moduledoc """
  Core catalog projection (`platform.camera_recording_catalog`) for NVR blocks (`B.1`–`B.3`).

  Each `(storage_id, block_key)` row is registered at most once:
  - **Sealed entry**: created only in the same transaction that freezes the
    `RecordingBlock` canonical descriptor (`RecordingBlocks.freeze_and_catalog/6`
    under `RecorderOwnership.with_current`, or the reconciler's historical freeze),
    recording media/timeline bounds, explicit `time_basis` (`received` with
    `time_uncertainty_us = nil` meaning unmeasured), and local/archive copy states.
  - **Quarantined entry** (`local_state = :quarantined`): created for an
    unrecoverable journal or a block with no Core authority (`recording_block_id = nil`),
    or transitioned in place when an unverified entry's recorded archive binding
    loses retained history or is ended as compromised. Quarantined entries are
    never playable.

  Terminal copy states (`local_state = :reclaimed` and `archive_state = :deleted`)
  are enforced by a PostgreSQL `BEFORE UPDATE` trigger and can never be revived.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query

  @hex64 ~r/\A[0-9a-f]{64}\z/
  @error_class_pattern ~r/\A[a-z0-9_:-]+\z/
  @system_actor SystemActor.system(:camera_recording_catalog)

  @local_states [:present, :quarantined, :reclaiming, :reclaimed, :missing]
  @archive_states [
    :not_required,
    :awaiting_binding,
    :pending,
    :failed_retryable,
    :failed_terminal,
    :verified,
    :deleting,
    :deleted,
    :missing
  ]
  @time_bases [:received, :camera_reported]
  @quarantine_reasons [
    :unrecoverable_journal,
    :unattributable,
    :binding_without_history,
    :binding_compromised
  ]
  @operator_disposition_states [
    :awaiting_operator,
    :export_requested,
    :delete_requested,
    :disposed
  ]
  @archive_deleted_reasons [:object_retention, :object_capacity, :operator]

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @footage_view_check {ActorHasPermission, permission: "devices.cameras.recordings.view"}

  @read_permissions [
    "settings.recording.view",
    "settings.recording.manage",
    "settings.recording.operate",
    "devices.cameras.recordings.view"
  ]

  postgres do
    table "camera_recording_catalog"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names storage_block: "camera_recording_catalog_storage_block_index"

    custom_indexes do
      index [:recording_block_id],
        name: "camera_recording_catalog_recording_block_index",
        unique: true,
        where: "recording_block_id IS NOT NULL"

      index [:camera_source_id, :stream_profile_id, :timeline_start_us],
        name: "camera_recording_catalog_timeline_index"

      index [:archive_state, :sealed_at],
        name: "camera_recording_catalog_archive_backlog_index",
        where: "archive_state IN ('awaiting_binding', 'pending', 'failed_retryable')"

      index [:storage_id, :sealed_at],
        name: "camera_recording_catalog_local_present_index",
        where: "local_state = 'present'"

      index [:archived_at],
        name: "camera_recording_catalog_archive_verified_index",
        where: "archive_state = 'verified'"

      index [:archive_binding_id],
        name: "camera_recording_catalog_archive_binding_index",
        where: "archive_binding_id IS NOT NULL"

      index [:quarantine_binding_id],
        name: "camera_recording_catalog_quarantine_binding_index",
        where: "quarantine_binding_id IS NOT NULL"

      index [:nvr_archive_receipt_id],
        name: "camera_recording_catalog_receipt_index",
        where: "nvr_archive_receipt_id IS NOT NULL"
    end

    custom_statements do
      statement :prevent_terminal_state_revival_fn do
        up """
        CREATE OR REPLACE FUNCTION platform.camera_recording_catalog_prevent_terminal_revival()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          IF OLD.local_state = 'reclaimed' AND NEW.local_state IS DISTINCT FROM 'reclaimed' THEN
            RAISE EXCEPTION 'camera_recording_catalog local_state cannot transition out of terminal state reclaimed'
              USING ERRCODE = 'check_violation',
                    CONSTRAINT = 'camera_recording_catalog_local_state_terminal';
          END IF;

          IF OLD.archive_state = 'deleted' AND NEW.archive_state IS DISTINCT FROM 'deleted' THEN
            RAISE EXCEPTION 'camera_recording_catalog archive_state cannot transition out of terminal state deleted'
              USING ERRCODE = 'check_violation',
                    CONSTRAINT = 'camera_recording_catalog_archive_state_terminal';
          END IF;

          RETURN NEW;
        END;
        $$;
        """

        down """
        DROP FUNCTION IF EXISTS platform.camera_recording_catalog_prevent_terminal_revival();
        """
      end

      statement :prevent_terminal_state_revival_trg do
        after_tables ["camera_recording_catalog"]

        up """
        CREATE TRIGGER trg_camera_recording_catalog_prevent_terminal_revival
        BEFORE UPDATE ON platform.camera_recording_catalog
        FOR EACH ROW
        EXECUTE FUNCTION platform.camera_recording_catalog_prevent_terminal_revival();
        """

        down """
        DROP TRIGGER IF EXISTS trg_camera_recording_catalog_prevent_terminal_revival
        ON platform.camera_recording_catalog;
        """
      end
    end

    references do
      reference :recording_block,
        on_delete: :restrict,
        name: "camera_recording_catalog_block_fkey"

      reference :archive_binding,
        on_delete: :restrict,
        name: "camera_recording_catalog_archive_binding_fkey"

      reference :quarantine_binding,
        on_delete: :restrict,
        name: "camera_recording_catalog_quarantine_binding_fkey"

      reference :nvr_archive_receipt,
        on_delete: :restrict,
        name: "camera_recording_catalog_receipt_fkey"
    end

    check_constraints do
      check_constraint :block_key, "camera_recording_catalog_states_and_digests",
        check: """
        block_key ~ '^[0-9a-f]{64}$' AND
        local_state IN ('present', 'quarantined', 'reclaiming', 'reclaimed', 'missing') AND
        archive_state IN ('not_required', 'awaiting_binding', 'pending', 'failed_retryable', 'failed_terminal', 'verified', 'deleting', 'deleted', 'missing') AND
        archive_attempts >= 0 AND
        (archive_last_error_class IS NULL OR (octet_length(archive_last_error_class) BETWEEN 1 AND 64 AND archive_last_error_class ~ '^[a-z0-9_:-]+$')) AND
        ((archive_state = 'deleted' AND archive_deleted_reason IN ('object_retention', 'object_capacity', 'operator')) OR
         (archive_state <> 'deleted' AND archive_deleted_reason IS NULL))
        """

      check_constraint :recording_block_id, "camera_recording_catalog_sealed_or_quarantined",
        check: """
        (local_state <> 'present' OR (recording_block_id IS NOT NULL AND quarantine_reason IS NULL)) AND
        (recording_block_id IS NOT NULL OR quarantine_reason IS NOT NULL) AND
        (recording_block_id IS NULL OR (
          camera_source_id IS NOT NULL AND
          stream_profile_id IS NOT NULL AND
          media_start_ns IS NOT NULL AND media_start_ns >= 0 AND
          media_end_ns IS NOT NULL AND media_end_ns > media_start_ns AND
          timeline_start_us IS NOT NULL AND
          timeline_end_us IS NOT NULL AND timeline_end_us >= timeline_start_us AND
          time_basis IN ('received', 'camera_reported') AND
          fragment_count IS NOT NULL AND fragment_count >= 1 AND
          media_bytes IS NOT NULL AND media_bytes >= 1 AND
          init_sha256 ~ '^[0-9a-f]{64}$' AND
          descriptor_sha256 ~ '^[0-9a-f]{64}$' AND
          sealed_at IS NOT NULL
        )) AND
        (local_state <> 'quarantined' OR quarantine_reason IS NOT NULL) AND
        ((quarantine_reason IS NULL AND quarantine_receipt IS NULL AND quarantined_bytes IS NULL AND quarantine_evidence IS NULL AND operator_disposition_state IS NULL AND operator_decision IS NULL) OR
         (quarantine_reason IN ('unrecoverable_journal', 'unattributable', 'binding_without_history', 'binding_compromised') AND
          quarantine_receipt IS NOT NULL AND
          quarantined_bytes IS NOT NULL AND quarantined_bytes >= 0 AND
          (operator_disposition_state IS NULL OR operator_disposition_state IN ('awaiting_operator', 'export_requested', 'delete_requested', 'disposed'))))
        """

      check_constraint :time_basis, "camera_recording_catalog_time_basis_valid",
        check: """
        (time_basis IS NULL OR time_basis IN ('received', 'camera_reported')) AND
        (time_basis <> 'received' OR time_uncertainty_us IS NULL) AND
        (time_uncertainty_us IS NULL OR time_uncertainty_us >= 0) AND
        ((timeline_start_us IS NULL AND timeline_end_us IS NULL) OR
         (timeline_start_us IS NOT NULL AND timeline_end_us IS NOT NULL AND timeline_end_us >= timeline_start_us))
        """
    end
  end

  actions do
    defaults [:read]

    read :for_camera_page do
      argument :camera_source_id, :uuid, allow_nil?: false
      argument :stream_profile_id, :uuid, allow_nil?: true

      pagination keyset?: true, default_limit: 25, max_page_size: 100, required?: true

      filter expr(
               camera_source_id == ^arg(:camera_source_id) and
                 (is_nil(^arg(:stream_profile_id)) or
                    stream_profile_id == ^arg(:stream_profile_id))
             )

      prepare build(sort: [timeline_start_us: :desc, id: :desc])
    end

    create :register_sealed do
      accept [
        :recording_block_id,
        :camera_source_id,
        :stream_profile_id,
        :policy_id,
        :storage_id,
        :block_key,
        :clock_epoch,
        :run_id,
        :media_start_ns,
        :media_end_ns,
        :first_unit_pts,
        :first_unit_received_at,
        :timeline_start_us,
        :timeline_end_us,
        :time_basis,
        :time_uncertainty_us,
        :anchor_id,
        :reanchored,
        :contiguous_with_previous,
        :fragment_count,
        :media_bytes,
        :init_sha256,
        :descriptor_sha256,
        :local_state_at,
        :archive_state,
        :archive_state_at,
        :archive_binding_id,
        :sealed_at
      ]

      change set_attribute(:local_state, :present)

      validate present([
                 :recording_block_id,
                 :camera_source_id,
                 :stream_profile_id,
                 :storage_id,
                 :block_key,
                 :media_start_ns,
                 :media_end_ns,
                 :timeline_start_us,
                 :timeline_end_us,
                 :time_basis,
                 :fragment_count,
                 :media_bytes,
                 :init_sha256,
                 :descriptor_sha256,
                 :local_state_at,
                 :archive_state,
                 :archive_state_at,
                 :sealed_at
               ])
    end

    create :register_quarantined do
      accept [
        :camera_source_id,
        :stream_profile_id,
        :policy_id,
        :storage_id,
        :block_key,
        :clock_epoch,
        :run_id,
        :media_start_ns,
        :media_end_ns,
        :first_unit_pts,
        :first_unit_received_at,
        :timeline_start_us,
        :timeline_end_us,
        :time_basis,
        :time_uncertainty_us,
        :anchor_id,
        :reanchored,
        :quarantine_reason,
        :quarantine_receipt,
        :quarantined_bytes,
        :quarantine_evidence,
        :operator_disposition_state,
        :operator_decision,
        :local_state_at,
        :archive_state,
        :archive_state_at,
        :quarantine_binding_id
      ]

      upsert? true
      upsert_identity :storage_block
      upsert_fields []

      change set_attribute(:local_state, :quarantined)
      change set_attribute(:recording_block_id, nil)

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, &verify_quarantined_idempotent/2)
      end

      validate present([
                 :storage_id,
                 :block_key,
                 :quarantine_reason,
                 :quarantine_receipt,
                 :quarantined_bytes,
                 :local_state_at,
                 :archive_state,
                 :archive_state_at
               ])
    end

    update :quarantine_in_place do
      accept [
        :quarantine_reason,
        :quarantine_receipt,
        :quarantined_bytes,
        :quarantine_evidence,
        :operator_disposition_state,
        :local_state_at,
        :archive_state,
        :archive_state_at,
        :quarantine_binding_id
      ]

      change set_attribute(:local_state, :quarantined)

      validate present([
                 :quarantine_reason,
                 :quarantine_receipt,
                 :quarantined_bytes,
                 :local_state_at,
                 :archive_state,
                 :archive_state_at
               ])
    end

    update :record_operator_decision do
      accept [
        :local_state,
        :local_state_at,
        :operator_disposition_state,
        :operator_decision
      ]

      validate present([:operator_disposition_state, :operator_decision])
    end

    update :transition_local_state do
      accept [:local_state, :local_state_at, :operator_disposition_state]
      validate present([:local_state, :local_state_at])
    end

    update :mark_local_missing do
      accept [:local_state_at]
      change set_attribute(:local_state, :missing)
      validate changing(:local_state, from: :present, to: :missing)
      validate present([:local_state_at])
    end

    update :transition_archive_state do
      accept [
        :archive_state,
        :archive_state_at,
        :archive_deleted_reason,
        :archive_binding_id,
        :quarantine_binding_id,
        :nvr_archive_receipt_id,
        :archive_attempts,
        :archive_last_error_class,
        :archived_at
      ]

      validate present([:archive_state, :archive_state_at])
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
      authorize_if @operate_check
      authorize_if @footage_view_check
    end

    policy action_type([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :recording_block_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :camera_source_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :stream_profile_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :policy_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :storage_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :block_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64, match: @hex64
    end

    attribute :clock_epoch, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :run_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :media_start_ns, :integer do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :media_end_ns, :integer do
      allow_nil? true
      public? true
      constraints min: 1
    end

    attribute :first_unit_pts, :integer do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :first_unit_received_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :timeline_start_us, :integer do
      allow_nil? true
      public? true
    end

    attribute :timeline_end_us, :integer do
      allow_nil? true
      public? true
    end

    attribute :time_basis, :atom do
      allow_nil? true
      public? true
      constraints one_of: @time_bases
    end

    attribute :time_uncertainty_us, :integer do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :anchor_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :reanchored, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :contiguous_with_previous, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :fragment_count, :integer do
      allow_nil? true
      public? true
      constraints min: 1
    end

    attribute :media_bytes, :integer do
      allow_nil? true
      public? true
      constraints min: 1
    end

    attribute :init_sha256, :string do
      allow_nil? true
      public? true
      constraints min_length: 64, max_length: 64, match: @hex64
    end

    attribute :descriptor_sha256, :string do
      allow_nil? true
      public? true
      constraints min_length: 64, max_length: 64, match: @hex64
    end

    attribute :local_state, :atom do
      allow_nil? false
      public? true
      constraints one_of: @local_states
    end

    attribute :local_state_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :quarantine_reason, :atom do
      allow_nil? true
      public? true
      constraints one_of: @quarantine_reasons
    end

    attribute :quarantine_receipt, :map do
      allow_nil? true
      public? true
    end

    attribute :quarantined_bytes, :integer do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :quarantine_evidence, :map do
      allow_nil? true
      public? true
    end

    attribute :operator_disposition_state, :atom do
      allow_nil? true
      public? true
      constraints one_of: @operator_disposition_states
    end

    attribute :operator_decision, :map do
      allow_nil? true
      public? true
    end

    attribute :archive_state, :atom do
      allow_nil? false
      public? true
      constraints one_of: @archive_states
    end

    attribute :archive_state_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :archive_deleted_reason, :atom do
      allow_nil? true
      public? true
      constraints one_of: @archive_deleted_reasons
    end

    attribute :archive_binding_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :quarantine_binding_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :nvr_archive_receipt_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :archive_attempts, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :archive_last_error_class, :string do
      allow_nil? true
      public? true
      constraints min_length: 1, max_length: 64, match: @error_class_pattern
    end

    attribute :sealed_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :archived_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :recording_block, RecordingBlock do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :recording_block_id
    end

    belongs_to :archive_binding, ArchiveBinding do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :archive_binding_id
    end

    belongs_to :quarantine_binding, ArchiveBinding do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :quarantine_binding_id
    end

    belongs_to :nvr_archive_receipt, NVRArchiveReceipt do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :nvr_archive_receipt_id
    end
  end

  identities do
    identity :storage_block, [:storage_id, :block_key]
  end

  @doc "Allowed `local_state` values (`B3`)."
  @spec local_states() :: [atom()]
  def local_states, do: @local_states

  @doc "Allowed `archive_state` values (`A6`, `B3`)."
  @spec archive_states() :: [atom()]
  def archive_states, do: @archive_states

  @doc "Allowed `quarantine_reason` classes (`B3`, `R2`)."
  @spec quarantine_reasons() :: [atom()]
  def quarantine_reasons, do: @quarantine_reasons

  @doc "Allowed `operator_disposition_state` values for quarantined/unattributable blocks (`R.3`, `R.10`)."
  @spec operator_disposition_states() :: [atom()]
  def operator_disposition_states, do: @operator_disposition_states

  @doc """
  Returns `true` when `entry` is a frozen, non-quarantined block with at least
  one playable copy (`local_state == :present` or `archive_state == :verified`).
  Quarantined entries are never playable (`B2`, `R2`).
  """
  @spec playable?(map()) :: boolean()
  def playable?(entry), do: availability(entry) == :playable

  @doc "Classifies the catalog copies for visual indexing and worker read grants."
  def availability(entry) when is_map(entry) do
    local = fetch_val(entry, :local_state)
    archive = fetch_val(entry, :archive_state)

    cond do
      is_nil(fetch_val(entry, :recording_block_id)) ->
        :recording_gone

      not is_nil(fetch_val(entry, :quarantine_reason)) ->
        :recording_gone

      local in [:quarantined, "quarantined"] ->
        :recording_gone

      local in [:reclaimed, "reclaimed"] and
          archive in [:deleted, :not_required, "deleted", "not_required"] ->
        :recording_gone

      local in [:present, "present"] or archive in [:verified, "verified"] ->
        :playable

      true ->
        :recording_unavailable
    end
  end

  def availability(_), do: :recording_gone

  @doc """
  Registers a never-frozen quarantined catalog entry (`recording_block_id = nil`)
  for an unattributable block or unrecoverable journal after the NVR confirms the
  move into `.quarantine/<block_key>/` (`B.1`, `B2`, `R2`).

  Applies Transition 1 of the archive state machine (`A6` predicate (b), `PD9`,
  `PD10`) when `:archive_state` is not explicitly supplied.
  """
  @spec register_quarantined(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def register_quarantined(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    {now, ash_opts} = Keyword.pop(opts, :now, DateTime.utc_now())

    {default_archive_state, default_q_binding_id} =
      resolve_quarantine_archive_transition(attrs)

    params = %{
      camera_source_id: fetch_val(attrs, :camera_source_id),
      stream_profile_id: fetch_val(attrs, :stream_profile_id),
      policy_id: fetch_val(attrs, :policy_id),
      storage_id: fetch_val(attrs, :storage_id),
      block_key: fetch_val(attrs, :block_key),
      clock_epoch: fetch_val(attrs, :clock_epoch),
      run_id: fetch_val(attrs, :run_id),
      media_start_ns: fetch_val(attrs, :media_start_ns),
      media_end_ns: fetch_val(attrs, :media_end_ns),
      first_unit_pts: fetch_val(attrs, :first_unit_pts),
      first_unit_received_at: fetch_val(attrs, :first_unit_received_at),
      timeline_start_us: fetch_val(attrs, :timeline_start_us),
      timeline_end_us: fetch_val(attrs, :timeline_end_us),
      time_basis: fetch_val(attrs, :time_basis),
      time_uncertainty_us: fetch_val(attrs, :time_uncertainty_us),
      anchor_id: fetch_val(attrs, :anchor_id),
      reanchored: fetch_val(attrs, :reanchored) == true,
      quarantine_reason: fetch_val(attrs, :quarantine_reason),
      quarantine_receipt: fetch_val(attrs, :quarantine_receipt),
      quarantined_bytes: fetch_val(attrs, :quarantined_bytes),
      quarantine_evidence: fetch_val(attrs, :quarantine_evidence),
      operator_disposition_state:
        fetch_val(attrs, :operator_disposition_state) || :awaiting_operator,
      operator_decision: fetch_val(attrs, :operator_decision),
      local_state_at: fetch_val(attrs, :local_state_at) || now,
      archive_state: fetch_val(attrs, :archive_state) || default_archive_state,
      archive_state_at: fetch_val(attrs, :archive_state_at) || now,
      quarantine_binding_id:
        case fetch_val(attrs, :quarantine_binding_id) do
          nil -> default_q_binding_id
          explicit -> explicit
        end
    }

    __MODULE__
    |> Ash.Changeset.for_create(:register_quarantined, params)
    |> Ash.create(ash_opts)
  end

  @doc """
  Quarantines an existing unverified sealed `RecordingCatalogEntry` in place (`R4` step 1,
  `B2`, `A6` Transition 3) when its recorded `archive_binding_id` is absent from retained
  history (`:binding_without_history`) or ended as compromised (`:binding_compromised`),
  preserving `recording_block_id`, the frozen descriptor fields, and `archive_binding_id`.
  """
  @spec quarantine_in_place(t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def quarantine_in_place(%{__struct__: __MODULE__} = entry, attrs, opts \\ [])
      when is_map(attrs) and is_list(opts) do
    cond do
      entry.archive_state == :verified ->
        {:error, :entry_already_verified}

      entry.local_state == :reclaimed ->
        {:error, :local_copy_already_reclaimed}

      true ->
        {now, ash_opts} = Keyword.pop(opts, :now, DateTime.utc_now())

        {default_archive_state, default_q_binding_id} =
          resolve_quarantine_archive_transition(attrs)

        params = %{
          quarantine_reason: fetch_val(attrs, :quarantine_reason),
          quarantine_receipt: fetch_val(attrs, :quarantine_receipt),
          quarantined_bytes: fetch_val(attrs, :quarantined_bytes) || entry.media_bytes || 0,
          quarantine_evidence: fetch_val(attrs, :quarantine_evidence),
          operator_disposition_state:
            fetch_val(attrs, :operator_disposition_state) || :awaiting_operator,
          local_state_at: fetch_val(attrs, :local_state_at) || now,
          archive_state: fetch_val(attrs, :archive_state) || default_archive_state,
          archive_state_at: fetch_val(attrs, :archive_state_at) || now,
          quarantine_binding_id:
            case fetch_val(attrs, :quarantine_binding_id) do
              nil -> default_q_binding_id
              explicit -> explicit
            end
        }

        entry
        |> Ash.Changeset.for_update(:quarantine_in_place, params)
        |> Ash.Changeset.filter(expr(archive_state != :verified and local_state != :reclaimed))
        |> Ash.update(ash_opts)
    end
  end

  @doc """
  Loads `RecordingCatalogEntry` rows matching a page of `RecordingBlock` structs
  or maps (keyed by `{to_string(storage_id), to_string(block_key)}`), after
  authorizing `settings.recording.view | manage | operate` or
  `devices.cameras.recordings.view`.
  """
  @spec for_blocks([map()], keyword()) ::
          {:ok, %{{String.t(), String.t()} => t()}} | {:error, term()}
  def for_blocks(blocks, opts \\ []) when is_list(blocks) and is_list(opts) do
    with :ok <- authorize_catalog_read(opts) do
      if blocks == [] do
        {:ok, %{}}
      else
        load_entries_for_blocks(blocks, opts)
      end
    end
  end

  @doc """
  Authorizes catalog read access for `settings.recording.view | manage | operate`
  or `devices.cameras.recordings.view` (supporting `:actor` or `:scope`).
  """
  @spec authorize_catalog_read(keyword()) :: :ok | {:error, Forbidden.t()}
  def authorize_catalog_read(opts) when is_list(opts) do
    actor = resolve_actor(opts)

    permitted? =
      match?(%{role: :system}, actor) or
        Enum.any?(@read_permissions, fn perm ->
          ActorHasPermission.match?(actor, [permission: perm], %{})
        end)

    if permitted? do
      :ok
    else
      {:error, Forbidden.exception([])}
    end
  end

  defp load_entries_for_blocks(blocks, opts) do
    case opts |> Keyword.get(:loaders, %{}) |> Map.get(:catalog_for_blocks_loader) do
      loader when is_function(loader, 1) ->
        loader.(blocks)

      _ ->
        block_keys =
          for b <- blocks,
              key = Map.get(b, :block_key) || Map.get(b, "block_key"),
              is_binary(key) and key != "",
              uniq: true,
              do: key

        storage_pairs =
          for b <- blocks,
              sid = Map.get(b, :storage_id) || Map.get(b, "storage_id"),
              key = Map.get(b, :block_key) || Map.get(b, "block_key"),
              not is_nil(sid) and is_binary(key),
              into: MapSet.new(),
              do: {to_string(sid), key}

        if block_keys == [] do
          {:ok, %{}}
        else
          __MODULE__
          |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
          |> Ash.Query.filter(block_key in ^block_keys)
          |> Ash.read(actor: @system_actor)
          |> case do
            {:ok, entries} ->
              filtered =
                for entry <- entries,
                    pair = {to_string(entry.storage_id), entry.block_key},
                    MapSet.member?(storage_pairs, pair),
                    into: %{},
                    do: {pair, entry}

              {:ok, filtered}

            {:error, _} = error ->
              error
          end
        end
    end
  end

  defp resolve_quarantine_archive_transition(attrs) do
    policy_storage = fetch_val(attrs, :policy_storage) || fetch_val(attrs, :storage)

    if policy_storage in [:local_only, "local_only"] do
      {:not_required, nil}
    else
      case ServiceRadar.Camera.RecordingArchiveSettings.get_settings(actor: @system_actor) do
        {:ok, %{archive_enabled: true, active_archive_binding_id: nil}} ->
          {:awaiting_binding, nil}

        {:ok, %{archive_enabled: true, active_archive_binding_id: binding_id}} ->
          {:pending, binding_id}

        _ ->
          {:not_required, nil}
      end
    end
  end

  defp verify_quarantined_idempotent(submitted, retained) do
    submitted_evidence = Ash.Changeset.get_attribute(submitted, :quarantine_evidence)

    same? =
      retained.local_state in [:quarantined, :reclaiming, :reclaimed] and
        is_nil(retained.recording_block_id) and
        retained.quarantine_reason == Ash.Changeset.get_attribute(submitted, :quarantine_reason) and
        retained.quarantine_receipt == Ash.Changeset.get_attribute(submitted, :quarantine_receipt) and
        retained.quarantined_bytes == Ash.Changeset.get_attribute(submitted, :quarantined_bytes) and
        (is_nil(submitted_evidence) or retained.quarantine_evidence == submitted_evidence)

    if same? do
      {:ok, retained}
    else
      {:error,
       InvalidArgument.exception(
         field: :block_key,
         message: "recording catalog entry conflicts with existing record"
       )}
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

  defp fetch_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
