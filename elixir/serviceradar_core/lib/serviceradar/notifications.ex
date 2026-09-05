defmodule ServiceRadar.Notifications do
  @moduledoc """
  Notification platform domain.

  This domain owns the notification decision engine: the channel registry,
  routing rules, escalation policies, schedules, silences, delivery records,
  and acknowledgement audit.

  The decision engine itself is deliberately NOT pluggable. Extensibility lives
  entirely at the transport boundary, behind `ServiceRadar.Notifications.Transport`,
  which has three tiers (`:native`, `:declarative`, `:wasm_plugin`) plus the
  built-in `:stream` provider type. Routing, escalation, deduplication,
  suppression, and acknowledgement never branch on `provider_type`.

  See `openspec/changes/add-notification-platform/design.md`.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain, AshPaperTrail.Domain, AshJsonApi.Domain]

  admin do
    show?(true)
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Notifications.NotificationProvider
    resource ServiceRadar.Notifications.NotificationChannel
    resource ServiceRadar.Notifications.NotificationSchedule
    resource ServiceRadar.Notifications.NotificationEscalationPolicy
    resource ServiceRadar.Notifications.NotificationEscalationStep
    resource ServiceRadar.Notifications.NotificationEscalationStepChannel
    resource ServiceRadar.Notifications.NotificationRoute
    resource ServiceRadar.Notifications.NotificationSilence
    resource ServiceRadar.Notifications.NotificationTemplate
    resource ServiceRadar.Notifications.NotificationDelivery
    resource ServiceRadar.Notifications.NotificationDeliveryMember
    resource ServiceRadar.Notifications.NotificationAcknowledgement
    resource ServiceRadar.Notifications.NotificationActionToken
    resource ServiceRadar.Notifications.NotificationCallbackApp
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
