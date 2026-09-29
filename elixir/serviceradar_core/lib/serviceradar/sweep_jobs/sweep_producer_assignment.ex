defmodule ServiceRadar.SweepJobs.SweepProducerAssignment do
  @moduledoc """
  The durable edge-record authority of one sweep group on one agent.

  One row per (sweep group, agent). It supplies the producer identity and fence
  the signed capability and the gateway agree on:

    * `id` is the `producer_assignment_id`;
    * `network_scope_id` is the scope the agent's records are written under (the
      agent's partition id);
    * `run_shard` is 0 until sweeps are sharded;
    * `authority_epoch` is the fence. It only moves up: `bump_epoch` and `revoke`
      add one atomically, and `reactivate` adds one before an assignment that was
      revoked becomes active again, so an epoch is never reused.

  Callers go through `ServiceRadar.SweepJobs.ProducerAssignments`. Only the system
  actor writes these rows.
  """

  use Ash.Resource,
    domain: ServiceRadar.SweepJobs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "sweep_producer_assignments"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read]

    create :create do
      accept [:sweep_group_id, :agent_id, :network_scope_id]

      change set_attribute(:epoch_reason, :created)
    end

    update :bump_epoch do
      description "Add one to the authority epoch of an active assignment"
      accept []

      argument :reason, :atom do
        allow_nil? false
        default :target_changed
        constraints one_of: [:target_changed, :manual]
      end

      change atomic_update(:authority_epoch, expr(authority_epoch + 1))
      change atomic_update(:epoch_changed_at, expr(now()))
      change set_attribute(:epoch_reason, arg(:reason))
    end

    update :revoke do
      description "Revoke an assignment and fence every record of its old epochs"
      accept []

      change atomic_update(:authority_epoch, expr(authority_epoch + 1))
      change atomic_update(:epoch_changed_at, expr(now()))
      change set_attribute(:state, :revoked)
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
      change set_attribute(:epoch_reason, :revoked)
    end

    update :reactivate do
      description "Make a revoked assignment active again under a new epoch"
      accept [:network_scope_id]

      change atomic_update(:authority_epoch, expr(authority_epoch + 1))
      change atomic_update(:epoch_changed_at, expr(now()))
      change set_attribute(:state, :active)
      change set_attribute(:revoked_at, nil)
      change set_attribute(:epoch_reason, :reactivated)
    end

    read :for_group do
      argument :sweep_group_id, :uuid, allow_nil?: false
      filter expr(sweep_group_id == ^arg(:sweep_group_id))
    end

    read :active_for_agent do
      argument :agent_id, :string, allow_nil?: false
      filter expr(agent_id == ^arg(:agent_id) and state == :active)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :sweep_group_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :agent_id, :string do
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
      constraints one_of: [:created, :target_changed, :manual, :revoked, :reactivated]
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

  relationships do
    belongs_to :sweep_group, ServiceRadar.SweepJobs.SweepGroup do
      source_attribute :sweep_group_id
      destination_attribute :id
      define_attribute? false
    end
  end

  identities do
    identity :unique_group_agent, [:sweep_group_id, :agent_id]
  end
end
