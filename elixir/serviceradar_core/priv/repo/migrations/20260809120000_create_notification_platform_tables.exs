defmodule ServiceRadar.Repo.Migrations.CreateNotificationPlatformTables do
  @moduledoc """
  Creates the notification platform resources.

  The tables live in the `platform` schema and use AshPaperTrail-compatible
  version tables for provider, channel, route, escalation policy, escalation
  step, silence, and template audit.

  Deliveries and acknowledgements are append-heavy audit records and are not
  paper-trailed; the delivery row is itself the audit surface.

  Note: this migration is hand-written. `priv/resource_snapshots/` was removed
  in 607b40f584 and every migration in this tree is authored by hand, so
  `mix ash.codegen` would emit a whole-application migration rather than a
  scoped one.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    # --- Providers -------------------------------------------------------
    create table(:notification_providers, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:provider_key, :text, null: false)
      add(:provider_type, :text, null: false)
      add(:display_name, :text, null: false)
      add(:description, :text)
      add(:icon, :text)
      add(:config_schema, :map, null: false, default: %{})
      add(:capabilities, {:array, :text}, null: false, default: [])
      add(:supported_routes, {:array, :text}, null: false, default: ["control_plane"])
      add(:payload_formats, {:array, :text}, null: false, default: [])
      add(:definition, :map)
      add(:definition_version, :integer, null: false, default: 1)

      add(
        :plugin_package_id,
        references(:plugin_packages, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:action_key, :text)
      add(:implementation_module, :text)
      add(:source, :text, null: false, default: "first_party")
      add(:status, :text, null: false, default: "draft")
      add(:default_max_attempts, :integer, null: false, default: 3)
      add(:managed, :boolean, null: false, default: false)
      add(:template_version, :text)
      add(:template_fingerprint, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:notification_providers, [:provider_key],
        name: :notification_providers_provider_key_uidx,
        prefix: @prefix
      )
    )

    create(index(:notification_providers, [:provider_type], prefix: @prefix))
    create(index(:notification_providers, [:status], prefix: @prefix))

    # A wasm_plugin provider must name both a package and an action key; a
    # non-plugin provider must name neither. Phase 3 adds the manifest
    # cross-check that action_key resolves to a notifications[].key.
    create(
      constraint(:notification_providers, :notification_providers_plugin_ref,
        check: """
        (provider_type = 'wasm_plugin'
          AND plugin_package_id IS NOT NULL AND action_key IS NOT NULL)
        OR (provider_type <> 'wasm_plugin'
          AND plugin_package_id IS NULL AND action_key IS NULL)
        """,
        prefix: @prefix
      )
    )

    # A native provider resolves an allowlisted module; no other tier may.
    create(
      constraint(:notification_providers, :notification_providers_native_module,
        check: """
        (provider_type = 'native' AND implementation_module IS NOT NULL)
        OR (provider_type <> 'native' AND implementation_module IS NULL)
        """,
        prefix: @prefix
      )
    )

    # A declarative provider carries a definition document; no other tier does.
    create(
      constraint(:notification_providers, :notification_providers_declarative_definition,
        check: """
        (provider_type = 'declarative' AND definition IS NOT NULL)
        OR (provider_type <> 'declarative' AND definition IS NULL)
        """,
        prefix: @prefix
      )
    )

    create_version_table(:notification_provider_versions, :notification_providers)

    # --- Schedules -------------------------------------------------------
    create table(:notification_schedules, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:timezone, :text, null: false, default: "Etc/UTC")
      add(:windows, {:array, :map}, null: false, default: [])
      add(:mode, :text, null: false, default: "active_within")
      add(:enabled, :boolean, null: false, default: true)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:notification_schedules, [:name],
        name: :notification_schedules_name_uidx,
        prefix: @prefix
      )
    )

    create_version_table(:notification_schedule_versions, :notification_schedules)

    # --- Escalation policies ---------------------------------------------
    create table(:notification_escalation_policies, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:enabled, :boolean, null: false, default: true)
      add(:repeat_count, :integer, null: false, default: 0)
      add(:repeat_interval_seconds, :integer)
      add(:resolve_notifies, :boolean, null: false, default: true)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:notification_escalation_policies, [:name],
        name: :notification_escalation_policies_name_uidx,
        prefix: @prefix
      )
    )

    create(
      constraint(:notification_escalation_policies, :notification_escalation_policies_repeat,
        check: "repeat_count >= 0 AND (repeat_count = 0 OR repeat_interval_seconds IS NOT NULL)",
        prefix: @prefix
      )
    )

    create_version_table(
      :notification_escalation_policy_versions,
      :notification_escalation_policies
    )

    # --- Channels --------------------------------------------------------
    create table(:notification_channels, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)

      add(
        :provider_id,
        references(:notification_providers,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(:enabled, :boolean, null: false, default: true)
      add(:config, :map, null: false, default: %{})
      add(:secret_refs, :map, null: false, default: %{})
      add(:execution_route, :text, null: false, default: "control_plane")
      add(:agent_uid, :text)
      add(:partition_id, :text)

      add(
        :fallback_channel_id,
        references(:notification_channels, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:fail_closed, :boolean, null: false, default: false)
      add(:rate_limit_per_minute, :integer)
      add(:max_attempts, :integer, null: false, default: 3)
      add(:health, :text, null: false, default: "unknown")
      add(:last_success_at, :utc_datetime_usec)
      add(:last_failure_at, :utc_datetime_usec)
      add(:last_error, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:notification_channels, [:name],
        name: :notification_channels_name_uidx,
        prefix: @prefix
      )
    )

    create(index(:notification_channels, [:provider_id], prefix: @prefix))
    create(index(:notification_channels, [:execution_route], prefix: @prefix))

    create(
      index(:notification_channels, [:agent_uid],
        prefix: @prefix,
        where: "agent_uid IS NOT NULL"
      )
    )

    # An edge-routed channel must name the agent it egresses from.
    create(
      constraint(:notification_channels, :notification_channels_edge_agent,
        check: """
        (execution_route = 'edge_agent' AND agent_uid IS NOT NULL)
        OR execution_route <> 'edge_agent'
        """,
        prefix: @prefix
      )
    )

    create(
      constraint(:notification_channels, :notification_channels_max_attempts,
        check: "max_attempts >= 1",
        prefix: @prefix
      )
    )

    # A channel cannot fail over to itself.
    create(
      constraint(:notification_channels, :notification_channels_fallback_not_self,
        check: "fallback_channel_id IS NULL OR fallback_channel_id <> id",
        prefix: @prefix
      )
    )

    create_version_table(:notification_channel_versions, :notification_channels)

    # --- Escalation steps ------------------------------------------------
    create table(:notification_escalation_steps, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :policy_id,
        references(:notification_escalation_policies,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:step_number, :integer, null: false)
      add(:delay_seconds, :integer, null: false, default: 0)
      add(:condition, :text, null: false, default: "if_unacknowledged")
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:notification_escalation_steps, [:policy_id, :step_number],
        name: :notification_escalation_steps_policy_step_uidx,
        prefix: @prefix
      )
    )

    create(
      constraint(:notification_escalation_steps, :notification_escalation_steps_bounds,
        check: "step_number >= 1 AND delay_seconds >= 0",
        prefix: @prefix
      )
    )

    create_version_table(:notification_escalation_step_versions, :notification_escalation_steps)

    # Fan-out: a step holds a SET of channels.
    create table(:notification_escalation_step_channels, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :step_id,
        references(:notification_escalation_steps,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :channel_id,
        references(:notification_channels, type: :uuid, on_delete: :delete_all, prefix: @prefix),
        null: false
      )

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:notification_escalation_step_channels, [:step_id, :channel_id],
        name: :notification_escalation_step_channels_uidx,
        prefix: @prefix
      )
    )

    create(index(:notification_escalation_step_channels, [:channel_id], prefix: @prefix))

    # --- Routes ----------------------------------------------------------
    create table(:notification_routes, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:enabled, :boolean, null: false, default: true)
      add(:priority, :integer, null: false, default: 100)
      add(:match_expression, :map, null: false, default: %{})

      add(
        :escalation_policy_id,
        references(:notification_escalation_policies,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :schedule_id,
        references(:notification_schedules, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:dedupe_key_template, :text)
      add(:throttle_seconds, :integer)
      add(:group_wait_seconds, :integer, null: false, default: 0)
      add(:group_interval_seconds, :integer)
      add(:continue, :boolean, null: false, default: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:notification_routes, [:name],
        name: :notification_routes_name_uidx,
        prefix: @prefix
      )
    )

    create(
      index(:notification_routes, [:priority, :id],
        name: :notification_routes_priority_idx,
        prefix: @prefix,
        where: "enabled"
      )
    )

    create_version_table(:notification_route_versions, :notification_routes)

    # --- Silences --------------------------------------------------------
    create table(:notification_silences, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text)
      add(:matchers, :map, null: false, default: %{})
      add(:starts_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:ends_at, :utc_datetime_usec, null: false)

      add(
        :created_by_user_id,
        references(:ng_users, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:created_by, :text)
      add(:comment, :text, null: false)
      add(:state, :text, null: false, default: "scheduled")
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      index(:notification_silences, [:state, :ends_at],
        name: :notification_silences_state_ends_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(:notification_silences, :notification_silences_window,
        check: "ends_at > starts_at",
        prefix: @prefix
      )
    )

    create_version_table(:notification_silence_versions, :notification_silences)

    # --- Templates -------------------------------------------------------
    create table(:notification_templates, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text, null: false)
      add(:alert_class, :text, null: false, default: "default")
      add(:payload_format, :text, null: false)
      add(:provider_key, :text)
      add(:subject_template, :text)
      add(:body_template, :text, null: false)
      add(:managed, :boolean, null: false, default: false)
      add(:template_version, :text)
      add(:template_fingerprint, :text)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    # Selection is (alert_class x payload_format) with an optional
    # provider-specific override tier. NULLS NOT DISTINCT so the generic
    # (provider_key IS NULL) row cannot be duplicated.
    execute("""
    CREATE UNIQUE INDEX notification_templates_selection_uidx
      ON #{@prefix}.notification_templates (alert_class, payload_format, provider_key)
      NULLS NOT DISTINCT
    """)

    create_version_table(:notification_template_versions, :notification_templates)

    # --- Deliveries ------------------------------------------------------
    create table(:notification_deliveries, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      # on_delete: :nilify_all, never :delete_all - AlertsRetentionWorker hard
      # deletes alerts after 3 days and a delivery record must outlive its alert.
      add(
        :alert_id,
        references(:alerts, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:alert_snapshot, :map, null: false, default: %{})

      add(
        :route_id,
        references(:notification_routes, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(
        :policy_id,
        references(:notification_escalation_policies,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:step_number, :integer)

      add(
        :channel_id,
        references(:notification_channels, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(
        :originating_delivery_id,
        references(:notification_deliveries, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:dedupe_key, :text)
      add(:state, :text, null: false, default: "pending")
      add(:suppression_reason, :text)
      add(:occurrence_count, :integer, null: false, default: 1)
      add(:last_evaluated_at, :utc_datetime_usec)
      add(:attempt_count, :integer, null: false, default: 0)
      add(:max_attempts, :integer, null: false, default: 3)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:external_correlation_id, :text)
      add(:error_class, :text)
      add(:error_message, :text)
      add(:result_summary, :map, null: false, default: %{})
      add(:rendered_payload_digest, :text)
      add(:payload_format, :text)
      add(:provider_version, :integer)
      add(:is_test, :boolean, null: false, default: false)
      add(:execution_route, :text, null: false, default: "control_plane")
      add(:agent_uid, :text)
      add(:command_id, :uuid)
      add(:queued_at, :utc_datetime_usec)
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:notification_deliveries, [:alert_id], prefix: @prefix))
    create(index(:notification_deliveries, [:channel_id], prefix: @prefix))
    create(index(:notification_deliveries, [:state], prefix: @prefix))

    create(
      index(:notification_deliveries, [:originating_delivery_id],
        prefix: @prefix,
        where: "originating_delivery_id IS NOT NULL"
      )
    )

    # Retry-due and escalation-due scan. :failed is terminal and is deliberately
    # excluded; retry-eligible rows stay :pending with next_attempt_at set.
    create(
      index(:notification_deliveries, [:next_attempt_at],
        name: :notification_deliveries_retry_due_idx,
        prefix: @prefix,
        where: "state = 'pending' AND next_attempt_at IS NOT NULL"
      )
    )

    create(
      index(:notification_deliveries, [:inserted_at],
        name: :notification_deliveries_retention_idx,
        prefix: @prefix
      )
    )

    # Suppression decision identity. NULLS NOT DISTINCT is load bearing: a
    # :no_matching_route decision has NULL policy_id/step_number/channel_id, and
    # under default NULLS DISTINCT semantics two identical unrouted decisions
    # would both INSERT, silently defeating occurrence collapsing for exactly
    # the case the reason exists to make visible.
    execute("""
    CREATE UNIQUE INDEX notification_deliveries_suppression_uidx
      ON #{@prefix}.notification_deliveries
        (alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason)
      NULLS NOT DISTINCT
      WHERE state = 'suppressed'
    """)

    create(
      constraint(:notification_deliveries, :notification_deliveries_suppression_reason,
        check: """
        (state = 'suppressed' AND suppression_reason IS NOT NULL)
        OR (state <> 'suppressed' AND suppression_reason IS NULL)
        """,
        prefix: @prefix
      )
    )

    create(
      constraint(:notification_deliveries, :notification_deliveries_attempts,
        check: "attempt_count >= 0 AND max_attempts >= 1 AND occurrence_count >= 1",
        prefix: @prefix
      )
    )

    create(
      constraint(:notification_deliveries, :notification_deliveries_not_self_origin,
        check: "originating_delivery_id IS NULL OR originating_delivery_id <> id",
        prefix: @prefix
      )
    )

    # --- Acknowledgements -------------------------------------------------
    create table(:notification_acknowledgements, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :delivery_id,
        references(:notification_deliveries, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(
        :alert_id,
        references(:alerts, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:action, :text, null: false)
      add(:actor_kind, :text, null: false)

      add(
        :actor_user_id,
        references(:ng_users, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:external_principal, :text)
      add(:note, :text)
      add(:snooze_until, :utc_datetime_usec)
      add(:source, :text, null: false)
      add(:received_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:notification_acknowledgements, [:alert_id], prefix: @prefix))
    create(index(:notification_acknowledgements, [:delivery_id], prefix: @prefix))

    create(
      constraint(:notification_acknowledgements, :notification_acknowledgements_actor,
        check: """
        (actor_kind = 'platform_user' AND actor_user_id IS NOT NULL)
        OR (actor_kind = 'external_principal' AND external_principal IS NOT NULL)
        OR actor_kind = 'system'
        """,
        prefix: @prefix
      )
    )

    create(
      constraint(:notification_acknowledgements, :notification_acknowledgements_snooze,
        check: "action <> 'snooze' OR snooze_until IS NOT NULL",
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:notification_acknowledgements, prefix: @prefix))
    drop_if_exists(table(:notification_deliveries, prefix: @prefix))
    drop_if_exists(table(:notification_template_versions, prefix: @prefix))
    drop_if_exists(table(:notification_templates, prefix: @prefix))
    drop_if_exists(table(:notification_silence_versions, prefix: @prefix))
    drop_if_exists(table(:notification_silences, prefix: @prefix))
    drop_if_exists(table(:notification_route_versions, prefix: @prefix))
    drop_if_exists(table(:notification_routes, prefix: @prefix))
    drop_if_exists(table(:notification_escalation_step_channels, prefix: @prefix))
    drop_if_exists(table(:notification_escalation_step_versions, prefix: @prefix))
    drop_if_exists(table(:notification_escalation_steps, prefix: @prefix))
    drop_if_exists(table(:notification_channel_versions, prefix: @prefix))
    drop_if_exists(table(:notification_channels, prefix: @prefix))
    drop_if_exists(table(:notification_escalation_policy_versions, prefix: @prefix))
    drop_if_exists(table(:notification_escalation_policies, prefix: @prefix))
    drop_if_exists(table(:notification_schedule_versions, prefix: @prefix))
    drop_if_exists(table(:notification_schedules, prefix: @prefix))
    drop_if_exists(table(:notification_provider_versions, prefix: @prefix))
    drop_if_exists(table(:notification_providers, prefix: @prefix))
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
      add(:version_inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:version_updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(version_table, [:version_source_id], prefix: @prefix))
  end
end
