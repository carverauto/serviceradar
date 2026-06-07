defmodule ServiceRadar.Plugins.AddonStatus do
  @moduledoc """
  Per-agent observed status of a native add-on (issue 3425, task 7.2).

  The agent reports the state of each supervised add-on in its `agent` capability
  status payload; this read model records what each agent reports so Edge Ops can
  reconcile desired assignments against observed state (installed / active /
  unhealthy + degradation reason). Keyed by `{agent_uid, addon_id}` and upserted on
  every report.

  `version` and `arch` are nullable: the agent does not yet report them per add-on
  (see task 7.1, agent-side enrichment); the columns exist so they can be populated
  without a schema change once it does.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  @report_fields [
    :state,
    :active,
    :degradation_reason,
    :pid,
    :restart_count,
    :last_health_at,
    :version,
    :arch,
    :reported_at
  ]

  postgres do
    table "addon_statuses"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    read :by_agent do
      argument :agent_uid, :string, allow_nil?: false
      filter expr(agent_uid == ^arg(:agent_uid))
    end

    create :report do
      description "Upsert the observed status of an add-on on an agent."

      accept [:agent_uid, :addon_id | @report_fields]

      upsert? true
      upsert_identity :unique_agent_addon
      upsert_fields @report_fields ++ [:updated_at]
    end
  end

  policies do
    import ServiceRadar.Plugins.Policies

    manage_action_types()
  end

  attributes do
    uuid_primary_key :id

    attribute :agent_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :addon_id, :string do
      allow_nil? false
      public? true
    end

    attribute :state, :string do
      allow_nil? false
      public? true

      description "Raw lifecycle state reported by the agent (running/unhealthy/circuit_open/stopped/...)."
    end

    attribute :active, :boolean do
      allow_nil? false
      default false
      public? true
      description "True when the add-on is running."
    end

    attribute :degradation_reason, :string do
      public? true
      description "Last error / degradation reason reported when the add-on is not healthy."
    end

    attribute :pid, :integer do
      public? true
    end

    attribute :restart_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :last_health_at, :utc_datetime_usec do
      public? true
      description "Last successful health check reported by the agent."
    end

    attribute :version, :string do
      public? true
      description "Add-on version (nullable; populated once the agent reports it, task 7.1)."
    end

    attribute :arch, :string do
      public? true
      description "Architecture (nullable; populated once the agent reports it, task 7.1)."
    end

    attribute :reported_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the agent reported this status."
    end

    timestamps()
  end

  identities do
    identity :unique_agent_addon, [:agent_uid, :addon_id]
  end
end
