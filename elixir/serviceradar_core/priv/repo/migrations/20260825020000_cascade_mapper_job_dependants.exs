defmodule ServiceRadar.Repo.Migrations.CascadeMapperJobDependants do
  @moduledoc """
  Deleting a discovery job silently orphaned everything that referenced it.

  `mapper_job_seeds.mapper_job_id` and `mapper_unifi_controllers.mapper_job_id`
  had NO foreign key at all -- only `credential_secret_id` did. So removing a job
  left its seeds and its UniFi controllers pointing at an id that no longer
  exists: invisible in the UI (which lists jobs), still present in the database,
  and impossible for an operator to find or remove through the product.

  Observed on a real deployment: a job deleted on 2026-08-11 while splitting two
  networks left behind a seed (`192.168.1.1`) and a UniFi controller (`farm01`,
  `https://192.168.1.1/...`), both referencing job
  `340c1db1-df38-465d-b3d6-0b3785b31ec9`. The links that job had produced -- 390
  of 521, 75% of the topology -- froze on that date and were still being drawn as
  current two weeks later.

  A foreign key with ON DELETE CASCADE makes this the database's problem rather
  than a thing application code has to remember. Cascade rather than SET NULL
  because neither row means anything without its job: a seed with no job is never
  scanned, and a controller with no job is never polled.

  serviceradar:allow-startup-maintenance -- the DELETE below is not general
  cleanup. Adding the constraint FAILS while violating rows exist, so removing
  them is a precondition of the schema change, not maintenance done alongside it.
  It is bounded by the number of orphans in two small operator-managed config
  tables (single digits on the deployment that motivated this), and it is
  restricted to rows whose referenced job does not exist -- a row a foreign key
  would have made impossible to create.
  """
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM platform.mapper_job_seeds s
    WHERE NOT EXISTS (SELECT 1 FROM platform.mapper_jobs j WHERE j.id = s.mapper_job_id)
    """)

    execute("""
    DELETE FROM platform.mapper_unifi_controllers c
    WHERE NOT EXISTS (SELECT 1 FROM platform.mapper_jobs j WHERE j.id = c.mapper_job_id)
    """)

    alter table(:mapper_job_seeds, prefix: "platform") do
      modify :mapper_job_id,
             references(:mapper_jobs,
               prefix: "platform",
               type: :uuid,
               on_delete: :delete_all,
               name: :mapper_job_seeds_mapper_job_id_fkey
             ),
             from: :uuid
    end

    alter table(:mapper_unifi_controllers, prefix: "platform") do
      modify :mapper_job_id,
             references(:mapper_jobs,
               prefix: "platform",
               type: :uuid,
               on_delete: :delete_all,
               name: :mapper_unifi_controllers_mapper_job_id_fkey
             ),
             from: :uuid
    end
  end

  def down do
    alter table(:mapper_job_seeds, prefix: "platform") do
      modify :mapper_job_id, :uuid,
        from:
          references(:mapper_jobs,
            prefix: "platform",
            type: :uuid,
            on_delete: :delete_all,
            name: :mapper_job_seeds_mapper_job_id_fkey
          )
    end

    alter table(:mapper_unifi_controllers, prefix: "platform") do
      modify :mapper_job_id, :uuid,
        from:
          references(:mapper_jobs,
            prefix: "platform",
            type: :uuid,
            on_delete: :delete_all,
            name: :mapper_unifi_controllers_mapper_job_id_fkey
          )
    end
  end
end
