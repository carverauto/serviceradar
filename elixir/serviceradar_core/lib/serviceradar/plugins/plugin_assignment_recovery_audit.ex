defmodule ServiceRadar.Plugins.PluginAssignmentRecoveryAudit do
  @moduledoc """
  Immutable, redacted decisions made while recovering partition-unbound plugin
  assignments.

  This resource intentionally records identifiers and typed outcomes only. It
  never stores assignment parameters, secret references, encrypted material, or
  error text returned by an adapter.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Plugins.Checks.RecoveryAuditLookup
  alias ServiceRadar.Plugins.Checks.RecoveryAuditWriter

  @audit_fields [
    :legacy_assignment_id,
    :replacement_assignment_id,
    :actor_id,
    :actor_type,
    :agent_uid,
    :authenticated_agent_id,
    :authenticated_partition_id,
    :outcome,
    :reason
  ]

  postgres do
    table "plugin_assignment_recovery_audits"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    read :for_legacy_assignment do
      argument :legacy_assignment_id, :uuid, allow_nil?: false
      filter expr(legacy_assignment_id == ^arg(:legacy_assignment_id))
      prepare build(sort: [occurred_at: :desc])
    end

    # Recovery is the only trusted producer of these rows. Its internal writer
    # uses a named SystemActor after it has authorized the initiating human/API
    # principal and derived every value itself. Do not add a user-facing create
    # action: a forged `:recovered` row would corrupt retry idempotency.
    create :record_recovery do
      accept @audit_fields

      change set_attribute(:occurred_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # Recovery audits contain identifiers and evidence that are broader than
    # the secret-free recovery projection. A plugin manager must not enumerate
    # them by guessed legacy IDs. `PluginAssignmentRecovery.legacy_detail/2`
    # first authorizes the exact legacy row, then uses the named lookup actor
    # to project only an allowlisted completion state.
    policy action_type(:read) do
      access_type :strict
      forbid_unless RecoveryAuditLookup
      authorize_if RecoveryAuditLookup
    end

    # Only recovery's exact dedicated internal writer may make immutable
    # decisions. This deliberately does not use `system_bypass/0`, so another
    # system component cannot accidentally inherit recovery-audit authority.
    policy action(:record_recovery) do
      authorize_if RecoveryAuditWriter
    end
  end

  attributes do
    uuid_primary_key :id

    # These are intentionally IDs rather than relationships. Recovery evidence
    # must remain explainable even after normal assignment retention/deletion.
    attribute :legacy_assignment_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :replacement_assignment_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :actor_id, :string do
      allow_nil? false
      public? true
    end

    attribute :actor_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:user, :api_token, :service]
    end

    attribute :agent_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :authenticated_agent_id, :string do
      allow_nil? true
      public? true
    end

    attribute :authenticated_partition_id, :string do
      allow_nil? true
      public? true
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :recovered,
                    :rejected,
                    :conflict,
                    :evidence_unavailable,
                    :identity_mismatch,
                    :schema_invalid,
                    :package_unavailable
                  ]
    end

    attribute :reason, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :reapproved,
                    :already_recovered,
                    :confirmation_required,
                    :not_legacy_unbound,
                    :policy_assignment_requires_reconciliation,
                    :authenticated_agent_partition_unavailable,
                    :authenticated_agent_partition_mismatch,
                    :authenticated_agent_partition_changed,
                    :active_assignment_conflict,
                    :bound_manual_assignment_conflict,
                    :plugin_package_not_found,
                    :plugin_package_not_approved,
                    :plugin_package_not_trusted,
                    :params_not_recoverable,
                    :assignment_create_failed
                  ]
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
  end
end
