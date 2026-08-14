defmodule ServiceRadar.CompositeChecks.CompositeCheckInput do
  @moduledoc """
  A named, typed signal that a composite check consumes.

  Two kinds ship: `:vantage_point` (per-agent reachability from
  `device_agent_availability`) and `:device_metadata` (a scalar fact on the
  device record). Adding a kind requires a resolver module and a clause in
  `ServiceRadar.CompositeChecks.Validations.InputConfig` — rule structure,
  result storage, and the evaluator are unaffected.

  `expected` is an authoring aid used to seed the rule table and to label
  liveness witnesses. The evaluator never reads it.
  """

  use Ash.Resource,
    domain: ServiceRadar.CompositeChecks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.CompositeChecks.Validations.InputConfig

  @fields [:check_id, :key, :label, :position, :kind, :config, :expected]

  postgres do
    table "composite_check_inputs"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :check, on_delete: :delete
    end

    custom_indexes do
      index [:check_id, :position], name: "composite_check_inputs_check_position_idx"
    end
  end

  code_interface do
    define :list_by_check, action: :by_check, args: [:check_id]
  end

  actions do
    defaults [:read, :destroy]

    read :by_check do
      argument :check_id, :uuid, allow_nil?: false
      filter expr(check_id == ^arg(:check_id))
      prepare build(sort: [position: :asc, key: :asc])
    end

    create :create do
      accept @fields
      validate InputConfig
    end

    update :update do
      accept @fields -- [:check_id]
      validate InputConfig
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update, :destroy])
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      description "Identifier used in rule match maps and result input snapshots"
    end

    attribute :label, :string do
      allow_nil? false
      public? true
    end

    attribute :position, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:vantage_point, :device_metadata]
    end

    attribute :config, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :expected, :string do
      public? true
      description "Authoring aid used to seed rules and label witnesses; never evaluated"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :check, ServiceRadar.CompositeChecks.CompositeCheck do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_key_per_check, [:check_id, :key]
  end
end
