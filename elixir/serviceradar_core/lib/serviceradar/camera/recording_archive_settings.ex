defmodule ServiceRadar.Camera.RecordingArchiveSettings do
  @moduledoc """
  Deployment singleton (`id = "deployment"`) for camera archive destination and
  credential selection.

  Credential choice stays outside `ArchiveBinding` so rotating to a new
  `s3_compatible` credential never changes `destination_sha256`. When no row
  exists in `platform.camera_recording_archive_settings`, code defaults apply
  (`archive_enabled: false` and nil references), representing normal local-only
  recording with no object storage configured.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset.OriginalDataNotAvailable
  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Credentials.CredentialSecretProvider
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query

  @singleton_id "deployment"
  @provider "s3_compatible"
  @system_actor SystemActor.system(:camera_recording_archive_settings)

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}

  @fields [
    :active_archive_binding_id,
    :writer_credential_secret_id,
    :reader_credential_secret_id,
    :archive_enabled
  ]

  defmodule ValidateArchiveSettings do
    @moduledoc false
    use Ash.Resource.Change

    alias Ash.Error.Changes.InvalidAttribute
    alias ServiceRadar.Camera.RecordingArchiveSettings

    @system_actor SystemActor.system(:camera_recording_archive_settings)

    @impl true
    def change(changeset, _opts, context) do
      validate_all(changeset, context)
    end

    @impl true
    def atomic(changeset, opts, context) do
      {:ok, change(changeset, opts, context)}
    end

    defp validate_all(changeset, context) do
      actor = context.actor || get_in(changeset.context, [:private, :actor])
      loaders = Map.get(changeset.context, :archive_settings_loaders, %{})
      archive_enabled = proposed_value(changeset, :archive_enabled) == true

      changeset
      |> enforce_credential_permission(actor)
      |> validate_binding(archive_enabled, loaders)
      |> validate_credential_slot(:writer_credential_secret_id, archive_enabled, loaders)
      |> validate_credential_slot(:reader_credential_secret_id, archive_enabled, loaders)
    end

    defp enforce_credential_permission(changeset, %{role: :system}), do: changeset

    defp enforce_credential_permission(changeset, actor) do
      changed_slots =
        Enum.filter(
          [:writer_credential_secret_id, :reader_credential_secret_id],
          &changing_credential?(changeset, &1)
        )

      if changed_slots == [] or
           ActorHasPermission.match?(actor, [permission: "settings.credentials.manage"], %{}) do
        changeset
      else
        Enum.reduce(changed_slots, changeset, fn field, acc ->
          Ash.Changeset.add_error(
            acc,
            InvalidAttribute.exception(
              field: field,
              message: "selecting an archive credential requires settings.credentials.manage"
            )
          )
        end)
      end
    end

    defp changing_credential?(%{action_type: :create} = changeset, field) do
      not is_nil(proposed_value(changeset, field))
    end

    defp changing_credential?(changeset, field) do
      case Ash.Changeset.fetch_change(changeset, field) do
        {:ok, new_value} ->
          if is_map(changeset.data) and
               not match?(%OriginalDataNotAvailable{}, changeset.data) do
            new_value != Map.get(changeset.data, field)
          else
            true
          end

        :error ->
          Keyword.has_key?(changeset.atomics, field)
      end
    end

    defp validate_binding(changeset, archive_enabled, loaders) do
      binding_id = proposed_value(changeset, :active_archive_binding_id)

      should_check? =
        not is_nil(binding_id) and
          (changeset.action_type == :create or
             changing_credential?(changeset, :active_archive_binding_id) or
             archive_enabled)

      if should_check? do
        binding_loader = Map.get(loaders, :binding_loader, &default_binding_loader/1)

        case binding_loader.(binding_id) do
          {:ok, %ArchiveBinding{}} ->
            changeset

          {:ok, %{id: _}} ->
            changeset

          _ ->
            Ash.Changeset.add_error(
              changeset,
              InvalidAttribute.exception(
                field: :active_archive_binding_id,
                message: "archive destination binding does not exist"
              )
            )
        end
      else
        changeset
      end
    end

    defp validate_credential_slot(changeset, field, archive_enabled, loaders) do
      secret_id = proposed_value(changeset, field)

      should_check? =
        not is_nil(secret_id) and
          (changeset.action_type == :create or
             changing_credential?(changeset, field) or
             archive_enabled)

      if should_check? do
        case RecordingArchiveSettings.inspect_credential_secret(secret_id, loaders) do
          {:ok, %{status: :available}} ->
            changeset

          {:ok, %{reason: reason}} ->
            Ash.Changeset.add_error(
              changeset,
              InvalidAttribute.exception(
                field: field,
                message: credential_error_message(reason)
              )
            )
        end
      else
        changeset
      end
    end

    defp proposed_value(changeset, field) do
      case Ash.Changeset.fetch_change(changeset, field) do
        {:ok, value} ->
          value

        :error ->
          resolve_fallback_value(changeset, field)
      end
    end

    defp resolve_fallback_value(changeset, field) do
      cond do
        Map.has_key?(changeset.attributes, field) ->
          Map.get(changeset.attributes, field)

        Keyword.has_key?(changeset.atomics, field) ->
          Keyword.get(changeset.atomics, field)

        match?(%OriginalDataNotAvailable{}, changeset.data) ->
          nil

        is_map(changeset.data) ->
          Map.get(changeset.data, field)

        true ->
          nil
      end
    end

    defp default_binding_loader(binding_id) do
      Ash.get(ArchiveBinding, binding_id, actor: @system_actor, not_found_error?: false)
    end

    defp credential_error_message(:credential_secret_missing),
      do: "credential secret does not exist"

    defp credential_error_message(:credential_secret_inactive),
      do: "credential secret is disabled or deleted"

    defp credential_error_message(:credential_provider_mismatch),
      do: "credential secret must use provider s3_compatible"

    defp credential_error_message(:credential_kind_mismatch),
      do: "credential secret must use kind opaque"
  end

  postgres do
    table "camera_recording_archive_settings"
    schema "platform"
    repo ServiceRadar.Repo

    references do
      reference :active_archive_binding,
        on_delete: :restrict,
        name: "camera_archive_settings_active_binding_fkey"

      reference :writer_credential_secret,
        on_delete: :restrict,
        name: "camera_archive_settings_writer_secret_fkey"

      reference :reader_credential_secret,
        on_delete: :restrict,
        name: "camera_archive_settings_reader_secret_fkey"
    end

    check_constraints do
      check_constraint :id, "camera_recording_archive_settings_singleton",
        check: "id = 'deployment'"
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "camera_recording_archive_settings_versions"
    reference_source? false
    mixin {ServiceRadar.Security.PaperTrailMixin, :mixin_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_singleton, action: :get_singleton
    define :create_settings, action: :create
    define :update_settings, action: :update
  end

  actions do
    defaults [:read]

    read :get_singleton do
      get? true
      filter expr(id == ^@singleton_id)
    end

    create :create do
      primary? true
      accept @fields
      change set_attribute(:id, @singleton_id)
      change ValidateArchiveSettings
    end

    update :update do
      primary? true
      accept @fields
      atomic_upgrade_with :read
      change ValidateArchiveSettings
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
      authorize_if @operate_check
    end

    action_type_with_permission([:create, :update], @manage_check)
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      default @singleton_id
      writable? false
      public? true
      constraints match: ~r/\Adeployment\z/
    end

    attribute :active_archive_binding_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :writer_credential_secret_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :reader_credential_secret_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :archive_enabled, :boolean do
      allow_nil? false
      default false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :active_archive_binding, ArchiveBinding do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :active_archive_binding_id
    end

    belongs_to :writer_credential_secret, NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :writer_credential_secret_id
    end

    belongs_to :reader_credential_secret, NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :reader_credential_secret_id
    end
  end

  @doc """
  Returns the in-memory default singleton when no row has been persisted yet.
  """
  @spec default_settings() :: t()
  def default_settings do
    struct(__MODULE__,
      id: @singleton_id,
      active_archive_binding_id: nil,
      writer_credential_secret_id: nil,
      reader_credential_secret_id: nil,
      archive_enabled: false
    )
  end

  @doc """
  Reads the persisted deployment singleton or returns `default_settings/0` when absent.
  """
  @spec get_settings(keyword()) :: {:ok, t()} | {:error, term()}
  def get_settings(opts \\ []) when is_list(opts) do
    ash_opts = ash_actor_opts(opts)

    case Ash.read_one(Ash.Query.for_read(__MODULE__, :get_singleton, %{}, ash_opts), ash_opts) do
      {:ok, nil} -> {:ok, default_settings()}
      {:ok, %{__struct__: __MODULE__} = row} -> {:ok, row}
      {:error, _} = error -> error
    end
  end

  @doc """
  Creates or updates the `"deployment"` singleton row under the caller's authorization scope.
  """
  @spec save_settings(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def save_settings(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    ash_opts = ash_actor_opts(opts)
    context = build_loader_context(opts)

    case Ash.read_one(
           Ash.Query.for_read(__MODULE__, :get_singleton, %{}, actor: @system_actor),
           actor: @system_actor
         ) do
      {:ok, nil} ->
        __MODULE__
        |> Ash.Changeset.for_create(:create, attrs, Keyword.put(ash_opts, :context, context))
        |> Ash.create(ash_opts)

      {:ok, %{__struct__: __MODULE__} = existing} ->
        existing
        |> Ash.Changeset.for_update(:update, attrs, Keyword.put(ash_opts, :context, context))
        |> Ash.update(ash_opts)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the settings together with redacted credential summaries (`id`, `name`,
  `status`) and archive readiness state so users without `settings.credentials.manage`
  can view the selected credential's redacted name and availability state.
  """
  @spec get_overview(keyword()) :: {:ok, map()} | {:error, term()}
  def get_overview(opts \\ []) when is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    with :ok <- authorize_overview(opts),
         {:ok, persisted} <- load_singleton_for_overview(loaders) do
      settings = persisted || default_settings()
      active_binding = load_active_binding(settings.active_archive_binding_id, loaders)

      writer_summary =
        summarize_slot(settings.writer_credential_secret_id, loaders)

      reader_summary =
        summarize_slot(settings.reader_credential_secret_id, loaders)

      storage_mode =
        if settings.archive_enabled and not is_nil(active_binding),
          do: :local_and_archive,
          else: :local_only

      {ready?, unavailable_reason} =
        derive_readiness(settings, active_binding, writer_summary, reader_summary)

      {:ok,
       %{
         settings: settings,
         persisted?: not is_nil(persisted),
         storage_mode: storage_mode,
         active_binding: active_binding,
         writer_credential: writer_summary,
         reader_credential: reader_summary,
         archive_ready?: ready?,
         unavailable_reason: unavailable_reason
       }}
    end
  end

  @doc false
  @spec inspect_credential_secret(Ecto.UUID.t(), map()) :: {:ok, map()}
  def inspect_credential_secret(secret_id, loaders \\ %{}) do
    secret_loader = Map.get(loaders, :secret_loader, &default_secret_loader/1)
    provider_loader = Map.get(loaders, :provider_loader, &default_provider_loader/1)

    case secret_loader.(secret_id) do
      {:ok, secret} when is_map(secret) ->
        classify_secret(secret_id, secret, provider_loader)

      _ ->
        {:ok,
         %{
           id: to_string(secret_id),
           name: nil,
           status: :missing,
           reason: :credential_secret_missing
         }}
    end
  end

  defp classify_secret(secret_id, secret, provider_loader) do
    name = field(secret, :name)
    provider = field(secret, :provider)
    kind = field(secret, :credential_kind)

    cond do
      not secret_enabled?(secret, provider_loader) ->
        {:ok,
         %{
           id: to_string(secret_id),
           name: name,
           status: :inactive,
           reason: :credential_secret_inactive
         }}

      provider != @provider ->
        {:ok,
         %{
           id: to_string(secret_id),
           name: name,
           status: :invalid,
           reason: :credential_provider_mismatch
         }}

      kind not in [:opaque, "opaque"] ->
        {:ok,
         %{
           id: to_string(secret_id),
           name: name,
           status: :invalid,
           reason: :credential_kind_mismatch
         }}

      true ->
        {:ok,
         %{
           id: to_string(secret_id),
           name: name,
           status: :available,
           reason: nil
         }}
    end
  end

  defp secret_enabled?(secret, provider_loader) do
    deleted_at = field(secret, :deleted_at)
    enabled = field(secret, :enabled)
    rotation_state = field(secret, :rotation_state)
    metadata = field(secret, :metadata) || %{}
    meta_enabled = Map.get(metadata, "enabled", Map.get(metadata, :enabled, true))

    base_active? =
      is_nil(deleted_at) and
        enabled != false and
        rotation_state not in [:disabled, "disabled"] and
        meta_enabled != false

    base_active? and external_provider_enabled?(secret, provider_loader)
  end

  defp external_provider_enabled?(secret, provider_loader) do
    source_type = field(secret, :source_type)
    provider_id = field(secret, :secret_provider_id)

    if source_type in [:external_reference, "external_reference"] and not is_nil(provider_id) do
      case provider_loader.(provider_id) do
        {:ok, provider} when is_map(provider) -> field(provider, :enabled) == true
        _ -> false
      end
    else
      true
    end
  end

  defp summarize_slot(nil, _loaders), do: nil

  defp summarize_slot(secret_id, loaders) do
    {:ok, summary} = inspect_credential_secret(secret_id, loaders)
    summary
  end

  defp derive_readiness(settings, active_binding, writer_summary, reader_summary) do
    cond do
      not is_nil(writer_summary) and writer_summary.status != :available ->
        {false, {:writer_credential_unavailable, writer_summary.reason}}

      not is_nil(reader_summary) and reader_summary.status != :available ->
        {false, {:reader_credential_unavailable, reader_summary.reason}}

      not settings.archive_enabled ->
        {false, nil}

      is_nil(settings.active_archive_binding_id) or is_nil(active_binding) ->
        {false, :missing_active_destination}

      is_nil(writer_summary) ->
        {false, :missing_writer_credential}

      true ->
        {true, nil}
    end
  end

  defp load_singleton_for_overview(loaders) do
    case Map.get(loaders, :settings_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ ->
        Ash.read_one(
          Ash.Query.for_read(__MODULE__, :get_singleton, %{}, actor: @system_actor),
          actor: @system_actor
        )
    end
  end

  defp load_active_binding(nil, _loaders), do: nil

  defp load_active_binding(binding_id, loaders) do
    binding_loader =
      Map.get(loaders, :binding_loader, fn id ->
        Ash.get(ArchiveBinding, id, actor: @system_actor, not_found_error?: false)
      end)

    case binding_loader.(binding_id) do
      {:ok, binding} -> binding
      _ -> nil
    end
  end

  defp default_secret_loader(secret_id) do
    NetworkCredentialSecret.get_by_id(secret_id, actor: @system_actor)
  end

  defp default_provider_loader(provider_id) do
    CredentialSecretProvider.get_by_id(provider_id, actor: @system_actor)
  end

  defp build_loader_context(opts) do
    case Keyword.get(opts, :loaders) do
      loaders when is_map(loaders) -> %{archive_settings_loaders: loaders}
      _ -> %{}
    end
  end

  defp authorize_overview(opts) do
    actor = resolve_actor(opts)

    permissions = [
      "settings.recording.view",
      "settings.recording.manage",
      "settings.recording.operate"
    ]

    cond do
      match?(%{role: :system}, actor) ->
        :ok

      Enum.any?(permissions, &ActorHasPermission.match?(actor, [permission: &1], %{})) ->
        :ok

      true ->
        {:error, Forbidden.exception([])}
    end
  end

  defp ash_actor_opts(opts) do
    case resolve_actor(opts) do
      nil -> Keyword.take(opts, [:scope])
      actor -> [actor: actor]
    end
  end

  defp resolve_actor(opts) do
    case Keyword.get(opts, :actor) do
      nil ->
        opts
        |> Keyword.get(:scope)
        |> actor_from_scope()

      actor ->
        actor
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
  defp actor_from_scope(%{actor: actor}) when not is_nil(actor), do: actor
  defp actor_from_scope(_), do: nil

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
