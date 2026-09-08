defmodule ServiceRadar.Automation.Ansible.PlaybookRunTarget do
  @moduledoc """
  Per-device target for a `PlaybookRun`.

  A run with N selected devices has N targets. Each target carries the AWX
  host id / name (so we can attribute incoming job_events to the right
  ServiceRadar device) and per-host outcome counters drawn from AWX's
  per-host stats. `device_uid` is the OCSF inventory uid (e.g. `sr:abc`).
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  postgres do
    table "ansible_playbook_run_targets"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :run, on_delete: :delete
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_run_host, action: :by_run_host, args: [:run_id, :awx_host_name]
    define :list_for_run, action: :for_run, args: [:run_id]
    define :list_for_device, action: :for_device, args: [:device_uid]
    define :create_target, action: :create
    define :record_outcome, action: :record_outcome
  end

  actions do
    defaults [:destroy]

    read :read do
      # Primary read so this resource loads via its inbound relationships /
      # default read (the run hierarchy the UI traverses). See PlaybookRun.
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_run do
      argument :run_id, :uuid, allow_nil?: false
      filter expr(run_id == ^arg(:run_id))
    end

    read :for_device do
      description "Newest-first run targets for one device — drives the device-detail Ansible panel"
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [inserted_at: :desc], limit: 50, load: [run: [:playbook]])
    end

    read :by_run_host do
      description "Resolve a target from (run_id, awx_host_name) — used by EventIngestor"
      argument :run_id, :uuid, allow_nil?: false
      argument :awx_host_name, :string, allow_nil?: false
      get? true
      filter expr(run_id == ^arg(:run_id) and awx_host_name == ^arg(:awx_host_name))
    end

    create :create do
      accept [
        :run_id,
        :device_uid,
        :awx_host_id,
        :awx_host_name,
        :metadata
      ]
    end

    update :record_outcome do
      # Not atomically expressible (no primary read for atomic upgrade) — the
      # runtime otherwise raises MustBeAtomic and the stats handler crashes.
      require_atomic? false
      description "Apply per-host stats from AWX `playbook_on_stats` event"

      accept [
        :status,
        :changed_count,
        :failed_count,
        :ok_count,
        :skipped_count,
        :unreachable_count,
        :started_at,
        :ended_at
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :for_run, :for_device], @view_check)
    # Mutations are system-only (driven by RunPulseWorker).
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :run_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :device_uid, :string do
      allow_nil? false
      public? true
      description "OCSF device uid (e.g. sr:abc)"
    end

    attribute :awx_host_id, :integer do
      allow_nil? true
      public? true
    end

    attribute :awx_host_name, :string do
      allow_nil? false
      public? true
      description "AWX host name; AWX events use this string to attribute results"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :ok, :failed, :unreachable, :skipped]
    end

    attribute :changed_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :failed_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :ok_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :skipped_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :unreachable_count, :integer, allow_nil?: false, default: 0, public?: true

    attribute :started_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :ended_at, :utc_datetime_usec do
      allow_nil? true
      public? true
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
    belongs_to :run, ServiceRadar.Automation.Ansible.PlaybookRun do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :run_id
    end

    has_many :task_results, ServiceRadar.Automation.Ansible.PlaybookTaskResult do
      destination_attribute :run_target_id
    end
  end

  identities do
    identity :unique_run_host, [:run_id, :awx_host_name]
  end
end
