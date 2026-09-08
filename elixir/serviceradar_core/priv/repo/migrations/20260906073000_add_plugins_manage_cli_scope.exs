defmodule ServiceRadar.Repo.Migrations.AddPluginsManageCliScope do
  @moduledoc """
  Makes `plugins.manage` requestable by the CLI device-code flow.
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
  end

  def down do
    alter table(:authorization_settings, prefix: @prefix) do
      modify(:cli_allowed_scopes, {:array, :text},
        null: false,
        default: fragment("ARRAY['dashboard.publish','plugin.publish']::text[]")
      )
    end
  end
end
