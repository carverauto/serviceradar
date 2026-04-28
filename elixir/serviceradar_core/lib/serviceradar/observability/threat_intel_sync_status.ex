defmodule ServiceRadar.Observability.ThreatIntelSyncStatus do
  @moduledoc """
  Latest sync health for threat-intel providers and edge collector assignments.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @upsert_fields [
    :provider,
    :source,
    :collection_id,
    :agent_id,
    :gateway_id,
    :plugin_id,
    :execution_mode,
    :last_status,
    :last_message,
    :last_error,
    :last_attempt_at,
    :last_success_at,
    :last_failure_at,
    :objects_count,
    :indicators_count,
    :skipped_count,
    :total_count,
    :cursor,
    :metadata
  ]

  postgres do
    table "threat_intel_sync_statuses"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept @upsert_fields

      upsert? true
      upsert_identity :unique_sync_status

      upsert_fields [
        :provider,
        :execution_mode,
        :last_status,
        :last_message,
        :last_error,
        :last_attempt_at,
        :last_success_at,
        :last_failure_at,
        :objects_count,
        :indicators_count,
        :skipped_count,
        :total_count,
        :cursor,
        :metadata,
        :updated_at
      ]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:upsert) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action(:destroy) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string do
      allow_nil? false
      public? true
    end

    attribute :source, :string do
      allow_nil? false
      public? true
    end

    attribute :collection_id, :string do
      allow_nil? false
      default ""
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      default ""
      public? true
    end

    attribute :gateway_id, :string do
      allow_nil? false
      default ""
      public? true
    end

    attribute :plugin_id, :string do
      allow_nil? false
      default ""
      public? true
    end

    attribute :execution_mode, :string do
      allow_nil? false
      default "edge_plugin"
      public? true
    end

    attribute :last_status, :string do
      allow_nil? false
      default "unknown"
      public? true
    end

    attribute :last_message, :string do
      public? true
    end

    attribute :last_error, :string do
      public? true
    end

    attribute :last_attempt_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_success_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_failure_at, :utc_datetime_usec do
      public? true
    end

    attribute :objects_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :indicators_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :skipped_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :total_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :cursor, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_sync_status, [:source, :collection_id, :agent_id, :gateway_id, :plugin_id]
  end
end
