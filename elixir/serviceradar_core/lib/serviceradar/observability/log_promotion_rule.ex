defmodule ServiceRadar.Observability.LogPromotionRule do
  @moduledoc """
  Rules for promoting logs into OCSF events.

  Rules are evaluated in priority order and can match on log fields plus
  attributes/resource_attributes. Event metadata is stored in the rule's
  `event` map and merged with generated defaults.
  """

  use ServiceRadar.Observability.PresetRuleResource,
    table: "log_promotion_rules",
    accept: [:name, :enabled, :priority, :match, :event],
    fields: [
      {:name, :string, [allow_nil?: false]},
      {:enabled, :boolean, [default: true]},
      {:priority, :integer, [default: 100]},
      {:match, :map, [default: %{}]},
      {:event, :map, [default: %{}]}
    ],
    identity_fields: [:name],
    active_sort: [priority: :asc, inserted_at: :asc]
end
