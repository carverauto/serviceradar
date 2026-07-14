defmodule ServiceRadar.Automation.Ansible.AutomationMutationPhase do
  @moduledoc """
  Append-only authenticated mutation-phase evidence for an execution target.

  Rows use `automation.mutation_phase.v1` semantics. The lifecycle service is
  responsible for validating the transition graph and authenticated controller
  source before calling the system-only create action. The unique idempotency
  key makes byte-identical retries distinguishable from conflicting evidence.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  postgres do
    table "ansible_automation_mutation_phases"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_idempotency_key:
                           "ansible_automation_mutation_phases_idempotency_uidx",
                         unique_transaction_generation:
                           "ansible_automation_mutation_phases_transaction_generation_uidx"

    references do
      reference :execution_target, on_delete: :delete
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]

    define :get_by_idempotency_key,
      action: :by_idempotency_key,
      args: [:execution_target_id, :idempotency_key]

    define :list_for_target, action: :for_target, args: [:execution_target_id]
    define :record_authenticated, action: :record_authenticated
  end

  actions do
    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_idempotency_key do
      argument :execution_target_id, :uuid, allow_nil?: false
      argument :idempotency_key, :string, allow_nil?: false
      get? true

      filter expr(
               execution_target_id == ^arg(:execution_target_id) and
                 idempotency_key == ^arg(:idempotency_key)
             )
    end

    read :for_target do
      argument :execution_target_id, :uuid, allow_nil?: false
      filter expr(execution_target_id == ^arg(:execution_target_id))
      prepare build(sort: [generation: :asc, occurred_at: :asc, inserted_at: :asc])
    end

    create :record_authenticated do
      primary? true

      accept [
        :execution_target_id,
        :transaction_id,
        :generation,
        :idempotency_key,
        :previous_phase,
        :phase,
        :action,
        :template_id,
        :scm_revision,
        :policy_digest,
        :outcome_digest,
        :evidence_digest,
        :authenticated_source,
        :deadline_at,
        :occurred_at,
        :metadata
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :by_idempotency_key, :for_target], @view_check)
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :execution_target_id, :uuid, allow_nil?: false, public?: true
    attribute :transaction_id, :uuid, allow_nil?: false, public?: true

    attribute :generation, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :idempotency_key, :string, allow_nil?: false, public?: true

    attribute :previous_phase, :atom do
      allow_nil? true
      public? true

      constraints one_of: [
                    :initial,
                    :staged,
                    :verified,
                    :committed,
                    :rolled_back,
                    :critical,
                    :unknown
                  ]
    end

    attribute :phase, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :initial,
                    :staged,
                    :verified,
                    :committed,
                    :rolled_back,
                    :critical,
                    :unknown
                  ]
    end

    attribute :action, :string, allow_nil?: false, public?: true

    attribute :template_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :scm_revision, :string, allow_nil?: false, public?: true
    attribute :policy_digest, :string, allow_nil?: false, public?: true
    attribute :outcome_digest, :string, allow_nil?: false, public?: true
    attribute :evidence_digest, :string, allow_nil?: false, public?: true

    attribute :authenticated_source, :map do
      allow_nil? false
      public? false
      sensitive? true

      description "Controller/command authentication evidence with no reusable credential material"
    end

    attribute :deadline_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :execution_target, ServiceRadar.Automation.Ansible.AutomationExecutionTarget do
      define_attribute? false
      source_attribute :execution_target_id
      public? true
    end
  end

  identities do
    identity :unique_idempotency_key, [:execution_target_id, :idempotency_key]

    identity :unique_transaction_generation,
             [:execution_target_id, :transaction_id, :generation]
  end
end
