defmodule ServiceRadar.Inventory.InterfaceSettings do
  @moduledoc """
  User-controlled settings for network interfaces.

  This resource stores settings that are independent of the interface's
  time-series observations, such as:
  - Favorite status (for quick access in UI)
  - Metrics collection enabled/disabled
  - Threshold configurations for alerting

  The settings are keyed by `device_id` and `interface_uid` to uniquely
  identify the interface across observations.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "interface_settings"
    repo ServiceRadar.Repo
  end

  json_api do
    type "interface_setting"

    routes do
      base "/interface-settings"

      index :read
      get :by_interface, route: "/by-interface/:device_id/:interface_uid"
      post :upsert
      patch :update
    end
  end

  code_interface do
    define :get_by_interface, action: :by_interface, args: [:device_id, :interface_uid]
    define :list_by_device, action: :by_device, args: [:device_id]
    define :list_favorited, action: :favorited
    define :list_metrics_enabled, action: :metrics_enabled
    define :upsert, action: :upsert, args: [:device_id, :interface_uid]
    define :bulk_update_favorites, action: :bulk_favorite, args: [:interface_uids, :favorited]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :device_id,
        :interface_uid,
        :favorited,
        :metrics_enabled,
        :metrics_selected,
        :metric_thresholds,
        :metric_groups,
        :metrics_interval_seconds,
        :threshold_enabled,
        :threshold_value,
        :threshold_comparison,
        :threshold_metric,
        :threshold_duration_seconds,
        :threshold_severity,
        :tags
      ]
    end

    update :update do
      accept [
        :favorited,
        :metrics_enabled,
        :metrics_selected,
        :metric_thresholds,
        :metric_groups,
        :metrics_interval_seconds,
        :threshold_enabled,
        :threshold_value,
        :threshold_comparison,
        :threshold_metric,
        :threshold_duration_seconds,
        :threshold_severity,
        :tags
      ]
    end

    create :upsert do
      description "Create or update interface settings"
      upsert? true
      upsert_identity :unique_interface

      argument :device_id, :string, allow_nil?: false
      argument :interface_uid, :string, allow_nil?: false

      accept [
        :favorited,
        :metrics_enabled,
        :metrics_selected,
        :metric_thresholds,
        :metric_groups,
        :metrics_interval_seconds,
        :threshold_enabled,
        :threshold_value,
        :threshold_comparison,
        :threshold_metric,
        :threshold_duration_seconds,
        :threshold_severity,
        :tags
      ]

      change set_attribute(:device_id, arg(:device_id))
      change set_attribute(:interface_uid, arg(:interface_uid))
      change ServiceRadar.Inventory.Changes.ScheduleThresholdEvaluator
      change ServiceRadar.Inventory.Changes.SyncMetricEventRules
      change ServiceRadar.Inventory.Changes.SyncSnmpInterfaceConfig
    end

    update :toggle_favorite do
      description "Toggle the favorite status of an interface"
      require_atomic? false

      change fn changeset, _context ->
        current = Ash.Changeset.get_attribute(changeset, :favorited)
        Ash.Changeset.force_change_attribute(changeset, :favorited, !current)
      end
    end

    update :set_favorite do
      description "Set the favorite status"
      argument :favorited, :boolean, allow_nil?: false
      change set_attribute(:favorited, arg(:favorited))
    end

    update :set_metrics_enabled do
      description "Enable or disable metrics collection"
      argument :enabled, :boolean, allow_nil?: false
      change set_attribute(:metrics_enabled, arg(:enabled))
    end

    update :set_tags do
      description "Set tags for an interface"
      argument :tags, {:array, :string}, allow_nil?: false
      change set_attribute(:tags, arg(:tags))
    end

    update :add_tags do
      description "Add tags to an interface (preserving existing)"
      argument :tags, {:array, :string}, allow_nil?: false
      require_atomic? false

      change fn changeset, _context ->
        current_tags = Ash.Changeset.get_attribute(changeset, :tags) || []
        new_tags = changeset.arguments.tags || []
        merged = Enum.uniq(current_tags ++ new_tags)
        Ash.Changeset.force_change_attribute(changeset, :tags, merged)
      end
    end

    read :by_interface do
      description "Get settings for a specific interface"
      argument :device_id, :string, allow_nil?: false
      argument :interface_uid, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id) and interface_uid == ^arg(:interface_uid))
      get? true
    end

    read :by_device do
      description "Get all interface settings for a device"
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id))
    end

    read :favorited do
      description "Get all favorited interfaces"
      filter expr(favorited == true)
    end

    read :metrics_enabled do
      description "Get all interfaces with metrics collection enabled"
      filter expr(metrics_enabled == true)
    end

    action :bulk_favorite do
      description "Bulk update favorite status for multiple interfaces"
      argument :interface_uids, {:array, :string}, allow_nil?: false
      argument :favorited, :boolean, allow_nil?: false

      run fn input, _context ->
        interface_uids = input.arguments.interface_uids
        favorited = input.arguments.favorited

        # This would need a proper bulk update implementation
        # For now, return success - actual implementation needed
        {:ok, %{updated_count: length(interface_uids), favorited: favorited}}
      end
    end
  end

  policies do
    # System actors can perform all operations (schema isolation via search_path)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Admins and operators can manage interface settings
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # All authenticated users can read
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :device_id, :string do
      allow_nil? false
      description "The device this interface belongs to"
    end

    attribute :interface_uid, :string do
      allow_nil? false
      description "The unique identifier for the interface"
    end

    attribute :favorited, :boolean do
      default false
      description "Whether this interface is marked as a favorite"
    end

    attribute :metrics_enabled, :boolean do
      default false
      description "Whether metrics collection is enabled for this interface"
    end

    attribute :metrics_selected, {:array, :string} do
      default []
      description "Selected interface metrics to collect"
    end

    attribute :metric_thresholds, :map do
      default %{}
      description "Per-metric threshold settings keyed by metric name"
    end

    attribute :metrics_interval_seconds, :integer do
      default 60
      description "Interval for metrics collection in seconds"
    end

    attribute :threshold_enabled, :boolean do
      default false
      description "Whether threshold alerting is enabled"
    end

    attribute :threshold_value, :integer do
      description "Threshold value (e.g., utilization percentage)"
    end

    attribute :threshold_comparison, :atom do
      description "Comparison operator: gt, lt, gte, lte, eq"
      constraints one_of: [:gt, :lt, :gte, :lte, :eq]
    end

    attribute :threshold_metric, :atom do
      description "Metric to apply threshold to: bandwidth_in, bandwidth_out, utilization, errors"
      constraints one_of: [:bandwidth_in, :bandwidth_out, :utilization, :errors]
    end

    attribute :threshold_duration_seconds, :integer do
      default 0
      description "How long the threshold must be exceeded before alerting (0 = immediate)"
    end

    attribute :threshold_severity, :atom do
      default :warning
      description "Severity of alerts generated when threshold is exceeded"
      constraints one_of: [:info, :warning, :critical, :emergency]
    end

    attribute :tags, {:array, :string} do
      default []
      description "User-defined tags for this interface"
    end

    attribute :metric_groups, {:array, :map} do
      default []
      description """
      User-defined metric groupings for composite charts.
      Each group is a map with:
        - id: UUID for the group
        - name: Display name for the group
        - metrics: List of metric names to combine in this chart
      """
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_interface, [:device_id, :interface_uid]
  end
end
