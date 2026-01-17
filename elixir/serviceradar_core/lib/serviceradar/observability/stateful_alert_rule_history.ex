defmodule ServiceRadar.Observability.StatefulAlertRuleHistory do
  @moduledoc """
  Evaluation history for stateful alert rules (fired/recovered/renotify/cooldown).

  Stored in a TimescaleDB hypertable with retention/compression managed by
  tenant migrations.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "stateful_alert_rule_history"
    repo ServiceRadar.Repo
    migrate? false
  end

  code_interface do
    define :list, action: :read
    define :list_by_rule, action: :by_rule, args: [:rule_id]
  end

  actions do
    defaults [:read]

    read :by_rule do
      argument :rule_id, :uuid, allow_nil?: false
      filter expr(rule_id == ^arg(:rule_id))
      prepare build(sort: [event_time: :desc])
    end

    create :record do
      accept [
        :event_time,
        :rule_id,
        :group_key,
        :event_type,
        :alert_id,
        :details
      ]

      change fn changeset, _context ->
        if is_nil(Ash.Changeset.get_attribute(changeset, :event_time)) do
          Ash.Changeset.change_attribute(changeset, :event_time, DateTime.utc_now())
        else
          changeset
        end
      end
    end
  end

  policies do

    # System actors can perform all operations (schema isolation via search_path)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :viewer)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action(:record) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  changes do
  end

  attributes do
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      default &Ash.UUID.generate/0
      public? true
    end

    attribute :event_time, :utc_datetime_usec do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :rule_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :group_key, :string do
      allow_nil? false
      public? true
    end

    attribute :event_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:fired, :recovered, :renotify, :cooldown]
    end

    attribute :alert_id, :uuid do
      public? true
    end

    attribute :details, :map do
      default %{}
      public? true
    end

    create_timestamp :created_at
  end
end
