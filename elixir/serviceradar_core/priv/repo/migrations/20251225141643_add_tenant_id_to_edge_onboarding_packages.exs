defmodule ServiceRadar.Repo.Migrations.AddTenantIdToEdgeOnboardingPackages do
  use Ecto.Migration

  def change do
    alter table(:edge_onboarding_packages) do
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false
    end

    create index(:edge_onboarding_packages, [:tenant_id])
  end
end
