defmodule ServiceRadar.Repo.Migrations.CreateOauthClients do
  @moduledoc """
  Creates the oauth_clients table for user self-service API credentials.

  Users can create OAuth2 client credentials to access the API programmatically.
  Each client has:
  - A client_id (UUID) - shown to user, used for identification
  - A client_secret hash - secret is shown once at creation, then hashed
  - Scopes - what the client can access (read, write, admin)
  - Usage tracking - when/where the client was last used
  """
  use Ecto.Migration

  def change do
    create table(:oauth_clients, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true
      add :user_id, references(:ng_users, type: :uuid, prefix: "platform", on_delete: :delete_all), null: false

      # Client identification
      add :name, :string, null: false
      add :description, :text

      # Credentials - client_id is the primary key (id), secret_hash stores bcrypt hash
      add :secret_hash, :string, null: false
      add :secret_prefix, :string, size: 8, null: false  # First 8 chars for display

      # Permissions
      add :scopes, {:array, :string}, null: false, default: ["read"]

      # Status
      add :enabled, :boolean, null: false, default: true
      add :revoked_at, :utc_datetime_usec

      # Usage tracking
      add :last_used_at, :utc_datetime_usec
      add :last_used_ip, :string
      add :use_count, :integer, null: false, default: 0

      # Expiration
      add :expires_at, :utc_datetime_usec

      timestamps()
    end

    # Index for user lookup
    create index(:oauth_clients, [:user_id], prefix: "platform")

    # Index for finding active clients by user
    create index(:oauth_clients, [:user_id, :enabled], prefix: "platform",
      where: "revoked_at IS NULL")

    # Index for validation by secret prefix (fast lookup)
    create index(:oauth_clients, [:secret_prefix], prefix: "platform")
  end
end
