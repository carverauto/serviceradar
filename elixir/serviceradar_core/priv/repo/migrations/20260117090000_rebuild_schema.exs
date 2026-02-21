defmodule ServiceRadar.Repo.Migrations.RebuildSchema do
  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS \"platform\"")
    execute("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")
    execute("CREATE EXTENSION IF NOT EXISTS \"citext\"")

    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_or(left BOOLEAN, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE)
    AS $$ SELECT COALESCE(NULLIF($1, FALSE), $2) $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_or(left ANYCOMPATIBLE, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE)
    AS $$ SELECT COALESCE($1, $2) $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_and(left BOOLEAN, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE) AS $$
      SELECT CASE
        WHEN $1 IS TRUE THEN $2
        ELSE $1
      END $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_and(left ANYCOMPATIBLE, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE) AS $$
      SELECT CASE
        WHEN $1 IS NOT NULL THEN $2
        ELSE $1
      END $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_trim_whitespace(arr text[])
    RETURNS text[] AS $$
    DECLARE
        start_index INT = 1;
        end_index INT = array_length(arr, 1);
    BEGIN
        WHILE start_index <= end_index AND arr[start_index] = '' LOOP
            start_index := start_index + 1;
        END LOOP;

        WHILE end_index >= start_index AND arr[end_index] = '' LOOP
            end_index := end_index - 1;
        END LOOP;

        IF start_index > end_index THEN
            RETURN ARRAY[]::text[];
        ELSE
            RETURN arr[start_index : end_index];
        END IF;
    END; $$
    LANGUAGE plpgsql
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_raise_error(json_data jsonb)
    RETURNS BOOLEAN AS $$
    BEGIN
        -- Raise an error with the provided JSON data.
        -- The JSON object is converted to text for inclusion in the error message.
        RAISE EXCEPTION 'ash_error: %', json_data::text;
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    STABLE
    SET search_path = '';
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_raise_error(json_data jsonb, type_signal ANYCOMPATIBLE)
    RETURNS ANYCOMPATIBLE AS $$
    BEGIN
        -- Raise an error with the provided JSON data.
        -- The JSON object is converted to text for inclusion in the error message.
        RAISE EXCEPTION 'ash_error: %', json_data::text;
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    STABLE
    SET search_path = '';
    """)

    execute("""
    CREATE OR REPLACE FUNCTION uuid_generate_v7()
    RETURNS UUID
    AS $$
    DECLARE
      timestamp    TIMESTAMPTZ;
      microseconds INT;
    BEGIN
      timestamp    = clock_timestamp();
      microseconds = (cast(extract(microseconds FROM timestamp)::INT - (floor(extract(milliseconds FROM timestamp))::INT * 1000) AS DOUBLE PRECISION) * 4.096)::INT;

      RETURN encode(
        set_byte(
          set_byte(
            overlay(uuid_send(gen_random_uuid()) placing substring(int8send(floor(extract(epoch FROM timestamp) * 1000)::BIGINT) FROM 3) FROM 1 FOR 6
          ),
          6, (b'0111' || (microseconds >> 8)::bit(4))::bit(8)::int
        ),
        7, microseconds::bit(8)::int
      ),
      'hex')::UUID;
    END
    $$
    LANGUAGE PLPGSQL
    SET search_path = ''
    VOLATILE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION timestamp_from_uuid_v7(_uuid uuid)
    RETURNS TIMESTAMP WITHOUT TIME ZONE
    AS $$
      SELECT to_timestamp(('x0000' || substr(_uuid::TEXT, 1, 8) || substr(_uuid::TEXT, 10, 4))::BIT(64)::BIGINT::NUMERIC / 1000);
    $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE PARALLEL SAFE STRICT;
    """)
    create table(:edge_sites, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :slug, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :nats_leaf_url, :text
      add :last_seen_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:edge_sites, [:slug], name: "edge_sites_unique_slug_index")

    create table(:sysmon_profiles, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :sample_interval, :text, null: false, default: "10s"
      add :collect_cpu, :boolean, null: false, default: true
      add :collect_memory, :boolean, null: false, default: true
      add :collect_disk, :boolean, null: false, default: true
      add :collect_network, :boolean, null: false, default: false
      add :collect_processes, :boolean, null: false, default: false
      add :disk_paths, {:array, :text}, null: false, default: []
      add :disk_exclude_paths, {:array, :text}, null: false, default: []
      add :thresholds, :map, null: false, default: %{}
      add :is_default, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :target_query, :text
      add :priority, :bigint, null: false, default: 0

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:sysmon_profiles, [:name], name: "sysmon_profiles_unique_name_index")

    create table(:alerts, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :title, :text, null: false
      add :description, :text
      add :severity, :text, null: false, default: "warning"
      add :status, :text, null: false, default: "pending"
      add :source_type, :text
      add :source_id, :text
      add :service_check_id, :uuid
      add :device_uid, :text
      add :agent_uid, :text
      add :event_id, :uuid
      add :event_time, :utc_datetime_usec
      add :metric_name, :text
      add :metric_value, :float
      add :threshold_value, :float
      add :comparison, :text
      add :triggered_at, :utc_datetime
      add :acknowledged_at, :utc_datetime
      add :acknowledged_by, :text
      add :resolved_at, :utc_datetime
      add :resolved_by, :text
      add :resolution_note, :text
      add :escalated_at, :utc_datetime
      add :escalation_level, :bigint, default: 0
      add :escalation_reason, :text
      add :notification_count, :bigint, default: 0
      add :last_notification_at, :utc_datetime
      add :suppressed_until, :utc_datetime
      add :metadata, :map, default: %{}
      add :tags, {:array, :text}, default: []

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create table(:health_events, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :entity_type, :text, null: false
      add :entity_id, :text, null: false
      add :old_state, :text
      add :new_state, :text, null: false
      add :reason, :text
      add :node, :text
      add :duration_seconds, :bigint
      add :recorded_at, :utc_datetime, null: false
      add :metadata, :map, default: %{}
    end

    create index(:health_events, [:entity_type, :new_state, :recorded_at])

    create index(:health_events, [:entity_type, :entity_id, :recorded_at])

    create unique_index(:health_events, [:id], name: "health_events_unique_event_index")

    create table(:poll_jobs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :schedule_id, :uuid, null: false
      add :schedule_name, :text
      add :check_count, :bigint, default: 0
      add :check_ids, {:array, :uuid}, default: []
      add :gateway_id, :text
      add :agent_id, :text
      add :priority, :bigint, default: 0
      add :timeout_seconds, :bigint, default: 60
      add :status, :text, null: false, default: "pending"
      add :dispatched_at, :utc_datetime
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :duration_ms, :bigint
      add :success_count, :bigint, default: 0
      add :failure_count, :bigint, default: 0
      add :results, {:array, :map}, default: []
      add :error_message, :text
      add :error_code, :text
      add :retry_count, :bigint, default: 0
      add :max_retries, :bigint, default: 3
      add :metadata, :map, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create table(:snmp_targets, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :name, :text, null: false
      add :host, :text, null: false
      add :port, :bigint, null: false, default: 161
      add :version, :text, null: false, default: "v2c"
      add :community_encrypted, :binary
      add :username, :text
      add :security_level, :text
      add :auth_protocol, :text
      add :auth_password_encrypted, :binary
      add :priv_protocol, :text
      add :priv_password_encrypted, :binary

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :snmp_profile_id, :uuid, null: false
    end

    create table(:nats_credentials, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :user_name, :text, null: false
      add :user_public_key, :text, null: false
      add :credential_type, :text, null: false, default: "collector"
      add :collector_type, :text
      add :status, :text, null: false, default: "active"
      add :issued_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :revoke_reason, :text
      add :onboarding_package_id, :uuid
      add :metadata, :map, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create table(:merge_audit, primary_key: false) do
      add :event_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :from_device_id, :text, null: false
      add :to_device_id, :text, null: false
      add :reason, :text
      add :confidence_score, :decimal
      add :source, :text
      add :details, :map, default: %{}
      add :created_at, :utc_datetime
    end

    create table(:integration_sources, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :source_type, :text, null: false
      add :endpoint, :text, null: false
      add :enabled, :boolean, default: true
      add :agent_id, :text
      add :gateway_id, :text
      add :partition, :text, default: "default"
      add :poll_interval_seconds, :bigint, default: 300
      add :discovery_interval_seconds, :bigint, default: 3600
      add :sweep_interval_seconds, :bigint, default: 3600
      add :page_size, :bigint, default: 100
      add :network_blacklist, {:array, :text}, default: []
      add :queries, {:array, :map}, default: []
      add :custom_fields, {:array, :text}, default: []
      add :settings, :map, default: %{}
      add :last_sync_at, :utc_datetime
      add :last_sync_result, :text
      add :last_device_count, :bigint, default: 0
      add :last_error_message, :text
      add :sync_status, :text, null: false, default: "idle"
      add :consecutive_failures, :bigint, default: 0
      add :total_syncs, :bigint, default: 0

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :encrypted_credentials_encrypted, :binary
    end

    create unique_index(:integration_sources, [:name],
             name: "integration_sources_unique_name_index"
           )

    create table(:agent_config_versions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :config_instance_id, :uuid, null: false
      add :version, :bigint, null: false
      add :compiled_config, :map, null: false, default: %{}
      add :content_hash, :text, null: false
      add :source_ids, {:array, :uuid}, null: false, default: []
      add :actor_id, :uuid
      add :actor_email, :text
      add :change_reason, :text

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:agent_config_versions, [:config_instance_id, :version],
             name: "agent_config_versions_instance_version_idx",
             unique: true
           )

    create table(:sweep_host_results, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :ip, :text, null: false
      add :hostname, :text
      add :status, :text, null: false
      add :response_time_ms, :bigint
      add :sweep_modes_results, :map, null: false, default: %{}
      add :open_ports, {:array, :bigint}, null: false, default: []
      add :error_message, :text
      add :execution_id, :uuid, null: false
      add :device_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:sweep_host_results, [:status], name: "sweep_host_results_status_idx")

    create index(:sweep_host_results, [:ip], name: "sweep_host_results_ip_idx")

    create index(:sweep_host_results, [:execution_id], name: "sweep_host_results_execution_idx")

    create table(:collector_packages, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :collector_type, :text, null: false
      add :user_name, :text, null: false
      add :site, :text, default: "default"
      add :hostname, :text
      add :status, :text, null: false, default: "pending"

      add :nats_credential_id,
          references(:nats_credentials,
            column: :id,
            name: "collector_packages_nats_credential_id_fkey",
            type: :uuid
          )

      add :download_token_hash, :text
      add :download_token_expires_at, :utc_datetime_usec
      add :downloaded_at, :utc_datetime_usec
      add :downloaded_by_ip, :text
      add :installed_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :revoke_reason, :text
      add :error_message, :text
      add :tls_cert_pem, :text
      add :ca_chain_pem, :text
      add :config_overrides, :map, default: %{}

      add :edge_site_id,
          references(:edge_sites,
            column: :id,
            name: "collector_packages_edge_site_id_fkey",
            type: :uuid
          )

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :encrypted_nats_creds_ciphertext, :binary
      add :encrypted_tls_key_pem_ciphertext, :binary
    end

    create unique_index(:collector_packages, [:user_name],
             name: "collector_packages_unique_user_name_index"
           )

    create table(:snmp_oid_configs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :oid, :text, null: false
      add :name, :text, null: false
      add :data_type, :text, null: false, default: "gauge"
      add :scale, :float, null: false, default: 1.0
      add :delta, :boolean, null: false, default: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :snmp_target_id,
          references(:snmp_targets,
            column: :id,
            name: "snmp_oid_configs_snmp_target_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ), null: false
    end

    create unique_index(:snmp_oid_configs, [:snmp_target_id, :oid],
             name: "snmp_oid_configs_unique_oid_per_target_index"
           )

    create table(:zen_rules, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :enabled, :boolean, default: true
      add :order, :bigint, default: 100
      add :stream_name, :text, null: false, default: "events"
      add :subject, :text, null: false
      add :format, :text, null: false, default: "json"
      add :template, :text, null: false
      add :builder_config, :map, default: %{}
      add :jdm_definition, :map
      add :compiled_jdm, :map, default: %{}
      add :kv_revision, :bigint
      add :agent_id, :text, null: false, default: "default-agent"

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:zen_rules, [:subject, :name], name: "zen_rules_unique_name_index")

    create table(:device_groups, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :desc, :text
      add :type, :text, default: "custom"

      add :parent_id,
          references(:device_groups,
            column: :id,
            name: "device_groups_parent_id_fkey",
            type: :uuid
          )

      add :metadata, :map, default: %{}
      add :device_count, :bigint, default: 0

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:device_groups, [:name], name: "device_groups_unique_name_index")

    create table(:sweep_group_executions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
    end

    alter table(:sweep_host_results) do
      modify :execution_id,
             references(:sweep_group_executions,
               column: :id,
               name: "sweep_host_results_execution_id_fkey",
               type: :uuid
             )
    end

    alter table(:sweep_group_executions) do
      add :status, :text, null: false, default: "pending"
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :duration_ms, :bigint
      add :hosts_total, :bigint, default: 0
      add :hosts_available, :bigint, default: 0
      add :hosts_failed, :bigint, default: 0
      add :error_message, :text
      add :agent_id, :text
      add :config_version, :text
      add :sweep_group_id, :uuid, null: false
      add :scanner_metrics, :map, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:sweep_group_executions, [:status], name: "sweep_group_executions_status_idx")

    create index(:sweep_group_executions, [:sweep_group_id, :started_at],
             name: "sweep_group_executions_group_started_idx"
           )

    create table(:stateful_alert_rule_templates, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :enabled, :boolean, default: true
      add :priority, :bigint, default: 100
      add :signal, :text, null: false, default: "log"
      add :match, :map, default: %{}
      add :group_by, {:array, :text}
      add :threshold, :bigint, null: false, default: 5
      add :window_seconds, :bigint, null: false, default: 600
      add :bucket_seconds, :bigint, null: false, default: 60
      add :cooldown_seconds, :bigint, null: false, default: 300
      add :renotify_seconds, :bigint, null: false, default: 21600
      add :event, :map, default: %{}
      add :alert, :map, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:stateful_alert_rule_templates, [:name],
             name: "stateful_alert_rule_templates_unique_name_index"
           )

    create table(:ng_users, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :email, :citext, null: false
      add :hashed_password, :text
      add :display_name, :text
      add :role, :text, null: false, default: "viewer"
      add :confirmed_at, :utc_datetime
      add :authenticated_at, :utc_datetime

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:ng_users, [:email], name: "ng_users_email_index")

    create table(:checkers, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :type, :text, null: false
      add :description, :text
      add :enabled, :boolean, default: true
      add :status, :text, null: false, default: "active"
      add :consecutive_failures, :bigint, default: 0
      add :last_success, :utc_datetime
      add :last_failure, :utc_datetime
      add :failure_reason, :text
      add :config, :map, default: %{}
      add :interval_seconds, :bigint, default: 60
      add :timeout_seconds, :bigint, default: 30
      add :retries, :bigint, default: 3
      add :target_type, :text, default: "agent"
      add :target_filter, :map, default: %{}
      add :agent_uid, :text
      add :created_at, :utc_datetime
      add :updated_at, :utc_datetime
    end

    create table(:polling_schedules, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
    end

    alter table(:poll_jobs) do
      modify :schedule_id,
             references(:polling_schedules,
               column: :id,
               name: "poll_jobs_schedule_id_fkey",
               type: :uuid
             )
    end

    create unique_index(:poll_jobs, [:id], name: "poll_jobs_unique_job_index")

    alter table(:polling_schedules) do
      add :name, :text, null: false
      add :description, :text
      add :schedule_type, :text, null: false, default: "interval"
      add :interval_seconds, :bigint
      add :cron_expression, :text
      add :assignment_mode, :text, null: false, default: "any"
      add :assigned_gateway_id, :text
      add :assigned_partition_id, :uuid
      add :assigned_domain, :text
      add :enabled, :boolean, default: true
      add :priority, :bigint, default: 0
      add :max_concurrent, :bigint, default: 10
      add :timeout_seconds, :bigint, default: 60
      add :last_executed_at, :utc_datetime
      add :last_result, :text
      add :last_check_count, :bigint, default: 0
      add :last_success_count, :bigint, default: 0
      add :last_failure_count, :bigint, default: 0
      add :execution_count, :bigint, default: 0
      add :consecutive_failures, :bigint, default: 0
      add :lock_token, :uuid
      add :locked_at, :utc_datetime
      add :locked_by, :text
      add :metadata, :map, default: %{}

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create table(:log_promotion_rules, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :enabled, :boolean, default: true
      add :priority, :bigint, default: 100
      add :match, :map, default: %{}
      add :event, :map, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:log_promotion_rules, [:name],
             name: "log_promotion_rules_unique_name_index"
           )

    create table(:nats_leaf_servers, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :edge_site_id,
          references(:edge_sites,
            column: :id,
            name: "nats_leaf_servers_edge_site_id_fkey",
            type: :uuid
          ), null: false

      add :status, :text, null: false, default: "pending"
      add :upstream_url, :text, null: false
      add :local_listen, :text, null: false, default: "0.0.0.0:4222"
      add :leaf_cert_pem, :text
      add :server_cert_pem, :text
      add :ca_chain_pem, :text
      add :config_checksum, :text
      add :cert_expires_at, :utc_datetime_usec
      add :provisioned_at, :utc_datetime_usec
      add :connected_at, :utc_datetime_usec
      add :disconnected_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :encrypted_leaf_key_pem_ciphertext, :binary
      add :encrypted_server_key_pem_ciphertext, :binary
    end

    create unique_index(:nats_leaf_servers, [:edge_site_id],
             name: "nats_leaf_servers_unique_per_edge_site_index"
           )

    create table(:snmp_oid_templates, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :vendor, :text, null: false
      add :category, :text
      add :oids, {:array, :map}, null: false, default: []
      add :is_builtin, :boolean, null: false, default: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:snmp_oid_templates, [:vendor, :name],
             name: "snmp_oid_templates_unique_name_per_vendor_index"
           )

    create table(:device_identifiers, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true
      add :device_id, :text, null: false
      add :identifier_type, :text, null: false
      add :identifier_value, :text, null: false
      add :partition, :text, default: "default"
      add :confidence, :text, default: "strong"
      add :source, :text
      add :first_seen, :utc_datetime
      add :last_seen, :utc_datetime
      add :verified, :boolean, default: false
      add :metadata, :map, default: %{}
    end

    create table(:agent_config_templates, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :config_type, :text, null: false
      add :schema, :map, default: %{}
      add :default_values, :map, null: false, default: %{}
      add :admin_only, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:agent_config_templates, [:name, :config_type],
             name: "agent_config_templates_unique_name_and_type_index"
           )

    create table(:user_tokens, primary_key: false) do
      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :extra_data, :map
      add :purpose, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :subject, :text, null: false
      add :jti, :text, null: false, primary_key: true
    end

    create table(:ng_job_schedules, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true
      add :job_key, :text, null: false
      add :cron, :text, null: false
      add :timezone, :text, default: "Etc/UTC"
      add :args, :map, default: %{}
      add :enabled, :boolean, default: true
      add :unique_period_seconds, :bigint
      add :last_enqueued_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:ng_job_schedules, [:job_key],
             name: "ng_job_schedules_unique_job_key_index"
           )

    create table(:edge_onboarding_packages, primary_key: false) do
      add :package_id, :uuid,
        null: false,
        default: fragment("gen_random_uuid()"),
        primary_key: true
    end

    alter table(:nats_credentials) do
      modify :onboarding_package_id,
             references(:edge_onboarding_packages,
               column: :package_id,
               name: "nats_credentials_onboarding_package_id_fkey",
               type: :uuid
             )
    end

    create unique_index(:nats_credentials, [:user_public_key],
             name: "nats_credentials_unique_user_public_key_index"
           )

    alter table(:edge_onboarding_packages) do
      add :label, :text, null: false
      add :component_id, :text
      add :component_type, :text, default: "gateway"
      add :parent_type, :text
      add :parent_id, :text
      add :gateway_id, :text
      add :site, :text
      add :status, :text, null: false, default: "issued"
      add :security_mode, :text, default: "spire"
      add :downstream_entry_id, :text
      add :downstream_spiffe_id, :text
      add :selectors, {:array, :text}, default: []
      add :checker_kind, :text
      add :checker_config_json, :map, default: %{}
      add :join_token_ciphertext, :text
      add :join_token_expires_at, :utc_datetime
      add :bundle_ciphertext, :text
      add :download_token_hash, :text
      add :download_token_expires_at, :utc_datetime
      add :created_by, :text, default: "system"
      add :delivered_at, :utc_datetime
      add :activated_at, :utc_datetime
      add :activated_from_ip, :text
      add :last_seen_spiffe_id, :text
      add :revoked_at, :utc_datetime
      add :deleted_at, :utc_datetime
      add :deleted_by, :text
      add :deleted_reason, :text
      add :metadata_json, :map, default: %{}
      add :kv_revision, :bigint
      add :notes, :text

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create table(:gateways, primary_key: false) do
      add :gateway_id, :text, null: false, primary_key: true
      add :component_id, :text
      add :registration_source, :text
      add :status, :text, null: false, default: "inactive"
      add :spiffe_identity, :text
      add :first_registered, :utc_datetime
      add :first_seen, :utc_datetime
      add :last_seen, :utc_datetime
      add :metadata, :map, default: %{}
      add :created_by, :text
      add :is_healthy, :boolean, default: true
      add :agent_count, :bigint, default: 0
      add :checker_count, :bigint, default: 0
      add :updated_at, :utc_datetime
      add :partition_id, :uuid
    end

    create table(:ocsf_devices, primary_key: false) do
      add :uid, :text, null: false, primary_key: true
      add :type_id, :bigint, default: 0
      add :type, :text
      add :name, :text
      add :hostname, :text
      add :ip, :text
      add :mac, :text
      add :uid_alt, :text
      add :vendor_name, :text
      add :model, :text
      add :domain, :text
      add :zone, :text
      add :subnet_uid, :text
      add :vlan_uid, :text
      add :region, :text
      add :first_seen_time, :utc_datetime
      add :last_seen_time, :utc_datetime
      add :created_time, :utc_datetime
      add :modified_time, :utc_datetime
      add :risk_level_id, :bigint
      add :risk_level, :text
      add :risk_score, :bigint
      add :is_managed, :boolean, default: false
      add :is_compliant, :boolean
      add :is_trusted, :boolean, default: false
      add :os, :map, default: %{}
      add :hw_info, :map, default: %{}
      add :network_interfaces, {:array, :map}, default: []
      add :owner, :map, default: %{}
      add :org, :map, default: %{}
      add :groups, {:array, :map}, default: []
      add :agent_list, {:array, :map}, default: []
      add :gateway_id, :text
      add :agent_id, :text
      add :discovery_sources, {:array, :text}, default: []
      add :tags, :map, default: %{}
      add :is_available, :boolean, default: true
      add :metadata, :map, default: %{}

      add :group_id,
          references(:device_groups,
            column: :id,
            name: "ocsf_devices_group_id_fkey",
            type: :uuid
          )
    end

    create unique_index(:ocsf_devices, [:uid], name: "ocsf_devices_unique_uid_index")

    alter table(:device_identifiers) do
      modify :device_id,
             references(:ocsf_devices,
               column: :uid,
               name: "device_identifiers_device_id_fkey",
               type: :text
             )
    end

    create unique_index(:device_identifiers, [:identifier_type, :identifier_value, :partition],
             name: "device_identifiers_unique_identifier_index"
           )

    create table(:discovered_interfaces, primary_key: false) do
      add :timestamp, :utc_datetime, null: false, primary_key: true

      add :device_id,
          references(:ocsf_devices,
            column: :uid,
            name: "discovered_interfaces_device_id_fkey",
            type: :text
          ), primary_key: true, null: false

      add :if_index, :bigint, null: false, primary_key: true
      add :agent_id, :text
      add :gateway_id, :text
      add :device_ip, :text
      add :if_name, :text
      add :if_descr, :text
      add :if_alias, :text
      add :if_speed, :bigint
      add :if_phys_address, :text
      add :ip_addresses, {:array, :text}, default: []
      add :if_admin_status, :bigint
      add :if_oper_status, :bigint
      add :metadata, :map, default: %{}
      add :created_at, :utc_datetime
    end

    create table(:api_tokens, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :token_hash, :text, null: false
      add :token_prefix, :text, null: false
      add :scope, :text, default: "read"
      add :enabled, :boolean, default: true
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime
      add :last_used_ip, :text
      add :use_count, :bigint, default: 0
      add :revoked_at, :utc_datetime
      add :revoked_by, :text
      add :metadata, :map, default: %{}
      add :created_at, :utc_datetime

      add :user_id,
          references(:ng_users,
            column: :id,
            name: "api_tokens_user_id_fkey",
            type: :uuid
          ), null: false
    end

    create table(:snmp_profiles, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
    end

    alter table(:snmp_targets) do
      modify :snmp_profile_id,
             references(:snmp_profiles,
               column: :id,
               name: "snmp_targets_snmp_profile_id_fkey",
               type: :uuid,
                  on_delete: :delete_all
             )
    end

    create unique_index(:snmp_targets, [:snmp_profile_id, :name],
             name: "snmp_targets_unique_name_per_profile_index"
           )

    alter table(:snmp_profiles) do
      add :name, :text, null: false
      add :description, :text
      add :poll_interval, :bigint, null: false, default: 60
      add :timeout, :bigint, null: false, default: 5
      add :retries, :bigint, null: false, default: 3
      add :is_default, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :target_query, :text
      add :priority, :bigint, null: false, default: 0

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:snmp_profiles, [:name], name: "snmp_profiles_unique_name_index")

    create table(:sweep_groups, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
    end

    alter table(:sweep_group_executions) do
      modify :sweep_group_id,
             references(:sweep_groups,
               column: :id,
               name: "sweep_group_executions_sweep_group_id_fkey",
               type: :uuid
             )
    end

    alter table(:sweep_groups) do
      add :name, :text, null: false
      add :description, :text
      add :partition, :text, null: false, default: "default"
      add :agent_id, :text
      add :enabled, :boolean, null: false, default: true
      add :interval, :text, null: false, default: "1h"
      add :schedule_type, :text, null: false, default: "interval"
      add :cron_expression, :text
      add :target_criteria, :map, null: false, default: %{}
      add :static_targets, {:array, :text}, null: false, default: []
      add :ports, {:array, :bigint}
      add :sweep_modes, {:array, :text}
      add :overrides, :map, null: false, default: %{}
      add :last_run_at, :utc_datetime
      add :profile_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:sweep_groups, [:agent_id],
             name: "sweep_groups_agent_idx",
             where: "agent_id IS NOT NULL"
           )

    create index(:sweep_groups, [:partition], name: "sweep_groups_partition_idx")

    create table(:partitions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
    end

    alter table(:polling_schedules) do
      modify :assigned_partition_id,
             references(:partitions,
               column: :id,
               name: "polling_schedules_assigned_partition_id_fkey",
               type: :uuid
             )
    end

    alter table(:partitions) do
      add :name, :text, null: false
      add :slug, :text, null: false
      add :description, :text
      add :enabled, :boolean, default: true
      add :cidr_ranges, {:array, :text}, default: []
      add :default_gateway, :text
      add :dns_servers, {:array, :text}, default: []
      add :site, :text
      add :region, :text
      add :environment, :text, default: "production"
      add :connectivity_type, :text, default: "direct"
      add :proxy_endpoint, :text
      add :metadata, :map, default: %{}
      add :created_at, :utc_datetime
      add :updated_at, :utc_datetime
    end

    create unique_index(:partitions, [:slug], name: "partitions_unique_slug_index")

    alter table(:gateways) do
      modify :partition_id,
             references(:partitions,
               column: :id,
               name: "gateways_partition_id_fkey",
               type: :uuid
             )
    end

    create unique_index(:gateways, [:gateway_id], name: "gateways_unique_gateway_id_index")

    create table(:log_promotion_rule_templates, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :enabled, :boolean, default: true
      add :priority, :bigint, default: 100
      add :match, :map, default: %{}
      add :event, :map, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:log_promotion_rule_templates, [:name],
             name: "log_promotion_rule_templates_unique_name_index"
           )

    create table(:ocsf_agents, primary_key: false) do
      add :uid, :text, null: false, primary_key: true
      add :name, :text
      add :type_id, :bigint, default: 0
      add :type, :text
      add :uid_alt, :text
      add :vendor_name, :text, default: "ServiceRadar"
      add :version, :text
      add :policies, {:array, :map}, default: []

      add :gateway_id,
          references(:gateways,
            column: :gateway_id,
            name: "ocsf_agents_gateway_id_fkey",
            type: :text
          )

      add :device_uid,
          references(:ocsf_devices,
            column: :uid,
            name: "ocsf_agents_device_uid_fkey",
            type: :text
          )

      add :capabilities, {:array, :text}, default: []
      add :host, :text
      add :port, :bigint
      add :spiffe_identity, :text
      add :status, :text, null: false, default: "connecting"
      add :is_healthy, :boolean, default: true
      add :first_seen_time, :utc_datetime
      add :last_seen_time, :utc_datetime
      add :created_time, :utc_datetime
      add :modified_time, :utc_datetime
      add :metadata, :map, default: %{}
      add :config_source, :text
    end

    create unique_index(:ocsf_agents, [:uid], name: "ocsf_agents_unique_uid_index")

    alter table(:checkers) do
      modify :agent_uid,
             references(:ocsf_agents,
               column: :uid,
               name: "checkers_agent_uid_fkey",
               type: :text
             )
    end

    create table(:stateful_alert_rule_states, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :rule_id, :uuid, null: false
      add :group_key, :text, null: false
      add :group_values, :map, default: %{}
      add :window_seconds, :bigint, null: false
      add :bucket_seconds, :bigint, null: false
      add :current_bucket_start, :utc_datetime_usec, null: false
      add :bucket_counts, :map, default: %{}
      add :last_seen_at, :utc_datetime_usec
      add :last_fired_at, :utc_datetime_usec
      add :last_notification_at, :utc_datetime_usec
      add :cooldown_until, :utc_datetime_usec
      add :alert_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:stateful_alert_rule_states, [:rule_id, :group_key],
             name: "stateful_alert_rule_states_unique_state_index"
           )

    create table(:edge_onboarding_events, primary_key: false) do
      add :event_time, :utc_datetime_usec, null: false, primary_key: true

      add :package_id,
          references(:edge_onboarding_packages,
            column: :package_id,
            name: "edge_onboarding_events_package_id_fkey",
            type: :uuid
          ), primary_key: true, null: false

      add :event_type, :text, null: false
      add :actor, :text
      add :source_ip, :text
      add :details_json, :map, default: %{}
    end

    create table(:device_alias_states, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :device_id,
          references(:ocsf_devices,
            column: :uid,
            name: "device_alias_states_device_id_fkey",
            type: :text
          ), null: false

      add :partition, :text
      add :alias_type, :text, null: false
      add :alias_value, :text, null: false
      add :state, :text, null: false, default: "detected"
      add :first_seen_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
      add :sighting_count, :bigint, default: 1
      add :metadata, :map, default: %{}
      add :previous_alias_id, :uuid
      add :replaced_by_alias_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:device_alias_states, [:device_id, :alias_type, :alias_value],
             name: "device_alias_states_unique_device_alias_index"
           )

    create table(:service_checks, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
    end

    alter table(:alerts) do
      modify :service_check_id,
             references(:service_checks,
               column: :id,
               name: "alerts_service_check_id_fkey",
               type: :uuid
             )

      modify :device_uid,
             references(:ocsf_devices,
               column: :uid,
               name: "alerts_device_uid_fkey",
               type: :text
             )

      modify :agent_uid,
             references(:ocsf_agents,
               column: :uid,
               name: "alerts_agent_uid_fkey",
               type: :text
             )
    end

    alter table(:service_checks) do
      add :name, :text, null: false
      add :description, :text
      add :check_type, :text, null: false
      add :target, :text, null: false
      add :port, :bigint
      add :interval_seconds, :bigint, default: 60
      add :timeout_seconds, :bigint, default: 10
      add :retries, :bigint, default: 3
      add :enabled, :boolean, default: true
      add :config, :map, default: %{}
      add :warning_threshold_ms, :bigint
      add :critical_threshold_ms, :bigint
      add :last_check_at, :utc_datetime
      add :last_result, :text
      add :last_response_time_ms, :bigint
      add :last_error, :text
      add :consecutive_failures, :bigint, default: 0

      add :agent_uid,
          references(:ocsf_agents,
            column: :uid,
            name: "service_checks_agent_uid_fkey",
            type: :text
          )

      add :device_uid,
          references(:ocsf_devices,
            column: :uid,
            name: "service_checks_device_uid_fkey",
            type: :text
          )

      add :metadata, :map, default: %{}

      add :schedule_id,
          references(:polling_schedules,
            column: :id,
            name: "service_checks_schedule_id_fkey",
            type: :uuid
          )

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create table(:agent_config_instances, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
    end

    alter table(:agent_config_versions) do
      modify :config_instance_id,
             references(:agent_config_instances,
               column: :id,
               name: "agent_config_versions_config_instance_id_fkey",
               type: :uuid
             )
    end

    alter table(:agent_config_instances) do
      add :config_type, :text, null: false
      add :partition, :text, null: false, default: "default"
      add :agent_id, :text
      add :compiled_config, :map, null: false, default: %{}
      add :content_hash, :text, null: false
      add :version, :bigint, null: false, default: 1
      add :source_ids, {:array, :uuid}, null: false, default: []
      add :last_delivered_at, :utc_datetime
      add :delivery_count, :bigint, null: false, default: 0

      add :template_id,
          references(:agent_config_templates,
            column: :id,
            name: "agent_config_instances_template_id_fkey",
            type: :uuid
          )

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:agent_config_instances, [:config_type, :agent_id],
             name: "agent_config_instances_type_agent_idx",
             where: "agent_id IS NOT NULL"
           )

    create index(:agent_config_instances, [:config_type, :partition],
             name: "agent_config_instances_type_partition_idx"
           )

    create unique_index(:agent_config_instances, [:config_type, :partition, :agent_id],
             name: "agent_config_instances_unique_config_per_agent_index"
           )

    create table(:zen_rule_templates, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :enabled, :boolean, default: true
      add :order, :bigint, default: 100
      add :stream_name, :text, null: false, default: "events"
      add :subject, :text, null: false
      add :template, :text, null: false
      add :builder_config, :map, default: %{}
      add :agent_id, :text, null: false, default: "default-agent"

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:zen_rule_templates, [:subject, :name],
             name: "zen_rule_templates_unique_name_index"
           )

    create table(:sweep_profiles, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
    end

    alter table(:sweep_groups) do
      modify :profile_id,
             references(:sweep_profiles,
               column: :id,
               name: "sweep_groups_profile_id_fkey",
               type: :uuid
             )
    end

    create unique_index(:sweep_groups, [:name], name: "sweep_groups_unique_name_index")

    alter table(:sweep_profiles) do
      add :name, :text, null: false
      add :description, :text
      add :ports, {:array, :bigint}, null: false, default: []
      add :sweep_modes, {:array, :text}, null: false
      add :concurrency, :bigint, null: false, default: 50
      add :timeout, :text, null: false, default: "3s"
      add :icmp_settings, :map, null: false, default: %{}
      add :tcp_settings, :map, null: false, default: %{}
      add :admin_only, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:sweep_profiles, [:name], name: "sweep_profiles_unique_name_index")

    create table(:stateful_alert_rules, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :enabled, :boolean, default: true
      add :priority, :bigint, default: 100
      add :signal, :text, null: false, default: "log"
      add :match, :map, default: %{}
      add :group_by, {:array, :text}
      add :threshold, :bigint, null: false, default: 5
      add :window_seconds, :bigint, null: false, default: 600
      add :bucket_seconds, :bigint, null: false, default: 60
      add :cooldown_seconds, :bigint, null: false, default: 300
      add :renotify_seconds, :bigint, null: false, default: 21600
      add :event, :map, default: %{}
      add :alert, :map, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:stateful_alert_rules, [:name],
             name: "stateful_alert_rules_unique_name_index"
           )

    Oban.Migrations.up(prefix: prefix() || "platform")
  end

  def down do
    Oban.Migrations.down(prefix: prefix() || "platform")

    drop_if_exists unique_index(:stateful_alert_rules, [:name],
                     name: "stateful_alert_rules_unique_name_index"
                   )

    drop table(:stateful_alert_rules)

    drop_if_exists unique_index(:sweep_profiles, [:name],
                     name: "sweep_profiles_unique_name_index"
                   )

    alter table(:sweep_profiles) do
      remove :updated_at
      remove :inserted_at
      remove :enabled
      remove :admin_only
      remove :tcp_settings
      remove :icmp_settings
      remove :timeout
      remove :concurrency
      remove :sweep_modes
      remove :ports
      remove :description
      remove :name
    end

    drop_if_exists unique_index(:sweep_groups, [:name], name: "sweep_groups_unique_name_index")

    drop constraint(:sweep_groups, "sweep_groups_profile_id_fkey")

    alter table(:sweep_groups) do
      modify :profile_id, :uuid
    end

    drop table(:sweep_profiles)

    drop_if_exists unique_index(:zen_rule_templates, [:subject, :name],
                     name: "zen_rule_templates_unique_name_index"
                   )

    drop table(:zen_rule_templates)

    drop_if_exists unique_index(:agent_config_instances, [:config_type, :partition, :agent_id],
                     name: "agent_config_instances_unique_config_per_agent_index"
                   )

    drop constraint(:agent_config_instances, "agent_config_instances_template_id_fkey")

    drop_if_exists index(:agent_config_instances, [:config_type, :partition],
                     name: "agent_config_instances_type_partition_idx"
                   )

    drop_if_exists index(:agent_config_instances, [:config_type, :agent_id],
                     name: "agent_config_instances_type_agent_idx"
                   )

    alter table(:agent_config_instances) do
      remove :updated_at
      remove :inserted_at
      remove :template_id
      remove :delivery_count
      remove :last_delivered_at
      remove :source_ids
      remove :version
      remove :content_hash
      remove :compiled_config
      remove :agent_id
      remove :partition
      remove :config_type
    end

    drop constraint(:agent_config_versions, "agent_config_versions_config_instance_id_fkey")

    alter table(:agent_config_versions) do
      modify :config_instance_id, :uuid
    end

    drop table(:agent_config_instances)

    drop constraint(:service_checks, "service_checks_agent_uid_fkey")

    drop constraint(:service_checks, "service_checks_device_uid_fkey")

    drop constraint(:service_checks, "service_checks_schedule_id_fkey")

    alter table(:service_checks) do
      remove :updated_at
      remove :created_at
      remove :schedule_id
      remove :metadata
      remove :device_uid
      remove :agent_uid
      remove :consecutive_failures
      remove :last_error
      remove :last_response_time_ms
      remove :last_result
      remove :last_check_at
      remove :critical_threshold_ms
      remove :warning_threshold_ms
      remove :config
      remove :enabled
      remove :retries
      remove :timeout_seconds
      remove :interval_seconds
      remove :port
      remove :target
      remove :check_type
      remove :description
      remove :name
    end

    drop constraint(:alerts, "alerts_service_check_id_fkey")

    drop constraint(:alerts, "alerts_device_uid_fkey")

    drop constraint(:alerts, "alerts_agent_uid_fkey")

    alter table(:alerts) do
      modify :agent_uid, :text
      modify :device_uid, :text
      modify :service_check_id, :uuid
    end

    drop table(:service_checks)

    drop_if_exists unique_index(:device_alias_states, [:device_id, :alias_type, :alias_value],
                     name: "device_alias_states_unique_device_alias_index"
                   )

    drop constraint(:device_alias_states, "device_alias_states_device_id_fkey")

    drop table(:device_alias_states)

    drop constraint(:edge_onboarding_events, "edge_onboarding_events_package_id_fkey")

    drop table(:edge_onboarding_events)

    drop_if_exists unique_index(:stateful_alert_rule_states, [:rule_id, :group_key],
                     name: "stateful_alert_rule_states_unique_state_index"
                   )

    drop table(:stateful_alert_rule_states)

    drop constraint(:checkers, "checkers_agent_uid_fkey")

    alter table(:checkers) do
      modify :agent_uid, :text
    end

    drop_if_exists unique_index(:ocsf_agents, [:uid], name: "ocsf_agents_unique_uid_index")

    drop constraint(:ocsf_agents, "ocsf_agents_gateway_id_fkey")

    drop constraint(:ocsf_agents, "ocsf_agents_device_uid_fkey")

    drop table(:ocsf_agents)

    drop_if_exists unique_index(:log_promotion_rule_templates, [:name],
                     name: "log_promotion_rule_templates_unique_name_index"
                   )

    drop table(:log_promotion_rule_templates)

    drop_if_exists unique_index(:gateways, [:gateway_id],
                     name: "gateways_unique_gateway_id_index"
                   )

    drop constraint(:gateways, "gateways_partition_id_fkey")

    alter table(:gateways) do
      modify :partition_id, :uuid
    end

    drop_if_exists unique_index(:partitions, [:slug], name: "partitions_unique_slug_index")

    alter table(:partitions) do
      remove :updated_at
      remove :created_at
      remove :metadata
      remove :proxy_endpoint
      remove :connectivity_type
      remove :environment
      remove :region
      remove :site
      remove :dns_servers
      remove :default_gateway
      remove :cidr_ranges
      remove :enabled
      remove :description
      remove :slug
      remove :name
    end

    drop constraint(:polling_schedules, "polling_schedules_assigned_partition_id_fkey")

    alter table(:polling_schedules) do
      modify :assigned_partition_id, :uuid
    end

    drop table(:partitions)

    drop_if_exists index(:sweep_groups, [:partition], name: "sweep_groups_partition_idx")

    drop_if_exists index(:sweep_groups, [:agent_id], name: "sweep_groups_agent_idx")

    alter table(:sweep_groups) do
      remove :updated_at
      remove :inserted_at
      remove :profile_id
      remove :last_run_at
      remove :overrides
      remove :sweep_modes
      remove :ports
      remove :static_targets
      remove :target_criteria
      remove :cron_expression
      remove :schedule_type
      remove :interval
      remove :enabled
      remove :agent_id
      remove :partition
      remove :description
      remove :name
    end

    drop constraint(:sweep_group_executions, "sweep_group_executions_sweep_group_id_fkey")

    alter table(:sweep_group_executions) do
      modify :sweep_group_id, :uuid
    end

    drop table(:sweep_groups)

    drop_if_exists unique_index(:snmp_profiles, [:name], name: "snmp_profiles_unique_name_index")

    alter table(:snmp_profiles) do
      remove :updated_at
      remove :inserted_at
      remove :priority
      remove :target_query
      remove :enabled
      remove :is_default
      remove :retries
      remove :timeout
      remove :poll_interval
      remove :description
      remove :name
    end

    drop_if_exists unique_index(:snmp_targets, [:snmp_profile_id, :name],
                     name: "snmp_targets_unique_name_per_profile_index"
                   )

    drop constraint(:snmp_targets, "snmp_targets_snmp_profile_id_fkey")

    alter table(:snmp_targets) do
      modify :snmp_profile_id, :uuid
    end

    drop table(:snmp_profiles)

    drop constraint(:api_tokens, "api_tokens_user_id_fkey")

    drop table(:api_tokens)

    drop constraint(:discovered_interfaces, "discovered_interfaces_device_id_fkey")

    drop table(:discovered_interfaces)

    drop_if_exists unique_index(
                     :device_identifiers,
                     [:identifier_type, :identifier_value, :partition],
                     name: "device_identifiers_unique_identifier_index"
                   )

    drop constraint(:device_identifiers, "device_identifiers_device_id_fkey")

    alter table(:device_identifiers) do
      modify :device_id, :text
    end

    drop_if_exists unique_index(:ocsf_devices, [:uid], name: "ocsf_devices_unique_uid_index")

    drop constraint(:ocsf_devices, "ocsf_devices_group_id_fkey")

    drop table(:ocsf_devices)

    drop table(:gateways)

    drop_if_exists unique_index(:nats_credentials, [:user_public_key],
                     name: "nats_credentials_unique_user_public_key_index"
                   )

    drop constraint(:nats_credentials, "nats_credentials_onboarding_package_id_fkey")

    alter table(:nats_credentials) do
      modify :onboarding_package_id, :uuid
    end

    alter table(:edge_onboarding_packages) do
      remove :updated_at
      remove :created_at
      remove :notes
      remove :kv_revision
      remove :metadata_json
      remove :deleted_reason
      remove :deleted_by
      remove :deleted_at
      remove :revoked_at
      remove :last_seen_spiffe_id
      remove :activated_from_ip
      remove :activated_at
      remove :delivered_at
      remove :created_by
      remove :download_token_expires_at
      remove :download_token_hash
      remove :bundle_ciphertext
      remove :join_token_expires_at
      remove :join_token_ciphertext
      remove :checker_config_json
      remove :checker_kind
      remove :selectors
      remove :downstream_spiffe_id
      remove :downstream_entry_id
      remove :security_mode
      remove :status
      remove :site
      remove :gateway_id
      remove :parent_id
      remove :parent_type
      remove :component_type
      remove :component_id
      remove :label
    end

    drop table(:edge_onboarding_packages)

    drop_if_exists unique_index(:ng_job_schedules, [:job_key],
                     name: "ng_job_schedules_unique_job_key_index"
                   )

    drop table(:ng_job_schedules)

    drop table(:user_tokens)

    drop_if_exists unique_index(:agent_config_templates, [:name, :config_type],
                     name: "agent_config_templates_unique_name_and_type_index"
                   )

    drop table(:agent_config_templates)

    drop table(:device_identifiers)

    drop_if_exists unique_index(:snmp_oid_templates, [:vendor, :name],
                     name: "snmp_oid_templates_unique_name_per_vendor_index"
                   )

    drop table(:snmp_oid_templates)

    drop_if_exists unique_index(:nats_leaf_servers, [:edge_site_id],
                     name: "nats_leaf_servers_unique_per_edge_site_index"
                   )

    drop constraint(:nats_leaf_servers, "nats_leaf_servers_edge_site_id_fkey")

    drop table(:nats_leaf_servers)

    drop_if_exists unique_index(:log_promotion_rules, [:name],
                     name: "log_promotion_rules_unique_name_index"
                   )

    drop table(:log_promotion_rules)

    alter table(:polling_schedules) do
      remove :updated_at
      remove :created_at
      remove :metadata
      remove :locked_by
      remove :locked_at
      remove :lock_token
      remove :consecutive_failures
      remove :execution_count
      remove :last_failure_count
      remove :last_success_count
      remove :last_check_count
      remove :last_result
      remove :last_executed_at
      remove :timeout_seconds
      remove :max_concurrent
      remove :priority
      remove :enabled
      remove :assigned_domain
      remove :assigned_partition_id
      remove :assigned_gateway_id
      remove :assignment_mode
      remove :cron_expression
      remove :interval_seconds
      remove :schedule_type
      remove :description
      remove :name
    end

    drop_if_exists unique_index(:poll_jobs, [:id], name: "poll_jobs_unique_job_index")

    drop constraint(:poll_jobs, "poll_jobs_schedule_id_fkey")

    alter table(:poll_jobs) do
      modify :schedule_id, :uuid
    end

    drop table(:polling_schedules)

    drop table(:checkers)

    drop_if_exists unique_index(:ng_users, [:email], name: "ng_users_email_index")

    drop table(:ng_users)

    drop_if_exists unique_index(:stateful_alert_rule_templates, [:name],
                     name: "stateful_alert_rule_templates_unique_name_index"
                   )

    drop table(:stateful_alert_rule_templates)

    drop_if_exists index(:sweep_group_executions, [:sweep_group_id, :started_at],
                     name: "sweep_group_executions_group_started_idx"
                   )

    drop_if_exists index(:sweep_group_executions, [:status],
                     name: "sweep_group_executions_status_idx"
                   )

    alter table(:sweep_group_executions) do
      remove :updated_at
      remove :inserted_at
      remove :scanner_metrics
      remove :sweep_group_id
      remove :config_version
      remove :agent_id
      remove :error_message
      remove :hosts_failed
      remove :hosts_available
      remove :hosts_total
      remove :duration_ms
      remove :completed_at
      remove :started_at
      remove :status
    end

    drop constraint(:sweep_host_results, "sweep_host_results_execution_id_fkey")

    alter table(:sweep_host_results) do
      modify :execution_id, :uuid
    end

    drop table(:sweep_group_executions)

    drop_if_exists unique_index(:device_groups, [:name], name: "device_groups_unique_name_index")

    drop constraint(:device_groups, "device_groups_parent_id_fkey")

    drop table(:device_groups)

    drop_if_exists unique_index(:zen_rules, [:subject, :name],
                     name: "zen_rules_unique_name_index"
                   )

    drop table(:zen_rules)

    drop_if_exists unique_index(:snmp_oid_configs, [:snmp_target_id, :oid],
                     name: "snmp_oid_configs_unique_oid_per_target_index"
                   )

    drop constraint(:snmp_oid_configs, "snmp_oid_configs_snmp_target_id_fkey")

    drop table(:snmp_oid_configs)

    drop_if_exists unique_index(:collector_packages, [:user_name],
                     name: "collector_packages_unique_user_name_index"
                   )

    drop constraint(:collector_packages, "collector_packages_nats_credential_id_fkey")

    drop constraint(:collector_packages, "collector_packages_edge_site_id_fkey")

    drop table(:collector_packages)

    drop_if_exists index(:sweep_host_results, [:execution_id],
                     name: "sweep_host_results_execution_idx"
                   )

    drop_if_exists index(:sweep_host_results, [:ip], name: "sweep_host_results_ip_idx")

    drop_if_exists index(:sweep_host_results, [:status], name: "sweep_host_results_status_idx")

    drop table(:sweep_host_results)

    drop_if_exists index(:agent_config_versions, [:config_instance_id, :version],
                     name: "agent_config_versions_instance_version_idx"
                   )

    drop table(:agent_config_versions)

    drop_if_exists unique_index(:integration_sources, [:name],
                     name: "integration_sources_unique_name_index"
                   )

    drop table(:integration_sources)

    drop table(:merge_audit)

    drop table(:nats_credentials)

    drop table(:snmp_targets)

    drop table(:poll_jobs)

    drop_if_exists unique_index(:health_events, [:id], name: "health_events_unique_event_index")

    drop_if_exists index(:health_events, [:entity_type, :entity_id, :recorded_at])

    drop_if_exists index(:health_events, [:entity_type, :new_state, :recorded_at])

    drop table(:health_events)

    drop table(:alerts)

    drop_if_exists unique_index(:sysmon_profiles, [:name],
                     name: "sysmon_profiles_unique_name_index"
                   )

    drop table(:sysmon_profiles)

    drop_if_exists unique_index(:edge_sites, [:slug], name: "edge_sites_unique_slug_index")

    drop table(:edge_sites)

    # Uncomment this if you actually want to uninstall the extensions
    # when this migration is rolled back:
    # execute("DROP EXTENSION IF EXISTS \"uuid-ossp\"")
    # execute("DROP EXTENSION IF EXISTS \"citext\"")
    execute(
      "DROP FUNCTION IF EXISTS uuid_generate_v7(), timestamp_from_uuid_v7(uuid), ash_raise_error(jsonb), ash_raise_error(jsonb, ANYCOMPATIBLE), ash_elixir_and(BOOLEAN, ANYCOMPATIBLE), ash_elixir_and(ANYCOMPATIBLE, ANYCOMPATIBLE), ash_elixir_or(ANYCOMPATIBLE, ANYCOMPATIBLE), ash_elixir_or(BOOLEAN, ANYCOMPATIBLE), ash_trim_whitespace(text[])"
    )
  end
end
