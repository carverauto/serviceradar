defmodule ServiceRadar.Repo.Migrations.AddCredentialBrokerAllowedSchemes do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:credential_broker_grants, prefix: "platform") do
      add :allowed_schemes, {:array, :text}, null: false, default: []
    end
  end

  def down do
    alter table(:credential_broker_grants, prefix: "platform") do
      remove :allowed_schemes
    end
  end
end
