defmodule ServiceRadar.Observability.StatefulAlertRuleState do
  @moduledoc """
  Durable state snapshots for stateful alert rules.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "stateful_alert_rule_states"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read]

    read :by_rule do
      argument :rule_id, :uuid, allow_nil?: false
      filter expr(rule_id == ^arg(:rule_id))
    end

    create :upsert do
      accept [
        :rule_id,
        :group_key,
        :group_values,
        :window_seconds,
        :bucket_seconds,
        :current_bucket_start,
        :bucket_counts,
        :last_seen_at,
        :last_fired_at,
        :last_notification_at,
        :cooldown_until,
        :alert_id
      ]

      upsert? true
      upsert_identity :unique_state

      upsert_fields [
        :group_values,
        :window_seconds,
        :bucket_seconds,
        :current_bucket_start,
        :bucket_counts,
        :last_seen_at,
        :last_fired_at,
        :last_notification_at,
        :cooldown_until,
        :alert_id,
        :updated_at
      ]
    end
  end

  identities do
    identity :unique_state, [:rule_id, :group_key]
  end

  policies do
    bypass always() do
    end

    # System actors can perform all operations (tenant isolation via schema)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :viewer)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action(:upsert) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  changes do
  end

  attributes do
    uuid_primary_key :id

    attribute :rule_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :group_key, :string do
      allow_nil? false
      public? true
    end

    attribute :group_values, :map do
      default %{}
      public? true
    end

    attribute :window_seconds, :integer do
      allow_nil? false
      public? true
    end

    attribute :bucket_seconds, :integer do
      allow_nil? false
      public? true
    end

    attribute :current_bucket_start, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :bucket_counts, :map do
      default %{}
      public? true
    end

    attribute :last_seen_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_fired_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_notification_at, :utc_datetime_usec do
      public? true
    end

    attribute :cooldown_until, :utc_datetime_usec do
      public? true
    end

    attribute :alert_id, :uuid do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
