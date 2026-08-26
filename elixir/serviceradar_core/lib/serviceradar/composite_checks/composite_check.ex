defmodule ServiceRadar.CompositeChecks.CompositeCheck do
  @moduledoc """
  An operator-authored composite check.

  The check scopes a device population with SRQL and derives one verdict per
  device from its declared inputs and its ordered rule table. A composite check
  never dispatches a probe: it reads signals other subsystems already persist.
  """

  use Ash.Resource,
    domain: ServiceRadar.CompositeChecks,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.CompositeChecks.ScheduleNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.CompositeChecks.Changes.DeriveSlug
  alias ServiceRadar.CompositeChecks.Validations.EnforceReadiness
  alias ServiceRadar.CompositeChecks.Validations.ScopeQuery

  @create_fields [
    :name,
    :description,
    :scope_query,
    :evaluation_interval_seconds,
    :write_canonical_availability
  ]
  @update_fields @create_fields

  postgres do
    table "composite_checks"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index ["lower(name)"], unique: true, name: "composite_checks_name_uidx"
      index [:state], name: "composite_checks_state_idx"
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_slug, action: :by_slug, args: [:slug]
    define :list_enabled, action: :enabled
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :enabled do
      filter expr(state == :enabled)
      prepare build(sort: [name: :asc])
    end

    create :create do
      accept @create_fields
      change DeriveSlug
      validate ScopeQuery
      change after_action(&create_catch_all_rule/3)
    end

    update :update do
      accept @update_fields
      validate ScopeQuery
    end

    update :set_state do
      description "Disable or return a check to draft. Enabling goes through :enable."
      accept [:state]
      validate attribute_does_not_equal(:state, :enabled)
    end

    update :enable do
      description "Enable a check after confirming it can produce meaningful verdicts"

      argument :acknowledge_coverage_gap, :boolean, default: false

      change set_attribute(:state, :enabled)
      validate EnforceReadiness
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update, :destroy])
    operator_action(:enable)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      writable? false
      description "Immutable query handle, derived from the name at creation"
    end

    attribute :description, :string do
      public? true
    end

    attribute :scope_query, :string do
      allow_nil? false
      public? true
      description "SRQL query selecting the devices this check evaluates"
    end

    attribute :evaluation_interval_seconds, :integer do
      allow_nil? false
      default 300
      public? true
      constraints min: 60, max: 86_400
    end

    attribute :write_canonical_availability, :boolean do
      allow_nil? false
      default false
      public? true

      description """
      When true, a healthy verdict sets Device.is_available and a down verdict
      clears it. Off by default: composite checks derive a separate verdict
      (and Armis northbound reads that verdict as its own custom field).
      Availability Sources remain the way to pick which sweep agent owns the
      canonical bit.
      """
    end

    attribute :state, :atom do
      allow_nil? false
      default :draft
      public? true
      constraints one_of: [:draft, :enabled, :disabled]
    end

    attribute :last_evaluated_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_slug, [:slug]
  end

  @doc false
  # Every check is born with a catch-all rule. It is what makes the decision
  # table total: any input combination that matches no authored rule lands here
  # instead of leaving the device with no verdict at all.
  def create_catch_all_rule(_changeset, check, context) do
    ServiceRadar.CompositeChecks.CompositeCheckRule
    |> Ash.Changeset.for_create(
      :create_catch_all,
      %{
        check_id: check.id,
        verdict: "inconclusive",
        verdict_label: "Inconclusive",
        verdict_description:
          "One or more inputs were unknown or stale, so no verdict can be asserted"
      },
      actor: context.actor
    )
    |> Ash.create()
    |> case do
      {:ok, _rule} -> {:ok, check}
      {:error, error} -> {:error, error}
    end
  end
end
