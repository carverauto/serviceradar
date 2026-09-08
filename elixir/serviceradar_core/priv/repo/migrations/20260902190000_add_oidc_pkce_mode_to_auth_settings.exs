defmodule ServiceRadar.Repo.Migrations.AddOidcPkceModeToAuthSettings do
  @moduledoc """
  Adds `oidc_pkce_mode` to `platform.auth_settings`.

  Controls Proof Key for Code Exchange on the upstream OIDC login
  (confidential authorization-code client). Default `auto` sends S256
  unless discovery lists challenge methods without S256.

  The `auth_settings` table is a singleton managed manually (the resource
  sets `migrate? false`), so this column is added by hand here.
  """

  use Ecto.Migration

  def up do
    alter table(:auth_settings, prefix: "platform") do
      add :oidc_pkce_mode, :string, null: false, default: "auto"
    end
  end

  def down do
    alter table(:auth_settings, prefix: "platform") do
      remove :oidc_pkce_mode
    end
  end
end
