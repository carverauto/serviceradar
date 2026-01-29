defmodule ServiceRadar.Repo.Migrations.AddUserExternalId do
  @moduledoc """
  Adds external_id column to ng_users table for SSO user linking.

  The external_id stores the IdP subject identifier (sub claim from OIDC/SAML)
  to link local users to their SSO identity.
  """

  use Ecto.Migration

  def change do
    alter table(:ng_users, prefix: "platform") do
      add :external_id, :string
    end

    # Index for looking up users by external_id during SSO login
    create index(:ng_users, [:external_id], prefix: "platform", where: "external_id IS NOT NULL")
  end
end
