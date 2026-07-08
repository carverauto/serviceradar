defmodule ServiceRadar.Automation.Ansible.PlaybookTask do
  @moduledoc """
  A task within a `PlaybookPlay` (Ansible's `task` concept). Created by
  RunPulseWorker when a `playbook_on_task_start` event arrives. Per-host
  outcomes live on `PlaybookTaskResult`, keyed to a `PlaybookRunTarget`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  postgres do
    table "ansible_playbook_tasks"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :play, on_delete: :delete
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_play, action: :for_play, args: [:play_id]
    define :upsert_task, action: :upsert
    define :record_completion, action: :record_completion
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

    read :for_play do
      argument :play_id, :uuid, allow_nil?: false
      filter expr(play_id == ^arg(:play_id))
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_task_uuid

      accept [
        :play_id,
        :awx_task_uuid,
        :name,
        :action,
        :is_handler,
        :path,
        :line_number,
        :tags,
        :started_at,
        :metadata
      ]
    end

    update :record_completion do
      accept [:ended_at, :metadata]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :for_play], @view_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :play_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :awx_task_uuid, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? true
      public? true
    end

    attribute :action, :string do
      allow_nil? true
      public? true
      description "Ansible module name, e.g. `ansible.builtin.command`"
    end

    attribute :is_handler, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :path, :string do
      allow_nil? true
      public? true
      description "Source file path reported by AWX"
    end

    attribute :line_number, :integer do
      allow_nil? true
      public? true
    end

    attribute :tags, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

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
    belongs_to :play, ServiceRadar.Automation.Ansible.PlaybookPlay do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :play_id
    end

    has_many :results, ServiceRadar.Automation.Ansible.PlaybookTaskResult do
      destination_attribute :task_id
    end
  end

  identities do
    identity :unique_task_uuid, [:play_id, :awx_task_uuid]
  end
end
