defmodule ServiceRadar.Camera.RecordingGap do
  @moduledoc """
  Append-only timeline gap record (`platform.camera_recording_gaps`) for intervals
  where an enabled continuous recording policy or bounded/reconciled capture did
  not produce sealed playable footage (`A7`, `B.2`, `B3`).

  Rows are append-only except closing an open gap (`end_us: nil -> end_us >= start_us`)
  once. No destroy action exists, and a PostgreSQL `BEFORE UPDATE` trigger prevents
  modifying any immutable field or re-closing an already closed gap.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query

  @detail_class_pattern ~r/\A[a-z0-9_:-]+\z/
  @time_bases [:received, :camera_reported]
  @reasons [
    :handover_overflow,
    :keyframe_wait,
    :source_unavailable,
    :epoch_change,
    :nvr_refused,
    :block_absent,
    :run_stopped,
    :incomplete_tail,
    :quarantined,
    :archive_capacity_exhausted
  ]

  @system_actor SystemActor.system(:camera_recording_gap)

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @footage_view_check {ActorHasPermission, permission: "devices.cameras.recordings.view"}

  postgres do
    table "camera_recording_gaps"
    schema "platform"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:camera_source_id, :stream_profile_id, :start_us],
        name: "camera_recording_gaps_timeline_index"

      index [:camera_source_id, :start_us],
        name: "camera_recording_gaps_open_index",
        where: "end_us IS NULL"
    end

    custom_statements do
      statement :enforce_gap_append_only_close_fn do
        up """
        CREATE OR REPLACE FUNCTION platform.camera_recording_gaps_enforce_append_only()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          IF OLD.end_us IS NOT NULL THEN
            RAISE EXCEPTION 'camera_recording_gaps row is already closed and cannot be updated'
              USING ERRCODE = 'check_violation',
                    CONSTRAINT = 'camera_recording_gaps_already_closed';
          END IF;

          IF NEW.end_us IS NULL OR
             NEW.camera_source_id IS DISTINCT FROM OLD.camera_source_id OR
             NEW.stream_profile_id IS DISTINCT FROM OLD.stream_profile_id OR
             NEW.policy_id IS DISTINCT FROM OLD.policy_id OR
             NEW.storage_id IS DISTINCT FROM OLD.storage_id OR
             NEW.run_id IS DISTINCT FROM OLD.run_id OR
             NEW.clock_epoch IS DISTINCT FROM OLD.clock_epoch OR
             NEW.start_us IS DISTINCT FROM OLD.start_us OR
             NEW.media_gap_ns IS DISTINCT FROM OLD.media_gap_ns OR
             NEW.time_basis IS DISTINCT FROM OLD.time_basis OR
             NEW.time_uncertainty_us IS DISTINCT FROM OLD.time_uncertainty_us OR
             NEW.reason IS DISTINCT FROM OLD.reason OR
             NEW.detail_class IS DISTINCT FROM OLD.detail_class OR
             NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
            RAISE EXCEPTION 'camera_recording_gaps allows only closing end_us from NULL'
              USING ERRCODE = 'check_violation',
                    CONSTRAINT = 'camera_recording_gaps_immutable_fields';
          END IF;

          RETURN NEW;
        END;
        $$;
        """

        down """
        DROP FUNCTION IF EXISTS platform.camera_recording_gaps_enforce_append_only();
        """
      end

      statement :enforce_gap_append_only_close_trg do
        after_tables ["camera_recording_gaps"]

        up """
        CREATE TRIGGER trg_camera_recording_gaps_enforce_append_only
        BEFORE UPDATE ON platform.camera_recording_gaps
        FOR EACH ROW
        EXECUTE FUNCTION platform.camera_recording_gaps_enforce_append_only();
        """

        down """
        DROP TRIGGER IF EXISTS trg_camera_recording_gaps_enforce_append_only
        ON platform.camera_recording_gaps;
        """
      end
    end

    check_constraints do
      check_constraint :end_us, "camera_recording_gaps_interval_valid",
        check: """
        (end_us IS NULL OR end_us >= start_us) AND
        (media_gap_ns IS NULL OR media_gap_ns >= 0) AND
        time_basis IN ('received', 'camera_reported') AND
        (time_basis <> 'received' OR time_uncertainty_us IS NULL) AND
        (time_uncertainty_us IS NULL OR time_uncertainty_us >= 0) AND
        reason IN ('handover_overflow', 'keyframe_wait', 'source_unavailable', 'epoch_change', 'nvr_refused', 'block_absent', 'run_stopped', 'incomplete_tail', 'quarantined', 'archive_capacity_exhausted') AND
        (detail_class IS NULL OR (octet_length(detail_class) BETWEEN 1 AND 64 AND detail_class ~ '^[a-z0-9_:-]+$'))
        """
    end
  end

  code_interface do
    define :record, action: :record
  end

  actions do
    defaults [:read]

    read :for_camera_window do
      argument :camera_source_id, :uuid, allow_nil?: false
      argument :stream_profile_id, :uuid, allow_nil?: true
      argument :from_us, :integer, allow_nil?: false
      argument :to_us, :integer, allow_nil?: false

      filter expr(
               camera_source_id == ^arg(:camera_source_id) and
                 (is_nil(^arg(:stream_profile_id)) or
                    stream_profile_id == ^arg(:stream_profile_id)) and
                 start_us < ^arg(:to_us) and
                 (is_nil(end_us) or end_us > ^arg(:from_us))
             )

      prepare build(sort: [start_us: :asc, id: :asc])
    end

    create :record do
      accept [
        :camera_source_id,
        :stream_profile_id,
        :policy_id,
        :storage_id,
        :run_id,
        :clock_epoch,
        :start_us,
        :end_us,
        :media_gap_ns,
        :time_basis,
        :time_uncertainty_us,
        :reason,
        :detail_class
      ]

      validate present([:camera_source_id, :start_us, :time_basis, :reason])
    end

    update :close do
      accept [:end_us]
      validate present(:end_us)
      validate changing(:end_us, from: nil)
      validate compare(:end_us, greater_than_or_equal_to: :start_us)
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

    attribute :camera_source_id, :uuid do
      allow_nil? false
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
      allow_nil? true
      public? true
    end

    attribute :run_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :clock_epoch, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :start_us, :integer do
      allow_nil? false
      public? true
    end

    attribute :end_us, :integer do
      allow_nil? true
      public? true
    end

    attribute :media_gap_ns, :integer do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :time_basis, :atom do
      allow_nil? false
      default :received
      public? true
      constraints one_of: @time_bases
    end

    attribute :time_uncertainty_us, :integer do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :reason, :atom do
      allow_nil? false
      public? true
      constraints one_of: @reasons
    end

    attribute :detail_class, :string do
      allow_nil? true
      public? true
      constraints min_length: 1, max_length: 64, match: @detail_class_pattern
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  @doc "Allowed `RecordingGap` reasons (`design.md` `A7`)."
  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  @doc """
  Atomically closes an open `RecordingGap` (`end_us: nil -> end_us >= start_us`).
  Refuses if the gap is already closed or if `end_us < start_us`.
  """
  @spec close(t(), integer(), keyword()) :: {:ok, t()} | {:error, term()}
  def close(%{__struct__: __MODULE__} = gap, end_us, opts \\ [])
      when is_integer(end_us) and is_list(opts) do
    actor_opts = Keyword.put_new(opts, :actor, @system_actor)

    gap
    |> Ash.Changeset.for_update(:close, %{end_us: end_us})
    |> Ash.Changeset.filter(expr(is_nil(end_us)))
    |> Ash.update(actor_opts)
    |> case do
      {:ok, %{__struct__: __MODULE__} = closed} ->
        {:ok, closed}

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{} | _]}} ->
        {:error, :gap_already_closed}

      {:error, _} = error ->
        error
    end
  end
end
