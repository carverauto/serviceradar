defmodule ServiceRadar.Observability.StatefulAlertRuleTemplate do
  @moduledoc """
  Templates for stateful alert rule presets.
  """

  use ServiceRadar.Observability.PresetRuleResource,
    table: "stateful_alert_rule_templates",
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
    identity_fields: [:name]
end
