defmodule ServiceRadar.Repo.Migrations.AddDeviceAgentAvailability do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:ocsf_devices, prefix: "platform") do
      add :availability_source_agent_id, :text
    end

    alter table(:integration_sources, prefix: "platform") do
      add :northbound_availability_source_agent_id, :text
    end

    create index(:ocsf_devices, [:availability_source_agent_id],
             prefix: "platform",
             name: "ocsf_devices_availability_source_agent_id_idx"
           )

    create index(:integration_sources, [:northbound_availability_source_agent_id],
             prefix: "platform",
             name: "integration_sources_northbound_availability_source_agent_id_idx"
           )

    create table(:device_agent_availability, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :device_uid,
          references(:ocsf_devices,
            column: :uid,
            type: :text,
            prefix: "platform",
            on_delete: :delete_all
          ),
          null: false

      add :agent_id, :text, null: false
      add :agent_name, :text
      add :is_available, :boolean, null: false
      add :checked_at, :utc_datetime_usec, null: false
      add :response_time_ms, :bigint
      add :open_ports, {:array, :integer}, null: false, default: []
      add :sweep_modes_results, :map, null: false, default: %{}
      add :sweep_group_id, :uuid
      add :execution_id, :uuid
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:device_agent_availability, [:device_uid, :agent_id],
             prefix: "platform",
             name: "device_agent_availability_device_agent_uidx"
           )

    create index(:device_agent_availability, [:device_uid],
             prefix: "platform",
             name: "device_agent_availability_device_uid_idx"
           )

    create index(:device_agent_availability, [:agent_id],
             prefix: "platform",
             name: "device_agent_availability_agent_id_idx"
           )

    create index(:device_agent_availability, [:device_uid, :checked_at],
             prefix: "platform",
             name: "device_agent_availability_device_checked_at_idx"
           )
  end
end
