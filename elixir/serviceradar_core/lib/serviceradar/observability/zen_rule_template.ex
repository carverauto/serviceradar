defmodule ServiceRadar.Observability.ZenRuleTemplate do
  @moduledoc """
  Templates for Zen rule builder presets.
  """

  use ServiceRadar.Observability.ZenPresetResource,
    table: "zen_rule_templates",
    accept: [
      :name,
      :description,
      :enabled,
      :order,
      :stream_name,
      :subject,
      :template,
      :builder_config,
      :agent_id
    ],
    fields: [
      {:name, :string, [allow_nil?: false]},
      {:description, :string, []},
      {:enabled, :boolean, [default: true]},
      {:order, :integer, [default: 100]},
      {:stream_name, :string, [allow_nil?: false, default: "events"]},
      {:subject, :string, [allow_nil?: false]},
      {:template, :atom,
       [
         allow_nil?: false,
         constraints: [one_of: [:passthrough, :strip_full_message, :cef_severity, :snmp_severity]]
       ]},
      {:builder_config, :map, [default: %{}]},
      {:agent_id, :string, [allow_nil?: false, default: "default-agent"]}
    ],
    create_validations: [ServiceRadar.Observability.Validations.ZenRuleTemplate],
    update_validations: [ServiceRadar.Observability.Validations.ZenRuleTemplate]
end
