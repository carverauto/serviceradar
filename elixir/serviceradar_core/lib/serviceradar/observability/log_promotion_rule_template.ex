defmodule ServiceRadar.Observability.LogPromotionRuleTemplate do
  @moduledoc """
  Templates for log promotion rule presets.
  """

  use ServiceRadar.Observability.PresetRuleResource,
    table: "log_promotion_rule_templates",
    accept: [:name, :description, :enabled, :priority, :match, :event],
    fields: [
      {:name, :string, [allow_nil?: false]},
      {:description, :string, []},
      {:enabled, :boolean, [default: true]},
      {:priority, :integer, [default: 100]},
      {:match, :map, [default: %{}]},
      {:event, :map, [default: %{}]}
    ],
    identity_fields: [:name]
end
