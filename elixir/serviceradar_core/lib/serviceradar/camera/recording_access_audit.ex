defmodule ServiceRadar.Camera.RecordingAccessAudit do
  @moduledoc """
  Append-only audit record (`platform.camera_recording_access_audits`) for
  authorized camera recording timeline playback windows and hold operations
  (`D.4`, `design.md` `D7`, `spec.md:667-677`).

  One row is appended for each issued HLS playlist window (`:playlist_window`)
  and for each hold acceptance (`:hold_placed`) or explicit hold release
  (`:hold_released`). Individual fragment fetches are covered by their window
  audit row. There are no update or destroy actions, and a PostgreSQL
  `BEFORE UPDATE OR DELETE` trigger (`camera_recording_access_audits_append_only_trigger`)
  unconditionally refuses row mutation or deletion.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Changeset.OriginalDataNotAvailable
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query

  @event_kinds [:playlist_window, :hold_placed, :hold_released, :semantic_search]
  @source_modes [:auto, :local, :archive]
  @time_bases [:received, :camera_reported]

  @system_actor SystemActor.system(:camera_recording_access_audit)

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @audit_view_check {ActorHasPermission, permission: "settings.audit.view"}
  @footage_view_check {ActorHasPermission, permission: "devices.cameras.recordings.view"}
  @hold_check {ActorHasPermission, permission: "devices.cameras.recordings.hold"}

  defmodule ValidateAccessAudit do
    @moduledoc false
    use Ash.Resource.Validation

    alias Ash.Error.Changes.InvalidAttribute

    @max_actor_bytes 255
    @max_details_bytes 8192
    @forbidden_keys ~w(
      access_key_id
      api_key
      authorization
      bearer
      credential
      encrypted_secret_payload
      headers
      password
      secret_access_key
      secret_key
      secret_payload
      session_token
      token
    )

    @impl true
    def validate(changeset, _opts, _context) do
      event_kind = proposed_value(changeset, :event_kind)
      camera_source_id = proposed_value(changeset, :camera_source_id)
      actor_id = proposed_value(changeset, :actor_id)
      start_us = proposed_value(changeset, :window_start_us)
      end_us = proposed_value(changeset, :window_end_us)
      segment_count = proposed_value(changeset, :segment_count)
      details = proposed_value(changeset, :details)

      with :ok <- validate_camera_source_id(event_kind, camera_source_id),
           :ok <- validate_actor_id(actor_id),
           :ok <- validate_window(start_us, end_us),
           :ok <- validate_segment_count(segment_count) do
        validate_details(details)
      end
    end

    @impl true
    def atomic(changeset, opts, context) do
      validate(changeset, opts, context)
    end

    defp validate_camera_source_id(:semantic_search, _camera_source_id), do: :ok
    defp validate_camera_source_id("semantic_search", _camera_source_id), do: :ok
    defp validate_camera_source_id(_event_kind, id) when is_binary(id) and id != "", do: :ok

    defp validate_camera_source_id(_event_kind, _missing) do
      {:error,
       InvalidAttribute.exception(
         field: :camera_source_id,
         message: "is required unless event_kind is semantic_search"
       )}
    end

    defp validate_actor_id(actor_id) when is_binary(actor_id) do
      cond do
        String.trim(actor_id) == "" ->
          {:error, InvalidAttribute.exception(field: :actor_id, message: "must not be blank")}

        byte_size(actor_id) > @max_actor_bytes ->
          {:error,
           InvalidAttribute.exception(
             field: :actor_id,
             message: "must be at most #{@max_actor_bytes} bytes"
           )}

        true ->
          :ok
      end
    end

    defp validate_actor_id(_other) do
      {:error, InvalidAttribute.exception(field: :actor_id, message: "is required")}
    end

    defp validate_window(start_us, end_us)
         when is_integer(start_us) and is_integer(end_us) and end_us > start_us do
      :ok
    end

    defp validate_window(_start_us, _end_us) do
      {:error,
       InvalidAttribute.exception(
         field: :window_end_us,
         message: "window_end_us must be strictly greater than window_start_us"
       )}
    end

    defp validate_segment_count(nil), do: :ok
    defp validate_segment_count(n) when is_integer(n) and n >= 0, do: :ok

    defp validate_segment_count(_other) do
      {:error,
       InvalidAttribute.exception(
         field: :segment_count,
         message: "segment_count must be nil or a non-negative integer"
       )}
    end

    defp validate_details(details) when is_map(details) do
      cond do
        contains_forbidden_key?(details) ->
          {:error,
           InvalidAttribute.exception(
             field: :details,
             message: "details must not contain credential or secret fields"
           )}

        encoded_byte_size(details) > @max_details_bytes ->
          {:error,
           InvalidAttribute.exception(
             field: :details,
             message: "details must be at most #{@max_details_bytes} bytes"
           )}

        true ->
          :ok
      end
    end

    defp validate_details(_other) do
      {:error, InvalidAttribute.exception(field: :details, message: "must be a map")}
    end

    defp contains_forbidden_key?(map) when is_map(map) do
      Enum.any?(map, fn {k, v} ->
        normalized = k |> to_string() |> String.downcase()
        normalized in @forbidden_keys or contains_forbidden_key?(v)
      end)
    end

    defp contains_forbidden_key?(list) when is_list(list) do
      Enum.any?(list, &contains_forbidden_key?/1)
    end

    defp contains_forbidden_key?(_), do: false

    defp encoded_byte_size(map) do
      case Jason.encode(map) do
        {:ok, json} -> byte_size(json)
        {:error, _} -> @max_details_bytes + 1
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
    table "camera_recording_access_audits"
    schema "platform"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:camera_source_id, :inserted_at],
        name: "camera_recording_access_audits_camera_source_index"

      index [:actor_id, :inserted_at],
        name: "camera_recording_access_audits_actor_index"
    end

    custom_statements do
      statement :enforce_access_audit_append_only_fn do
        up """
        CREATE OR REPLACE FUNCTION platform.camera_recording_access_audits_enforce_append_only()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          RAISE EXCEPTION 'camera_recording_access_audits is append-only and cannot be modified or deleted'
            USING ERRCODE = 'check_violation',
                  CONSTRAINT = 'camera_recording_access_audits_append_only';
        END;
        $$;
        """

        down """
        DROP FUNCTION IF EXISTS platform.camera_recording_access_audits_enforce_append_only();
        """
      end

      statement :enforce_access_audit_append_only_trg do
        after_tables ["camera_recording_access_audits"]

        up """
        CREATE TRIGGER camera_recording_access_audits_append_only_trigger
        BEFORE UPDATE OR DELETE ON platform.camera_recording_access_audits
        FOR EACH ROW
        EXECUTE FUNCTION platform.camera_recording_access_audits_enforce_append_only();
        """

        down """
        DROP TRIGGER IF EXISTS camera_recording_access_audits_append_only_trigger
        ON platform.camera_recording_access_audits;
        """
      end
    end

    references do
      reference :camera_source,
        on_delete: :delete,
        name: "camera_recording_access_audits_camera_source_fkey"
    end

    check_constraints do
      check_constraint :window_end_us, "camera_recording_access_audits_valid",
        check: """
        window_end_us > window_start_us AND
        event_kind IN ('playlist_window', 'hold_placed', 'hold_released', 'semantic_search') AND
        (event_kind = 'semantic_search' OR camera_source_id IS NOT NULL) AND
        btrim(actor_id) <> '' AND octet_length(actor_id) <= 255 AND
        (source_mode IS NULL OR source_mode IN ('auto', 'local', 'archive')) AND
        (time_basis IS NULL OR time_basis IN ('received', 'camera_reported')) AND
        (segment_count IS NULL OR segment_count >= 0)
        """
    end
  end

  code_interface do
    define :record_audit, action: :record
    define :list_for_camera, action: :for_camera, args: [:camera_source_id]
    define :list_for_hold, action: :for_hold, args: [:recording_hold_id]
  end

  actions do
    defaults [:read]

    read :for_camera do
      argument :camera_source_id, :uuid, allow_nil?: false
      filter expr(camera_source_id == ^arg(:camera_source_id))
      prepare build(sort: [inserted_at: :desc, id: :desc])
    end

    read :for_hold do
      argument :recording_hold_id, :uuid, allow_nil?: false
      filter expr(recording_hold_id == ^arg(:recording_hold_id))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :record do
      primary? true

      accept [
        :event_kind,
        :actor_id,
        :camera_source_id,
        :stream_profile_id,
        :recording_hold_id,
        :window_start_us,
        :window_end_us,
        :source_mode,
        :time_basis,
        :segment_count,
        :details
      ]

      validate present([
                 :event_kind,
                 :actor_id,
                 :window_start_us,
                 :window_end_us
               ])

      validate ValidateAccessAudit
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
      authorize_if @operate_check
      authorize_if @audit_view_check
      authorize_if @footage_view_check
      authorize_if @hold_check
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :event_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @event_kinds
    end

    attribute :actor_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :camera_source_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :stream_profile_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :recording_hold_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :window_start_us, :integer do
      allow_nil? false
      public? true
    end

    attribute :window_end_us, :integer do
      allow_nil? false
      public? true
    end

    attribute :source_mode, :atom do
      allow_nil? true
      public? true
      constraints one_of: @source_modes
    end

    attribute :time_basis, :atom do
      allow_nil? true
      public? true
      constraints one_of: @time_bases
    end

    attribute :segment_count, :integer do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :details, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :camera_source, Source do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :camera_source_id
    end
  end

  @doc "Allowed `RecordingAccessAudit` event kinds."
  @spec event_kinds() :: [atom()]
  def event_kinds, do: @event_kinds

  @doc "Allowed `RecordingAccessAudit` playback source modes."
  @spec source_modes() :: [atom()]
  def source_modes, do: @source_modes

  @doc "Allowed `RecordingAccessAudit` time bases."
  @spec time_bases() :: [atom()]
  def time_bases, do: @time_bases

  @doc """
  Appends a `RecordingAccessAudit` record under system actor authority.
  """
  @spec record(map() | keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def record(attrs, opts \\ []) when (is_map(attrs) or is_list(attrs)) and is_list(opts) do
    params = if is_map(attrs), do: attrs, else: Map.new(attrs)
    write_opts = Keyword.put(opts, :actor, @system_actor)

    __MODULE__
    |> Ash.Changeset.for_create(:record, params, write_opts)
    |> Ash.create(write_opts)
  end
end
