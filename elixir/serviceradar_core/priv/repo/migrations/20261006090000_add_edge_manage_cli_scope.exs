defmodule ServiceRadar.Repo.Migrations.AddEdgeManageCliScope do
  @moduledoc """
  Makes `edge.manage` requestable by the CLI device-code flow.

  1. The column default gains the scope, for fresh installs.
  2. Existing `authorization_settings` rows have it appended, so an existing
     tenant answers `serviceradar-cli login --scope "dashboard.publish edge.manage"`
     instead of rejecting it with `invalid_scope`.

  Appending is safe for the same reason as `plugin.publish`: the scope grants
  nothing on its own. It only makes the scope requestable, a human still
  approves the device grant in a browser, and every edge endpoint still checks
  the user's `settings.edge.manage` permission. With `Auth.NarrowScopes`, a
  token holding only `edge.manage` reaches the edge routes and nothing else.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:authorization_settings, prefix: @prefix) do
      modify(:cli_allowed_scopes, {:array, :text},
        null: false,
        default: fragment("ARRAY['dashboard.publish','plugin.publish','plugins.manage','edge.manage']::text[]")
      )
    end

    execute("""
    UPDATE #{@prefix}.authorization_settings
    SET cli_allowed_scopes = array_append(cli_allowed_scopes, 'edge.manage')
    WHERE NOT ('edge.manage' = ANY(cli_allowed_scopes))
    """)
  end

  def down do
    execute("""
    UPDATE #{@prefix}.authorization_settings
    SET cli_allowed_scopes = array_remove(cli_allowed_scopes, 'edge.manage')
    """)

    alter table(:authorization_settings, prefix: @prefix) do
      modify(:cli_allowed_scopes, {:array, :text},
        null: false,
        default: fragment("ARRAY['dashboard.publish','plugin.publish','plugins.manage']::text[]")
      )
    end
  end
end
