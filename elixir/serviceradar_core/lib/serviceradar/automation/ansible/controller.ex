defmodule ServiceRadar.Automation.Ansible.Controller do
  @moduledoc """
  AWX/AAP controller registration.

  Holds the `base_url`, the `agent_id` of the ServiceRadar agent that can reach
  the controller's network, a reference to a `NetworkCredentialSecret` holding
  the AWX API token, and tunable sync intervals. The token itself is held by
  the credential broker (the same mechanism proxmox/unifi use today); this
  resource carries only the secret reference. Short-lived broker grants are
  minted at dispatch time and embedded in `CommandRequest`s flowing through
  `AgentCommandBus`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Automation.Ansible.Changes.SeedControllerLifecycle
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_check {ActorHasPermission, permission: "ansible.controllers.manage"}

  @public_fields [
    :name,
    :description,
    :base_url,
    :awx_version,
    :agent_id,
    :credential_secret_id,
    :inventory_sync_interval_seconds,
    :catalog_sync_interval_seconds,
    :run_pulse_interval_ms,
    :status,
    :last_health_at,
    :last_health_summary,
    :metadata
  ]

  @public_read_fields [:id, :inserted_at, :updated_at | @public_fields]

  postgres do
    table "ansible_controllers"
    repo ServiceRadar.Repo
    schema "platform"
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "ansible_controller_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at, :last_health_at, :last_health_summary]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_agent, action: :by_agent, args: [:agent_id]
    define :create_controller, action: :create
    define :update_controller, action: :update
    define :destroy_controller, action: :destroy
    define :record_health, action: :record_health
  end

  actions do
    destroy :destroy do
      change {SeedControllerLifecycle, mode: :teardown}
    end

    read :read do
      prepare build(select: @public_read_fields)
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: @public_read_fields)
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false
      filter expr(agent_id == ^arg(:agent_id))
      prepare build(select: @public_read_fields)
    end

    create :create do
      accept [
        :name,
        :description,
        :base_url,
        :awx_version,
        :agent_id,
        :credential_secret_id,
        :inventory_sync_interval_seconds,
        :catalog_sync_interval_seconds,
        :run_pulse_interval_ms,
        :metadata
      ]

      change SeedControllerLifecycle
    end

    update :update do
      accept [
        :name,
        :description,
        :base_url,
        :awx_version,
        :agent_id,
        :credential_secret_id,
        :inventory_sync_interval_seconds,
        :catalog_sync_interval_seconds,
        :run_pulse_interval_ms,
        :metadata
      ]

      change SeedControllerLifecycle
    end

    update :record_health do
      description "Bus-driven health update from the awx.ping verb result"
      accept [:status, :awx_version, :last_health_summary]
      change set_attribute(:last_health_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :by_agent], @manage_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
    action_with_permission([:record_health], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Operator-facing controller name (unique)"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :base_url, :string do
      allow_nil? false
      public? true
      description "AWX/AAP base URL, e.g. https://awx.internal.example.com"
    end

    attribute :awx_version, :string do
      allow_nil? true
      public? true
      description "AWX version string reported by /api/v2/ping/"
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
      description "ID of the ServiceRadar agent that can reach this controller's network"
    end

    attribute :credential_secret_id, :uuid do
      allow_nil? false
      public? true
      description "ID of the NetworkCredentialSecret holding the AWX API token"
    end

    attribute :inventory_sync_interval_seconds, :integer do
      allow_nil? false
      public? true
      default 300
      constraints min: 30
      description "Cadence for the awx plugin's inventory_sync scheduled assignment"
    end

    attribute :catalog_sync_interval_seconds, :integer do
      allow_nil? false
      public? true
      default 600
      constraints min: 60
      description "Cadence for AwxCatalogSyncWorker (mirrors AWX Job Templates)"
    end

    attribute :run_pulse_interval_ms, :integer do
      allow_nil? false
      public? true
      default 2000
      constraints min: 250, max: 60_000
      description "Cadence for RunPulseWorker; lower = lower latency, higher AWX API load"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :unknown
      constraints one_of: [:unknown, :ok, :degraded, :unreachable, :unauthorized]
      description "Last-known health derived from awx.ping responses"
    end

    attribute :last_health_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Wall-clock time of the last successful or failed awx.ping"
    end

    attribute :last_health_summary, :string do
      allow_nil? true
      public? true
      description "Operator-safe summary of the last health-check result"
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end
end
