defmodule ServiceRadar.Automation.Ansible.PlaybookRun do
  @moduledoc """
  A single Ansible playbook execution.

  State machine: `pending → launching → running → (succeeded | partial | failed | unreachable | canceled)`.
  Terminal states do not transition further. `partial` is reached when the run's
  `PlaybookRunTarget`s have mixed outcomes; `failed` when every target failed.

  `last_event_id` is the watermark for AWX `/api/v2/jobs/{id}/job_events/?since_id=N`
  ingestion; RunPulseWorker advances it as events are persisted. Runs created from
  a `PlaybookSchedule` carry `schedule_id`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer],
    # The primary `:read` carries a `prepare build(select: ...)`, which trips
    # Ash's "primary read has preparations" warning (an error under
    # --warnings-as-errors). Both are intentional — same pattern as #4495.
    primary_read_warning?: false

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}
  @launch_check {ActorHasPermission, permission: "ansible.runs.launch"}
  @cancel_check {ActorHasPermission, permission: "ansible.runs.cancel"}

  @public_read_fields [
    :id,
    :playbook_id,
    :controller_id,
    :schedule_id,
    :awx_job_id,
    :state,
    :requested_extra_vars,
    :requested_by_actor_id,
    :host_limit,
    :started_at,
    :ended_at,
    :last_event_id,
    :summary,
    :diagnostics,
    :metadata,
    :inserted_at,
    :updated_at
  ]

  postgres do
    table "ansible_playbook_runs"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :playbook, on_delete: :restrict
      reference :controller, on_delete: :restrict
      reference :schedule, on_delete: :nilify
    end
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :state

    transitions do
      transition :record_launching, from: :pending, to: :launching
      transition :record_running, from: :launching, to: :running
      transition :record_succeeded, from: :running, to: :succeeded
      transition :record_partial, from: :running, to: :partial
      transition :record_failed, from: [:launching, :running], to: :failed
      transition :record_unreachable, from: [:pending, :launching, :running], to: :unreachable
      transition :record_canceled, from: [:running], to: :canceled
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "ansible_playbook_run_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at, :last_event_id]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_awx_job_id, action: :by_awx_job_id, args: [:awx_job_id]
    define :list_active_for_controller, action: :active_for_controller, args: [:controller_id]
    define :list_by_schedule, action: :by_schedule, args: [:schedule_id]
    define :create_run, action: :create
    define :record_launching, action: :record_launching
    define :record_running, action: :record_running
    define :record_succeeded, action: :record_succeeded
    define :record_partial, action: :record_partial
    define :record_failed, action: :record_failed
    define :record_unreachable, action: :record_unreachable
    define :record_canceled, action: :record_canceled
    define :advance_watermark, action: :advance_watermark
  end

  actions do
    read :read do
      # Primary read — the device Ansible panel's `for_device` load chain
      # resolves the `run` relationship through this; Ash requires a primary read
      # to load a resource via a relationship. Missing it crash-looped the
      # device-details run history the first time a device had a run.
      primary? true
      prepare build(select: @public_read_fields)
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: @public_read_fields)
    end

    read :active_for_controller do
      description "Non-terminal runs for a controller — drives RunPulseWorker tick batching"
      argument :controller_id, :uuid, allow_nil?: false

      filter expr(
               controller_id == ^arg(:controller_id) and state in [:pending, :launching, :running]
             )

      prepare build(select: @public_read_fields)
    end

    read :by_awx_job_id do
      description "Resolve a run from the AWX job id — used by EventIngestor to attribute events"
      argument :awx_job_id, :integer, allow_nil?: false
      get? true
      filter expr(awx_job_id == ^arg(:awx_job_id))
      prepare build(select: @public_read_fields)
    end

    read :by_schedule do
      argument :schedule_id, :uuid, allow_nil?: false
      filter expr(schedule_id == ^arg(:schedule_id))
      prepare build(select: @public_read_fields)
    end

    create :create do
      accept [
        :playbook_id,
        :controller_id,
        :schedule_id,
        :requested_by_actor_id,
        :host_limit,
        :metadata
      ]
    end

    update :record_launching do
      # transition_state/1 is not atomically expressible and the resource has
      # no primary read for atomic upgrade — without this, EVERY run state
      # transition raised "must be performed atomically" at runtime and runs
      # were stuck at :pending forever.
      require_atomic? false
      description "Launch dispatched to AWX; awx_job_id captured"
      accept [:awx_job_id]
      change set_attribute(:started_at, &DateTime.utc_now/0)
      change transition_state(:launching)
    end

    update :record_running do
      # transition_state/1 is not atomically expressible and the resource has
      # no primary read for atomic upgrade — without this, EVERY run state
      # transition raised "must be performed atomically" at runtime and runs
      # were stuck at :pending forever.
      require_atomic? false
      description "First job event arrived — run is actively executing on AWX"
      change transition_state(:running)
    end

    update :record_succeeded do
      # transition_state/1 is not atomically expressible and the resource has
      # no primary read for atomic upgrade — without this, EVERY run state
      # transition raised "must be performed atomically" at runtime and runs
      # were stuck at :pending forever.
      require_atomic? false
      accept [:summary]
      change set_attribute(:ended_at, &DateTime.utc_now/0)
      change transition_state(:succeeded)
    end

    update :record_partial do
      # transition_state/1 is not atomically expressible and the resource has
      # no primary read for atomic upgrade — without this, EVERY run state
      # transition raised "must be performed atomically" at runtime and runs
      # were stuck at :pending forever.
      require_atomic? false
      description "Multi-target run with mixed outcomes"
      accept [:summary]
      change set_attribute(:ended_at, &DateTime.utc_now/0)
      change transition_state(:partial)
    end

    update :record_failed do
      # transition_state/1 is not atomically expressible and the resource has
      # no primary read for atomic upgrade — without this, EVERY run state
      # transition raised "must be performed atomically" at runtime and runs
      # were stuck at :pending forever.
      require_atomic? false
      accept [:summary, :diagnostics]
      change set_attribute(:ended_at, &DateTime.utc_now/0)
      change transition_state(:failed)
    end

    update :record_unreachable do
      # transition_state/1 is not atomically expressible and the resource has
      # no primary read for atomic upgrade — without this, EVERY run state
      # transition raised "must be performed atomically" at runtime and runs
      # were stuck at :pending forever.
      require_atomic? false
      description "Watchdog or AWX-side failure — run did not reach a normal terminal state"
      accept [:diagnostics]
      change set_attribute(:ended_at, &DateTime.utc_now/0)
      change transition_state(:unreachable)
    end

    update :record_canceled do
      # transition_state/1 is not atomically expressible and the resource has
      # no primary read for atomic upgrade — without this, EVERY run state
      # transition raised "must be performed atomically" at runtime and runs
      # were stuck at :pending forever.
      require_atomic? false
      accept [:summary]
      change set_attribute(:ended_at, &DateTime.utc_now/0)
      change transition_state(:canceled)
    end

    update :advance_watermark do
      description "RunPulseWorker advances last_event_id after persisting a batch"
      accept [:last_event_id]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :active_for_controller, :by_schedule], @view_check)
    action_with_permission([:create], @launch_check)
    action_with_permission([:record_canceled], @cancel_check)
    # Lifecycle transitions other than cancel are driven by the system
    # (RunPulseWorker / RunWatchdog); they pass through `system_bypass`.
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :playbook_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :controller_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :schedule_id, :uuid do
      allow_nil? true
      public? true
      description "Set when the run was created by ScheduleEvaluatorWorker"
    end

    attribute :awx_job_id, :integer do
      allow_nil? true
      public? true
      description "AWX job id; null until record_launching fires"
    end

    attribute :requested_extra_vars, :map do
      allow_nil? false
      public? true
      default %{}
      description "extra_vars snapshot at launch time"
    end

    attribute :requested_by_actor_id, :uuid do
      allow_nil? true
      public? true
      description "Operator who launched the run; null for schedule-driven runs"
    end

    attribute :host_limit, :string do
      allow_nil? true
      public? true
      description "AWX `limit:` value used for this run (comma-joined host names)"
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :ended_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_event_id, :integer do
      allow_nil? false
      public? true
      default 0
      description "Watermark for AWX job_events ingestion"
    end

    attribute :summary, :string do
      allow_nil? true
      public? true
    end

    attribute :diagnostics, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :playbook, ServiceRadar.Automation.Ansible.Playbook do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :playbook_id
    end

    belongs_to :controller, ServiceRadar.Automation.Ansible.Controller do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :controller_id
    end

    belongs_to :schedule, ServiceRadar.Automation.Ansible.PlaybookSchedule do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :schedule_id
    end

    has_many :targets, ServiceRadar.Automation.Ansible.PlaybookRunTarget do
      destination_attribute :run_id
    end

    has_many :plays, ServiceRadar.Automation.Ansible.PlaybookPlay do
      destination_attribute :run_id
    end
  end
end
