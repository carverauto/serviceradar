defmodule ServiceRadar.Scans.ScanPolicySettings do
  @moduledoc """
  Instance-level policy for ad-hoc scans.

  Singleton (`key == "default"`). Holds the inventory-scoping guardrail: when
  `restrict_to_inventory` is enabled, scan requests may only target IPs that
  already exist in the device inventory. Managed by users with `scans.manage`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Scans,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @scans_manage_check {ActorHasPermission, permission: "scans.manage"}

  @settings_fields [:restrict_to_inventory]

  postgres do
    table "scan_policy_settings"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_settings, action: :get_singleton
    define :create_settings, action: :create
    define :update_settings, action: :update
  end

  actions do
    defaults [:read]

    read :get_singleton do
      description "Get the singleton scan policy settings"
      get? true
      filter expr(key == "default")
    end

    create :create do
      description "Create scan policy settings"
      accept @settings_fields
      change set_attribute(:key, "default")
    end

    update :update do
      description "Update scan policy settings"
      accept @settings_fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_operator_plus()
    action_with_permission([:create, :update], @scans_manage_check)
  end

  attributes do
    attribute :key, :string do
      allow_nil? false
      default "default"
      primary_key? true
      public? false
    end

    attribute :restrict_to_inventory, :boolean do
      allow_nil? false
      default false
      public? true
      description "When enabled, only IPs already in inventory may be scanned"
    end

    timestamps()
  end
end
