defmodule ServiceRadar.Repo.Migrations.CreateAuthoredDashboards do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:authored_dashboards, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:title, :text, null: false)
      add(:description, :text)
      add(:slug, :text)
      add(:owner_id, references(:ng_users, type: :uuid, prefix: @prefix, on_delete: :nilify_all))
      add(:visibility, :text, null: false, default: "private")
      add(:status, :text, null: false, default: "draft")
      add(:default_time_range, :text, null: false, default: "last_1h")
      add(:layout, :map, null: false, default: %{})
      add(:variables, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:archived_at, :utc_datetime_usec)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:authored_dashboards, [:slug],
        name: :authored_dashboards_slug_idx,
        prefix: @prefix,
        where: "slug IS NOT NULL"
      )
    )

    create(
      index(:authored_dashboards, [:owner_id, :status],
        name: :authored_dashboards_owner_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:authored_dashboards, [:visibility, :status],
        name: :authored_dashboards_visibility_status_idx,
        prefix: @prefix
      )
    )

    create table(:authored_dashboard_panels, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :dashboard_id,
        references(:authored_dashboards,
          column: :id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:title, :text, null: false)
      add(:srql_query, :text, null: false)
      add(:visual_type, :text, null: false, default: "table")
      add(:visual_config, :map, null: false, default: %{})
      add(:field_metadata, :map, null: false, default: %{})
      add(:layout, :map, null: false, default: %{})
      add(:refresh_interval_seconds, :integer, null: false, default: 0)
      add(:position, :integer, null: false, default: 0)
      add(:metadata, :map, null: false, default: %{})

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:authored_dashboard_panels, [:dashboard_id, :position],
        name: :authored_dashboard_panels_dashboard_position_idx,
        prefix: @prefix
      )
    )

    create(
      index(:authored_dashboard_panels, [:visual_type],
        name: :authored_dashboard_panels_visual_type_idx,
        prefix: @prefix
      )
    )

    create table(:dashboard_report_schedules, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :dashboard_id,
        references(:authored_dashboards,
          column: :id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:name, :text, null: false)
      add(:enabled, :boolean, null: false, default: true)
      add(:recipients, {:array, :text}, null: false, default: [])
      add(:cron, :text, null: false)
      add(:timezone, :text, null: false, default: "UTC")
      add(:format, :text, null: false, default: "html")
      add(:next_due_at, :utc_datetime_usec)
      add(:last_due_at, :utc_datetime_usec)
      add(:last_delivered_at, :utc_datetime_usec)
      add(:last_status, :text)
      add(:last_error, :text)
      add(:metadata, :map, null: false, default: %{})

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:dashboard_report_schedules, [:dashboard_id, :enabled],
        name: :dashboard_report_schedules_dashboard_enabled_idx,
        prefix: @prefix
      )
    )

    create(
      index(:dashboard_report_schedules, [:enabled, :next_due_at],
        name: :dashboard_report_schedules_due_idx,
        prefix: @prefix,
        where: "enabled = true AND next_due_at IS NOT NULL"
      )
    )

    create table(:dashboard_report_deliveries, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :schedule_id,
        references(:dashboard_report_schedules,
          column: :id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :dashboard_id,
        references(:authored_dashboards,
          column: :id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :nilify_all
        )
      )

      add(:due_at, :utc_datetime_usec, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:recipients, {:array, :text}, null: false, default: [])
      add(:recipient_count, :integer, null: false, default: 0)
      add(:message_id, :text)
      add(:error, :text)
      add(:rendered_metadata, :map, null: false, default: %{})
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      add(:sent_at, :utc_datetime_usec)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:dashboard_report_deliveries, [:schedule_id, :due_at],
        name: :dashboard_report_deliveries_schedule_due_idx,
        prefix: @prefix
      )
    )

    create(
      index(:dashboard_report_deliveries, [:dashboard_id, :inserted_at],
        name: :dashboard_report_deliveries_dashboard_inserted_idx,
        prefix: @prefix
      )
    )

    create(
      index(:dashboard_report_deliveries, [:status, :inserted_at],
        name: :dashboard_report_deliveries_status_inserted_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(
      index(:dashboard_report_deliveries, [:status, :inserted_at],
        name: :dashboard_report_deliveries_status_inserted_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      index(:dashboard_report_deliveries, [:dashboard_id, :inserted_at],
        name: :dashboard_report_deliveries_dashboard_inserted_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      unique_index(:dashboard_report_deliveries, [:schedule_id, :due_at],
        name: :dashboard_report_deliveries_schedule_due_idx,
        prefix: @prefix
      )
    )

    drop(table(:dashboard_report_deliveries, prefix: @prefix))

    drop_if_exists(
      index(:dashboard_report_schedules, [:enabled, :next_due_at],
        name: :dashboard_report_schedules_due_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      index(:dashboard_report_schedules, [:dashboard_id, :enabled],
        name: :dashboard_report_schedules_dashboard_enabled_idx,
        prefix: @prefix
      )
    )

    drop(table(:dashboard_report_schedules, prefix: @prefix))

    drop_if_exists(
      index(:authored_dashboard_panels, [:visual_type],
        name: :authored_dashboard_panels_visual_type_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      index(:authored_dashboard_panels, [:dashboard_id, :position],
        name: :authored_dashboard_panels_dashboard_position_idx,
        prefix: @prefix
      )
    )

    drop(table(:authored_dashboard_panels, prefix: @prefix))

    drop_if_exists(
      index(:authored_dashboards, [:visibility, :status],
        name: :authored_dashboards_visibility_status_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      index(:authored_dashboards, [:owner_id, :status],
        name: :authored_dashboards_owner_status_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      unique_index(:authored_dashboards, [:slug],
        name: :authored_dashboards_slug_idx,
        prefix: @prefix
      )
    )

    drop(table(:authored_dashboards, prefix: @prefix))
  end
end
