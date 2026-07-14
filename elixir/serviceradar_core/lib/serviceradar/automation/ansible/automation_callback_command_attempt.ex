defmodule ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt do
  @moduledoc """
  Durable outbox and result-processing ledger for one callback AWX command.

  Every command UUID is allocated before dispatch. The request snapshot contains
  only non-secret orchestration fields and lets a recovery worker dispatch a
  command only when no `AgentCommand` with that UUID exists. Result processing
  is correlated to this immutable row and is monotonic across crashes/replays.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  postgres do
    table "automation_callback_command_attempts"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_command: "automation_callback_command_attempts_command_uidx",
                         unique_stage_attempt:
                           "automation_callback_command_attempts_stage_attempt_uidx",
                         one_active_stage:
                           "automation_callback_command_attempts_active_stage_uidx"

    identity_wheres_to_sql one_active_stage:
                             "state IN ('planned', 'dispatching', 'dispatched', 'processing', 'waiting')"

    references do
      reference :grant, on_delete: :restrict
      reference :operation, on_delete: :restrict
      reference :execution, on_delete: :restrict
      reference :controller, on_delete: :restrict
    end

    check_constraints do
      check_constraint :request_digest, "automation_callback_command_attempts_digest_check",
        check:
          "request_digest ~ '^[0-9a-f]{64}$' AND context_digest ~ '^[0-9a-f]{64}$' AND (result_digest IS NULL OR result_digest ~ '^[0-9a-f]{64}$')",
        message: "must be a lowercase SHA-256 digest"

      check_constraint :request_schema_version,
                       "automation_callback_command_attempts_schema_check",
                       check:
                         "request_schema_version = 'serviceradar.automation_callback_command/v1'",
                       message: "must use the supported callback command schema"

      check_constraint :command_type, "automation_callback_command_attempts_stage_command_check",
        check: """
        (stage = 'create_credential' AND command_type = 'awx.create_callback_credential' AND purpose = 'credential_creation' AND expected_credential_id IS NULL AND expected_job_id IS NULL)
        OR (stage = 'fetch_credential' AND command_type = 'awx.fetch_callback_credential' AND purpose = 'credential_reconciliation' AND expected_credential_id IS NULL AND expected_job_id IS NULL)
        OR (stage = 'launch_job' AND command_type = 'awx.launch_job' AND purpose = 'accepted_job_proof' AND expected_credential_id IS NOT NULL AND expected_job_id IS NULL)
        OR (stage = 'fetch_job' AND command_type = 'awx.fetch_job' AND purpose IN ('accepted_job_proof', 'scope_poll', 'terminal_poll') AND expected_job_id IS NOT NULL)
        OR (stage = 'list_recent_jobs' AND command_type = 'awx.list_recent_jobs' AND purpose = 'launch_reconciliation')
        OR (stage = 'fetch_host_summaries' AND command_type = 'awx.fetch_job_host_summaries' AND purpose IN ('host_scope_proof', 'terminal_confirmation') AND expected_job_id IS NOT NULL)
        OR (stage = 'cancel_job' AND command_type = 'awx.cancel_job' AND purpose = 'terminal_cleanup' AND expected_job_id IS NOT NULL)
        OR (stage = 'delete_credential' AND command_type = 'awx.delete_callback_credential' AND purpose = 'terminal_cleanup' AND expected_credential_id IS NOT NULL)
        """,
        message: "must match its bounded callback stage contract"

      check_constraint :next_attempt_at, "automation_callback_command_attempts_deadline_check",
        check: "next_attempt_at IS NULL OR next_attempt_at <= deadline_at",
        message: "must not exceed the callback deadline"

      check_constraint :candidate_job_ids,
                       "automation_callback_command_attempts_candidate_jobs_check",
                       check: """
                       cardinality(candidate_job_ids) <= 5000
                       AND 0 < ALL(candidate_job_ids)
                       AND array_position(candidate_job_ids, NULL) IS NULL
                       """,
                       message: "must contain at most 5000 positive AWX job IDs"

      check_constraint :reconcile_after, "automation_callback_command_attempts_reconcile_check",
        check:
          "(stage = 'list_recent_jobs' AND reconcile_after IS NOT NULL) OR (stage <> 'list_recent_jobs' AND reconcile_after IS NULL)",
        message: "must be present only for launch reconciliation"

      check_constraint :terminal_job_snapshot,
                       "automation_callback_command_attempts_terminal_evidence_check",
                       check:
                         "(purpose = 'terminal_confirmation' AND terminal_job_snapshot IS NOT NULL) OR (purpose <> 'terminal_confirmation' AND terminal_job_snapshot IS NULL)",
                       message: "must be present only for terminal confirmation"

      check_constraint :lease_token, "automation_callback_command_attempts_lease_check",
        check: """
        (state IN ('dispatching', 'processing') AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
        OR (state NOT IN ('dispatching', 'processing') AND lease_token IS NULL AND lease_expires_at IS NULL)
        """,
        message: "must exactly match a leased state"

      check_constraint :processed_at, "automation_callback_command_attempts_terminal_check",
        check: """
        (state IN ('succeeded', 'failed', 'ambiguous') AND processed_at IS NOT NULL AND outcome_code IS NOT NULL AND next_attempt_at IS NULL)
        OR (state NOT IN ('succeeded', 'failed', 'ambiguous') AND processed_at IS NULL)
        """,
        message: "must exactly match a terminal state"
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_command_id, action: :by_command_id, args: [:command_id]
    define :list_for_grant, action: :for_grant, args: [:grant_id]
    define :list_recoverable, action: :recoverable, args: [:now]

    define :list_activation_cleanup_pending,
      action: :activation_cleanup_pending,
      args: [:retry_before]

    define :create_planned, action: :create_planned
    define :claim_dispatch, action: :claim_dispatch
    define :mark_dispatched, action: :mark_dispatched
    define :release_dispatch, action: :release_dispatch
    define :mark_processing, action: :mark_processing
    define :mark_succeeded, action: :mark_succeeded
    define :mark_failed, action: :mark_failed
    define :mark_ambiguous, action: :mark_ambiguous
    define :deny_before_dispatch, action: :deny_before_dispatch
    define :deny_incomplete, action: :deny_incomplete
    define :mark_deadline_elapsed, action: :mark_deadline_elapsed
  end

  actions do
    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_command_id do
      argument :command_id, :uuid, allow_nil?: false
      get? true
      filter expr(command_id == ^arg(:command_id))
    end

    read :for_grant do
      argument :grant_id, :uuid, allow_nil?: false
      filter expr(grant_id == ^arg(:grant_id))
      prepare build(sort: [inserted_at: :asc, stage: :asc, attempt: :asc])
    end

    read :recoverable do
      argument :now, :utc_datetime_usec, allow_nil?: false

      filter expr(
               (state == :planned and
                  (is_nil(next_attempt_at) or next_attempt_at <= ^arg(:now))) or
                 (state == :waiting and next_attempt_at <= ^arg(:now)) or
                 (state == :dispatched and next_attempt_at <= ^arg(:now)) or
                 (state in [:dispatching, :processing] and lease_expires_at <= ^arg(:now))
             )

      prepare build(sort: [next_attempt_at: :asc_nils_first, inserted_at: :asc], limit: 100)
    end

    read :activation_cleanup_pending do
      argument :retry_before, :utc_datetime_usec, allow_nil?: false

      filter expr(
               state == :succeeded and outcome_code == "scope_verified_and_activated" and
                 (grant.credential_cleanup_state not in [:deleting, :deleted] or
                    (grant.credential_cleanup_state == :deleting and
                       not is_nil(grant.credential_cleanup_attempted_at) and
                       grant.credential_cleanup_attempted_at <= ^arg(:retry_before)))
             )

      prepare build(sort: [processed_at: :asc], limit: 100)
    end

    create :create_planned do
      primary? true

      accept [
        :grant_id,
        :operation_id,
        :execution_id,
        :controller_id,
        :dispatch_agent_id,
        :dispatch_partition_id,
        :cleanup_only,
        :stage,
        :purpose,
        :attempt,
        :command_id,
        :command_type,
        :request_schema_version,
        :request_digest,
        :context_digest,
        :reconcile_after,
        :terminal_job_snapshot,
        :candidate_job_ids,
        :expected_credential_id,
        :expected_job_id,
        :deadline_at,
        :next_attempt_at
      ]
    end

    update :claim_dispatch do
      require_atomic? true
      argument :lease_token, :uuid, allow_nil?: false
      argument :lease_expires_at, :utc_datetime_usec, allow_nil?: false
      argument :now, :utc_datetime_usec, allow_nil?: false

      filter expr(
               (state == :planned and
                  (is_nil(next_attempt_at) or next_attempt_at <= ^arg(:now))) or
                 (state == :waiting and next_attempt_at <= ^arg(:now)) or
                 (state == :dispatching and lease_expires_at <= ^arg(:now))
             )

      change set_attribute(:state, :dispatching)
      change set_attribute(:lease_token, arg(:lease_token))
      change set_attribute(:lease_expires_at, arg(:lease_expires_at))
    end

    update :mark_dispatched do
      require_atomic? true
      argument :lease_token, :uuid, allow_nil?: false
      accept [:dispatched_at, :next_attempt_at]
      filter expr(state == :dispatching and lease_token == ^arg(:lease_token))
      change set_attribute(:state, :dispatched)
      change set_attribute(:last_error_code, nil)
      change set_attribute(:lease_token, nil)
      change set_attribute(:lease_expires_at, nil)
    end

    update :release_dispatch do
      require_atomic? true
      argument :lease_token, :uuid, allow_nil?: false
      accept [:next_attempt_at, :last_error_code]
      filter expr(state == :dispatching and lease_token == ^arg(:lease_token))
      change set_attribute(:state, :waiting)
      change set_attribute(:lease_token, nil)
      change set_attribute(:lease_expires_at, nil)
    end

    update :mark_processing do
      require_atomic? true
      argument :lease_token, :uuid, allow_nil?: false
      argument :lease_expires_at, :utc_datetime_usec, allow_nil?: false
      argument :now, :utc_datetime_usec, allow_nil?: false
      accept [:processing_started_at]

      filter expr(
               state in [:dispatching, :dispatched, :waiting] or
                 (state == :processing and lease_expires_at <= ^arg(:now))
             )

      change set_attribute(:state, :processing)
      change set_attribute(:lease_token, arg(:lease_token))
      change set_attribute(:lease_expires_at, arg(:lease_expires_at))
    end

    update :mark_succeeded do
      require_atomic? true
      argument :lease_token, :uuid, allow_nil?: false
      accept [:processed_at, :outcome_code, :result_digest]
      filter expr(state == :processing and lease_token == ^arg(:lease_token))
      change set_attribute(:state, :succeeded)
      change set_attribute(:last_error_code, nil)
      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:lease_token, nil)
      change set_attribute(:lease_expires_at, nil)
    end

    update :mark_failed do
      require_atomic? true
      argument :lease_token, :uuid, allow_nil?: false
      accept [:processed_at, :outcome_code, :last_error_code, :result_digest]
      filter expr(state == :processing and lease_token == ^arg(:lease_token))
      change set_attribute(:state, :failed)
      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:lease_token, nil)
      change set_attribute(:lease_expires_at, nil)
    end

    update :mark_ambiguous do
      require_atomic? true
      argument :lease_token, :uuid, allow_nil?: false
      accept [:processed_at, :outcome_code, :last_error_code, :result_digest]
      filter expr(state == :processing and lease_token == ^arg(:lease_token))
      change set_attribute(:state, :ambiguous)
      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:lease_token, nil)
      change set_attribute(:lease_expires_at, nil)
    end

    update :deny_before_dispatch do
      require_atomic? true
      accept [:processed_at, :outcome_code, :last_error_code]
      filter expr(state in [:planned, :waiting, :dispatching])
      change set_attribute(:state, :failed)
      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:lease_token, nil)
      change set_attribute(:lease_expires_at, nil)
    end

    update :deny_incomplete do
      require_atomic? true
      accept [:processed_at, :outcome_code, :last_error_code]
      filter expr(state in [:planned, :waiting, :dispatching, :dispatched])
      change set_attribute(:state, :failed)
      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:lease_token, nil)
      change set_attribute(:lease_expires_at, nil)
    end

    update :mark_deadline_elapsed do
      require_atomic? true
      argument :now, :utc_datetime_usec, allow_nil?: false
      accept [:processed_at, :outcome_code, :last_error_code]

      filter expr(
               state in [:planned, :dispatching, :dispatched, :processing, :waiting] and
                 deadline_at <= ^arg(:now)
             )

      change set_attribute(:state, :ambiguous)
      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:lease_token, nil)
      change set_attribute(:lease_expires_at, nil)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission(
      [:read, :by_id, :by_command_id, :for_grant, :activation_cleanup_pending],
      @view_check
    )
  end

  changes do
    # Lifecycle filters define a valid transition. The version guard makes the
    # lease exclusive when multiple recovery workers loaded the same row; a
    # stale struct must never report a second successful claim.
    change optimistic_lock(:lock_version), on: [:update]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :grant_id, :uuid, allow_nil?: false, public?: true
    attribute :operation_id, :uuid, allow_nil?: false, public?: true
    attribute :execution_id, :uuid, allow_nil?: false, public?: true
    attribute :controller_id, :uuid, allow_nil?: false, public?: true
    attribute :dispatch_agent_id, :string, allow_nil?: false, public?: true
    attribute :dispatch_partition_id, :string, allow_nil?: false, public?: true
    attribute :cleanup_only, :boolean, allow_nil?: false, default: false, public?: true

    attribute :stage, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :create_credential,
                    :fetch_credential,
                    :launch_job,
                    :fetch_job,
                    :list_recent_jobs,
                    :fetch_host_summaries,
                    :cancel_job,
                    :delete_credential
                  ]
    end

    attribute :purpose, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :credential_creation,
                    :credential_reconciliation,
                    :accepted_job_proof,
                    :launch_reconciliation,
                    :scope_poll,
                    :host_scope_proof,
                    :terminal_poll,
                    :terminal_confirmation,
                    :terminal_cleanup
                  ]
    end

    attribute :attempt, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1, max: 1_000
    end

    attribute :command_id, :uuid, allow_nil?: false, public?: true
    attribute :command_type, :string, allow_nil?: false, public?: true

    attribute :request_schema_version, :string do
      allow_nil? false
      default "serviceradar.automation_callback_command/v1"
      public? true
    end

    attribute :request_digest, :string, allow_nil?: false, public?: true
    attribute :context_digest, :string, allow_nil?: false, public?: true
    attribute :result_digest, :string, allow_nil?: true, public?: true

    attribute :expected_credential_id, :integer do
      allow_nil? true
      public? false
      sensitive? true
      constraints min: 1
    end

    attribute :expected_job_id, :integer do
      allow_nil? true
      public? true
      constraints min: 1
    end

    attribute :reconcile_after, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :terminal_job_snapshot, :map, allow_nil?: true, public?: true

    attribute :candidate_job_ids, {:array, :integer},
      allow_nil?: false,
      default: [],
      public?: true,
      constraints: [items: [min: 1], max_length: 5_000]

    attribute :state, :atom do
      allow_nil? false
      default :planned
      public? true

      constraints one_of: [
                    :planned,
                    :dispatching,
                    :dispatched,
                    :processing,
                    :waiting,
                    :succeeded,
                    :failed,
                    :ambiguous
                  ]
    end

    attribute :deadline_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :next_attempt_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :lease_token, :uuid, allow_nil?: true, public?: false, sensitive?: true
    attribute :lease_expires_at, :utc_datetime_usec, allow_nil?: true, public?: false
    attribute :dispatched_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :processing_started_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :processed_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :outcome_code, :string, allow_nil?: true, public?: true
    attribute :last_error_code, :string, allow_nil?: true, public?: true
    attribute :lock_version, :integer, allow_nil?: false, default: 1, public?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :grant, ServiceRadar.Automation.Callbacks.Grant do
      define_attribute? false
      source_attribute :grant_id
    end

    belongs_to :operation, ServiceRadar.Automation.Ansible.AutomationOperation do
      define_attribute? false
      source_attribute :operation_id
    end

    belongs_to :execution, ServiceRadar.Automation.Ansible.AutomationExecution do
      define_attribute? false
      source_attribute :execution_id
    end

    belongs_to :controller, ServiceRadar.Automation.Ansible.Controller do
      define_attribute? false
      source_attribute :controller_id
    end
  end

  identities do
    identity :unique_command, [:command_id]
    identity :unique_stage_attempt, [:grant_id, :stage, :purpose, :attempt]

    identity :one_active_stage, [:grant_id, :stage, :purpose],
      where: expr(state in [:planned, :dispatching, :dispatched, :processing, :waiting])
  end
end
