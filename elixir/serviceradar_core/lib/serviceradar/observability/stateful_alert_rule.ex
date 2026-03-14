defmodule ServiceRadar.Observability.StatefulAlertRule do
  @moduledoc """
  Stateful alert rule definitions for threshold windows (N occurrences in T).
  """

  use ServiceRadar.Observability.PresetRuleResource,
    table: "stateful_alert_rules",
    accept: [
      :name,
      :description,
      :enabled,
      :priority,
      :signal,
      :match,
      :group_by,
      :threshold,
      :window_seconds,
      :bucket_seconds,
      :cooldown_seconds,
      :renotify_seconds,
      :event,
      :alert
    ],
    fields: [
      {:name, :string, [allow_nil?: false]},
      {:description, :string, []},
      {:enabled, :boolean, [default: true]},
      {:priority, :integer, [default: 100]},
      {:signal, :atom, [default: :log, allow_nil?: false]},
      {:match, :map, [default: %{}]},
      {:group_by, {:array, :string}, [default: ["serviceradar.sync.integration_source_id"]]},
      {:threshold, :integer, [default: 5, allow_nil?: false]},
      {:window_seconds, :integer, [default: 600, allow_nil?: false]},
      {:bucket_seconds, :integer, [default: 60, allow_nil?: false]},
      {:cooldown_seconds, :integer, [default: 300, allow_nil?: false]},
      {:renotify_seconds, :integer, [default: 21_600, allow_nil?: false]},
      {:event, :map, [default: %{}]},
      {:alert, :map, [default: %{}]}
    ],
    identity_fields: [:name],
    active_sort: [priority: :asc, inserted_at: :asc],
    create_validations: [ServiceRadar.Observability.Validations.WindowBucket],
    update_validations: [ServiceRadar.Observability.Validations.WindowBucket],
    create_changes: [ServiceRadar.Observability.Changes.ScheduleAlertCleanup]
end
