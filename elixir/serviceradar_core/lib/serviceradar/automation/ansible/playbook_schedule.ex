defmodule ServiceRadar.Automation.Ansible.PlaybookSchedule do
  @moduledoc """
  A recurring schedule that fires `PlaybookRun`s at a cron cadence.

  ScheduleEvaluatorWorker (AshOban) reads enabled rows, evaluates their cron
  expressions against `last_evaluated_at` / `next_run_at`, and creates a new
  `PlaybookRun` per fire. When the previous run is still non-terminal and
  `allow_concurrent = false`, the worker records `skipped_overlap` on the
  schedule's audit trail and skips the fire.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.schedules.view"}
  @manage_check {ActorHasPermission, permission: "ansible.schedules.manage"}

  postgres do
    table "ansible_playbook_schedules"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :playbook, on_delete: :restrict
      reference :last_run, on_delete: :nilify
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "ansible_playbook_schedule_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at, :last_evaluated_at, :next_run_at, :last_run_id]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_due, action: :due
    define :create_schedule, action: :create
    define :update_schedule, action: :update
    define :destroy_schedule, action: :destroy
    define :enable, action: :enable
    define :disable, action: :disable
    define :record_evaluation, action: :record_evaluation
  end

  actions do
    defaults [:destroy]

    read :read do
      # Primary read so this resource loads via its inbound relationships /
      # default read (e.g. `PlaybookRun.schedule`). See PlaybookRun.
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :due do
      description "Enabled schedules whose next_run_at has passed"
      filter expr(enabled == true and not is_nil(next_run_at) and next_run_at <= now())
    end

    create :create do
      accept [
        :name,
        :description,
        :enabled,
        :playbook_id,
        :target_device_uids,
        :cron,
        :timezone,
        :allow_concurrent,
        :owner_id,
        :metadata
      ]

      change set_attribute(:enabled, false)
    end

    update :update do
      accept [
        :name,
        :description,
        :playbook_id,
        :target_device_uids,
        :cron,
        :timezone,
        :allow_concurrent,
        :metadata
      ]
    end

    update :enable do
      require_atomic? false

      validate fn _changeset, _context ->
        {:error,
         field: :enabled,
         message: "requires a hardened immutable execution delegation and reapproval"}
      end
    end

    update :disable do
      change set_attribute(:enabled, false)
    end

    update :record_evaluation do
      description "ScheduleEvaluatorWorker records the outcome of a fire (or skip)"
      accept [:last_run_id, :next_run_at, :last_evaluation_outcome]
      change set_attribute(:last_evaluated_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :due], @view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
    action_with_permission([:enable, :disable], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :playbook_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :target_device_uids, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "OCSF device uids to target; resolves to PlaybookRunTargets at fire time"
    end

    attribute :requested_extra_vars, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :cron, :string do
      allow_nil? false
      public? true
      description "Standard 5-field cron expression"
    end

    attribute :timezone, :string do
      allow_nil? false
      public? true
      default "UTC"
      description "IANA timezone name, e.g. Europe/London"
    end

    attribute :allow_concurrent, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :owner_id, :uuid do
      allow_nil? true
      public? true
      description "Actor who created the schedule (for audit / display)"
    end

    attribute :last_evaluated_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_run_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :next_run_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_evaluation_outcome, :atom do
      allow_nil? true
      public? true

      constraints one_of: [
                    :fired,
                    :skipped_overlap,
                    :skipped_disabled,
                    :skipped_ineligible_targets,
                    :error
                  ]
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

    belongs_to :last_run, PlaybookRun do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :last_run_id
    end

    has_many :runs, PlaybookRun do
      destination_attribute :schedule_id
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
