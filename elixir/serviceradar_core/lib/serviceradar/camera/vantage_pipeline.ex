defmodule ServiceRadar.Camera.VantagePipeline do
  @moduledoc """
  Declarative Vantage ML pipeline definition (`platform.camera_vantage_pipelines`)
  specifying camera targeting, Stage 1 / sealed-block / live-tap triggers,
  ROI masks, bounding-box crop policy, rate budgets, runner capability,
  `signal_schema`, and `display_contract`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Camera.Validations.VantageCapability
  alias ServiceRadar.Camera.Validations.VantageSignalSchema
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @pipeline_id_pattern ~r/\A[a-z][a-z0-9-]*(\.[a-z0-9][a-z0-9._-]*)+\z/
  @capability_regex ~r/\A[a-z0-9][a-z0-9._-]{0,127}\z/
  @source_modes [:recorded_block, :live_keyframe_tap]
  @trigger_kinds [:on_sealed_block, :on_stage1_detection, :live_keyframe_tap]
  @input_modes [:full_frame, :detection_crop, :multi_frame_track]
  @runners [:camera_vlm, :external_worker]

  @default_crop_policy %{
    "padding_ratio" => 0.15,
    "min_bbox_width_px" => 96,
    "max_dimension" => 640,
    "max_bytes" => 98_304
  }

  @mutable_fields [
    :name,
    :description,
    :enabled,
    :source_mode,
    :trigger_kind,
    :camera_selector,
    :object_classes,
    :min_confidence,
    :roi_polygons,
    :input_mode,
    :crop_policy,
    :max_jobs_per_minute,
    :max_frames_per_track,
    :runner,
    :capability,
    :fallback_runner,
    :vlm_config,
    :signal_schema_id,
    :signal_schema_version,
    :signal_schema,
    :display_contract_id,
    :display_contract,
    :emit_ocsf_events,
    :live_observation_retention_days,
    :pack_id,
    :pack_version,
    :managed,
    :template_fingerprint,
    :parameter_overrides
  ]

  @all_fields [:pipeline_id, :version | @mutable_fields]

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @footage_view_check {ActorHasPermission, permission: "devices.cameras.recordings.view"}
  @catalog_view_check {ActorHasPermission, permission: "catalog.view"}
  @pack_install_check {ActorHasPermission, permission: "catalog.packs.install"}

  postgres do
    table "camera_vantage_pipelines"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names unique_pipeline_version: "camera_vantage_pipelines_pipeline_version_uidx"

    custom_indexes do
      index [:enabled, :source_mode, :trigger_kind],
        name: "camera_vantage_pipelines_active_trigger_idx",
        where: "enabled = true"

      index [:pack_id],
        name: "camera_vantage_pipelines_pack_id_idx",
        where: "pack_id IS NOT NULL"
    end

    check_constraints do
      check_constraint :pipeline_id, "camera_vantage_pipelines_valid",
        check: """
        btrim(pipeline_id) <> '' AND
        btrim(version) <> '' AND
        btrim(name) <> '' AND
        source_mode IN ('recorded_block', 'live_keyframe_tap') AND
        trigger_kind IN ('on_sealed_block', 'on_stage1_detection', 'live_keyframe_tap') AND
        input_mode IN ('full_frame', 'detection_crop', 'multi_frame_track') AND
        runner IN ('camera_vlm', 'external_worker') AND
        max_jobs_per_minute >= 1 AND
        max_frames_per_track >= 1 AND
        live_observation_retention_days >= 1 AND
        btrim(signal_schema_id) <> '' AND
        btrim(signal_schema_version) <> '' AND
        btrim(display_contract_id) <> '' AND
        (min_confidence IS NULL OR (min_confidence >= 0.0 AND min_confidence <= 1.0))
        """
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_pipeline_version, action: :by_pipeline_version, args: [:pipeline_id, :version]
    define :list_enabled_for_trigger, action: :enabled_for_trigger, args: [:trigger_kind]
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_pipeline_version do
      argument :pipeline_id, :string, allow_nil?: false
      argument :version, :string, allow_nil?: false
      get? true
      filter expr(pipeline_id == ^arg(:pipeline_id) and version == ^arg(:version))
    end

    read :enabled_for_trigger do
      argument :trigger_kind, :atom, allow_nil?: false
      filter expr(enabled == true and trigger_kind == ^arg(:trigger_kind))
    end

    create :create do
      primary? true
      accept @all_fields

      validate {VantageSignalSchema, []}
      validate {VantageCapability, []}

      validate present([
                 :pipeline_id,
                 :version,
                 :name,
                 :signal_schema_id,
                 :signal_schema_version,
                 :display_contract_id
               ])
    end

    create :upsert do
      accept @all_fields
      upsert? true
      upsert_identity :unique_pipeline_version
      upsert_fields @mutable_fields ++ [:updated_at]

      validate {VantageSignalSchema, []}
      validate {VantageCapability, []}

      validate present([
                 :pipeline_id,
                 :version,
                 :name,
                 :signal_schema_id,
                 :signal_schema_version,
                 :display_contract_id
               ])
    end

    update :update do
      primary? true
      accept @mutable_fields

      validate {VantageSignalSchema, []}
      validate {VantageCapability, []}
    end

    update :set_enabled do
      accept [:enabled]
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
      authorize_if @catalog_view_check
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
      authorize_if @pack_install_check
      authorize_if @manage_check
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :pipeline_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 255, match: @pipeline_id_pattern
    end

    attribute :version, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 4096
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :source_mode, :atom do
      allow_nil? false
      default :recorded_block
      public? true
      constraints one_of: @source_modes
    end

    attribute :trigger_kind, :atom do
      allow_nil? false
      default :on_stage1_detection
      public? true
      constraints one_of: @trigger_kinds
    end

    attribute :camera_selector, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :object_classes, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :min_confidence, :float do
      allow_nil? true
      public? true
      constraints min: 0.0, max: 1.0
    end

    attribute :roi_polygons, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :input_mode, :atom do
      allow_nil? false
      default :detection_crop
      public? true
      constraints one_of: @input_modes
    end

    attribute :crop_policy, :map do
      allow_nil? false
      default @default_crop_policy
      public? true
    end

    attribute :max_jobs_per_minute, :integer do
      allow_nil? false
      default 60
      public? true
      constraints min: 1
    end

    attribute :max_frames_per_track, :integer do
      allow_nil? false
      default 3
      public? true
      constraints min: 1, max: 32
    end

    attribute :runner, :atom do
      allow_nil? false
      default :camera_vlm
      public? true
      constraints one_of: @runners
    end

    attribute :capability, :string do
      allow_nil? true
      public? true
      constraints max_length: 128, match: @capability_regex
    end

    attribute :fallback_runner, :string do
      allow_nil? true
      public? true
      constraints max_length: 64
    end

    attribute :vlm_config, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :signal_schema_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :signal_schema_version, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :signal_schema, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :display_contract_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :display_contract, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :emit_ocsf_events, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :live_observation_retention_days, :integer do
      allow_nil? false
      default 30
      public? true
      constraints min: 1, max: 3650
    end

    attribute :pack_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
    end

    attribute :pack_version, :string do
      allow_nil? true
      public? true
      constraints max_length: 64
    end

    attribute :managed, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :template_fingerprint, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :parameter_overrides, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  identities do
    identity :unique_pipeline_version, [:pipeline_id, :version]
  end

  @doc "Allowed `source_mode` values (`:recorded_block | :live_keyframe_tap`)."
  @spec source_modes() :: [atom()]
  def source_modes, do: @source_modes

  @doc "Allowed `trigger_kind` values."
  @spec trigger_kinds() :: [atom()]
  def trigger_kinds, do: @trigger_kinds

  @doc "Allowed `input_mode` values."
  @spec input_modes() :: [atom()]
  def input_modes, do: @input_modes

  @doc "Allowed `runner` values."
  @spec runners() :: [atom()]
  def runners, do: @runners

  @doc "Capability identifier regex (`^[a-z0-9][a-z0-9._-]{0,127}$`)."
  @spec capability_regex() :: Regex.t()
  def capability_regex, do: @capability_regex

  @doc "Returns `true` when `capability` is a valid non-empty capability token."
  @spec valid_capability?(term()) :: boolean()
  def valid_capability?(capability) when is_binary(capability),
    do: Regex.match?(@capability_regex, capability)

  def valid_capability?(_), do: false

  @doc """
  Resolves the effective `pipeline_config` map from a `VantagePipeline` struct
  or plain-map stub.

  Unwraps `Reconciler`'s `%{"config" => ..., "enabled" => ...}` wrapper when
  present, drops the `"enabled"` reconciler meta-flag if present alone, and falls
  back to `:pipeline_config` on plain-map stubs.
  """
  @spec effective_pipeline_config(map() | nil) :: map()
  def effective_pipeline_config(nil), do: %{}

  def effective_pipeline_config(pipeline) when is_map(pipeline) do
    normalized_overrides =
      pipeline
      |> fetch_map_field(:parameter_overrides)
      |> unwrap_parameter_overrides()

    direct_config = fetch_map_field(pipeline, :pipeline_config)

    cond do
      map_size(normalized_overrides) > 0 and map_size(direct_config) > 0 ->
        Map.merge(direct_config, normalized_overrides)

      map_size(normalized_overrides) > 0 ->
        normalized_overrides

      true ->
        direct_config
    end
  end

  def effective_pipeline_config(_), do: %{}

  defp unwrap_parameter_overrides(overrides) when is_map(overrides) and map_size(overrides) > 0 do
    if Map.drop(overrides, ["config", "enabled"]) == %{} do
      case Map.get(overrides, "config") do
        cfg when is_map(cfg) -> cfg
        _ -> %{}
      end
    else
      overrides
    end
  end

  defp unwrap_parameter_overrides(_), do: %{}

  defp fetch_map_field(map, key) when is_map(map) do
    val =
      case Map.fetch(map, key) do
        {:ok, v} -> v
        :error -> Map.get(map, Atom.to_string(key))
      end

    if is_map(val) and not is_struct(val), do: val, else: %{}
  end
end
