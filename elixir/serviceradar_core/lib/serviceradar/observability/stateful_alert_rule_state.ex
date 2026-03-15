defmodule ServiceRadar.Observability.StatefulAlertRuleState do
  @moduledoc """
  Durable state snapshots for stateful alert rules.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @state_fields [
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
  @state_upsert_fields @state_fields -- [:rule_id, :group_key]

  postgres do
    table "stateful_alert_rule_states"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    read :by_rule do
      argument :rule_id, :uuid, allow_nil?: false
      filter expr(rule_id == ^arg(:rule_id))
    end

    create :upsert do
      accept @state_fields

      upsert? true
      upsert_identity :unique_state

      upsert_fields @state_upsert_fields ++ [:updated_at]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action(:upsert)
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

  identities do
    identity :unique_state, [:rule_id, :group_key]
  end
end
