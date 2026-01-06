defmodule ServiceRadar.Repo.Migrations.AddAuthenticatedAtToNgUsers do
  use Ecto.Migration

  def change do
    alter table(:ng_users) do
      add :authenticated_at, :utc_datetime, null: true
    end
  end
end
