defmodule ServiceRadar.Automation.Ansible.PlaybookTaskResult do
  @moduledoc """
  Per-host outcome of a `PlaybookTask`.

  Each result references both its `PlaybookTask` and the `PlaybookRunTarget`
  it was attributed to (so the run-detail UI can render per-device drill-downs
  without joining through the AWX host name string). `awx_event_id` is the
  monotonic AWX event id; we keep it for idempotent upsert and for OCSF event
  projection.

  stdout / stderr blobs live on `PlaybookContent` (sha256-deduped) so repeated
  runs of the same playbook don't store the same output N times.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Automation.Ansible.PlaybookContent
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  postgres do
    table "ansible_playbook_task_results"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :task, on_delete: :delete
      reference :run_target, on_delete: :delete
      reference :stdout_content, on_delete: :nilify
      reference :stderr_content, on_delete: :nilify
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_task, action: :for_task, args: [:task_id]
    define :list_for_run_target, action: :for_run_target, args: [:run_target_id]
    define :upsert_result, action: :upsert
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

    read :for_task do
      argument :task_id, :uuid, allow_nil?: false
      filter expr(task_id == ^arg(:task_id))
    end

    read :for_run_target do
      argument :run_target_id, :uuid, allow_nil?: false
      filter expr(run_target_id == ^arg(:run_target_id))
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_awx_event

      accept [
        :task_id,
        :run_target_id,
        :awx_event_id,
        :status,
        :changed,
        :ignore_errors,
        :delegated_to,
        :stdout_content_id,
        :stderr_content_id,
        :result_payload,
        :event_at
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :for_task, :for_run_target], @view_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :task_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :run_target_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :awx_event_id, :integer do
      allow_nil? false
      public? true
      description "Monotonic AWX event id; primary idempotency key"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ok, :failed, :skipped, :unreachable]
    end

    attribute :changed, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :ignore_errors, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :delegated_to, :string do
      allow_nil? true
      public? true
      description "AWX host name when the task was delegated"
    end

    attribute :stdout_content_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :stderr_content_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :result_payload, :map do
      allow_nil? false
      public? true
      default %{}

      description "Selected fields from the AWX event payload (no full blob — those go to PlaybookContent)"
    end

    attribute :event_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :task, ServiceRadar.Automation.Ansible.PlaybookTask do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :task_id
    end

    belongs_to :run_target, ServiceRadar.Automation.Ansible.PlaybookRunTarget do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :run_target_id
    end

    belongs_to :stdout_content, PlaybookContent do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :stdout_content_id
    end

    belongs_to :stderr_content, PlaybookContent do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :stderr_content_id
    end
  end

  identities do
    identity :unique_awx_event, [:task_id, :run_target_id, :awx_event_id]
  end
end
