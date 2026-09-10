defmodule ServiceRadar.Observability.StatefulAlertRule do
  @moduledoc """
  Stateful alert rule definitions for threshold windows (N occurrences in T).

  Rules seeded by `ServiceRadar.Observability.RuleSeeder` carry `managed: true`
  plus a `template_version`/`template_fingerprint` pair so the seeder can
  reconcile them when the bundled templates change. Clearing `managed`
  permanently detaches a rule from the seeder.
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
      :alert,
      :managed,
      :template_version,
      :template_fingerprint,
      :plugin_package_id
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
      {:alert, :map, [default: %{}]},
      {:managed, :boolean, [default: false, allow_nil?: false]},
      {:template_version, :integer, []},
      {:template_fingerprint, :string, []},
      # Provenance for a rule contributed by a plugin package. NULL for every
      # rule an operator authored or core seeded, which is why it is nullable
      # rather than defaulted.
      {:plugin_package_id, :uuid, []}
    ],
    identity_fields: [:name],
    active_sort: [priority: :asc, inserted_at: :asc],
    create_validations: [ServiceRadar.Observability.Validations.WindowBucket],
    update_validations: [ServiceRadar.Observability.Validations.WindowBucket],
    create_changes: [
      ServiceRadar.Observability.Changes.ScheduleAlertCleanup,
      ServiceRadar.Observability.Changes.StampEventSource
    ],
    update_changes: [ServiceRadar.Observability.Changes.StampEventSource],
    destroy_changes: [ServiceRadar.Observability.Changes.StampEventSource],
    extensions: [AshJsonApi.Resource, AshEvents.Events],
    extra_code_interface: [quote(do: define(:get_by_id, action: :by_id, args: [:id]))],
    extra_actions: [
      quote do
        read :by_id do
          argument :id, :uuid, allow_nil?: false
          get? true
          filter expr(unquote(Macro.var(:id, nil)) == ^arg(:id))
        end
      end
    ]

  json_api do
    type "stateful-alert-rule"

    routes do
      base "/stateful-alert-rules"
      get :by_id
      index :read
      index :active, route: "/active"
      post :create
      patch :update
      delete :destroy
    end
  end

  events do
    event_log(ServiceRadar.Observability.ApiEvent)
  end
end
