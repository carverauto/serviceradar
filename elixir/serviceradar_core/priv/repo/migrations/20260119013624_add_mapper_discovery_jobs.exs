defmodule ServiceRadar.Repo.Migrations.AddMapperDiscoveryJobs do
  @moduledoc """
  Adds mapper discovery job tables.
  """

  use Ecto.Migration

  def up do
    create table(:mapper_jobs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :enabled, :boolean, null: false, default: true
      add :interval, :text, null: false, default: "2h"
      add :partition, :text, null: false, default: "default"
      add :agent_id, :text
      add :discovery_mode, :text, null: false, default: "snmp"
      add :discovery_type, :text, null: false, default: "full"
      add :concurrency, :bigint, null: false, default: 10
      add :timeout, :text, null: false, default: "45s"
      add :retries, :bigint, null: false, default: 2
      add :options, :map, null: false, default: %{}
      add :last_run_at, :utc_datetime

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:mapper_jobs, [:name], name: "mapper_jobs_unique_name_index")
    create index(:mapper_jobs, [:partition], name: "mapper_jobs_partition_idx")
    create index(:mapper_jobs, [:agent_id],
             where: "agent_id IS NOT NULL",
             name: "mapper_jobs_agent_idx"
           )

    create table(:mapper_job_seeds, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :seed, :text, null: false
      add :mapper_job_id, :uuid, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:mapper_job_seeds, [:mapper_job_id], name: "mapper_job_seeds_job_idx")

    create unique_index(:mapper_job_seeds, [:mapper_job_id, :seed],
             name: "mapper_job_seeds_unique_seed_per_job_index"
           )

    create table(:mapper_snmp_credentials, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text
      add :version, :text, null: false, default: "v2c"
      add :encrypted_community, :binary
      add :username, :text
      add :auth_protocol, :text
      add :encrypted_auth_password, :binary
      add :privacy_protocol, :text
      add :encrypted_privacy_password, :binary
      add :mapper_job_id, :uuid, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:mapper_snmp_credentials, [:mapper_job_id],
             name: "mapper_snmp_credentials_job_idx"
           )

    create unique_index(:mapper_snmp_credentials, [:mapper_job_id],
             name: "mapper_snmp_credentials_unique_job_credential_index"
           )

    create table(:mapper_unifi_controllers, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text
      add :base_url, :text, null: false
      add :encrypted_api_key, :binary
      add :insecure_skip_verify, :boolean, null: false, default: false
      add :mapper_job_id, :uuid, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:mapper_unifi_controllers, [:mapper_job_id],
             name: "mapper_unifi_controllers_job_idx"
           )

    create unique_index(:mapper_unifi_controllers, [:mapper_job_id, :base_url],
             name: "mapper_unifi_controllers_unique_base_url_per_job_index"
           )
  end

  def down do
    drop_if_exists unique_index(:mapper_unifi_controllers,
                     [:mapper_job_id, :base_url],
                     name: "mapper_unifi_controllers_unique_base_url_per_job_index"
                   )

    drop_if_exists index(:mapper_unifi_controllers, [:mapper_job_id],
                     name: "mapper_unifi_controllers_job_idx"
                   )

    drop_if_exists table(:mapper_unifi_controllers)

    drop_if_exists unique_index(:mapper_snmp_credentials, [:mapper_job_id],
                     name: "mapper_snmp_credentials_unique_job_credential_index"
                   )

    drop_if_exists index(:mapper_snmp_credentials, [:mapper_job_id],
                     name: "mapper_snmp_credentials_job_idx"
                   )

    drop_if_exists table(:mapper_snmp_credentials)

    drop_if_exists unique_index(:mapper_job_seeds, [:mapper_job_id, :seed],
                     name: "mapper_job_seeds_unique_seed_per_job_index"
                   )

    drop_if_exists index(:mapper_job_seeds, [:mapper_job_id],
                     name: "mapper_job_seeds_job_idx"
                   )

    drop_if_exists table(:mapper_job_seeds)

    drop_if_exists index(:mapper_jobs, [:agent_id], name: "mapper_jobs_agent_idx")
    drop_if_exists index(:mapper_jobs, [:partition], name: "mapper_jobs_partition_idx")

    drop_if_exists unique_index(:mapper_jobs, [:name],
                     name: "mapper_jobs_unique_name_index"
                   )

    drop_if_exists table(:mapper_jobs)
  end
end
