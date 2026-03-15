defmodule ServiceRadar.Observability.ZenRule do
  @moduledoc """
  Zen rule definitions for log normalization.

  Rules compile to GoRules/Zen JSON decision models and are synced to KV so
  the zen consumer can reload them without manual JSON edits.
  """

  use ServiceRadar.Observability.ZenPresetResource,
    table: "zen_rules",
    accept: [
      :name,
      :description,
      :enabled,
      :order,
      :stream_name,
      :subject,
      :template,
      :builder_config,
      :jdm_definition,
      :agent_id
    ],
    fields: [
      {:name, :string, [allow_nil?: false]},
      {:description, :string, []},
      {:enabled, :boolean, [default: true]},
      {:order, :integer, [default: 100]},
      {:stream_name, :string, [allow_nil?: false, default: "events"]},
      {:subject, :string, [allow_nil?: false]},
      {:format, :atom,
       [
         allow_nil?: false,
         default: :json,
         constraints: [one_of: [:json, :protobuf, :otel_metrics]]
       ]},
      {:template, :atom,
       [
         allow_nil?: false,
         constraints: [one_of: [:passthrough, :strip_full_message, :cef_severity, :snmp_severity]]
       ]},
      {:builder_config, :map, [default: %{}]},
      {:jdm_definition, :map,
       [
         description:
           "User-authored JDM JSON from the rule editor (takes precedence over template)"
       ]},
      {:compiled_jdm, :map, [default: %{}, public?: false]},
      {:kv_revision, :integer, [public?: false]},
      {:agent_id, :string, [allow_nil?: false, default: "default-agent"]}
    ],
    active_sort: [order: :asc, inserted_at: :asc],
    create_validations: [ServiceRadar.Observability.Validations.ZenRule],
    update_validations: [ServiceRadar.Observability.Validations.ZenRule],
    create_changes: [
      ServiceRadar.Observability.Changes.CompileZenRule,
      ServiceRadar.Observability.Changes.SyncZenRule
    ],
    update_changes: [
      ServiceRadar.Observability.Changes.CompileZenRule,
      ServiceRadar.Observability.Changes.SyncZenRule
    ],
    destroy_changes: [ServiceRadar.Observability.Changes.SyncZenRule],
    extra_operator_actions: [:set_kv_revision],
    extra_code_interface: [quote(do: define(:set_kv_revision, action: :set_kv_revision))],
    extra_actions: [
      quote do
        update :set_kv_revision do
          accept [:kv_revision]
        end
      end
    ]
end
