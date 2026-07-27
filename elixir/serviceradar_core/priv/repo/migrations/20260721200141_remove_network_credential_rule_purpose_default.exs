defmodule ServiceRadar.Repo.Migrations.RemoveNetworkCredentialRulePurposeDefault do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("ALTER TABLE platform.network_credential_rules ALTER COLUMN purpose DROP DEFAULT")
  end

  def down do
    execute(
      "ALTER TABLE platform.network_credential_rules ALTER COLUMN purpose SET DEFAULT 'inventory_enrichment'"
    )
  end
end
