defmodule ServiceRadar.Observability.ServiceState do
  @moduledoc """
  Current state registry for service identities.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "service_state"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    read :active do
      filter expr(state == "active")
    end

    read :active_plugin_cards do
      filter expr(state == "active" and service_type == "plugin")

      prepare build(
                select: [
                  :id,
                  :agent_id,
                  :gateway_id,
                  :partition,
                  :service_type,
                  :service_name,
                  :available,
                  :message,
                  :last_observed_at,
                  :state
                ]
              )
    end

    read :by_identity do
      argument :agent_id, :string, allow_nil?: false
      argument :gateway_id, :string, allow_nil?: false
      argument :partition, :string, allow_nil?: false
      argument :service_type, :string, allow_nil?: false
      argument :service_name, :string, allow_nil?: false

      get? true

      filter expr(
               agent_id == ^arg(:agent_id) and gateway_id == ^arg(:gateway_id) and
                 partition == ^arg(:partition) and service_type == ^arg(:service_type) and
                 service_name == ^arg(:service_name)
             )
    end

    create :upsert do
      accept [
        :agent_id,
        :gateway_id,
        :partition,
        :service_type,
        :service_name,
        :available,
        :message,
        :details,
        :last_observed_at,
        :state
      ]

      upsert? true
      upsert_identity :unique_service_identity

      upsert_fields [
        :available,
        :message,
        :details,
        :last_observed_at,
        :state,
        :updated_at
      ]

      upsert_condition expr(
                         last_observed_at < upsert_conflict(:last_observed_at) or
                           (last_observed_at == upsert_conflict(:last_observed_at) and
                              ((available == true and upsert_conflict(:available) == false) or
                                 (state != "active" and upsert_conflict(:state) == "active" and
                                    available == upsert_conflict(:available))))
                       )

      return_skipped_upsert? true
    end

    update :deactivate do
      accept []
      change set_attribute(:state, "inactive")
    end

    update :activate do
      accept []
      change set_attribute(:state, "active")
    end

    update :replace_snapshot do
      accept [:available, :message, :details, :last_observed_at, :state]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:upsert, :activate, :deactivate, :replace_snapshot]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :gateway_id, :string do
      allow_nil? false
      public? true
    end

    attribute :partition, :string do
      allow_nil? false
      public? true
    end

    attribute :service_type, :string do
      allow_nil? false
      public? true
    end

    attribute :service_name, :string do
      allow_nil? false
      public? true
    end

    attribute :available, :boolean do
      allow_nil? false
      public? true
    end

    attribute :state, :string do
      allow_nil? false
      public? true
      default "active"
    end

    attribute :message, :string do
      public? true
    end

    attribute :details, :string do
      public? true
    end

    attribute :last_observed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_service_identity, [
      :agent_id,
      :gateway_id,
      :partition,
      :service_type,
      :service_name
    ]
  end
end
