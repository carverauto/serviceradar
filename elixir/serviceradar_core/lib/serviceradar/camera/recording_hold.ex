defmodule ServiceRadar.Camera.RecordingHold do
  @moduledoc """
  Audited evidence and export hold resource (`platform.camera_recording_holds`)
  protecting recorded camera footage across `[start_us, end_us)` (`C.2`, `C4`, `PD5`).

  Holds are audited via `AshPaperTrail` (`platform.camera_recording_holds_versions`)
  and surfaced in `ServiceRadar.Security.AuditHistory`. Acceptance is serialized
  against copy deletion intents on covered `RecordingCatalogEntry` rows through
  `ServiceRadar.Camera.RecordingHolds.place_hold/2`:
  - When a covered entry has `archive_state == :verified`, the hold pins the
    `:archive` copy and the `:local` copy remains evictable (`PD5`).
  - Otherwise (local-only, unarchived, archive already deleted, or archive
    `:missing` while `local_state == :present`), the hold pins the `:local` copy.
  - Covered blocks whose copies already had a committed deletion intent with no
    surviving pinnable copy are recorded in `unavailable_blocks` as
    `"unavailable, deletion in progress"` and are never silently claimed.

  Release is explicit and audited (`RecordingHolds.release_hold/3`); expiry,
  disconnection, policy changes, and storage pressure never release a hold.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Changeset.OriginalDataNotAvailable
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @kinds [:investigation, :export]
  @states [:pending, :accepted, :released]

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @footage_view_check {ActorHasPermission, permission: "devices.cameras.recordings.view"}
  @hold_check {ActorHasPermission, permission: "devices.cameras.recordings.hold"}
  @audit_view_check {ActorHasPermission, permission: "settings.audit.view"}

  defmodule ValidateHold do
    @moduledoc false
    use Ash.Resource.Validation

    alias Ash.Error.Changes.InvalidAttribute

    @max_reason_bytes 1024
    @max_actor_bytes 128

    @impl true
    def validate(changeset, opts, _context) do
      mode = Keyword.get(opts, :mode, :accept)
      validate_mode(changeset, mode)
    end

    @impl true
    def atomic(changeset, opts, context) do
      if match?(%OriginalDataNotAvailable{}, changeset.data) and
           Keyword.get(opts, :mode) == :release do
        {:not_atomic, "releasing a hold validates existing state and accepted_at"}
      else
        validate(changeset, opts, context)
      end
    end

    defp validate_mode(changeset, mode) when mode in [:pending, :accept] do
      start_us = proposed_value(changeset, :start_us)
      end_us = proposed_value(changeset, :end_us)
      reason = proposed_value(changeset, :reason)
      created_by_id = proposed_value(changeset, :created_by_id)
      accepted_at = proposed_value(changeset, :accepted_at)
      unavailable = proposed_value(changeset, :unavailable_blocks)

      with :ok <- validate_window(start_us, end_us),
           :ok <- validate_bounded_text(:reason, reason, @max_reason_bytes, true),
           :ok <- validate_bounded_text(:created_by_id, created_by_id, @max_actor_bytes, true),
           :ok <- validate_unavailable_blocks(unavailable) do
        if mode == :accept and not match?(%DateTime{}, accepted_at) do
          {:error,
           InvalidAttribute.exception(
             field: :accepted_at,
             message: "accepted_at is required when state is accepted"
           )}
        else
          :ok
        end
      end
    end

    defp validate_mode(changeset, :release) do
      existing_state = existing_value(changeset, :state)
      accepted_at = existing_value(changeset, :accepted_at)
      released_by_id = proposed_value(changeset, :released_by_id)
      released_at = proposed_value(changeset, :released_at)
      release_reason = proposed_value(changeset, :release_reason)

      cond do
        existing_state != :accepted ->
          {:error,
           InvalidAttribute.exception(
             field: :state,
             message: "only an accepted hold can be released"
           )}

        not match?(%DateTime{}, released_at) ->
          {:error,
           InvalidAttribute.exception(
             field: :released_at,
             message: "released_at is required when releasing a hold"
           )}

        match?(%DateTime{}, accepted_at) and DateTime.before?(released_at, accepted_at) ->
          {:error,
           InvalidAttribute.exception(
             field: :released_at,
             message: "released_at must be at or after accepted_at"
           )}

        true ->
          with :ok <-
                 validate_bounded_text(:released_by_id, released_by_id, @max_actor_bytes, true) do
            validate_bounded_text(:release_reason, release_reason, @max_reason_bytes, false)
          end
      end
    end

    defp validate_window(start_us, end_us)
         when is_integer(start_us) and is_integer(end_us) and end_us > start_us do
      :ok
    end

    defp validate_window(_start_us, _end_us) do
      {:error,
       InvalidAttribute.exception(
         field: :end_us,
         message: "end_us must be strictly greater than start_us"
       )}
    end

    defp validate_bounded_text(_field, nil, _max_bytes, false), do: :ok

    defp validate_bounded_text(field, nil, _max_bytes, true) do
      {:error, InvalidAttribute.exception(field: field, message: "is required")}
    end

    defp validate_bounded_text(field, value, max_bytes, _required?) when is_binary(value) do
      cond do
        String.trim(value) == "" ->
          {:error, InvalidAttribute.exception(field: field, message: "must not be blank")}

        byte_size(value) > max_bytes ->
          {:error,
           InvalidAttribute.exception(
             field: field,
             message: "must be at most #{max_bytes} bytes"
           )}

        true ->
          :ok
      end
    end

    defp validate_bounded_text(field, _value, _max_bytes, _required?) do
      {:error, InvalidAttribute.exception(field: field, message: "must be a string")}
    end

    defp validate_unavailable_blocks(blocks) when is_list(blocks) do
      if Enum.all?(blocks, &is_map/1) do
        :ok
      else
        {:error,
         InvalidAttribute.exception(
           field: :unavailable_blocks,
           message: "unavailable_blocks entries must be maps"
         )}
      end
    end

    defp validate_unavailable_blocks(_) do
      {:error,
       InvalidAttribute.exception(
         field: :unavailable_blocks,
         message: "unavailable_blocks must be a list of maps"
       )}
    end

    defp existing_value(changeset, field) do
      if is_map(changeset.data) and not match?(%OriginalDataNotAvailable{}, changeset.data) do
        Map.get(changeset.data, field)
      end
    end

    defp proposed_value(changeset, field) do
      case Keyword.fetch(changeset.atomics, field) do
        {:ok, value} ->
          value

        :error ->
          case Ash.Changeset.fetch_change(changeset, field) do
            {:ok, value} -> value
            :error -> fallback_value(changeset, field)
          end
      end
    end

    defp fallback_value(changeset, field) do
      cond do
        Map.has_key?(changeset.attributes, field) ->
          Map.get(changeset.attributes, field)

        match?(%OriginalDataNotAvailable{}, changeset.data) ->
          nil

        is_map(changeset.data) ->
          Map.get(changeset.data, field)

        true ->
          nil
      end
    end
  end

  postgres do
    table "camera_recording_holds"
    schema "platform"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:camera_source_id, :start_us, :end_us],
        name: "camera_recording_holds_active_range_index",
        where: "state = 'accepted'"

      index [:camera_source_id, :stream_profile_id, :start_us, :end_us],
        name: "camera_recording_holds_profile_range_index",
        where: "state = 'accepted' AND stream_profile_id IS NOT NULL"

      index [:state, :inserted_at],
        name: "camera_recording_holds_state_index"
    end

    references do
      reference :camera_source,
        on_delete: :restrict,
        name: "camera_recording_holds_camera_source_fkey"

      reference :stream_profile,
        on_delete: :restrict,
        name: "camera_recording_holds_stream_profile_fkey"
    end

    check_constraints do
      check_constraint :end_us, "camera_recording_holds_bounds_and_kind",
        check: """
        end_us > start_us AND
        kind IN ('investigation', 'export') AND
        btrim(reason) <> '' AND octet_length(reason) <= 1024 AND
        btrim(created_by_id) <> '' AND octet_length(created_by_id) <= 128
        """

      check_constraint :state, "camera_recording_holds_state_lifecycle",
        check: """
        (state = 'pending' AND accepted_at IS NULL AND released_by_id IS NULL AND released_at IS NULL AND release_reason IS NULL) OR
        (state = 'accepted' AND accepted_at IS NOT NULL AND released_by_id IS NULL AND released_at IS NULL AND release_reason IS NULL) OR
        (state = 'released' AND accepted_at IS NOT NULL AND released_by_id IS NOT NULL AND btrim(released_by_id) <> '' AND octet_length(released_by_id) <= 128 AND released_at IS NOT NULL AND released_at >= accepted_at AND (release_reason IS NULL OR (btrim(release_reason) <> '' AND octet_length(release_reason) <= 1024)))
        """
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "camera_recording_holds_versions"
    reference_source? false
    mixin {ServiceRadar.Security.PaperTrailMixin, :mixin_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :active_for_camera do
      argument :camera_source_id, :uuid, allow_nil?: false
      argument :stream_profile_id, :uuid, allow_nil?: true
      argument :from_us, :integer, allow_nil?: true
      argument :to_us, :integer, allow_nil?: true

      filter expr(
               state == :accepted and
                 camera_source_id == ^arg(:camera_source_id) and
                 (is_nil(^arg(:stream_profile_id)) or is_nil(stream_profile_id) or
                    stream_profile_id == ^arg(:stream_profile_id)) and
                 (is_nil(^arg(:to_us)) or start_us < ^arg(:to_us)) and
                 (is_nil(^arg(:from_us)) or end_us > ^arg(:from_us))
             )

      prepare build(sort: [start_us: :asc, id: :asc])
    end

    read :for_camera do
      argument :camera_source_id, :uuid, allow_nil?: false

      filter expr(camera_source_id == ^arg(:camera_source_id))
      prepare build(sort: [inserted_at: :desc, id: :desc])
    end

    create :create_pending do
      accept [
        :camera_source_id,
        :stream_profile_id,
        :start_us,
        :end_us,
        :kind,
        :reason,
        :created_by_id
      ]

      change set_attribute(:state, :pending)
      change set_attribute(:accepted_at, nil)
      change set_attribute(:unavailable_blocks, [])

      validate present([:camera_source_id, :start_us, :end_us, :kind, :reason, :created_by_id])
      validate {ValidateHold, mode: :pending}
    end

    create :accept do
      primary? true

      accept [
        :camera_source_id,
        :stream_profile_id,
        :start_us,
        :end_us,
        :kind,
        :reason,
        :created_by_id,
        :accepted_at,
        :unavailable_blocks
      ]

      change set_attribute(:state, :accepted)

      validate present([
                 :camera_source_id,
                 :start_us,
                 :end_us,
                 :kind,
                 :reason,
                 :created_by_id,
                 :accepted_at
               ])

      validate {ValidateHold, mode: :accept}
    end

    update :release do
      primary? true
      accept [:released_by_id, :released_at, :release_reason]
      atomic_upgrade_with :read

      change set_attribute(:state, :released)
      validate present([:released_by_id, :released_at])
      validate {ValidateHold, mode: :release}
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
      authorize_if @hold_check
      authorize_if @audit_view_check
    end

    action_type_with_permission([:create, :update], @hold_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :camera_source_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :stream_profile_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :start_us, :integer do
      allow_nil? false
      public? true
    end

    attribute :end_us, :integer do
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 1024, trim?: true
    end

    attribute :created_by_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128, trim?: true
    end

    attribute :state, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: @states
    end

    attribute :accepted_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :released_by_id, :string do
      allow_nil? true
      public? true
      constraints min_length: 1, max_length: 128, trim?: true
    end

    attribute :released_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :release_reason, :string do
      allow_nil? true
      public? true
      constraints min_length: 1, max_length: 1024, trim?: true
    end

    attribute :unavailable_blocks, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :camera_source, Source do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :camera_source_id
    end

    belongs_to :stream_profile, StreamProfile do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :stream_profile_id
    end
  end

  @doc "Allowed `RecordingHold` kinds (`:investigation | :export`)."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Allowed `RecordingHold` lifecycle states (`:pending | :accepted | :released`)."
  @spec states() :: [atom()]
  def states, do: @states
end
