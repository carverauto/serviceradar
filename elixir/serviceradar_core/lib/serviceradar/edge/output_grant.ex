defmodule ServiceRadar.Edge.OutputGrant do
  @moduledoc """
  The standing edge-record authority of one passive output contract on one agent.

  One row per (agent, contract). It supplies the producer identity and fence the signed
  capability and the gateway agree on, exactly as a sweep producer assignment does for a sweep
  group:

    * `id` is the `producer_assignment_id`, and also the capability's `run_id` and `scope_id`;
    * `network_scope_id` is the agent's partition id; one spool carries exactly one scope;
    * `run_shard` is 0;
    * `authority_epoch` is the fence. It only moves up: `revoke` adds one atomically, and
      `reactivate` adds one before a revoked grant becomes active again, so an epoch is never
      reused and records signed before a revocation stay stale.

  Callers go through `ServiceRadar.Edge.OutputGrants`. Only the system actor writes these rows.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_output_grants"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read]

    create :create do
      accept [:agent_id, :contract_id, :network_scope_id]

      change set_attribute(:epoch_reason, :created)
    end

    update :revoke do
      description "Revoke a grant and fence every record of its old epochs"
      accept []

      change atomic_update(:authority_epoch, expr(authority_epoch + 1))
      change atomic_update(:epoch_changed_at, expr(now()))
      change set_attribute(:state, :revoked)
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
      change set_attribute(:epoch_reason, :revoked)
    end

    update :reactivate do
      description "Make a revoked grant, or one whose scope changed, active under a new epoch"
      accept [:network_scope_id]

      change atomic_update(:authority_epoch, expr(authority_epoch + 1))
      change atomic_update(:epoch_changed_at, expr(now()))
      change set_attribute(:state, :active)
      change set_attribute(:revoked_at, nil)
      change set_attribute(:epoch_reason, :reactivated)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :contract_id, :string do
      allow_nil? false
      public? true
    end

    attribute :network_scope_id, :uuid do
      allow_nil? false
      public? true
      description "The agent's partition id; one spool carries exactly one scope"
    end

    attribute :run_shard, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0, max: 4_294_967_295
    end

    attribute :authority_epoch, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1
      description "Fence generation; only ever increases"
    end

    attribute :state, :atom do
      allow_nil? false
      default :active
      public? true
      constraints one_of: [:active, :revoked]
    end

    attribute :epoch_reason, :atom do
      allow_nil? false
      default :created
      public? true
      constraints one_of: [:created, :revoked, :reactivated]
    end

    attribute :epoch_changed_at, :utc_datetime_usec do
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end

    attribute :revoked_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_agent_contract, [:agent_id, :contract_id]
  end
end
