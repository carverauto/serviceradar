defmodule ServiceRadar.Identity.UserAuthEvent do
  @moduledoc """
  Immutable authentication/audit events for user accounts.

  These events back the "Account details" UI (login history, access changes, etc).
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer

  require Ash.Query

  postgres do
    table "user_auth_events"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :list_for_user, action: :for_user, args: [:user_id]
    define :record, action: :create
  end

  actions do
    defaults [:read]

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [inserted_at: :desc])

      pagination keyset?: true, required?: false, default_limit: 50
    end

    create :create do
      accept [:user_id, :actor_user_id, :event_type, :auth_method, :ip, :user_agent, :metadata]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :event_type, :string do
      allow_nil? false
      public? true
    end

    attribute :auth_method, :string do
      allow_nil? true
      public? true
    end

    attribute :ip, :string do
      allow_nil? true
      public? true
    end

    attribute :user_agent, :string do
      allow_nil? true
      public? false
    end

    attribute :metadata, :map do
      allow_nil? true
      public? false
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, ServiceRadar.Identity.User do
      attribute_writable? true
      allow_nil? false
    end

    belongs_to :actor_user, ServiceRadar.Identity.User do
      attribute_writable? true
      allow_nil? true
    end
  end
end
