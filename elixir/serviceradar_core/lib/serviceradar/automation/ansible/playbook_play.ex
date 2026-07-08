defmodule ServiceRadar.Automation.Ansible.PlaybookPlay do
  @moduledoc """
  A play within a `PlaybookRun` (Ansible's `play` concept). Created by
  RunPulseWorker when a `playbook_on_play_start` event arrives.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  postgres do
    table "ansible_playbook_plays"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :run, on_delete: :delete
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_run, action: :for_run, args: [:run_id]
    define :upsert_play, action: :upsert
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

    read :for_run do
      argument :run_id, :uuid, allow_nil?: false
      filter expr(run_id == ^arg(:run_id))
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_play_uuid

      accept [
        :run_id,
        :awx_play_uuid,
        :name,
        :started_at,
        :metadata
      ]
    end

    update :record_completion do
      accept [:ended_at, :status, :metadata]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :for_run], @view_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :run_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :awx_play_uuid, :string do
      allow_nil? false
      public? true
      description "Ansible play UUID from the AWX events stream"
    end

    attribute :name, :string do
      allow_nil? true
      public? true
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :ended_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :running
      constraints one_of: [:running, :ok, :failed]
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

    has_many :tasks, ServiceRadar.Automation.Ansible.PlaybookTask do
      destination_attribute :play_id
    end
  end

  identities do
    identity :unique_play_uuid, [:run_id, :awx_play_uuid]
  end
end
