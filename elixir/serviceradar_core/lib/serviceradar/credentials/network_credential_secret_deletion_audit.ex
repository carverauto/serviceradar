defmodule ServiceRadar.Credentials.NetworkCredentialSecretDeletionAudit do
  @moduledoc """
  Append-only, redacted identity record for permanently deleted credentials.

  Ciphertext, external secret locations, metadata, and action inputs are never
  stored here.
  """

  use Ash.Resource,
    domain: ServiceRadar.Credentials,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @credential_manage_check {ActorHasPermission, permission: "settings.credentials.manage"}
  @fields [
    :secret_id,
    :name,
    :provider,
    :credential_kind,
    :source_type,
    :deleted_by_actor_id,
    :deleted_at
  ]

  postgres do
    table "network_credential_secret_deletion_audits"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    read :read do
      primary? true
    end

    create :record do
      accept @fields
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
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :credential_kind, :atom, allow_nil?: false, public?: true
    attribute :source_type, :atom, allow_nil?: false, public?: true
    attribute :deleted_by_actor_id, :string, allow_nil?: true, public?: true

    attribute :deleted_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end
  end
end
