defmodule ServiceRadar.CompositeChecks.CompositeCheckRule do
  @moduledoc """
  One row of a composite check's decision table.

  Rules are evaluated in ascending `position` order and the first match wins.
  `match` maps an input key to a literal value, a list of literal values, or the
  wildcard `"*"`; an input key absent from the map is treated as a wildcard.

  `verdict` is an operator-defined slug carrying the domain meaning. `status` is
  a fixed enum so rollups, colors, and northbound exports work without knowing a
  given deployment's vocabulary.
  """

  use Ash.Resource,
    domain: ServiceRadar.CompositeChecks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @fields [:check_id, :position, :match, :verdict, :verdict_label, :verdict_description, :status]

  @catch_all_position 1_000_000

  postgres do
    table "composite_check_rules"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :check, on_delete: :delete
    end

    custom_indexes do
      index [:check_id, :position], name: "composite_check_rules_check_position_idx"
    end

    # Enforced in the database rather than by a validation, because an Ash
    # validation cannot read the incoming value when an update runs atomically:
    # atomic changes live in `changeset.atomics`, not `changeset.attributes`, so
    # `get_attribute/2` returns nil and the check would reject every legitimate
    # match edit. A constraint holds in every mode and exempts the catch-all,
    # which is the one rule allowed to match everything.
    check_constraints do
      check_constraint :match, "composite_check_rules_match_non_empty",
        check: "catch_all OR match::text <> '{}'",
        message: "must constrain at least one input; only the catch-all rule may match everything"
    end
  end

  code_interface do
    define :list_by_check, action: :by_check, args: [:check_id]
  end

  actions do
    defaults [:read]

    read :by_check do
      argument :check_id, :uuid, allow_nil?: false
      filter expr(check_id == ^arg(:check_id))
      prepare build(sort: [position: :asc, inserted_at: :asc])
    end

    create :create do
      accept @fields
    end

    create :create_catch_all do
      description "Creates the mandatory trailing catch-all; called on check creation"
      accept [:check_id, :verdict, :verdict_label, :verdict_description]

      change set_attribute(:catch_all, true)
      change set_attribute(:match, %{})
      change set_attribute(:status, :unknown)
      change set_attribute(:position, @catch_all_position)
    end

    update :update do
      description "Edit an authored rule. Not permitted on the catch-all."
      accept @fields -- [:check_id]
    end

    update :relabel do
      description "Rename a rule's verdict presentation without touching its matching"
      accept [:verdict, :verdict_label, :verdict_description]
    end

    destroy :destroy do
      primary? true
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()

    # The catch-all's totality is structural, so it is enforced by a filter the
    # database evaluates rather than by a change that inspects the changeset.
    # An `Ash.Resource.Change` cannot do this reliably: `changeset.data` is not
    # populated when an update runs atomically, so the guard silently no-ops.
    # Relabelling stays available through `:relabel`.
    policy action(:update) do
      forbid_if expr(catch_all == true)
      authorize_if is_operator()
    end

    policy action(:destroy) do
      forbid_if expr(catch_all == true)
      authorize_if is_operator()
    end

    operator_action_type(:create)
    operator_action(:relabel)
  end

  attributes do
    uuid_primary_key :id

    attribute :position, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :match, :map do
      allow_nil? false
      default %{}
      public? true
      description ~S(input_key => literal | [literals] | "*"; absent key means wildcard)
    end

    attribute :verdict, :string do
      allow_nil? false
      public? true
    end

    attribute :verdict_label, :string do
      allow_nil? false
      public? true
    end

    attribute :verdict_description, :string do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :unknown
      public? true
      constraints one_of: [:healthy, :degraded, :down, :unknown]
    end

    attribute :catch_all, :boolean do
      allow_nil? false
      default false
      public? true
      writable? false
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
end
