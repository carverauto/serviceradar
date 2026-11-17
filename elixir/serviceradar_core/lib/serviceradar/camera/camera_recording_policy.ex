defmodule ServiceRadar.Camera.CameraRecordingPolicy do
  @moduledoc """
  Audited per-camera, per-profile recording policy (`platform.camera_recording_policies`)
  driving continuous NVR capture and per-policy object retention overrides (`A.2.1`, `A3`, `E1`).

  Each `(camera_source_id, stream_profile_id)` pair has at most one policy row:
  - `stream_profile` must belong to `camera_source_id` and be `relay_eligible == true`.
  - `mode` is `:off | :continuous` (default `:off`). When `:continuous`, `nvr_member`
    is required (`[a-z0-9][a-z0-9-]{0,62}`).
  - `storage` is `:local_and_archive | :local_only`, defaulting to `:local_and_archive`
    when `RecordingArchiveSettings.archive_enabled` is true and `:local_only` otherwise.
  - `archive_retention_override_mode` (`:inherit | :limited | :unlimited`, default `:inherit`)
    pairs with `archive_retention_days_override` (`1..3_650` iff `:limited`, `nil` otherwise).
  - `policy_revision` starts at `1` and increments atomically on every update so
    policy edits act as assignment transitions (`A3`).
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Changeset.OriginalDataNotAvailable
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @modes [:off, :continuous]
  @storage_modes [:local_and_archive, :local_only]
  @override_modes [:inherit, :limited, :unlimited]
  @member_name_pattern ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @audit_view_check {ActorHasPermission, permission: "settings.audit.view"}

  @create_fields [
    :camera_source_id,
    :stream_profile_id,
    :mode,
    :nvr_member,
    :storage,
    :archive_retention_override_mode,
    :archive_retention_days_override
  ]

  @update_fields [
    :mode,
    :nvr_member,
    :storage,
    :archive_retention_override_mode,
    :archive_retention_days_override
  ]

  defmodule ValidatePolicy do
    @moduledoc false
    use Ash.Resource.Change

    alias Ash.Error.Changes.InvalidAttribute
    alias ServiceRadar.Actors.SystemActor

    @system_actor SystemActor.system(:camera_recording_policy)
    @member_regex ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
    @min_override_days 1
    @max_override_days 3_650

    @impl true
    def change(changeset, _opts, _context) do
      {errors, stamped} = evaluate(changeset)

      changeset =
        if map_size(stamped) == 0 do
          changeset
        else
          Ash.Changeset.force_change_attributes(changeset, stamped)
        end

      Enum.reduce(errors, changeset, &Ash.Changeset.add_error(&2, &1))
    end

    @impl true
    def atomic(changeset, _opts, _context) do
      if match?(%OriginalDataNotAvailable{}, changeset.data) do
        {:not_atomic, "validating camera recording policy requires existing state"}
      else
        {errors, stamped} = evaluate(changeset)

        cond do
          errors != [] -> {:error, errors}
          map_size(stamped) > 0 -> {:atomic, stamped}
          true -> :ok
        end
      end
    end

    defp evaluate(changeset) do
      loaders = Map.get(changeset.context, :policy_loaders, %{})
      {stamped, normalized_member} = normalize_stamped_inputs(changeset, loaders)

      errors =
        []
        |> check_source_and_profile(changeset, loaders)
        |> check_mode_and_member(changeset, normalized_member)
        |> check_retention_override(changeset)

      {Enum.reverse(errors), stamped}
    end

    defp normalize_stamped_inputs(changeset, loaders) do
      raw_member = proposed_value(changeset, :nvr_member)

      {stamped, normalized_member} =
        case raw_member do
          val when is_binary(val) ->
            trimmed = String.trim(val)

            if trimmed == "" do
              {%{nvr_member: nil}, nil}
            else
              stamped_map = if trimmed == val, do: %{}, else: %{nvr_member: trimmed}
              {stamped_map, trimmed}
            end

          nil ->
            {%{}, nil}

          other ->
            {%{}, other}
        end

      stamped = maybe_default_storage_on_create(changeset, stamped, loaders)
      {stamped, normalized_member}
    end

    defp maybe_default_storage_on_create(%{action_type: :create} = changeset, stamped, loaders) do
      if explicit_input?(changeset, :storage) do
        stamped
      else
        Map.put(stamped, :storage, resolve_default_storage(loaders))
      end
    end

    defp maybe_default_storage_on_create(_changeset, stamped, _loaders), do: stamped

    defp resolve_default_storage(loaders) do
      case load_archive_settings(loaders) do
        {:ok, %{archive_enabled: true}} -> :local_and_archive
        _ -> :local_only
      end
    end

    defp load_archive_settings(loaders) do
      case Map.get(loaders, :settings_loader) do
        loader when is_function(loader, 0) -> loader.()
        _ when map_size(loaders) > 0 -> {:ok, RecordingArchiveSettings.default_settings()}
        _ -> RecordingArchiveSettings.get_settings(actor: @system_actor)
      end
    end

    defp check_source_and_profile(errors, %{action_type: :create} = changeset, loaders) do
      source_id = proposed_value(changeset, :camera_source_id)
      profile_id = proposed_value(changeset, :stream_profile_id)

      errors
      |> verify_camera_source(source_id, loaders)
      |> verify_stream_profile(source_id, profile_id, loaders)
    end

    defp check_source_and_profile(errors, _changeset, _loaders), do: errors

    defp verify_camera_source(errors, nil, _loaders), do: errors

    defp verify_camera_source(errors, source_id, loaders) do
      case load_source(source_id, loaders) do
        {:ok, %{id: _}} ->
          errors

        _ ->
          [
            InvalidAttribute.exception(
              field: :camera_source_id,
              message: "camera source does not exist"
            )
            | errors
          ]
      end
    end

    defp verify_stream_profile(errors, source_id, profile_id, loaders)
         when not is_nil(source_id) and not is_nil(profile_id) do
      case load_profile(profile_id, loaders) do
        {:ok, %{camera_source_id: prof_source_id, relay_eligible: relay_eligible}} ->
          validate_loaded_profile(errors, source_id, prof_source_id, relay_eligible)

        _ ->
          [
            InvalidAttribute.exception(
              field: :stream_profile_id,
              message: "stream profile does not exist"
            )
            | errors
          ]
      end
    end

    defp verify_stream_profile(errors, _source_id, _profile_id, _loaders), do: errors

    defp validate_loaded_profile(errors, source_id, prof_source_id, relay_eligible) do
      cond do
        to_string(prof_source_id) != to_string(source_id) ->
          [
            InvalidAttribute.exception(
              field: :stream_profile_id,
              message: "stream profile does not belong to selected camera source"
            )
            | errors
          ]

        relay_eligible != true ->
          [
            InvalidAttribute.exception(
              field: :stream_profile_id,
              message: "stream profile must be relay-eligible"
            )
            | errors
          ]

        true ->
          errors
      end
    end

    defp load_source(source_id, loaders) do
      case Map.get(loaders, :source_loader) do
        loader when is_function(loader, 1) ->
          loader.(source_id)

        _ ->
          Ash.get(Source, source_id, actor: @system_actor, not_found_error?: false)
      end
    end

    defp load_profile(profile_id, loaders) do
      case Map.get(loaders, :profile_loader) do
        loader when is_function(loader, 1) ->
          loader.(profile_id)

        _ ->
          Ash.get(StreamProfile, profile_id, actor: @system_actor, not_found_error?: false)
      end
    end

    defp check_mode_and_member(errors, changeset, member) do
      mode = proposed_value(changeset, :mode)

      cond do
        mode == :continuous and is_nil(member) ->
          [
            InvalidAttribute.exception(
              field: :nvr_member,
              message: "is required when mode is continuous"
            )
            | errors
          ]

        not is_nil(member) and
            (not is_binary(member) or not Regex.match?(@member_regex, member)) ->
          [
            InvalidAttribute.exception(
              field: :nvr_member,
              message: "must match [a-z0-9][a-z0-9-]{0,62}"
            )
            | errors
          ]

        true ->
          errors
      end
    end

    defp check_retention_override(errors, changeset) do
      mode = proposed_value(changeset, :archive_retention_override_mode)
      days = effective_value_for_validation(changeset, :archive_retention_days_override)

      if mode == :limited do
        validate_limited_override_days(errors, days)
      else
        validate_unset_override_days(errors, mode, days)
      end
    end

    defp validate_limited_override_days(errors, nil) do
      [
        InvalidAttribute.exception(
          field: :archive_retention_days_override,
          message: "is required when archive_retention_override_mode is limited"
        )
        | errors
      ]
    end

    defp validate_limited_override_days(errors, days)
         when is_integer(days) and days >= @min_override_days and days <= @max_override_days do
      errors
    end

    defp validate_limited_override_days(errors, _days) do
      [
        InvalidAttribute.exception(
          field: :archive_retention_days_override,
          message: "must be between #{@min_override_days} and #{@max_override_days}"
        )
        | errors
      ]
    end

    defp validate_unset_override_days(errors, _mode, nil), do: errors

    defp validate_unset_override_days(errors, mode, _days) do
      [
        InvalidAttribute.exception(
          field: :archive_retention_days_override,
          message: "must be nil when archive_retention_override_mode is #{mode}"
        )
        | errors
      ]
    end

    defp explicit_input?(changeset, field) do
      params = changeset.params || %{}
      str_key = Atom.to_string(field)

      Map.has_key?(params, field) or Map.has_key?(params, str_key)
    end

    defp effective_value_for_validation(changeset, field) do
      if param_explicitly_nil?(changeset, field) do
        nil
      else
        proposed_value(changeset, field)
      end
    end

    defp param_explicitly_nil?(changeset, field) do
      params = changeset.params || %{}
      str_key = Atom.to_string(field)

      cond do
        Map.has_key?(params, field) -> is_nil(Map.get(params, field))
        Map.has_key?(params, str_key) -> is_nil(Map.get(params, str_key))
        true -> false
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
    table "camera_recording_policies"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names camera_profile: "camera_recording_policies_camera_profile_index"

    custom_indexes do
      index [:mode, :nvr_member],
        name: "camera_recording_policies_active_member_index",
        where: "mode = 'continuous'"
    end

    references do
      reference :camera_source,
        on_delete: :restrict,
        name: "camera_recording_policies_camera_source_fkey"

      reference :stream_profile,
        on_delete: :restrict,
        name: "camera_recording_policies_stream_profile_fkey"
    end

    check_constraints do
      check_constraint :nvr_member, "camera_recording_policies_mode_member",
        check: """
        mode IN ('off', 'continuous') AND
        storage IN ('local_and_archive', 'local_only') AND
        policy_revision >= 1 AND
        ((mode = 'off' AND (nvr_member IS NULL OR nvr_member ~ '^[a-z0-9][a-z0-9-]{0,62}$')) OR
         (mode = 'continuous' AND nvr_member IS NOT NULL AND nvr_member ~ '^[a-z0-9][a-z0-9-]{0,62}$'))
        """

      check_constraint :archive_retention_days_override,
                       "camera_recording_policies_archive_override",
                       check: """
                       (archive_retention_override_mode = 'limited' AND archive_retention_days_override IS NOT NULL AND archive_retention_days_override BETWEEN 1 AND 3650) OR
                       (archive_retention_override_mode IN ('inherit', 'unlimited') AND archive_retention_days_override IS NULL)
                       """
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "camera_recording_policies_versions"
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

    define :get_by_camera_profile,
      action: :by_camera_profile,
      args: [:camera_source_id, :stream_profile_id]

    define :list_for_camera, action: :for_camera, args: [:camera_source_id]
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_camera_profile do
      argument :camera_source_id, :uuid, allow_nil?: false
      argument :stream_profile_id, :uuid, allow_nil?: false
      get? true

      filter expr(
               camera_source_id == ^arg(:camera_source_id) and
                 stream_profile_id == ^arg(:stream_profile_id)
             )
    end

    read :for_camera do
      argument :camera_source_id, :uuid, allow_nil?: false
      filter expr(camera_source_id == ^arg(:camera_source_id))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :create do
      primary? true
      accept @create_fields
      change set_attribute(:policy_revision, 1)
      validate present([:camera_source_id, :stream_profile_id])
      change ValidatePolicy
    end

    update :update do
      primary? true
      accept @update_fields
      atomic_upgrade_with :read
      change atomic_update(:policy_revision, expr(policy_revision + 1))
      change ValidatePolicy
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
    end

    action_type_with_permission([:create, :update], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :camera_source_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :stream_profile_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :mode, :atom do
      allow_nil? false
      default :off
      public? true
      constraints one_of: @modes
    end

    attribute :nvr_member, :string do
      allow_nil? true
      default nil
      public? true
      constraints max_length: 63
    end

    attribute :storage, :atom do
      allow_nil? false
      default :local_only
      public? true
      constraints one_of: @storage_modes
    end

    attribute :archive_retention_override_mode, :atom do
      allow_nil? false
      default :inherit
      public? true
      constraints one_of: @override_modes
    end

    attribute :archive_retention_days_override, :integer do
      allow_nil? true
      default nil
      public? true
    end

    attribute :policy_revision, :integer do
      allow_nil? false
      default 1
      writable? false
      public? true
      constraints min: 1
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
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :stream_profile_id
    end
  end

  identities do
    identity :camera_profile, [:camera_source_id, :stream_profile_id]
  end

  @doc "Allowed `mode` values (`:off | :continuous`)."
  @spec modes() :: [atom()]
  def modes, do: @modes

  @doc "Allowed `storage` values (`:local_and_archive | :local_only`)."
  @spec storage_modes() :: [atom()]
  def storage_modes, do: @storage_modes

  @doc "Allowed `archive_retention_override_mode` values (`:inherit | :limited | :unlimited`)."
  @spec override_modes() :: [atom()]
  def override_modes, do: @override_modes

  @doc "Valid NVR member name regex (`[a-z0-9][a-z0-9-]{0,62}`)."
  @spec member_name_pattern() :: Regex.t()
  def member_name_pattern, do: @member_name_pattern

  @doc """
  Resolves the default `storage` mode from `RecordingArchiveSettings`:
  `:local_and_archive` when `archive_enabled` is true, else `:local_only`.
  """
  @spec default_storage_for_settings(map() | RecordingArchiveSettings.t() | nil) ::
          :local_and_archive | :local_only
  def default_storage_for_settings(%{archive_enabled: true}), do: :local_and_archive
  def default_storage_for_settings(%{"archive_enabled" => true}), do: :local_and_archive
  def default_storage_for_settings(_), do: :local_only
end
