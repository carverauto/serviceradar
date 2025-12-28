defmodule ServiceRadarWebNG.Repo.Migrations.CreateTenants do
  @moduledoc """
  Creates the tenants table for multi-tenant SaaS architecture.

  Each tenant represents an organization/customer with their own isolated data.
  """
  use Ecto.Migration

  def change do
    # Ensure citext extension exists (needed for case-insensitive slug)
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:tenants, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :name, :string, null: false
      add :slug, :citext, null: false
      add :status, :string, null: false, default: "active"
      add :settings, :map, default: %{}

      # Billing/plan info
      add :plan, :string, default: "free"
      add :max_devices, :integer, default: 100
      add :max_users, :integer, default: 5

      # Contact info
      add :contact_email, :string
      add :contact_name, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tenants, [:slug])
    create index(:tenants, [:status])

    # Create a default tenant for existing data migration
    execute """
            INSERT INTO tenants (id, name, slug, status, inserted_at, updated_at)
            VALUES (
              '00000000-0000-0000-0000-000000000001',
              'Default Tenant',
              'default',
              'active',
              NOW(),
              NOW()
            );
            """,
            """
            DELETE FROM tenants WHERE id = '00000000-0000-0000-0000-000000000001';
            """
  end
end
