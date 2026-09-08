defmodule ServiceRadar.Repo.Migrations.AddSsoAutoProvisionToAuthSettings do
  @moduledoc """
  Adds `sso_auto_provision` to `platform.auth_settings`.

  This gates SSO just-in-time (JIT) provisioning. It defaults to `false` (deny):
  an SSO identity with no pre-existing local account is rejected rather than
  auto-created. Admins must explicitly opt in to auto-create accounts on first
  SSO login. See `ServiceRadarWebNGWeb.Auth.SSOProvisioning`.

  The `auth_settings` table is a singleton managed manually (the resource sets
  `migrate? false`), so this column is added by hand here.
  """

  use Ecto.Migration

  def up do
    alter table(:auth_settings, prefix: "platform") do
      add :sso_auto_provision, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:auth_settings, prefix: "platform") do
      remove :sso_auto_provision
    end
  end
end
