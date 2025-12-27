defmodule ServiceRadarWebNG.Repo.Migrations.CreateAshAuthTokens do
  @moduledoc """
  Creates the token table for AshAuthentication.

  This runs alongside the existing ng_users_tokens table during
  the migration period. Once AshAuthentication is fully adopted,
  the old table can be deprecated.
  """
  use Ecto.Migration

  def change do
    create table(:user_tokens, primary_key: false) do
      # JTI is the JWT ID - used as primary key per AshAuthentication requirements
      add :jti, :string, null: false, primary_key: true
      # Token subject (user identifier)
      add :subject, :string, null: false
      # Token purpose (e.g., "user", "confirm", "reset")
      add :purpose, :string, null: false
      # Extra data stored with token
      add :extra_data, :map, default: %{}
      # When the token expires
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:user_tokens, [:subject])
    create index(:user_tokens, [:purpose])
    create index(:user_tokens, [:expires_at])
  end
end
