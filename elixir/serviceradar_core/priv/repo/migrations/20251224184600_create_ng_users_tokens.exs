defmodule ServiceRadar.Repo.Migrations.CreateNgUsersTokens do
  @moduledoc """
  Creates the ng_users_tokens table for legacy Phoenix authentication.

  This table is used by the Ecto-based UserToken schema in web-ng
  for session management alongside the Ash Identity resources.
  """
  use Ecto.Migration

  def change do
    create table(:ng_users_tokens) do
      add :user_id, references(:ng_users, type: :uuid, on_delete: :delete_all), null: false
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
