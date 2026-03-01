defmodule ServiceRadar.Observability.MtrPolicy do
  @moduledoc """
  Policy resource for automated MTR baseline and incident dispatch behavior.

  Controls automated target selection cadence, protocol defaults, fanout bounds,
  cooldown windows, and consensus strategy.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mtr_policies"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  code_interface do
    define :list_enabled, action: :enabled
    define :create_policy, action: :create
    define :update_policy, action: :update
  end

  actions do
    defaults [:read, :destroy]

    read :enabled do
      filter expr(enabled == true)
    end

    create :create do
      accept [
        :name,
        :enabled,
        :scope,
        :partition_id,
        :target_selector,
        :baseline_interval_sec,
        :baseline_protocol,
        :baseline_canary_vantages,
        :incident_fanout_max_agents,
        :incident_cooldown_sec,
        :recovery_capture,
        :consensus_mode,
        :consensus_threshold,
        :consensus_min_agents
      ]
    end

    update :update do
      accept [
        :name,
        :enabled,
        :scope,
        :partition_id,
        :target_selector,
        :baseline_interval_sec,
        :baseline_protocol,
        :baseline_canary_vantages,
        :incident_fanout_max_agents,
        :incident_cooldown_sec,
        :recovery_capture,
        :consensus_mode,
        :consensus_threshold,
        :consensus_min_agents
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:create, :update, :destroy]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :scope, :string do
      allow_nil? false
      default "managed_devices"
      public? true
    end

    attribute :partition_id, :string do
      public? true
    end

    attribute :target_selector, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :baseline_interval_sec, :integer do
      allow_nil? false
      default 300
      public? true
      constraints min: 30
    end

    attribute :baseline_protocol, :string do
      allow_nil? false
      default "icmp"
      public? true
    end

    attribute :baseline_canary_vantages, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :incident_fanout_max_agents, :integer do
      allow_nil? false
      default 3
      public? true
      constraints min: 1, max: 10
    end

    attribute :incident_cooldown_sec, :integer do
      allow_nil? false
      default 600
      public? true
      constraints min: 30
    end

    attribute :recovery_capture, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :consensus_mode, :string do
      allow_nil? false
      default "majority"
      public? true
    end

    attribute :consensus_threshold, :float do
      allow_nil? false
      default 0.66
      public? true
      constraints min: 0.0, max: 1.0
    end

    attribute :consensus_min_agents, :integer do
      allow_nil? false
      default 2
      public? true
      constraints min: 1
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end
end
