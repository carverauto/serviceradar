defmodule ServiceRadar.Automation.Ansible.Controller do
  @moduledoc """
  AWX/AAP controller registration.

  Holds the `base_url`, the `agent_id` of the ServiceRadar agent that can reach
  the controller's network, purpose-specific references to
  `NetworkCredentialSecret` rows holding AWX API tokens, and tunable sync
  intervals. The tokens themselves are held by the credential broker (the same
  mechanism proxmox/unifi use today); this resource carries only secret
  references. Short-lived broker grants are minted at dispatch time and
  embedded in `CommandRequest`s flowing through `AgentCommandBus`.

  AWX credentials are separated by privilege ceiling:

    * `:sync` performs health, catalog, and inventory reads;
    * `:execution` launches, observes, and cancels jobs;
    * `:callback` creates, fetches, and deletes reviewed ephemeral credentials.

  `credential_secret_id` is a deprecated, one-release rolling-upgrade bridge.
  It may supply only the sync credential when an old binary wrote a row after
  the purpose columns were added. The data migration backfills all three
  purpose columns for controllers that existed before the split, preserving
  their pre-upgrade behavior without a runtime cross-purpose fallback.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer],
    # The primary `:read` carries a `prepare build(select: ...)`, which trips
    # Ash's "primary read has preparations" warning (an error under
    # --warnings-as-errors). Both are intentional — same pattern as #4495.
    primary_read_warning?: false

  alias ServiceRadar.Automation.Ansible.Changes.SeedControllerLifecycle
  alias ServiceRadar.Automation.Ansible.Changes.SyncLegacyControllerCredential
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_check {ActorHasPermission, permission: "ansible.controllers.manage"}
  @run_view_check {ActorHasPermission, permission: "ansible.runs.view"}

  @public_fields [
    :name,
    :description,
    :base_url,
    :awx_version,
    :agent_id,
    :enabled,
    :credential_secret_id,
    :sync_credential_secret_id,
    :execution_credential_secret_id,
    :callback_credential_secret_id,
    :inventory_sync_interval_seconds,
    :catalog_sync_interval_seconds,
    :run_pulse_interval_ms,
    :status,
    :last_health_at,
    :last_health_summary,
    :metadata
  ]

  @public_read_fields [:id, :inserted_at, :updated_at | @public_fields]

  postgres do
    table "ansible_controllers"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :credential_secret, on_delete: :restrict
      reference :sync_credential_secret, on_delete: :restrict
      reference :execution_credential_secret, on_delete: :restrict
      reference :callback_credential_secret, on_delete: :restrict
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "ansible_controller_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :retained_versions, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? true
    ignore_attributes [:inserted_at, :updated_at, :last_health_at, :last_health_summary]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_history_by_id, action: :history_by_id, args: [:id]
    define :list_history_by_ids, action: :history_by_ids, args: [:ids]
    define :list_by_agent, action: :by_agent, args: [:agent_id]
    define :create_controller, action: :create
    define :update_controller, action: :update
    define :destroy_controller, action: :destroy
    define :enable_controller, action: :enable
    define :disable_controller, action: :disable
    define :record_health, action: :record_health
  end

  actions do
    destroy :destroy do
      change {SeedControllerLifecycle, mode: :teardown}
    end

    read :read do
      # Primary read so this resource loads via its inbound relationships (e.g.
      # `PlaybookRun.controller` / `Playbook.controller`). See PlaybookRun.
      primary? true
      prepare build(select: @public_read_fields)
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: @public_read_fields)
    end

    read :history_by_id do
      description "Controller label only, for secret-safe run history"
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: [:id, :name])
    end

    read :history_by_ids do
      description "Controller labels only, for secret-safe device history joins"
      argument :ids, {:array, :uuid}, allow_nil?: false
      filter expr(id in ^arg(:ids))
      prepare build(select: [:id, :name])
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false
      filter expr(agent_id == ^arg(:agent_id))
      prepare build(select: @public_read_fields)
    end

    create :create do
      accept [
        :name,
        :description,
        :base_url,
        :awx_version,
        :agent_id,
        :enabled,
        :credential_secret_id,
        :sync_credential_secret_id,
        :execution_credential_secret_id,
        :callback_credential_secret_id,
        :inventory_sync_interval_seconds,
        :catalog_sync_interval_seconds,
        :run_pulse_interval_ms,
        :metadata
      ]

      change SyncLegacyControllerCredential
      change SeedControllerLifecycle
    end

    update :update do
      accept [
        :name,
        :description,
        :base_url,
        :awx_version,
        :agent_id,
        :enabled,
        :credential_secret_id,
        :sync_credential_secret_id,
        :execution_credential_secret_id,
        :callback_credential_secret_id,
        :inventory_sync_interval_seconds,
        :catalog_sync_interval_seconds,
        :run_pulse_interval_ms,
        :metadata
      ]

      change SyncLegacyControllerCredential
      change SeedControllerLifecycle
    end

    update :enable do
      description "Resume a paused controller: re-seed its jobs and inventory-sync assignment"
      accept []
      change set_attribute(:enabled, true)
      change SeedControllerLifecycle
    end

    update :disable do
      description "Pause a controller: retract its inventory-sync assignment and stop its jobs"
      accept []
      change set_attribute(:enabled, false)
      change SeedControllerLifecycle
    end

    update :record_health do
      description "Bus-driven health update from the awx.ping verb result"
      accept [:status, :awx_version, :last_health_summary]
      change set_attribute(:last_health_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :by_agent], @manage_check)
    action_with_permission([:history_by_id, :history_by_ids], @run_view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
    action_with_permission([:record_health], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Operator-facing controller name (unique)"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :base_url, :string do
      allow_nil? false
      public? true
      description "AWX/AAP base URL, e.g. https://awx.internal.example.com"
    end

    attribute :awx_version, :string do
      allow_nil? true
      public? true
      description "AWX version string reported by /api/v2/ping/"
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
      description "ID of the ServiceRadar agent that can reach this controller's network"
    end

    attribute :credential_secret_id, :uuid do
      allow_nil? false
      public? true

      description "Deprecated one-release sync-only compatibility reference; mirrors sync_credential_secret_id on writes"
    end

    attribute :sync_credential_secret_id, :uuid do
      allow_nil? true
      public? true
      description "AWX API token used only for health, catalog, and inventory read operations"
    end

    attribute :execution_credential_secret_id, :uuid do
      allow_nil? true
      public? true

      description "AWX API token used only for job launch, observation, reconciliation, and cancellation"
    end

    attribute :callback_credential_secret_id, :uuid do
      allow_nil? true
      public? true

      description "AWX API token used only for reviewed ephemeral callback credential lifecycle operations; may equal the execution reference"
    end

    attribute :inventory_sync_interval_seconds, :integer do
      allow_nil? false
      public? true
      default 300
      constraints min: 30
      description "Cadence for the awx plugin's inventory_sync scheduled assignment"
    end

    attribute :catalog_sync_interval_seconds, :integer do
      allow_nil? false
      public? true
      default 600
      constraints min: 60
      description "Cadence for AwxCatalogSyncWorker (mirrors AWX Job Templates)"
    end

    attribute :run_pulse_interval_ms, :integer do
      allow_nil? false
      public? true
      default 2000
      constraints min: 250, max: 60_000
      description "Cadence for RunPulseWorker; lower = lower latency, higher AWX API load"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true

      description "When false, the controller is paused: its inventory-sync assignment is retracted and its lifecycle jobs stop; the row is retained."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :unknown
      constraints one_of: [:unknown, :ok, :degraded, :unreachable, :unauthorized]
      description "Last-known health derived from awx.ping responses"
    end

    attribute :last_health_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Wall-clock time of the last successful or failed awx.ping"
    end

    attribute :last_health_summary, :string do
      allow_nil? true
      public? true
      description "Operator-safe summary of the last health-check result"
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
    belongs_to :credential_secret, NetworkCredentialSecret do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :credential_secret_id
      destination_attribute :id
    end

    belongs_to :sync_credential_secret, NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :sync_credential_secret_id
      destination_attribute :id
    end

    belongs_to :execution_credential_secret, NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :execution_credential_secret_id
      destination_attribute :id
    end

    belongs_to :callback_credential_secret, NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :callback_credential_secret_id
      destination_attribute :id
    end
  end

  identities do
    identity :unique_name, [:name]
  end

  @typedoc "Purpose-specific AWX controller credential ceiling."
  @type credential_purpose :: :sync | :execution | :callback

  @doc """
  Returns the credential reference for an exact AWX operation purpose.

  During the one-release rolling-upgrade window only `:sync` may fall back to
  deprecated `credential_secret_id`. Execution and callback operations always
  require their explicit purpose column; this prevents a read-only sync token
  from being silently promoted into a mutating principal.
  """
  @spec credential_secret_id_for(map(), credential_purpose()) ::
          {:ok, String.t()} | {:error, {:controller_credential_missing, credential_purpose()}}
  def credential_secret_id_for(controller, :sync) when is_map(controller) do
    controller
    |> first_present([:sync_credential_secret_id, "sync_credential_secret_id"])
    |> case do
      nil ->
        controller
        |> first_present([:credential_secret_id, "credential_secret_id"])
        |> credential_result(:sync)

      secret_id ->
        {:ok, secret_id}
    end
  end

  def credential_secret_id_for(controller, :execution) when is_map(controller) do
    controller
    |> first_present([:execution_credential_secret_id, "execution_credential_secret_id"])
    |> credential_result(:execution)
  end

  def credential_secret_id_for(controller, :callback) when is_map(controller) do
    controller
    |> first_present([:callback_credential_secret_id, "callback_credential_secret_id"])
    |> credential_result(:callback)
  end

  defp credential_result(nil, purpose), do: {:error, {:controller_credential_missing, purpose}}
  defp credential_result(secret_id, _purpose), do: {:ok, secret_id}

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) -> if(String.trim(value) == "", do: nil, else: value)
        nil -> nil
        value -> to_string(value)
      end
    end)
  end
end
