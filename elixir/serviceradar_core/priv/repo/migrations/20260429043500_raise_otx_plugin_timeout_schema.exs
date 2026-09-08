defmodule ServiceRadar.Repo.Migrations.RaiseOtxPluginTimeoutSchema do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    UPDATE platform.plugin_packages
    SET config_schema = jsonb_set(
          config_schema::jsonb,
          '{properties,timeout_ms,maximum}',
          '600000'::jsonb,
          true
        ),
        updated_at = now()
    WHERE plugin_id = 'alienvault-otx-threat-intel'
      AND config_schema::jsonb #>> '{properties,timeout_ms,maximum}' = '120000'
    """)
  end

  def down do
    execute("""
    UPDATE platform.plugin_packages
    SET config_schema = jsonb_set(
          config_schema::jsonb,
          '{properties,timeout_ms,maximum}',
          '120000'::jsonb,
          true
        ),
        updated_at = now()
    WHERE plugin_id = 'alienvault-otx-threat-intel'
      AND config_schema::jsonb #>> '{properties,timeout_ms,maximum}' = '600000'
    """)
  end
end
