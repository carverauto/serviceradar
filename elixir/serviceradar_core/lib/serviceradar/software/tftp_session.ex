defmodule ServiceRadar.Software.TftpSession do
  @moduledoc """
  A TFTP session tracks a single file transfer between an agent and a network device.

  Two modes:
  - **Receive**: Agent runs TFTP server, device writes file to agent (e.g. config backup)
    States: configuring → queued → waiting → receiving → completed → storing → stored / failed
  - **Serve**: Agent runs TFTP server, device reads file from agent (e.g. firmware upgrade)
    States: configuring → queued → staging → ready → serving → completed / failed

  Common transitions: any active state → expired / canceled
  """

  use Ash.Resource,
    domain: ServiceRadar.Software,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshOban]

  postgres do
    table "tftp_sessions"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :image, on_delete: :nilify
    end
  end

  state_machine do
    initial_states [:configuring]
    default_initial_state :configuring
    state_attribute :status

    transitions do
      # Common initial transition
      transition :queue, from: :configuring, to: :queued

      # Receive mode transitions
      transition :start_waiting, from: :queued, to: :waiting
      transition :start_receiving, from: :waiting, to: :receiving
      transition :complete_receive, from: :receiving, to: :completed
      transition :start_storing, from: :completed, to: :storing
      transition :finish_store, from: :storing, to: :stored

      # Serve mode transitions
      transition :start_staging, from: :queued, to: :staging
      transition :mark_ready, from: :staging, to: :ready
      transition :start_serving, from: :ready, to: :serving
      transition :complete_serve, from: :serving, to: :completed

      # Failure from any active state
      transition :fail,
        from: [
          :configuring,
          :queued,
          :waiting,
          :receiving,
          :staging,
          :ready,
          :serving,
          :storing
        ],
        to: :failed

      # Expiration from any active state
      transition :expire,
        from: [:queued, :waiting, :receiving, :staging, :ready, :serving],
        to: :expired

      # Cancellation from any active state
      transition :cancel,
        from: [
          :configuring,
          :queued,
          :waiting,
          :receiving,
          :staging,
          :ready,
          :serving
        ],
        to: :canceled
    end
  end

  oban do
    triggers do
      trigger :expire_sessions do
        queue :software
        extra_args &ServiceRadar.Oban.AshObanQueueResolver.job_meta/1
        read_action :needs_expiration
        scheduler_cron "* * * * *"
        action :expire

        scheduler_module_name ServiceRadar.Software.TftpSession.ExpireSessionsScheduler
        worker_module_name ServiceRadar.Software.TftpSession.ExpireSessionsWorker
      end

      trigger :store_received_files do
        queue :software
        extra_args &ServiceRadar.Oban.AshObanQueueResolver.job_meta/1
        read_action :needs_storing
        scheduler_cron "* * * * *"
        action :start_storing

        scheduler_module_name ServiceRadar.Software.TftpSession.StoreReceivedFilesScheduler
        worker_module_name ServiceRadar.Software.TftpSession.StoreReceivedFilesWorker
      end

      trigger :stage_images do
        queue :software
        extra_args &ServiceRadar.Oban.AshObanQueueResolver.job_meta/1
        read_action :needs_staging
        scheduler_cron "* * * * *"
        action :start_staging

        scheduler_module_name ServiceRadar.Software.TftpSession.StageImagesScheduler
        worker_module_name ServiceRadar.Software.TftpSession.StageImagesWorker
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :mode,
        :agent_id,
        :expected_filename,
        :storage_destination,
        :timeout_seconds,
        :image_id,
        :notes,
        :bind_address,
        :port,
        :max_file_size
      ]

      change set_attribute(:status, :configuring)
    end

    create :create_and_queue do
      accept [
        :mode,
        :agent_id,
        :expected_filename,
        :storage_destination,
        :timeout_seconds,
        :image_id,
        :notes,
        :bind_address,
        :port,
        :max_file_size
      ]

      description "Create and immediately queue a TFTP session for agent dispatch"
      change set_attribute(:status, :configuring)
      change ServiceRadar.Software.Changes.QueueTftpSession
    end

    read :list do
      description "List TFTP sessions"

      pagination do
        default_limit 25
        offset? true
        countable :by_default
      end
    end

    read :active do
      description "List active (non-terminal) sessions"

      filter expr(
               status in [
                 :configuring,
                 :queued,
                 :waiting,
                 :receiving,
                 :staging,
                 :ready,
                 :serving,
                 :storing
               ]
             )
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false
      filter expr(agent_id == ^arg(:agent_id))
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :needs_expiration do
      description "Active sessions that may have exceeded their timeout"

      pagination do
        keyset? true
      end

      # Select all active sessions older than 1 minute. The expire action's
      # change hook checks the per-session timeout_seconds before transitioning.
      filter expr(
               status in [:queued, :waiting, :receiving, :staging, :ready, :serving] and
                 updated_at < ago(1, :minute)
             )
    end

    read :needs_storing do
      description "Completed receive sessions that need files uploaded to storage"

      pagination do
        keyset? true
      end

      filter expr(status == :completed and mode == :receive)
    end

    read :needs_staging do
      description "Queued serve sessions that need images staged to agents"

      pagination do
        keyset? true
      end

      filter expr(status == :queued and mode == :serve)
    end

    # State transitions
    update :queue do
      accept []
      require_atomic? false
      description "Queue the session for dispatch to the agent"
      change ServiceRadar.Software.Changes.DispatchTftpStart
    end

    update :start_waiting do
      accept []
      description "Agent is listening for TFTP connections (receive mode)"
    end

    update :start_receiving do
      accept []
      description "TFTP transfer in progress (receive mode)"
    end

    update :complete_receive do
      accept [:file_size, :content_hash]
      description "File received successfully"
    end

    update :start_storing do
      accept []
      description "Uploading received file to storage"
    end

    update :finish_store do
      accept [:object_key]
      description "File stored successfully"
    end

    update :start_staging do
      accept []
      require_atomic? false
      description "Downloading image to agent staging area (serve mode)"
      change ServiceRadar.Software.Changes.DispatchTftpStage
    end

    update :mark_ready do
      accept []
      description "Image staged on agent, ready to serve"
    end

    update :start_serving do
      accept []
      description "TFTP transfer in progress (serve mode)"
    end

    update :complete_serve do
      accept [:file_size]
      description "File served successfully"
    end

    update :fail do
      accept [:error_message]
      description "Session failed"
    end

    update :expire do
      accept []
      require_atomic? false
      description "Session expired due to timeout"
      change ServiceRadar.Software.Changes.CheckSessionTimeout
    end

    update :cancel do
      accept []
      require_atomic? false
      description "Session canceled by user"
      change ServiceRadar.Software.Changes.DispatchTftpStop
    end

    update :update_progress do
      accept [:bytes_transferred, :transfer_rate]
      require_atomic? false
      description "Update transfer progress"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:receive, :serve]
      description "Session mode: receive (device→agent) or serve (agent→device)"
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
      description "Agent that will run the TFTP server"
    end

    attribute :expected_filename, :string do
      allow_nil? false
      public? true
      description "Filename the TFTP server will accept/serve"
    end

    attribute :storage_destination, :string do
      allow_nil? true
      public? true
      description "Where to store the received file (receive mode)"
    end

    attribute :timeout_seconds, :integer do
      allow_nil? false
      default 300
      public? true
      description "Session timeout in seconds"
      constraints min: 10, max: 3600
    end

    attribute :notes, :string do
      allow_nil? true
      public? true
    end

    attribute :bind_address, :string do
      allow_nil? true
      public? true
      description "Address the TFTP server should bind to"
    end

    attribute :port, :integer do
      allow_nil? true
      public? true
      default 69
      description "UDP port for the TFTP server"
      constraints min: 1, max: 65535
    end

    attribute :max_file_size, :integer do
      allow_nil? true
      public? true
      description "Maximum allowed file size in bytes"
      constraints min: 1, max: 104_857_600
    end

    # Transfer results
    attribute :file_size, :integer do
      allow_nil? true
      public? true
      description "Actual transferred file size in bytes"
    end

    attribute :content_hash, :string do
      allow_nil? true
      public? true
      description "SHA-256 hash of the transferred file"
    end

    attribute :object_key, :string do
      allow_nil? true
      public? true
      description "Storage object key for the received file"
    end

    attribute :bytes_transferred, :integer do
      allow_nil? true
      public? true
      default 0
      description "Current transfer progress in bytes"
    end

    attribute :transfer_rate, :integer do
      allow_nil? true
      public? true
      description "Current transfer rate in bytes/second"
    end

    attribute :error_message, :string do
      allow_nil? true
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :configuring
      public? true

      constraints one_of: [
                    :configuring,
                    :queued,
                    :waiting,
                    :receiving,
                    :completed,
                    :storing,
                    :stored,
                    :staging,
                    :ready,
                    :serving,
                    :failed,
                    :expired,
                    :canceled
                  ]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :image, ServiceRadar.Software.SoftwareImage do
      allow_nil? true
      public? true
      description "Software image being served (serve mode only)"
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # AshOban schedulers run without an actor
    bypass action([
      :expire, :start_storing, :start_staging,
      :start_waiting, :start_receiving, :complete_receive,
      :finish_store, :mark_ready, :start_serving, :complete_serve,
      :fail, :update_progress,
      :needs_expiration, :needs_storing, :needs_staging
    ]) do
      authorize_if ServiceRadar.Policies.Checks.ActorIsNil
    end

    policy action_type(:read) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.view"}
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end

    policy action(:create) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "tftp.session.create"}
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end

    policy action(:create_and_queue) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "tftp.session.create"}
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end

    policy action(:queue) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "tftp.session.create"}
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end

    policy action(:cancel) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "tftp.session.cancel"}
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end

    policy action(:destroy) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "tftp.session.cancel"}
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end
  end
end
