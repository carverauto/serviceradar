defmodule ServiceRadar.Repo.Migrations.AddPluginsManageCliScope do
  @moduledoc """
  Makes `plugins.manage` requestable by the CLI device-code flow.

  Two parts, because the column default only reaches rows created after it:

  1. The column default gains the scope, for fresh installs.
  2. Existing `authorization_settings` rows have it appended, so an upgraded
     instance does not answer `serviceradar-cli plugin apply` with
     `invalid_scope` until an operator hand-edits Settings.

  Appending is safe because the scope grants nothing on its own. It only makes
  the scope *requestable*; the device grant is still approved by a human in a
  browser, and every endpoint still checks the caller's RBAC permission.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:authorization_settings, prefix: @prefix) do
      modify(:cli_allowed_scopes, {:array, :text},
        null: false,
        default: fragment("ARRAY['dashboard.publish','plugin.publish','plugins.manage']::text[]")
      )
    end

    execute("""
    UPDATE #{@prefix}.authorization_settings
    SET cli_allowed_scopes = array_append(cli_allowed_scopes, 'plugins.manage')
    WHERE NOT ('plugins.manage' = ANY(cli_allowed_scopes))
    """)
  end

  def down do
    execute("""
    UPDATE #{@prefix}.authorization_settings
    SET cli_allowed_scopes = array_remove(cli_allowed_scopes, 'plugins.manage')
    """)

    alter table(:authorization_settings, prefix: @prefix) do
      modify(:cli_allowed_scopes, {:array, :text},
        null: false,
        default: fragment("ARRAY['dashboard.publish','plugin.publish']::text[]")
      )
    end
  end
end
