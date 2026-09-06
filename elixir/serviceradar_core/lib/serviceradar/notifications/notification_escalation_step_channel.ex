defmodule ServiceRadar.Notifications.NotificationEscalationStepChannel do
  @moduledoc """
  The fan-out join: a `NotificationEscalationStep` holds a **set** of channels
  (design D4).

  Fan-out is orthogonal to retry, failover, and escalation. A step notifies
  every channel in its set at the same instant; escalation is what happens at
  the *next* step, later, if a human still has not answered. Modelling the set
  as a real join resource rather than an array column is what lets the delivery
  engine attach one `NotificationDelivery` per (alert x step x channel) and lets
  the UI answer "which ladders page this channel?" without scanning arrays.

  This resource is deliberately **not** paper-trailed: the migration creates no
  `notification_escalation_step_channels_versions` table. Membership churn is
  audited on the two sides that do carry versions - the step and the channel -
  and a version table for a two-column join would record only what its own
  primary key already says.

  Membership is unique on `(step_id, channel_id)`
  (`notification_escalation_step_channels_uidx`), so `:attach` is an upsert and
  is safe to re-run. Deleting either the step or the channel deletes the
  membership row.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "notifications.routes.view"}
  @manage_check {ActorHasPermission, permission: "notifications.routes.manage"}

  @fields [
    :step_id,
    :channel_id
  ]

  postgres do
    table "notification_escalation_step_channels"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names step_channel: "notification_escalation_step_channels_uidx"

    references do
      reference :step, on_delete: :delete
      reference :channel, on_delete: :delete
    end
  end

  json_api do
    type "notification_escalation_step_channel"

    routes do
      base "/notification-escalation-step-channels"

      post :attach
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_step, action: :for_step, args: [:step_id]
    define :list_for_channel, action: :for_channel, args: [:channel_id]
    define :attach_channel, action: :attach
    define :detach_channel, action: :destroy
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
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :for_step do
      argument :step_id, :uuid, allow_nil?: false

      filter expr(step_id == ^arg(:step_id))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    # Answers "which escalation ladders page this channel?", which is what makes
    # disabling or deleting a channel a reviewable act rather than a silent one.
    read :for_channel do
      argument :channel_id, :uuid, allow_nil?: false

      filter expr(channel_id == ^arg(:channel_id))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    create :create do
      accept @fields
    end

    # Set semantics: adding a channel that is already in the set is a no-op, not
    # a unique-violation the caller has to interpret.
    create :attach do
      accept @fields
      upsert? true
      upsert_identity :step_channel
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :for_step, :for_channel], @view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
    action_with_permission([:attach], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :step_id, :uuid do
      allow_nil? false
      public? true
      description "Escalation step this membership belongs to"
    end

    attribute :channel_id, :uuid do
      allow_nil? false
      public? true
      description "Channel notified when the step fires"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :step, ServiceRadar.Notifications.NotificationEscalationStep do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :step_id
    end

    belongs_to :channel, ServiceRadar.Notifications.NotificationChannel do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :channel_id
    end
  end

  identities do
    identity :step_channel, [:step_id, :channel_id]
  end
end
