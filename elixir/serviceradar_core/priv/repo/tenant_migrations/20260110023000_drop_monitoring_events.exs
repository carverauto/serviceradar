defmodule ServiceRadar.Repo.TenantMigrations.DropMonitoringEvents do
  @moduledoc """
  Removes legacy monitoring_events in favor of OCSF events.
  """

  use Ecto.Migration

  def up do
    drop_if_exists table(:monitoring_events, prefix: prefix())
  end

  def down do
    create table(:monitoring_events, primary_key: false, prefix: prefix()) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :category, :text, null: false
      add :event_type, :text, null: false
      add :severity, :bigint, default: 1
      add :message, :text, null: false
      add :details, :text
      add :source_type, :text
      add :source_id, :text
      add :source_name, :text
      add :target_type, :text
      add :target_id, :text
      add :target_name, :text

      add :device_uid,
          references(:ocsf_devices,
            column: :uid,
            name: "monitoring_events_device_uid_fkey",
            type: :text,
            prefix: prefix()
          )

      add :agent_uid,
          references(:ocsf_agents,
            column: :uid,
            name: "monitoring_events_agent_uid_fkey",
            type: :text,
            prefix: prefix()
          )

      add :alert_id, :uuid
      add :metadata, :map, default: %{}
      add :tags, {:array, :text}, default: []
      add :actor_type, :text
      add :actor_id, :text
      add :actor_name, :text
      add :client_ip, :text
      add :occurred_at, :utc_datetime, null: false
      add :tenant_id, :uuid, null: false

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    alter table(:monitoring_events, prefix: prefix()) do
      modify :alert_id,
             references(:alerts,
               column: :id,
               name: "monitoring_events_alert_id_fkey",
               type: :uuid,
               prefix: prefix()
             )
    end
  end
end
