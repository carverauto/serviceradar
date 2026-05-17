defmodule ServiceRadar.Automation.Northbound.ActionInvocationTarget do
  @moduledoc """
  Per-target result for a northbound action invocation.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Northbound,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  alias ServiceRadar.Automation.Northbound.Changes.RedactTargetResult
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "northbound.actions.view"}
  @launch_check {ActorHasPermission, permission: "northbound.actions.launch"}

  postgres do
    table "northbound_action_invocation_targets"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :invocation, on_delete: :delete
    end
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :status

    transitions do
      transition :record_running, from: :pending, to: :running

      transition :record_deferred,
        from: [:pending, :running, :polling, :result_fetching],
        to: :polling

      transition :record_polling, from: [:running, :polling, :result_fetching], to: :polling

      transition :record_result_fetching,
        from: [:running, :polling, :result_fetching],
        to: :result_fetching

      transition :record_succeeded,
        from: [:pending, :running, :polling, :result_fetching],
        to: :succeeded

      transition :record_failed,
        from: [:pending, :running, :polling, :result_fetching],
        to: :failed

      transition :record_skipped,
        from: [:pending, :running, :polling, :result_fetching],
        to: :skipped

      transition :record_suppressed,
        from: [:pending, :running, :polling, :result_fetching],
        to: :suppressed

      transition :record_expired,
        from: [:pending, :running, :polling, :result_fetching],
        to: :expired

      transition :record_canceled,
        from: [:pending, :running, :polling, :result_fetching],
        to: :canceled
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_invocation, action: :for_invocation, args: [:invocation_id]
    define :list_for_device, action: :for_device, args: [:device_uid]
    define :list_for_interface, action: :for_interface, args: [:device_uid, :interface_uid]
    define :list_poll_due, action: :poll_due, args: [:now]
    define :create_target, action: :create
    define :record_result, action: :record_result
    define :record_running, action: :record_running
    define :record_deferred, action: :record_deferred
    define :record_polling, action: :record_polling
    define :record_result_fetching, action: :record_result_fetching
    define :record_succeeded, action: :record_succeeded
    define :record_failed, action: :record_failed
    define :record_skipped, action: :record_skipped
    define :record_suppressed, action: :record_suppressed
    define :record_expired, action: :record_expired
    define :record_canceled, action: :record_canceled
    define :prepare_callback, action: :prepare_callback
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_invocation do
      argument :invocation_id, :uuid, allow_nil?: false
      filter expr(invocation_id == ^arg(:invocation_id))
    end

    read :for_device do
      argument :device_uid, :string, allow_nil?: false

      filter expr(device_uid == ^arg(:device_uid))

      prepare build(sort: [inserted_at: :desc])
    end

    read :for_interface do
      argument :device_uid, :string, allow_nil?: false
      argument :interface_uid, :string, allow_nil?: false

      filter expr(device_uid == ^arg(:device_uid) and interface_uid == ^arg(:interface_uid))

      prepare build(sort: [inserted_at: :desc])
    end

    read :poll_due do
      argument :now, :utc_datetime_usec, allow_nil?: false

      filter expr(
               status in [:polling, :result_fetching] and not is_nil(next_poll_at) and
                 next_poll_at <= ^arg(:now)
             )

      prepare build(sort: [next_poll_at: :asc])
    end

    create :create do
      accept [
        :invocation_id,
        :target_kind,
        :device_uid,
        :interface_uid,
        :target_snapshot,
        :status,
        :result,
        :external_correlation_id,
        :continuation_state,
        :next_poll_at,
        :poll_deadline_at,
        :last_poll_at,
        :poll_attempt_count,
        :started_at,
        :completed_at
      ]

      change RedactTargetResult
    end

    update :record_result do
      accept [
        :status,
        :result,
        :external_correlation_id,
        :continuation_state,
        :next_poll_at,
        :poll_deadline_at,
        :last_poll_at,
        :poll_attempt_count,
        :started_at,
        :completed_at
      ]

      change RedactTargetResult
    end

    update :record_running do
      accept [:result, :external_correlation_id]
      change RedactTargetResult
      change set_attribute(:started_at, &DateTime.utc_now/0)
      change transition_state(:running)
    end

    update :record_deferred do
      accept [
        :result,
        :external_correlation_id,
        :continuation_state,
        :next_poll_at,
        :poll_deadline_at,
        :last_poll_at,
        :poll_attempt_count,
        :callback_received_at
      ]

      change RedactTargetResult
      change set_attribute(:started_at, &DateTime.utc_now/0)
      change transition_state(:polling)
    end

    update :record_polling do
      accept [
        :result,
        :external_correlation_id,
        :continuation_state,
        :next_poll_at,
        :poll_deadline_at,
        :last_poll_at,
        :poll_attempt_count,
        :callback_received_at
      ]

      change RedactTargetResult
      change transition_state(:polling)
    end

    update :record_result_fetching do
      accept [
        :result,
        :external_correlation_id,
        :continuation_state,
        :next_poll_at,
        :poll_deadline_at,
        :last_poll_at,
        :poll_attempt_count,
        :callback_received_at
      ]

      change RedactTargetResult
      change transition_state(:result_fetching)
    end

    update :record_succeeded do
      accept [
        :result,
        :external_correlation_id,
        :continuation_state,
        :last_poll_at,
        :poll_attempt_count,
        :callback_received_at
      ]

      change RedactTargetResult
      change set_attribute(:next_poll_at, nil)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:succeeded)
    end

    update :record_failed do
      accept [
        :result,
        :external_correlation_id,
        :continuation_state,
        :last_poll_at,
        :poll_attempt_count,
        :callback_received_at
      ]

      change RedactTargetResult
      change set_attribute(:next_poll_at, nil)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:failed)
    end

    update :record_skipped do
      accept [:result, :external_correlation_id, :callback_received_at]
      change RedactTargetResult
      change set_attribute(:next_poll_at, nil)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:skipped)
    end

    update :record_suppressed do
      accept [:result, :external_correlation_id, :callback_received_at]
      change RedactTargetResult
      change set_attribute(:next_poll_at, nil)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:suppressed)
    end

    update :record_expired do
      accept [
        :result,
        :external_correlation_id,
        :continuation_state,
        :last_poll_at,
        :poll_attempt_count,
        :callback_received_at
      ]

      change RedactTargetResult
      change set_attribute(:next_poll_at, nil)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:expired)
    end

    update :record_canceled do
      accept [:result, :external_correlation_id, :callback_received_at]
      change RedactTargetResult
      change set_attribute(:next_poll_at, nil)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:canceled)
    end

    update :prepare_callback do
      accept [
        :callback_token_hash,
        :callback_url,
        :callback_auth_mode,
        :callback_hmac_secret_ciphertext,
        :callback_hmac_algorithm,
        :callback_hmac_signature_header,
        :callback_hmac_timestamp_header,
        :callback_hmac_timestamp_tolerance_seconds
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission(
      [:read, :by_id, :for_invocation, :for_device, :for_interface, :poll_due],
      @view_check
    )

    action_with_permission([:create], @launch_check)
    # Result mutations are driven by the action dispatcher/provider.
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :invocation_id, :uuid, allow_nil?: false, public?: true

    attribute :target_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:device, :interface, :event]
    end

    attribute :device_uid, :string, allow_nil?: true, public?: true
    attribute :interface_uid, :string, allow_nil?: true, public?: true

    attribute :target_snapshot, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending

      constraints one_of: [
                    :pending,
                    :running,
                    :polling,
                    :result_fetching,
                    :succeeded,
                    :failed,
                    :skipped,
                    :suppressed,
                    :expired,
                    :canceled
                  ]
    end

    attribute :result, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :external_correlation_id, :string, allow_nil?: true, public?: true

    attribute :continuation_state, :map do
      allow_nil? false
      public? false
      sensitive? true
      default %{}
    end

    attribute :next_poll_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :poll_deadline_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :last_poll_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :poll_attempt_count, :integer, allow_nil?: false, public?: true, default: 0
    attribute :callback_token_hash, :string, allow_nil?: true, public?: false, sensitive?: true
    attribute :callback_url, :string, allow_nil?: true, public?: true
    attribute :callback_received_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :callback_auth_mode, :atom do
      allow_nil? false
      public? false
      default :token
      constraints one_of: [:token, :hmac_optional, :hmac_required]
    end

    attribute :callback_hmac_secret_ciphertext, :string do
      allow_nil? true
      public? false
      sensitive? true
    end

    attribute :callback_hmac_algorithm, :string do
      allow_nil? true
      public? false
      default "hmac-sha256"
    end

    attribute :callback_hmac_signature_header, :string do
      allow_nil? true
      public? false
      default "x-serviceradar-callback-signature"
    end

    attribute :callback_hmac_timestamp_header, :string do
      allow_nil? true
      public? false
      default "x-serviceradar-callback-timestamp"
    end

    attribute :callback_hmac_timestamp_tolerance_seconds, :integer do
      allow_nil? true
      public? false
      default 300
      constraints min: 1, max: 86_400
    end

    attribute :started_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :completed_at, :utc_datetime_usec, allow_nil?: true, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :invocation, ServiceRadar.Automation.Northbound.ActionInvocation do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :invocation_id
    end
  end
end
