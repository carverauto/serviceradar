defmodule ServiceRadar.Repo.Migrations.SeedDeviceAvailabilityTargetGroupsDashboard do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"
  @slug "device-availability-target-groups"

  def up do
    execute("""
    WITH dashboard AS (
      INSERT INTO #{@prefix}.authored_dashboards (
        dashboard_ref,
        title,
        description,
        slug,
        visibility,
        status,
        default_time_range,
        layout,
        variables,
        metadata
      )
      VALUES (
        (
          SELECT ref
          FROM generate_series(1903400, 1903499) AS ref
          WHERE NOT EXISTS (
            SELECT 1
            FROM #{@prefix}.authored_dashboards existing
            WHERE existing.dashboard_ref = ref
          )
          ORDER BY ref
          LIMIT 1
        ),
        'Device Availability by Target Group',
        'Sample dashboard showing SRQL-driven device availability distributions for Armis metadata tags and infrastructure device types.',
        '#{@slug}',
        'public',
        'active',
        'last_24h',
        '{}'::jsonb,
        '{}'::jsonb,
        '{"source":"first_party_sample","sample":"device_availability_target_groups"}'::jsonb
      )
      ON CONFLICT (slug) WHERE slug IS NOT NULL DO UPDATE SET
        title = EXCLUDED.title,
        description = EXCLUDED.description,
        visibility = EXCLUDED.visibility,
        status = EXCLUDED.status,
        default_time_range = EXCLUDED.default_time_range,
        metadata = EXCLUDED.metadata,
        updated_at = (now() AT TIME ZONE 'utc')
      RETURNING id
    ),
    removed_panels AS (
      DELETE FROM #{@prefix}.authored_dashboard_panels
      WHERE dashboard_id = (SELECT id FROM dashboard)
    )
    INSERT INTO #{@prefix}.authored_dashboard_panels (
      dashboard_id,
      dataset_key,
      title,
      srql_query,
      visual_type,
      builder_state,
      data_binding,
      display_config,
      visual_config,
      field_metadata,
      layout,
      refresh_interval_seconds,
      position,
      metadata
    )
    SELECT
      dashboard.id,
      panel.dataset_key,
      panel.title,
      panel.srql_query,
      'bar',
      '{}'::jsonb,
      '{"value_field":"count","label_field":"is_available","dataset":"primary"}'::jsonb,
      jsonb_build_object(
        'label', 'Availability state',
        'caption', panel.caption,
        'unit', 'devices'
      ),
      '{}'::jsonb,
      '{"fields":[{"name":"is_available","type":"boolean"},{"name":"count","type":"number"}],"compatible_visuals":["table","bar","category","pivot"]}'::jsonb,
      panel.layout,
      300,
      panel.position,
      '{"source":"first_party_sample","sample":"device_availability_target_groups"}'::jsonb
    FROM dashboard
    CROSS JOIN (
      VALUES
        (
          'armis_development',
          'Armis Development Tags',
          'in:devices metadata.armis_tags:%development% stats:"count() as count by is_available" sort:count:desc limit:5',
          'Faker/Armis devices with development in metadata.armis_tags.',
          '{"x":0,"y":0,"w":6,"h":5,"order":0}'::jsonb,
          0
        ),
        (
          'armis_testing',
          'Armis Testing Tags',
          'in:devices metadata.armis_tags:%testing% stats:"count() as count by is_available" sort:count:desc limit:5',
          'Faker/Armis devices with testing in metadata.armis_tags.',
          '{"x":6,"y":0,"w":6,"h":5,"order":1}'::jsonb,
          1
        ),
        (
          'workstations',
          'Workstations',
          'in:devices type:Workstation stats:"count() as count by is_available" sort:count:desc limit:5',
          'Endpoint devices classified as Workstation.',
          '{"x":0,"y":5,"w":6,"h":5,"order":2}'::jsonb,
          2
        ),
        (
          'hypervisors',
          'Hypervisors',
          'in:devices type:Hypervisor stats:"count() as count by is_available" sort:count:desc limit:5',
          'Infrastructure devices classified as Hypervisor.',
          '{"x":6,"y":5,"w":6,"h":5,"order":3}'::jsonb,
          3
        ),
        (
          'routers_switches',
          'Routers and Switches',
          'in:devices type:(Router,Switch) stats:"count() as count by is_available" sort:count:desc limit:5',
          'Network infrastructure devices classified as Router or Switch.',
          '{"x":0,"y":10,"w":12,"h":5,"order":4}'::jsonb,
          4
        )
    ) AS panel(dataset_key, title, srql_query, caption, layout, position);
    """)
  end

  def down do
    execute("""
    DELETE FROM #{@prefix}.authored_dashboard_panels
    WHERE dashboard_id IN (
      SELECT id
      FROM #{@prefix}.authored_dashboards
      WHERE slug = '#{@slug}'
        AND metadata->>'sample' = 'device_availability_target_groups'
    );

    DELETE FROM #{@prefix}.authored_dashboards
    WHERE slug = '#{@slug}'
      AND metadata->>'sample' = 'device_availability_target_groups';
    """)
  end
end
