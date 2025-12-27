defmodule ServiceRadarWebNG.Repo.Migrations.AddTenantIdToUsers do
  @moduledoc """
  Adds tenant_id to ng_users for multi-tenant isolation.

  Existing users are assigned to the default tenant during migration.
  """
  use Ecto.Migration

  @default_tenant_id "00000000-0000-0000-0000-000000000001"

  def change do
    alter table(:ng_users) do
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict)
      add :role, :string, default: "viewer"
      add :display_name, :string
    end

    create index(:ng_users, [:tenant_id])
    create index(:ng_users, [:role])

    # Assign existing users to default tenant
    execute """
    UPDATE ng_users SET tenant_id = '#{@default_tenant_id}' WHERE tenant_id IS NULL;
    """,
    """
    UPDATE ng_users SET tenant_id = NULL WHERE tenant_id = '#{@default_tenant_id}';
    """

    # Make tenant_id required after data migration
    execute """
    ALTER TABLE ng_users ALTER COLUMN tenant_id SET NOT NULL;
    """,
    """
    ALTER TABLE ng_users ALTER COLUMN tenant_id DROP NOT NULL;
    """

    # Update unique constraint for email to be per-tenant
    drop unique_index(:ng_users, [:email])
    create unique_index(:ng_users, [:tenant_id, :email])
  end
end
