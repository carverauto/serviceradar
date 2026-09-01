defmodule ServiceRadar.Credentials.NetworkCredentialSecretBinding do
  @moduledoc """
  Database-maintained inventory of live denormalized credential references.

  PostgreSQL triggers write this resource in the same transaction as each
  text or JSON owner. Application callers can only read it.
  """

  use Ash.Resource,
    domain: ServiceRadar.Credentials,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @credential_manage_check {ActorHasPermission, permission: "settings.credentials.manage"}

  postgres do
    table "network_credential_secret_bindings"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :secret, on_delete: :restrict
    end
  end

  actions do
    read :read do
      primary? true
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@credential_manage_check)
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :secret_id, :uuid, allow_nil?: false, public?: true

    attribute :owner_kind, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :vulnerability_feed_definition,
                    :notification_channel,
                    :producer_schedule,
                    :plugin_assignment,
                    :plugin_target_policy
                  ]
    end

    attribute :owner_id, :string, allow_nil?: false, public?: true
    attribute :field_path, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :secret, ServiceRadar.Credentials.NetworkCredentialSecret do
      allow_nil? false
      public? true
      source_attribute :secret_id
      destination_attribute :id
      define_attribute? false
    end
  end

  identities do
    identity :unique_owner_reference, [:owner_kind, :owner_id, :field_path]
  end
end
