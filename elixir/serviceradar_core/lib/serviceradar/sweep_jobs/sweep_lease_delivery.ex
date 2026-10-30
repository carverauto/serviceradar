defmodule ServiceRadar.SweepJobs.SweepLeaseDelivery do
  @moduledoc """
  What core has delivered of one assignment's sweep schedule lease, and the agent's
  acknowledgement of that push. `delivered_window_end` is the cursor, just after the last
  slot pushed. `delivered_high_water` is the furthest window end sent for the current lease.
  The row outlives the assignment and the group. `ServiceRadar.SweepJobs.LeaseDelivery` is
  the only writer.
  """

  use Ash.Resource,
    domain: ServiceRadar.SweepJobs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @push_fields [
    :producer_assignment_id,
    :sweep_group_id,
    :agent_id,
    :lease_id,
    :lease_issued_at,
    :delivered_window_end,
    :delivered_high_water,
    :delivered_payload_sha256,
    :delivered_at,
    :ack_pending_since,
    :revoked_at
  ]

  @ack_fields [
    :acked_payload_sha256,
    :ack_installed,
    :ack_error,
    :acked_through,
    :acked_slot_count,
    :acked_at
  ]

  postgres do
    table "sweep_lease_deliveries"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :record_push do
      description "Record a lease push the agent's session accepted"
      accept @push_fields
      upsert? true
      upsert_identity :assignment

      upsert_fields [
        :lease_id,
        :lease_issued_at,
        :delivered_window_end,
        :delivered_high_water,
        :delivered_payload_sha256,
        :delivered_at,
        :ack_pending_since,
        :revoked_at,
        :updated_at
      ]
    end

    update :record_revocation do
      accept [:delivered_payload_sha256, :delivered_at, :ack_pending_since, :revoked_at]
    end

    update :record_ack do
      description "Record the agent's answer to a lease push"
      accept @ack_fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    attribute :producer_assignment_id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :sweep_group_id, :uuid, allow_nil?: false, public?: true
    attribute :agent_id, :string, allow_nil?: false, public?: true
    attribute :lease_id, :uuid, allow_nil?: false, public?: true
    attribute :lease_issued_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :delivered_window_end, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :delivered_high_water, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :delivered_payload_sha256, :string, allow_nil?: false, public?: true
    attribute :delivered_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :ack_pending_since, :utc_datetime_usec, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true
    attribute :acked_payload_sha256, :string, public?: true
    attribute :ack_installed, :boolean, public?: true
    attribute :ack_error, :string, public?: true
    attribute :acked_through, :utc_datetime_usec, public?: true
    attribute :acked_slot_count, :integer, public?: true
    attribute :acked_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :assignment, [:producer_assignment_id]
  end
end
