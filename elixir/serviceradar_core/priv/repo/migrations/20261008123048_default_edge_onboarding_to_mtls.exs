defmodule ServiceRadar.Repo.Migrations.DefaultEdgeOnboardingToMtls do
  @moduledoc "Changes the default for new packages without rewriting existing security modes."
  use Ecto.Migration

  def up do
    execute("ALTER TABLE platform.edge_onboarding_packages ALTER COLUMN security_mode SET DEFAULT 'mtls'")
  end

  def down do
    execute("ALTER TABLE platform.edge_onboarding_packages ALTER COLUMN security_mode SET DEFAULT 'spire'")
  end
end
