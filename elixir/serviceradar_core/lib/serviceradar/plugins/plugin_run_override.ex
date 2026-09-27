defmodule ServiceRadar.Plugins.PluginRunOverride do
  @moduledoc """
  A time-bounded override that a plugin action set for its assignment.

  Plugin runs are stateless, so an action that changes how later runs behave
  (a demo fault injection, a maintenance window) returns an override in its
  action result instead of remembering anything itself. The platform keeps the
  override and the agent config generator delivers it to every run of the
  assignment:

    * while `now < expires_at` the run receives it active;
    * after expiry the run receives it marked expired, so the plugin can emit
      its resolving event, until the agent reports that such a run succeeded
      (`acknowledged_at`);
    * a later action may end it early (`ended_at`), after which it is not
      delivered at all.

  Rows are written only by the northbound result handler and the plugin result
  ingestor, both as system actors.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  postgres do
    table "plugin_run_overrides"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_assignment_override:
                           "plugin_run_overrides_unique_assignment_override_index"

    references do
      reference :plugin_assignment, on_delete: :delete
    end
  end

  code_interface do
    define :record, action: :record
    define :list_deliverable, action: :deliverable_for_assignments, args: [:assignment_ids]
  end

  actions do
    defaults [:read]

    # An expired override that no successful run ever acknowledged (the
    # assignment was paused or removed) stops being delivered after 7 days.
    read :deliverable_for_assignments do
      argument :assignment_ids, {:array, :uuid}, allow_nil?: false

      filter expr(
               plugin_assignment_id in ^arg(:assignment_ids) and is_nil(ended_at) and
                 is_nil(acknowledged_at) and
                 expires_at > ago(7, :day)
             )

      prepare build(sort: [plugin_assignment_id: :asc, starts_at: :asc, override_id: :asc])
    end

    create :record do
      upsert? true
      upsert_identity :unique_assignment_override
      # A re-recorded id refreshes its window but never revives an override
      # that was already ended or acknowledged.
      upsert_fields [
        :kind,
        :target,
        :params,
        :starts_at,
        :expires_at,
        :invocation_id,
        :updated_at
      ]

      accept [
        :plugin_assignment_id,
        :override_id,
        :kind,
        :target,
        :params,
        :starts_at,
        :expires_at,
        :invocation_id
      ]
    end

    update :end_early do
      accept []
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end

    update :acknowledge do
      accept []
      change set_attribute(:acknowledged_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if {ActorHasPermission, permission: "settings.plugins.manage"}
    end
  end

  validations do
    validate compare(:expires_at, greater_than: :starts_at),
      message: "must be after starts_at"
  end

  attributes do
    uuid_primary_key :id

    attribute :plugin_assignment_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :override_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 128, trim?: true, allow_empty?: false
    end

    attribute :kind, :string do
      allow_nil? false
      public? true
      constraints max_length: 128, trim?: true, allow_empty?: false
    end

    attribute :target, :string do
      allow_nil? true
      public? true
      constraints max_length: 512
    end

    attribute :params, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :starts_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :ended_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :acknowledged_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :invocation_id, :uuid do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  relationships do
    belongs_to :plugin_assignment, ServiceRadar.Plugins.PluginAssignment do
      source_attribute :plugin_assignment_id
      define_attribute? false
      public? true
    end
  end

  identities do
    identity :unique_assignment_override, [:plugin_assignment_id, :override_id]
  end
end
