defmodule ServiceRadar.NetworkDiscovery.MapperJob do
  @moduledoc """
  Mapper-based discovery job configuration.

  Each job defines scheduling and seed targets for mapper discovery runs
  executed by agents.
  """

  use Ash.Resource,
    domain: ServiceRadar.NetworkDiscovery,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.NetworkDiscovery.Validations.AgentAssignment
  alias ServiceRadar.NetworkDiscovery.Validations.SNMPCredential

  postgres do
    table "mapper_jobs"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:partition], name: "mapper_jobs_partition_idx"
      index [:agent_id], where: "agent_id IS NOT NULL", name: "mapper_jobs_agent_idx"

      index [:snmp_credential_secret_id],
        where: "snmp_credential_secret_id IS NOT NULL",
        name: "mapper_jobs_snmp_credential_secret_idx"
    end

    references do
      reference :snmp_credential_secret, on_delete: :restrict
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :description,
        :enabled,
        :interval,
        :partition,
        :agent_id,
        :discovery_mode,
        :discovery_type,
        :concurrency,
        :timeout,
        :retries,
        :options,
        :snmp_credential_secret_id
      ]

      validate AgentAssignment
      validate SNMPCredential
    end

    update :update do
      accept [
        :name,
        :description,
        :enabled,
        :interval,
        :partition,
        :agent_id,
        :discovery_mode,
        :discovery_type,
        :concurrency,
        :timeout,
        :retries,
        :options,
        :snmp_credential_secret_id
      ]

      validate AgentAssignment
      validate SNMPCredential
    end

    update :complete_snmp_credential_backfill do
      description "Backfill only: bind the pre-upgrade fallback credential, if any, and clear the mark"
      accept [:snmp_credential_secret_id]
      change set_attribute(:snmp_credential_backfill_pending, false)
      validate SNMPCredential
    end

    update :record_run do
      accept [:last_run_at, :last_run_status, :last_run_interface_count, :last_run_error]
    end

    update :run_now do
      accept []
      require_atomic? false
      change ServiceRadar.NetworkDiscovery.Changes.TriggerMapperRun
    end

    read :enabled_by_partition do
      argument :partition, :string, allow_nil?: false
      filter expr(enabled == true and partition == ^arg(:partition))
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false
      filter expr(enabled == true and (agent_id == ^arg(:agent_id) or is_nil(agent_id)))
    end

    read :for_agent_partition do
      argument :agent_id, :string, allow_nil?: true
      argument :partition, :string, allow_nil?: false

      filter expr(
               enabled == true and
                 partition == ^arg(:partition) and
                 (is_nil(^arg(:agent_id)) or agent_id == ^arg(:agent_id) or is_nil(agent_id))
             )
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    operator_action_type([:create, :update])

    policy action(:complete_snmp_credential_backfill) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    admin_action_type(:destroy)
    read_all()
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Discovery job name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Description of the discovery job"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
      description "Whether this job is active"
    end

    attribute :interval, :string do
      allow_nil? false
      public? true
      default "2h"
      description "Discovery interval (e.g., '15m', '2h')"
    end

    attribute :partition, :string do
      allow_nil? false
      public? true
      default "default"
      description "Partition for this job"
    end

    attribute :agent_id, :string do
      allow_nil? true
      public? true
      description "Specific agent ID (nil = any agent in partition)"
    end

    attribute :discovery_mode, :atom do
      allow_nil? false
      public? true
      default :snmp_api
      constraints one_of: [:snmp, :api, :snmp_api]
      description "Discovery mode (SNMP, API, or both)"
    end

    attribute :discovery_type, :atom do
      allow_nil? false
      public? true
      default :full
      constraints one_of: [:full, :basic, :interfaces, :topology]
      description "Discovery type (full/basic/interfaces/topology)"
    end

    attribute :concurrency, :integer do
      allow_nil? false
      public? true
      default 10
      description "Maximum concurrent discovery operations"
    end

    attribute :timeout, :string do
      allow_nil? false
      public? true
      default "45s"
      description "Timeout per discovery target"
    end

    attribute :retries, :integer do
      allow_nil? false
      public? true
      default 2
      description "Retries per discovery target"
    end

    attribute :options, :map do
      allow_nil? false
      public? true
      default %{}
      description "Additional discovery options"
    end

    # The credential the mapper uses for every address that has no per-device
    # credential: seeds and neighbours the inventory does not know yet. Nil on an
    # SNMP-mode job means those addresses are not probed with SNMP; the job is
    # shown as missing its SNMP credential.
    attribute :snmp_credential_secret_id, :uuid do
      allow_nil? true
      public? true
      description "Reusable SNMP credential used for addresses without a per-device credential"
    end

    # Set on jobs that existed before the job carried its own SNMP credential,
    # until MapperJobSNMPCredentialBackfillWorker has visited them. No action
    # accepts it; only the backfill's own action clears it.
    attribute :snmp_credential_backfill_pending, :boolean do
      allow_nil? false
      public? false
      default false
    end

    attribute :last_run_at, :utc_datetime do
      allow_nil? true
      public? true
      description "Last execution timestamp for this job"
    end

    attribute :last_run_status, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:success, :error]
      description "Last execution status for this job"
    end

    attribute :last_run_interface_count, :integer do
      allow_nil? true
      public? true
      description "Interface count from the most recent run"
    end

    attribute :last_run_error, :string do
      allow_nil? true
      public? true
      description "Error summary from the most recent run"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :snmp_credential_secret, ServiceRadar.Credentials.NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :snmp_credential_secret_id
      destination_attribute :id
    end

    has_many :seeds, ServiceRadar.NetworkDiscovery.MapperSeed do
      destination_attribute :mapper_job_id
    end

    has_many :unifi_controllers, ServiceRadar.NetworkDiscovery.MapperUnifiController do
      destination_attribute :mapper_job_id
    end

    has_many :mikrotik_controllers, ServiceRadar.NetworkDiscovery.MapperMikrotikController do
      destination_attribute :mapper_job_id
    end
  end

  calculations do
    # The one definition of "this job has no SNMP fallback credential", shared by
    # the discovery list badge and the job form warning.
    calculate :snmp_credential_missing,
              :boolean,
              expr(discovery_mode in [:snmp, :snmp_api] and is_nil(snmp_credential_secret_id)) do
      public? true
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
