defmodule ServiceRadar.Notifications.NotificationDeliveryMember do
  @moduledoc """
  Durable membership of an alert in one notification delivery.

  A grouped delivery has one transport row but can represent many alerts. The
  aggregate `NotificationDelivery.alert_snapshot` remains the bounded rendering
  payload; this resource is the unbounded relational identity used for routing
  idempotency and lifecycle handling.

  `alert_id` deliberately has no foreign key. Alert retention hard-deletes old
  alerts, while delivery history must retain which alert participated. The
  denormalized member snapshot likewise lets a pending aggregate be rebuilt and
  re-anchored without depending on a retained `Alert` row.

  `source_due_at` is the escalation instant this member contributed. It is part
  of the identity because one long-lived alert can legitimately contribute a
  later repeat to the same still-pending group.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Notifications.Validations.NonEmptyAlertSnapshot
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Policies.Checks.ActorIsNil

  @view_check {ActorHasPermission, permission: "notifications.deliveries.view"}
  @manage_check {ActorHasPermission, permission: "notifications.channels.manage"}

  @fields [:delivery_id, :alert_id, :source_due_at, :alert_snapshot]
  @read_actions [:read, :by_id, :for_delivery, :for_alert]
  @pipeline_writes [:attach, :destroy]

  postgres do
    table "notification_delivery_members"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names delivery_alert_due: "notification_delivery_members_identity_uidx"

    references do
      reference :delivery, on_delete: :delete
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_delivery, action: :for_delivery, args: [:delivery_id]
    define :list_for_alert, action: :for_alert, args: [:alert_id]
    define :attach, action: :attach
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_delivery do
      argument :delivery_id, :uuid, allow_nil?: false

      filter expr(delivery_id == ^arg(:delivery_id))
      prepare build(sort: [source_due_at: :asc, inserted_at: :asc])
    end

    read :for_alert do
      argument :alert_id, :uuid, allow_nil?: false

      filter expr(alert_id == ^arg(:alert_id))
      prepare build(sort: [source_due_at: :asc, inserted_at: :asc])
    end

    create :attach do
      primary? true
      accept @fields

      upsert? true
      upsert_identity :delivery_alert_due
      upsert_fields [:alert_snapshot, :updated_at]

      validate NonEmptyAlertSnapshot
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission(@read_actions, @view_check)

    policy action(@pipeline_writes) do
      authorize_if ActorIsNil
      authorize_if @manage_check
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :delivery_id, :uuid do
      allow_nil? false
      public? true
      description "Delivery whose bounded aggregate snapshot contains this member."
    end

    attribute :alert_id, :uuid do
      allow_nil? false
      public? true

      description "Stable alert identity with no FK so it survives alert retention."
    end

    attribute :source_due_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "Escalation instant this member contributed to the delivery."
    end

    attribute :alert_snapshot, :map do
      allow_nil? false
      public? true
      description "Member snapshot retained independently of the alert row."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :delivery, ServiceRadar.Notifications.NotificationDelivery do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :delivery_id
    end
  end

  identities do
    identity :delivery_alert_due, [:delivery_id, :alert_id, :source_due_at]
  end
end
