defmodule ServiceRadar.Repo.Migrations.CreateAnsibleIntegrationTables do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS #{@prefix}")

    create table(:ansible_controllers, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:base_url, :text, null: false)
      add(:awx_version, :text)
      add(:agent_id, :text, null: false)
      add(:credential_secret_id, :uuid, null: false)
      add(:inventory_sync_interval_seconds, :bigint, null: false, default: 300)
      add(:catalog_sync_interval_seconds, :bigint, null: false, default: 600)
      add(:run_pulse_interval_ms, :bigint, null: false, default: 2000)
      add(:status, :text, null: false, default: "unknown")
      add(:last_health_at, :utc_datetime_usec)
      add(:last_health_summary, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_controllers, [:name],
        name: "ansible_controllers_unique_name_index",
        prefix: @prefix
      )
    )

    create_version_table(:ansible_controller_versions, :ansible_controllers)

    create table(:ansible_playbook_repositories, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:git_url, :text, null: false)
      add(:git_ref, :text, null: false, default: "main")
      add(:sync_interval_seconds, :bigint, null: false, default: 600)
      add(:credential_secret_id, :uuid)
      add(:last_sync_at, :utc_datetime_usec)
      add(:last_sync_status, :text, null: false, default: "pending")
      add(:last_sync_summary, :text)
      add(:parse_diagnostics, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_playbook_repositories, [:name],
        name: "ansible_playbook_repositories_unique_name_index",
        prefix: @prefix
      )
    )

    create(
      unique_index(:ansible_playbook_repositories, [:git_url, :git_ref],
        name: "ansible_playbook_repositories_unique_url_ref_index",
        prefix: @prefix
      )
    )

    create_version_table(:ansible_playbook_repository_versions, :ansible_playbook_repositories)

    create table(:ansible_playbooks, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :repository_id,
        references(:ansible_playbook_repositories,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        )
      )

      add(
        :controller_id,
        references(:ansible_controllers,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        )
      )

      add(:source_type, :text, null: false)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:path, :text)
      add(:tags, {:array, :text}, null: false, default: [])
      add(:hosts_pattern, :text)
      add(:declared_vars, :map, null: false, default: %{})
      add(:vars_prompt, {:array, :map}, null: false, default: [])
      add(:survey_spec, :map, null: false, default: %{})
      add(:awx_job_template_id, :bigint)
      add(:parse_status, :text, null: false, default: "pending")
      add(:parse_diagnostics, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_playbooks, [:repository_id, :path],
        name: "ansible_playbooks_unique_git_path_index",
        prefix: @prefix,
        where: "source_type = 'git'"
      )
    )

    create(
      unique_index(:ansible_playbooks, [:controller_id, :awx_job_template_id],
        name: "ansible_playbooks_unique_awx_template_index",
        prefix: @prefix,
        where: "source_type = 'awx'"
      )
    )

    create_version_table(:ansible_playbook_versions, :ansible_playbooks)

    create table(:ansible_playbook_schedules, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:enabled, :boolean, null: false, default: true)

      add(
        :playbook_id,
        references(:ansible_playbooks, type: :uuid, on_delete: :restrict, prefix: @prefix),
        null: false
      )

      add(:target_device_uids, {:array, :text}, null: false, default: [])
      add(:requested_extra_vars, :map, null: false, default: %{})
      add(:cron, :text, null: false)
      add(:timezone, :text, null: false, default: "UTC")
      add(:allow_concurrent, :boolean, null: false, default: false)
      add(:owner_id, :uuid)
      add(:last_evaluated_at, :utc_datetime_usec)
      add(:last_run_id, :uuid)
      add(:next_run_at, :utc_datetime_usec)
      add(:last_evaluation_outcome, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_playbook_schedules, [:name],
        name: "ansible_playbook_schedules_unique_name_index",
        prefix: @prefix
      )
    )

    create_version_table(:ansible_playbook_schedule_versions, :ansible_playbook_schedules)

    create table(:ansible_playbook_runs, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :playbook_id,
        references(:ansible_playbooks, type: :uuid, on_delete: :restrict, prefix: @prefix),
        null: false
      )

      add(
        :controller_id,
        references(:ansible_controllers, type: :uuid, on_delete: :restrict, prefix: @prefix),
        null: false
      )

      add(
        :schedule_id,
        references(:ansible_playbook_schedules,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:awx_job_id, :bigint)
      add(:state, :text, null: false, default: "pending")
      add(:requested_extra_vars, :map, null: false, default: %{})
      add(:requested_by_actor_id, :uuid)
      add(:host_limit, :text)
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:last_event_id, :bigint, null: false, default: 0)
      add(:summary, :text)
      add(:diagnostics, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(index(:ansible_playbook_runs, [:controller_id, :state], prefix: @prefix))
    create(index(:ansible_playbook_runs, [:schedule_id], prefix: @prefix))

    execute("""
    ALTER TABLE #{@prefix}.ansible_playbook_schedules
    ADD CONSTRAINT ansible_playbook_schedules_last_run_id_fkey
    FOREIGN KEY (last_run_id)
    REFERENCES #{@prefix}.ansible_playbook_runs(id)
    ON DELETE SET NULL
    """)

    create_version_table(:ansible_playbook_run_versions, :ansible_playbook_runs)

    create table(:ansible_playbook_run_targets, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :run_id,
        references(:ansible_playbook_runs,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:device_uid, :text, null: false)
      add(:awx_host_id, :bigint)
      add(:awx_host_name, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:changed_count, :bigint, null: false, default: 0)
      add(:failed_count, :bigint, null: false, default: 0)
      add(:ok_count, :bigint, null: false, default: 0)
      add(:skipped_count, :bigint, null: false, default: 0)
      add(:unreachable_count, :bigint, null: false, default: 0)
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_playbook_run_targets, [:run_id, :awx_host_name],
        name: "ansible_playbook_run_targets_unique_run_host_index",
        prefix: @prefix
      )
    )

    create table(:ansible_playbook_plays, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :run_id,
        references(:ansible_playbook_runs,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:awx_play_uuid, :text, null: false)
      add(:name, :text)
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:status, :text, null: false, default: "running")
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_playbook_plays, [:run_id, :awx_play_uuid],
        name: "ansible_playbook_plays_unique_play_uuid_index",
        prefix: @prefix
      )
    )

    create table(:ansible_playbook_tasks, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :play_id,
        references(:ansible_playbook_plays,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:awx_task_uuid, :text, null: false)
      add(:name, :text)
      add(:action, :text)
      add(:is_handler, :boolean, null: false, default: false)
      add(:path, :text)
      add(:line_number, :bigint)
      add(:tags, {:array, :text}, null: false, default: [])
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_playbook_tasks, [:play_id, :awx_task_uuid],
        name: "ansible_playbook_tasks_unique_task_uuid_index",
        prefix: @prefix
      )
    )

    create table(:ansible_playbook_contents, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:sha256, :text, null: false)
      add(:payload, :text, null: false)
      add(:size_bytes, :bigint, null: false)
      add(:encoding, :text, null: false, default: "utf8")
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_playbook_contents, [:sha256],
        name: "ansible_playbook_contents_unique_sha256_index",
        prefix: @prefix
      )
    )

    create table(:ansible_playbook_task_results, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :task_id,
        references(:ansible_playbook_tasks,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :run_target_id,
        references(:ansible_playbook_run_targets,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :stdout_content_id,
        references(:ansible_playbook_contents,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(
        :stderr_content_id,
        references(:ansible_playbook_contents,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:awx_event_id, :bigint, null: false)
      add(:status, :text, null: false)
      add(:changed, :boolean, null: false, default: false)
      add(:ignore_errors, :boolean, null: false, default: false)
      add(:delegated_to, :text)
      add(:result_payload, :map, null: false, default: %{})
      add(:event_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_playbook_task_results, [:task_id, :run_target_id, :awx_event_id],
        name: "ansible_playbook_task_results_unique_awx_event_index",
        prefix: @prefix
      )
    )
  end

  def down do
    execute("""
    ALTER TABLE #{@prefix}.ansible_playbook_schedules
    DROP CONSTRAINT IF EXISTS ansible_playbook_schedules_last_run_id_fkey
    """)

    drop_if_exists(table(:ansible_playbook_task_results, prefix: @prefix))
    drop_if_exists(table(:ansible_playbook_contents, prefix: @prefix))
    drop_if_exists(table(:ansible_playbook_tasks, prefix: @prefix))
    drop_if_exists(table(:ansible_playbook_plays, prefix: @prefix))
    drop_if_exists(table(:ansible_playbook_run_targets, prefix: @prefix))
    drop_if_exists(table(:ansible_playbook_run_versions, prefix: @prefix))
    drop_if_exists(table(:ansible_playbook_runs, prefix: @prefix))
    drop_if_exists(table(:ansible_playbook_schedule_versions, prefix: @prefix))
    drop_if_exists(table(:ansible_playbook_schedules, prefix: @prefix))
    drop_if_exists(table(:ansible_playbook_versions, prefix: @prefix))
    drop_if_exists(table(:ansible_playbooks, prefix: @prefix))
    drop_if_exists(table(:ansible_playbook_repository_versions, prefix: @prefix))
    drop_if_exists(table(:ansible_playbook_repositories, prefix: @prefix))
    drop_if_exists(table(:ansible_controller_versions, prefix: @prefix))
    drop_if_exists(table(:ansible_controllers, prefix: @prefix))
  end

  defp create_version_table(version_table, source_table) do
    create table(version_table, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false, default: %{})

      add(
        :version_source_id,
        references(source_table, type: :uuid, on_delete: :delete_all, prefix: @prefix),
        null: false
      )

      add(:changes, :map, null: false, default: %{})
      add(:version_inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:version_updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(index(version_table, [:version_source_id], prefix: @prefix))
  end

  defp utc_now, do: fragment("(now() AT TIME ZONE 'utc')")
end
