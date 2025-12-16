defmodule ServiceRadarWebNG.Repo.Migrations.CreateNgUsersAuthTables do
  use Ecto.Migration

  def change do
    create table(:ng_users) do
      add :email, :string, null: false
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:ng_users, [:email])

    create table(:ng_users_tokens) do
      add :user_id, references(:ng_users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:ng_users_tokens, [:user_id])
    create unique_index(:ng_users_tokens, [:context, :token])
  end
end
