defmodule ServiceRadar.Repo.Migrations.AddPluginPublishCliScope do
  @moduledoc """
  Makes `plugin.publish` requestable by the CLI device-code flow.

  Two parts, because the column default only reaches rows created after it:

  1. The column default gains the scope, for fresh installs.
  2. Existing `authorization_settings` rows have it appended, so an upgraded
     instance does not answer `serviceradar-cli plugin publish` with
     `invalid_scope` until an operator hand-edits Settings.

  Appending is safe because the scope grants nothing on its own. It only makes
  the scope *requestable*; the device grant is still approved by a human in a
  browser, and every plugin endpoint still checks the user's `plugins.stage`
  RBAC permission. What the scope does is *narrow* a CLI token -- with
  `Auth.NarrowScopes`, a token holding only `plugin.publish` can reach the
  plugin publish routes and nothing else, where before this change a
  `dashboard.publish` token could reach them all.

  Rows that an operator has deliberately narrowed to a list excluding
  `dashboard.publish` are still appended to: the setting is an allow-list of
  what may be *requested*, not a record of a decision to forbid publishing
  plugins, which was not an expressible choice before this migration.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:authorization_settings, prefix: @prefix) do
      modify(:cli_allowed_scopes, {:array, :text},
        null: false,
        default: fragment("ARRAY['dashboard.publish','plugin.publish']::text[]")
      )
    end

    execute("""
    UPDATE #{@prefix}.authorization_settings
    SET cli_allowed_scopes = array_append(cli_allowed_scopes, 'plugin.publish')
    WHERE NOT ('plugin.publish' = ANY(cli_allowed_scopes))
    """)
  end

  def down do
    execute("""
    UPDATE #{@prefix}.authorization_settings
    SET cli_allowed_scopes = array_remove(cli_allowed_scopes, 'plugin.publish')
    """)

    alter table(:authorization_settings, prefix: @prefix) do
      modify(:cli_allowed_scopes, {:array, :text},
        null: false,
        default: fragment("ARRAY['dashboard.publish']::text[]")
      )
    end
  end
end
