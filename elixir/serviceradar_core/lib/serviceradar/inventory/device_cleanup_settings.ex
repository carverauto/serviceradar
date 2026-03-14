defmodule ServiceRadar.Inventory.DeviceCleanupSettings do
  @moduledoc """
  Instance-level settings for device cleanup retention.

  This resource stores the retention window and schedule used by the
  device cleanup worker to purge tombstoned devices.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "device_cleanup_settings"
    repo ServiceRadar.Repo
    schema "platform"
  end

  json_api do
    type "device_cleanup_settings"

    routes do
      base "/device-cleanup-settings"

      get :get_singleton, route: "/"
      post :create
      patch :update
    end
  end

  code_interface do
    define :get_settings, action: :get_singleton
    define :create_settings, action: :create
    define :update_settings, action: :update
    define :run_cleanup, action: :run_cleanup
  end

  actions do
    defaults [:read]

    read :get_singleton do
      description "Get the singleton cleanup settings"
      get? true
      filter expr(key == "default")
    end

    create :create do
      description "Create device cleanup settings"
      accept [:retention_days, :cleanup_interval_minutes, :batch_size, :enabled]
      change set_attribute(:key, "default")
    end

    update :update do
      description "Update device cleanup settings"
      accept [:retention_days, :cleanup_interval_minutes, :batch_size, :enabled]
    end

    action :run_cleanup do
      description "Enqueue an immediate device cleanup run"

      run fn _input, context ->
        actor = context[:actor]

        case ServiceRadar.Inventory.DeviceCleanupWorker.enqueue_manual(actor) do
          {:ok, _job} -> {:ok, %{scheduled: true}}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_operator_plus()
    operator_action([:create, :update, :run_cleanup])
  end

  attributes do
    attribute :key, :string do
      allow_nil? false
      default "default"
      primary_key? true
      public? false
    end

    attribute :retention_days, :integer do
      allow_nil? false
      default 30
      public? true
      constraints min: 1, max: 3650
      description "Number of days to keep soft-deleted devices before purging"
    end

    attribute :cleanup_interval_minutes, :integer do
      allow_nil? false
      default 1_440
      public? true
      constraints min: 5, max: 43_200
      description "How often to run device cleanup (minutes)"
    end

    attribute :batch_size, :integer do
      allow_nil? false
      default 1_000
      public? true
      constraints min: 100, max: 50_000
      description "Batch size for device cleanup deletes"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
      description "Whether device cleanup scheduling is enabled"
    end

    timestamps()
  end
end
