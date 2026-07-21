defmodule ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryRequest do
  @moduledoc """
  Immutable, secret-free authorization request for policy-owned legacy plugin
  assignment recovery.

  A request freezes only identifiers derived from the disabled legacy row and
  its initiating principal. It never stores assignment params, a partition,
  credentials, an access token, or a permission snapshot. The restricted
  executor must rebuild authorization and all current policy state before it
  materializes anything.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Plugins.Changes.PreparePolicyAssignmentRecoveryRequest
  alias ServiceRadar.Plugins.Checks.RecoveryRequestDispatcher
  alias ServiceRadar.Plugins.Checks.RecoveryRequestExecutor
  alias ServiceRadar.Plugins.Checks.RecoveryRequestLookup
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @plugin_manage_check {ActorHasPermission, permission: "settings.plugins.manage"}

  @statuses [
    :requested,
    :executing,
    :reconciled,
    :no_longer_eligible,
    :owner_not_authoritative,
    :identity_unavailable,
    :identity_changed,
    :package_unapproved,
    :schema_invalid,
    :conflict,
    :denied,
    :failed
  ]

  postgres do
    table "plugin_policy_assignment_recovery_requests"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :active_for_legacy, action: :active_for_legacy, args: [:legacy_assignment_id]
    define :latest_for_legacy, action: :latest_for_legacy, args: [:legacy_assignment_id]
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :active_for_legacy do
      argument :legacy_assignment_id, :uuid, allow_nil?: false

      filter expr(
               legacy_assignment_id == ^arg(:legacy_assignment_id) and
                 status in [:requested, :executing]
             )
    end

    read :latest_for_legacy do
      argument :legacy_assignment_id, :uuid, allow_nil?: false

      filter expr(legacy_assignment_id == ^arg(:legacy_assignment_id))
      prepare build(sort: [updated_at: :desc, inserted_at: :desc], limit: 1)
    end

    create :request do
      # This is the only caller-controlled recovery value. The custom change
      # reloads it and force-populates every other persisted identifier.
      accept [:legacy_assignment_id]

      argument :confirm, :boolean do
        allow_nil? false
        default false
      end

      change PreparePolicyAssignmentRecoveryRequest
    end
  end

  policies do
    # The individual-request read is executor-only. Claim/finish are dedicated
    # conditional SQL operations in `PolicyOwnedAssignmentRecovery.Lease`,
    # which independently require this same exact named actor. Do not replace
    # either boundary with `system_bypass/0`: an unrelated `%{role: :system}`
    # component must not inspect or mutate a recovery request.
    policy action(:by_id) do
      access_type :strict
      forbid_unless RecoveryRequestExecutor
      authorize_if RecoveryRequestExecutor
    end

    # The dispatcher only needs the generic read action to find pending work.
    # User-facing status access is mediated by a tenant-scoped legacy-assignment
    # lookup before the dedicated reader loads one redacted request. Do not let
    # a plugin manager enumerate this cross-resource table directly.
    policy action(:read) do
      access_type :strict
      forbid_unless RecoveryRequestDispatcher
      authorize_if RecoveryRequestDispatcher
    end

    policy action(:active_for_legacy) do
      access_type :strict
      forbid_unless RecoveryRequestLookup
      authorize_if RecoveryRequestLookup
    end

    policy action(:latest_for_legacy) do
      access_type :strict
      forbid_unless RecoveryRequestLookup
      authorize_if RecoveryRequestLookup
    end

    policy action(:request) do
      authorize_if @plugin_manage_check
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :legacy_assignment_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :legacy_agent_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :legacy_policy_id, :string do
      allow_nil? false
      public? true
    end

    attribute :legacy_plugin_package_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :owner_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:plugin_target_policy, :credential_rule]
    end

    attribute :owner_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :owner_purpose, :string do
      allow_nil? true
      public? true
      description "Package-declared credential purpose; nil for target-policy owners"
    end

    attribute :requested_by_principal_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:human, :service_principal]
    end

    attribute :requested_by_principal_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :requested_by_principal_owner_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :requested
      constraints one_of: @statuses
    end

    attribute :outcome_code, :string do
      allow_nil? true
      public? true
    end

    attribute :outcome_details, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :replacement_assignment_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      default []
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :lease_token, :uuid do
      allow_nil? true
      public? false
    end

    attribute :lease_expires_at, :utc_datetime_usec do
      allow_nil? true
      public? false
    end

    attribute :completed_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
