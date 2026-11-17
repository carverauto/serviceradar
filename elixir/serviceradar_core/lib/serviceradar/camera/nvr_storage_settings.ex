defmodule ServiceRadar.Camera.NVRStorageSettings do
  @moduledoc """
  Audited per-member NVR storage budget and reserve settings
  (`platform.camera_nvr_storage_settings`) keyed by `storage_id` (`C9`, `C.13`, `E1`).

  Stores operator-configured `budget_mode` (`:install_default | :custom`) +
  `budget_bytes` and `reserve_mode` (`:install_default | :custom`) +
  `reserve_bytes` with monotonic `revision` (incremented atomically on every
  desired-settings update), plus desired-vs-applied sync tracking
  (`applied_revision`, `sync_state`, `last_refusal_class`, `applied_at`).

  Save-time validation enforces:
  - `budget_bytes >= pinned_bytes_on_storage + 2 * 16_777_216` (pinned local
    bytes per `C1a` `P1..P5` plus two 16 MiB block reservations) and at most
    `1 PiB`, optional `install_ceiling_bytes`, and optional
    `volume_capacity_bytes - effective_reserve_bytes`.
  - `reserve_bytes >= max(64 MiB, install_reserve_bytes)` and at most
    `div(volume_capacity_bytes, 10)` when volume capacity is known.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Changeset.OriginalDataNotAvailable
  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingHold
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Camera.RetentionCalculator
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query

  @modes [:install_default, :custom]
  @sync_states [:pending, :applied, :refused]
  @refusal_class_pattern ~r/\A[a-z0-9_.:-]+\z/

  @min_reserve_bytes 67_108_864
  @block_reservation_bytes 16_777_216
  @two_block_reservations_bytes 2 * @block_reservation_bytes
  @max_spool_ceiling_bytes 1_125_899_906_842_624

  @system_actor SystemActor.system(:camera_nvr_storage_settings)

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @audit_view_check {ActorHasPermission, permission: "settings.audit.view"}

  @desired_fields [
    :budget_mode,
    :budget_bytes,
    :reserve_mode,
    :reserve_bytes
  ]

  defmodule ValidateStorageSettings do
    @moduledoc false
    use Ash.Resource.Change

    alias Ash.Error.Changes.InvalidAttribute
    alias ServiceRadar.Camera.NVRStorageSettings

    @min_reserve 67_108_864
    @two_blocks 33_554_432
    @max_spool 1_125_899_906_842_624

    @impl true
    def change(changeset, _opts, _context) do
      errors = evaluate(changeset)
      Enum.reduce(errors, changeset, &Ash.Changeset.add_error(&2, &1))
    end

    @impl true
    def atomic(changeset, _opts, _context) do
      if match?(%OriginalDataNotAvailable{}, changeset.data) do
        {:not_atomic, "validating NVR storage settings requires current state"}
      else
        case evaluate(changeset) do
          [] -> :ok
          errors -> {:error, errors}
        end
      end
    end

    defp evaluate(changeset) do
      ctx = Map.get(changeset.context, :storage_settings_bounds, %{})
      loaders = Map.get(changeset.context, :storage_settings_loaders, %{})
      storage_id = proposed_value(changeset, :storage_id)

      budget_mode = proposed_value(changeset, :budget_mode)
      budget_bytes = effective_value_for_validation(changeset, :budget_bytes)
      reserve_mode = proposed_value(changeset, :reserve_mode)
      reserve_bytes = effective_value_for_validation(changeset, :reserve_bytes)

      []
      |> check_reserve_bounds(reserve_mode, reserve_bytes, ctx)
      |> check_budget_bounds(
        storage_id,
        budget_mode,
        budget_bytes,
        reserve_mode,
        reserve_bytes,
        ctx,
        loaders
      )
      |> Enum.reverse()
    end

    defp check_reserve_bounds(errors, :install_default, nil, _ctx), do: errors

    defp check_reserve_bounds(errors, :install_default, _bytes, _ctx) do
      [
        InvalidAttribute.exception(
          field: :reserve_bytes,
          message: "must be nil when reserve_mode is install_default"
        )
        | errors
      ]
    end

    defp check_reserve_bounds(errors, :custom, nil, _ctx) do
      [
        InvalidAttribute.exception(
          field: :reserve_bytes,
          message: "is required when reserve_mode is custom"
        )
        | errors
      ]
    end

    defp check_reserve_bounds(errors, :custom, bytes, ctx) when is_integer(bytes) do
      install_floor =
        max(@min_reserve, positive_int_or(Map.get(ctx, :install_reserve_bytes), @min_reserve))

      vol_cap = positive_int_or(Map.get(ctx, :volume_capacity_bytes), nil)
      max_reserve = if is_integer(vol_cap), do: div(vol_cap, 10)

      cond do
        bytes < install_floor ->
          [
            InvalidAttribute.exception(
              field: :reserve_bytes,
              message: "must be at least #{install_floor} bytes"
            )
            | errors
          ]

        is_integer(max_reserve) and bytes > max_reserve ->
          [
            InvalidAttribute.exception(
              field: :reserve_bytes,
              message:
                "must be at most #{max_reserve} bytes (10% of volume capacity #{vol_cap} bytes)"
            )
            | errors
          ]

        bytes > @max_spool ->
          [
            InvalidAttribute.exception(
              field: :reserve_bytes,
              message: "must be at most #{@max_spool} bytes (1 PiB)"
            )
            | errors
          ]

        true ->
          errors
      end
    end

    defp check_reserve_bounds(errors, _mode, _bytes, _ctx) do
      [
        InvalidAttribute.exception(
          field: :reserve_bytes,
          message: "must be a positive integer"
        )
        | errors
      ]
    end

    defp check_budget_bounds(
           errors,
           _storage_id,
           :install_default,
           nil,
           _reserve_mode,
           _reserve_bytes,
           _ctx,
           _loaders
         ) do
      errors
    end

    defp check_budget_bounds(
           errors,
           _storage_id,
           :install_default,
           _bytes,
           _reserve_mode,
           _reserve_bytes,
           _ctx,
           _loaders
         ) do
      [
        InvalidAttribute.exception(
          field: :budget_bytes,
          message: "must be nil when budget_mode is install_default"
        )
        | errors
      ]
    end

    defp check_budget_bounds(
           errors,
           _storage_id,
           :custom,
           nil,
           _reserve_mode,
           _reserve_bytes,
           _ctx,
           _loaders
         ) do
      [
        InvalidAttribute.exception(
          field: :budget_bytes,
          message: "is required when budget_mode is custom"
        )
        | errors
      ]
    end

    defp check_budget_bounds(
           errors,
           storage_id,
           :custom,
           bytes,
           reserve_mode,
           reserve_bytes,
           ctx,
           loaders
         )
         when is_integer(bytes) do
      pinned_bytes = resolve_pinned_bytes(storage_id, ctx, loaders)
      min_budget = pinned_bytes + @two_blocks
      install_ceiling = positive_int_or(Map.get(ctx, :install_ceiling_bytes), nil)
      vol_cap = positive_int_or(Map.get(ctx, :volume_capacity_bytes), nil)
      eff_reserve = resolve_effective_reserve(reserve_mode, reserve_bytes, vol_cap, ctx)

      cond do
        bytes < min_budget ->
          [
            InvalidAttribute.exception(
              field: :budget_bytes,
              message:
                "must be at least #{min_budget} bytes (pinned_bytes=#{pinned_bytes} plus #{@two_blocks} bytes for two 16 MiB block reservations)"
            )
            | errors
          ]

        bytes > @max_spool ->
          [
            InvalidAttribute.exception(
              field: :budget_bytes,
              message: "must be at most #{@max_spool} bytes (1 PiB)"
            )
            | errors
          ]

        is_integer(install_ceiling) and bytes > install_ceiling ->
          [
            InvalidAttribute.exception(
              field: :budget_bytes,
              message: "must not exceed install ceiling of #{install_ceiling} bytes"
            )
            | errors
          ]

        is_integer(vol_cap) and bytes > max(0, vol_cap - eff_reserve) ->
          max_vol_budget = max(0, vol_cap - eff_reserve)

          [
            InvalidAttribute.exception(
              field: :budget_bytes,
              message: "must not exceed volume capacity minus reserve (#{max_vol_budget} bytes)"
            )
            | errors
          ]

        true ->
          errors
      end
    end

    defp check_budget_bounds(
           errors,
           _storage_id,
           _mode,
           _bytes,
           _reserve_mode,
           _reserve_bytes,
           _ctx,
           _loaders
         ) do
      [
        InvalidAttribute.exception(
          field: :budget_bytes,
          message: "must be a positive integer"
        )
        | errors
      ]
    end

    defp resolve_pinned_bytes(storage_id, ctx, loaders) do
      case Map.get(ctx, :pinned_bytes) do
        val when is_integer(val) and val >= 0 ->
          val

        _ when is_nil(storage_id) ->
          0

        _ ->
          NVRStorageSettings.pinned_bytes_for_storage(storage_id, loaders: loaders).total_pinned_bytes
      end
    end

    defp resolve_effective_reserve(:custom, reserve_bytes, _vol_cap, _ctx)
         when is_integer(reserve_bytes) and reserve_bytes >= @min_reserve do
      reserve_bytes
    end

    defp resolve_effective_reserve(_mode, _reserve_bytes, vol_cap, ctx) do
      case positive_int_or(Map.get(ctx, :install_reserve_bytes), nil) do
        val when is_integer(val) -> max(@min_reserve, val)
        nil when is_integer(vol_cap) -> max(@min_reserve, div(vol_cap, 100))
        nil -> @min_reserve
      end
    end

    defp positive_int_or(val, _fallback) when is_integer(val) and val > 0, do: val
    defp positive_int_or(_, fallback), do: fallback

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
    table "camera_nvr_storage_settings"
    schema "platform"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:sync_state, :updated_at],
        name: "camera_nvr_storage_settings_sync_state_index",
        where: "sync_state IN ('pending', 'refused')"
    end

    check_constraints do
      check_constraint :budget_bytes, "camera_nvr_storage_settings_budget_pair",
        check: """
        (budget_mode = 'custom' AND budget_bytes IS NOT NULL AND budget_bytes > 0 AND budget_bytes <= 1125899906842624) OR
        (budget_mode = 'install_default' AND budget_bytes IS NULL)
        """

      check_constraint :reserve_bytes, "camera_nvr_storage_settings_reserve_pair",
        check: """
        (reserve_mode = 'custom' AND reserve_bytes IS NOT NULL AND reserve_bytes >= 67108864 AND reserve_bytes <= 1125899906842624) OR
        (reserve_mode = 'install_default' AND reserve_bytes IS NULL)
        """

      check_constraint :sync_state, "camera_nvr_storage_settings_revision_and_sync",
        check: """
        revision >= 1 AND
        (applied_revision IS NULL OR (applied_revision >= 1 AND applied_revision <= revision)) AND
        sync_state IN ('pending', 'applied', 'refused') AND
        ((sync_state = 'refused' AND last_refusal_class IS NOT NULL AND octet_length(last_refusal_class) BETWEEN 1 AND 64 AND last_refusal_class ~ '^[a-z0-9_.:-]+$') OR
         (sync_state <> 'refused' AND last_refusal_class IS NULL)) AND
        (sync_state <> 'applied' OR (applied_revision IS NOT NULL AND applied_at IS NOT NULL))
        """
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "camera_nvr_storage_settings_versions"
    reference_source? false
    mixin {ServiceRadar.Security.PaperTrailMixin, :mixin_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_storage_id, action: :by_storage_id, args: [:storage_id]
  end

  actions do
    defaults [:read]

    read :by_storage_id do
      argument :storage_id, :uuid, allow_nil?: false
      get? true
      filter expr(storage_id == ^arg(:storage_id))
    end

    create :create do
      primary? true
      accept [:storage_id | @desired_fields]
      change set_attribute(:revision, 1)
      change set_attribute(:sync_state, :pending)
      change set_attribute(:applied_revision, nil)
      change set_attribute(:last_refusal_class, nil)
      change set_attribute(:applied_at, nil)
      validate present(:storage_id)
      change ValidateStorageSettings
    end

    update :update do
      primary? true
      accept @desired_fields
      atomic_upgrade_with :read
      change atomic_update(:revision, expr(revision + 1))
      change set_attribute(:sync_state, :pending)
      change set_attribute(:last_refusal_class, nil)
      change ValidateStorageSettings
    end

    update :record_applied do
      accept [:applied_revision, :applied_at]
      atomic_upgrade_with :read
      change set_attribute(:sync_state, :applied)
      change set_attribute(:last_refusal_class, nil)
      validate present([:applied_revision, :applied_at])
      validate compare(:applied_revision, less_than_or_equal_to: :revision)
    end

    update :record_refused do
      accept [:last_refusal_class]
      atomic_upgrade_with :read
      change set_attribute(:sync_state, :refused)
      validate present(:last_refusal_class)
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

    policy action([:create, :update]) do
      authorize_if @manage_check
    end

    policy action([:record_applied, :record_refused]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :storage_id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :budget_mode, :atom do
      allow_nil? false
      default :install_default
      public? true
      constraints one_of: @modes
    end

    attribute :budget_bytes, :integer do
      allow_nil? true
      default nil
      public? true
    end

    attribute :reserve_mode, :atom do
      allow_nil? false
      default :install_default
      public? true
      constraints one_of: @modes
    end

    attribute :reserve_bytes, :integer do
      allow_nil? true
      default nil
      public? true
    end

    attribute :revision, :integer do
      allow_nil? false
      default 1
      writable? false
      public? true
      constraints min: 1
    end

    attribute :applied_revision, :integer do
      allow_nil? true
      default nil
      public? true
      constraints min: 1
    end

    attribute :sync_state, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: @sync_states
    end

    attribute :last_refusal_class, :string do
      allow_nil? true
      default nil
      public? true
      constraints min_length: 1, max_length: 64, match: @refusal_class_pattern
    end

    attribute :applied_at, :utc_datetime_usec do
      allow_nil? true
      default nil
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  @doc "Minimum reserve floor (`67_108_864` bytes = 64 MiB)."
  @spec min_reserve_bytes() :: pos_integer()
  def min_reserve_bytes, do: @min_reserve_bytes

  @doc "Two 16 MiB block reservations (`33_554_432` bytes = 32 MiB) added to pinned bytes floor."
  @spec two_block_reservations_bytes() :: pos_integer()
  def two_block_reservations_bytes, do: @two_block_reservations_bytes

  @doc "Maximum local spool ceiling (`1_125_899_906_842_624` bytes = 1 PiB)."
  @spec max_spool_ceiling_bytes() :: pos_integer()
  def max_spool_ceiling_bytes, do: @max_spool_ceiling_bytes

  @doc """
  Returns the in-memory default `NVRStorageSettings` struct when no row has been
  persisted for `storage_id` yet (`budget_mode: :install_default`,
  `reserve_mode: :install_default`).
  """
  @spec default_storage_settings(Ecto.UUID.t()) :: t()
  def default_storage_settings(storage_id) when is_binary(storage_id) do
    struct(__MODULE__,
      storage_id: storage_id,
      budget_mode: :install_default,
      budget_bytes: nil,
      reserve_mode: :install_default,
      reserve_bytes: nil,
      revision: 0,
      applied_revision: nil,
      sync_state: :applied,
      last_refusal_class: nil,
      applied_at: nil
    )
  end

  @doc """
  Computes chart install defaults (`C1` / `PD6`) from a volume capacity in bytes:
  - `reserve_bytes = max(64 MiB, 1% of volume_capacity_bytes)`
  - `budget_bytes = floor(85% of volume_capacity_bytes) - reserve_bytes`
  """
  @spec derive_install_defaults(pos_integer()) :: %{
          reserve_bytes: non_neg_integer(),
          budget_bytes: non_neg_integer()
        }
  def derive_install_defaults(volume_capacity_bytes)
      when is_integer(volume_capacity_bytes) and volume_capacity_bytes > 0 do
    reserve = max(@min_reserve_bytes, div(volume_capacity_bytes, 100))
    budget = max(0, div(volume_capacity_bytes * 85, 100) - reserve)
    %{reserve_bytes: reserve, budget_bytes: budget}
  end

  @doc """
  Computes the disjoint `C1a` pinned-bytes partition (`P1..P5`) and minimum
  custom budget floor (`pinned_bytes + 33_554_432`) for `storage_id` from
  `RecordingCatalogEntry`, accepted `RecordingHold`s, and `RecordingArchiveSettings`.

  Supports `:loaders` (`settings_loader`, `catalog_loader`, `holds_loader`) for
  `:db_free` unit tests.
  """
  @spec pinned_bytes_for_storage(Ecto.UUID.t(), keyword()) :: %{
          p1: non_neg_integer(),
          p2: non_neg_integer(),
          p3: non_neg_integer(),
          p4: non_neg_integer(),
          p5: non_neg_integer(),
          total_pinned_bytes: non_neg_integer(),
          min_budget_bytes: pos_integer()
        }
  def pinned_bytes_for_storage(storage_id, opts \\ [])
      when is_binary(storage_id) and is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    settings = load_archive_settings(opts, loaders)
    entries = load_storage_catalog_entries(storage_id, loaders)
    holds = load_accepted_holds(loaders)
    unreconciled = max(0, Keyword.get(opts, :unreconciled_bytes, 0))

    counts =
      Enum.reduce(
        entries,
        %{p1: 0, kind_b: 0, held_kind_b: 0, held_kind_a: 0, p5: 0},
        fn entry, acc -> accumulate_storage_pinned_entry(entry, acc, holds) end
      )

    partition =
      RetentionCalculator.calculate_pinned_bytes(%{
        local_only_full_policy: Map.get(settings, :local_only_full_policy),
        p1_unarchived_bytes: counts.p1,
        p2_unreconciled_bytes: unreconciled,
        kind_b_local_only_bytes: counts.kind_b,
        held_kind_b_bytes: counts.held_kind_b,
        held_kind_a_local_only_bytes: counts.held_kind_a,
        p5_quarantined_bytes: counts.p5
      })

    Map.put(
      partition,
      :min_budget_bytes,
      partition.total_pinned_bytes + @two_block_reservations_bytes
    )
  end

  @doc """
  Lists all persisted `NVRStorageSettings` rows under `settings.recording.view | manage | operate`.
  Supports `loaders.storage_settings_loader` for `:db_free` unit tests.
  """
  @spec list_storage_settings(keyword()) :: {:ok, [t()]} | {:error, term()}
  def list_storage_settings(opts \\ []) when is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    with :ok <- RecordingArchiveSettings.authorize_recording_read(opts) do
      case Map.get(loaders, :storage_settings_loader) do
        loader when is_function(loader, 0) ->
          loader.()

        _ when map_size(loaders) > 0 ->
          {:ok, []}

        _ ->
          __MODULE__
          |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
          |> Ash.Query.sort(storage_id: :asc)
          |> Ash.read(actor: @system_actor)
      end
    end
  end

  @doc """
  Reads the persisted `NVRStorageSettings` row for `storage_id` (or `{:ok, nil}` when unset)
  under `settings.recording.view | manage | operate`.
  """
  @spec get_storage_settings(Ecto.UUID.t(), keyword()) :: {:ok, t() | nil} | {:error, term()}
  def get_storage_settings(storage_id, opts \\ []) when is_binary(storage_id) and is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    with :ok <- RecordingArchiveSettings.authorize_recording_read(opts) do
      case Map.get(loaders, :storage_settings_loader) do
        loader when is_function(loader, 1) ->
          loader.(storage_id)

        loader when is_function(loader, 0) ->
          with {:ok, rows} <- loader.() do
            {:ok,
             Enum.find(rows, &(to_string(Map.get(&1, :storage_id)) == to_string(storage_id)))}
          end

        _ when map_size(loaders) > 0 ->
          {:ok, nil}

        _ ->
          __MODULE__
          |> Ash.Query.for_read(:by_storage_id, %{storage_id: storage_id}, actor: @system_actor)
          |> Ash.read_one(actor: @system_actor)
      end
    end
  end

  @doc """
  Validates candidate `NVRStorageSettings` attributes for `storage_id` without persisting.
  Useful for LiveView `phx-change` validation.
  """
  @spec preview_changeset(Ecto.UUID.t(), map(), keyword()) :: Ash.Changeset.t()
  def preview_changeset(storage_id, attrs, opts \\ [])
      when is_binary(storage_id) and is_map(attrs) and is_list(opts) do
    base = Keyword.get(opts, :existing) || default_storage_settings(storage_id)
    normalized_attrs = normalize_mode_cleared_attrs(attrs)
    ash_opts = ash_actor_opts(opts)
    context = build_changeset_context(opts)

    Ash.Changeset.for_update(
      base,
      :update,
      normalized_attrs,
      Keyword.put(ash_opts, :context, context)
    )
  end

  @doc """
  Creates or updates desired `NVRStorageSettings` for `storage_id` under
  `settings.recording.manage` authorization, checking `C.13` / `C9` bounds
  (`pinned_bytes + 2 * 16 MiB` floor, optional `install_ceiling_bytes`,
  optional `volume_capacity_bytes`, and optional `install_reserve_bytes`).
  """
  @spec save_storage_settings(Ecto.UUID.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def save_storage_settings(storage_id, attrs, opts \\ [])
      when is_binary(storage_id) and is_map(attrs) and is_list(opts) do
    with :ok <- authorize_manage(opts) do
      normalized_attrs = normalize_mode_cleared_attrs(attrs)
      ash_opts = ash_actor_opts(opts)
      context = build_changeset_context(opts)

      case Ash.read_one(
             Ash.Query.for_read(__MODULE__, :by_storage_id, %{storage_id: storage_id},
               actor: @system_actor
             ),
             actor: @system_actor
           ) do
        {:ok, nil} ->
          create_attrs = Map.put(normalized_attrs, :storage_id, storage_id)

          __MODULE__
          |> Ash.Changeset.for_create(
            :create,
            create_attrs,
            Keyword.put(ash_opts, :context, context)
          )
          |> Ash.create(ash_opts)

        {:ok, %{__struct__: __MODULE__} = existing} ->
          existing
          |> Ash.Changeset.for_update(
            :update,
            normalized_attrs,
            Keyword.put(ash_opts, :context, context)
          )
          |> Ash.update(ash_opts)

        {:error, _} = error ->
          error
      end
    end
  end

  defp normalize_mode_cleared_attrs(attrs) when is_map(attrs) do
    attrs
    |> maybe_clear_paired_field(:budget_mode, :budget_bytes, :install_default)
    |> maybe_clear_paired_field(:reserve_mode, :reserve_bytes, :install_default)
  end

  defp maybe_clear_paired_field(attrs, mode_key, value_key, clear_mode) do
    mode = fetch_field(attrs, mode_key)
    clear? = mode in [clear_mode, Atom.to_string(clear_mode)]
    explicit_value? = has_non_nil_key?(attrs, value_key)

    if clear? and not explicit_value? do
      put_matching_key_style(attrs, value_key, nil)
    else
      attrs
    end
  end

  defp has_non_nil_key?(attrs, key) do
    str_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> not is_nil(Map.get(attrs, key))
      Map.has_key?(attrs, str_key) -> not is_nil(Map.get(attrs, str_key))
      true -> false
    end
  end

  defp put_matching_key_style(attrs, key, val) do
    if Enum.any?(Map.keys(attrs), &is_binary/1) and not Map.has_key?(attrs, key) do
      Map.put(attrs, Atom.to_string(key), val)
    else
      Map.put(attrs, key, val)
    end
  end

  defp accumulate_storage_pinned_entry(entry, acc, holds) do
    local_state = normalize_state_atom(fetch_field(entry, :local_state))
    archive_state = normalize_state_atom(fetch_field(entry, :archive_state))
    media_bytes = max(0, int_or_zero(fetch_field(entry, :media_bytes)))
    q_bytes = max(0, int_or_zero(fetch_field(entry, :quarantined_bytes)))

    cond do
      local_state == :quarantined ->
        %{acc | p5: acc.p5 + q_bytes}

      local_state != :present ->
        acc

      archive_state in [
        :awaiting_binding,
        :pending,
        :failed_retryable,
        :failed_terminal,
        :deleting,
        :missing
      ] ->
        %{acc | p1: acc.p1 + media_bytes}

      true ->
        held? = Enum.any?(holds, &entry_protected_by_hold?(&1, entry))
        pinned_local? = held? and RecordingHolds.pinned_copy_for_entry(entry) == :local

        %{
          acc
          | kind_b: acc.kind_b + if(archive_state == :not_required, do: media_bytes, else: 0),
            held_kind_b:
              acc.held_kind_b +
                if(pinned_local? and archive_state == :not_required, do: media_bytes, else: 0),
            held_kind_a:
              acc.held_kind_a +
                if(pinned_local? and archive_state == :deleted, do: media_bytes, else: 0)
        }
    end
  end

  defp entry_protected_by_hold?(hold, entry) when is_map(hold) and is_map(entry) do
    normalized_hold =
      if is_nil(fetch_field(hold, :state)),
        do: Map.put(hold, :state, :accepted),
        else: hold

    RecordingHolds.hold_protects_entry?(normalized_hold, entry)
  end

  defp load_archive_settings(opts, loaders) do
    case Keyword.get(opts, :settings) do
      %RecordingArchiveSettings{} = s ->
        s

      _ ->
        case Map.get(loaders, :settings_loader) do
          loader when is_function(loader, 0) ->
            case loader.() do
              {:ok, %{} = s} -> s
              _ -> RecordingArchiveSettings.default_settings()
            end

          _ when map_size(loaders) > 0 ->
            RecordingArchiveSettings.default_settings()

          _ ->
            case RecordingArchiveSettings.get_settings(actor: @system_actor) do
              {:ok, s} -> s
              _ -> RecordingArchiveSettings.default_settings()
            end
        end
    end
  end

  defp load_storage_catalog_entries(storage_id, loaders) do
    case Map.get(loaders, :catalog_loader) do
      loader when is_function(loader, 1) ->
        unwrap_rows(loader.(storage_id))

      loader when is_function(loader, 0) ->
        loader.()
        |> unwrap_rows()
        |> Enum.filter(&(to_string(fetch_field(&1, :storage_id)) == to_string(storage_id)))

      _ when map_size(loaders) > 0 ->
        []

      _ ->
        RecordingCatalogEntry
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.filter(storage_id == ^storage_id and local_state in [:present, :quarantined])
        |> Ash.Query.select([
          :id,
          :camera_source_id,
          :stream_profile_id,
          :storage_id,
          :block_key,
          :timeline_start_us,
          :timeline_end_us,
          :local_state,
          :archive_state,
          :media_bytes,
          :quarantined_bytes
        ])
        |> Ash.read(actor: @system_actor)
        |> unwrap_rows()
    end
  end

  defp load_accepted_holds(loaders) do
    case Map.get(loaders, :holds_loader) do
      loader when is_function(loader, 0) ->
        unwrap_rows(loader.())

      _ when map_size(loaders) > 0 ->
        []

      _ ->
        RecordingHold
        |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
        |> Ash.Query.filter(state == :accepted)
        |> Ash.Query.select([
          :id,
          :camera_source_id,
          :stream_profile_id,
          :start_us,
          :end_us,
          :kind,
          :state,
          :unavailable_blocks
        ])
        |> Ash.read(actor: @system_actor)
        |> unwrap_rows()
    end
  end

  defp unwrap_rows({:ok, rows}) when is_list(rows), do: rows
  defp unwrap_rows(rows) when is_list(rows), do: rows
  defp unwrap_rows(_), do: []

  defp build_changeset_context(opts) do
    bounds =
      opts
      |> Keyword.take([
        :pinned_bytes,
        :install_ceiling_bytes,
        :install_reserve_bytes,
        :volume_capacity_bytes
      ])
      |> Map.new()

    context = %{storage_settings_bounds: bounds}

    case Keyword.get(opts, :loaders) do
      loaders when is_map(loaders) -> Map.put(context, :storage_settings_loaders, loaders)
      _ -> context
    end
  end

  defp authorize_manage(opts) do
    actor = resolve_actor(opts)

    cond do
      match?(%{role: :system}, actor) ->
        :ok

      ActorHasPermission.match?(actor, [permission: "settings.recording.manage"], %{}) ->
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
      nil -> opts |> Keyword.get(:scope) |> actor_from_scope()
      actor -> actor
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

  defp normalize_state_atom(val) when is_atom(val), do: val

  defp normalize_state_atom(val) when is_binary(val) do
    Enum.find(
      RecordingCatalogEntry.local_states() ++ RecordingCatalogEntry.archive_states(),
      &(Atom.to_string(&1) == val)
    )
  end

  defp normalize_state_atom(_), do: nil

  defp int_or_zero(val) when is_integer(val), do: val
  defp int_or_zero(val) when is_float(val), do: trunc(val)
  defp int_or_zero(_), do: 0

  defp fetch_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
