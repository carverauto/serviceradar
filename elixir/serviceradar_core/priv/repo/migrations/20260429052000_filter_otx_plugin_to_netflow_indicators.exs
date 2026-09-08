defmodule ServiceRadar.Repo.Migrations.FilterOtxPluginToNetflowIndicators do
  @moduledoc false
  use Ecto.Migration

  @default_types "IPv4,IPv6,CIDR"

  def up do
    execute("""
    UPDATE platform.plugin_packages
    SET config_schema =
          jsonb_set(
            jsonb_set(
              jsonb_set(
                jsonb_set(
                  config_schema::jsonb,
                  '{properties,types}',
                  '{"type":"string","description":"Comma-delimited OTX indicator types to fetch","default":"#{@default_types}"}'::jsonb,
                  true
                ),
                '{properties,limit,maximum}',
                '1000'::jsonb,
                true
              ),
              '{properties,limit,default}',
              '1000'::jsonb,
              true
            ),
            '{properties,timeout_ms,maximum}',
            '600000'::jsonb,
            true
          ),
        updated_at = now()
    WHERE plugin_id = 'alienvault-otx-threat-intel'
    """)

    execute("""
    UPDATE platform.plugin_assignments AS assignment
    SET params =
          assignment.params::jsonb ||
          jsonb_build_object(
            'types', '#{@default_types}',
            'limit', 1000,
            'page', 1,
            'cursor_complete', false,
            'cursor_next', NULL,
            'run_nonce', floor(extract(epoch FROM now()))::bigint
          ),
        updated_at = now()
    FROM platform.plugin_packages AS package
    WHERE package.id = assignment.plugin_package_id
      AND package.plugin_id = 'alienvault-otx-threat-intel'
      AND NOT assignment.params::jsonb ? 'types'
    """)
  end

  def down do
    execute("""
    UPDATE platform.plugin_assignments AS assignment
    SET params = assignment.params::jsonb - 'types',
        updated_at = now()
    FROM platform.plugin_packages AS package
    WHERE package.id = assignment.plugin_package_id
      AND package.plugin_id = 'alienvault-otx-threat-intel'
      AND assignment.params::jsonb->>'types' = '#{@default_types}'
    """)

    execute("""
    UPDATE platform.plugin_packages
    SET config_schema =
          jsonb_set(
            jsonb_set(
              config_schema::jsonb #- '{properties,types}',
              '{properties,limit,maximum}',
              '100'::jsonb,
              true
            ),
            '{properties,limit,default}',
            '100'::jsonb,
            true
          ),
        updated_at = now()
    WHERE plugin_id = 'alienvault-otx-threat-intel'
    """)
  end
end
