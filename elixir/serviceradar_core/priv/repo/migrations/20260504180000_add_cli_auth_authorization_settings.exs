defmodule ServiceRadar.Repo.Migrations.AddCliAuthAuthorizationSettings do
  @moduledoc """
  Adds the three CLI device-code policy fields to AuthorizationSettings.

  - cli_auth_enabled (bool, default true): admin kill-switch for the
    whole flow. When false, /api/v1/cli/auth/{device,token} respond
    503 with error: cli_auth_disabled and the CLI's manual-token
    fallback takes over.
  - cli_session_ttl_days (integer, default 30): TTL applied to JWTs
    minted from the device-code flow.
  - cli_allowed_scopes (text[], default ['dashboard.publish']):
    request scopes outside this allow-list 400 with invalid_scope.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:authorization_settings, prefix: @prefix) do
      add(:cli_auth_enabled, :boolean, null: false, default: true)
      add(:cli_session_ttl_days, :integer, null: false, default: 30)

      add(:cli_allowed_scopes, {:array, :text},
        null: false,
        default: fragment("ARRAY['dashboard.publish']::text[]")
      )
    end
  end

  def down do
    alter table(:authorization_settings, prefix: @prefix) do
      remove(:cli_allowed_scopes)
      remove(:cli_session_ttl_days)
      remove(:cli_auth_enabled)
    end
  end
end
