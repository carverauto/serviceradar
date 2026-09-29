defmodule ServiceRadar.SweepJobs.SweepExecutionSlot do
  @moduledoc """
  One pre-minted execution of a schedule lease.

  Core mints the execution before it runs: `id` is the `execution_id`, a UUIDv7 whose time
  is the slot start, and the row keeps the collection window, the fence (`authority_epoch`)
  it was planned under, and the plan a source authorization binds (`plan_header` and
  `plan_pages` are the protobuf-encoded `ScheduledPlanHeaderV1` and pages). The results
  ingest creates the `SweepGroupExecution` under the same id when the results arrive.

  A slot that will not run any more (its assignment was revoked, or the group became
  ineligible) is `:dropped`, not deleted, so what was planned stays inspectable.

  Callers go through `ServiceRadar.SweepJobs.ExecutionSlots`. Only the system actor writes.
  """

  use Ash.Resource,
    domain: ServiceRadar.SweepJobs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @schedule_fields [
    :id,
    :sweep_group_id,
    :agent_id,
    :producer_assignment_id,
    :network_scope_id,
    :authority_epoch,
    :lease_id,
    :slot_start,
    :collection_expires,
    :plan_id,
    :plan_sha256,
    :check_set_sha256,
    :plan_header,
    :plan_pages
  ]

  postgres do
    table "sweep_execution_slots"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read]

    create :schedule do
      description "Record a pre-minted execution of a lease"
      accept @schedule_fields
    end

    update :drop do
      description "Withdraw a slot that will not run"
      accept []

      change set_attribute(:state, :dropped)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true

    attribute :sweep_group_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :producer_assignment_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :network_scope_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :authority_epoch, :integer do
      allow_nil? false
      public? true
      constraints min: 1
      description "The assignment's fence when this slot was planned"
    end

    attribute :lease_id, :uuid do
      allow_nil? false
      public? true
      description "The lease (the record's run_id) the slot belongs to"
    end

    attribute :slot_start, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :collection_expires, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "End of the slot's collection window"
    end

    attribute :state, :atom do
      allow_nil? false
      default :scheduled
      public? true
      constraints one_of: [:scheduled, :dropped]
    end

    attribute :plan_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :plan_sha256, :binary do
      allow_nil? false
      public? true
      description "The plan header digest: execution_plan_sha256"
    end

    attribute :check_set_sha256, :binary do
      allow_nil? false
      public? true
    end

    attribute :plan_header, :binary do
      allow_nil? false
      public? true
    end

    attribute :plan_pages, {:array, :binary} do
      allow_nil? false
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

    belongs_to :producer_assignment, ServiceRadar.SweepJobs.SweepProducerAssignment do
      source_attribute :producer_assignment_id
      destination_attribute :id
      define_attribute? false
    end
  end

  identities do
    identity :unique_assignment_slot, [:producer_assignment_id, :slot_start]
  end
end
