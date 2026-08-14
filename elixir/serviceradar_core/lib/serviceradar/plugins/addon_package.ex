defmodule ServiceRadar.Plugins.AddonPackage do
  @moduledoc """
  Native agent add-on (feature set) package metadata and import review state.

  Each record represents a specific add-on version (addon_id + version) for the
  issue 3425 native add-on framework. Add-ons are delivered to agents as
  go-plugin subprocesses; packages are staged on import and require explicit
  approval before they can be assigned to agents. Unlike Wasm plugins, an add-on
  is a free-standing identifier (no separate root resource) and may ship
  per-architecture native artifacts.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  import Ash.Expr

  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.Plugins.ProducerScheduleCatalog
  alias ServiceRadar.Plugins.Validations.DisplayContracts

  @package_fields [
    :name,
    :description,
    :kind,
    :delivery,
    :supervision,
    :binary,
    :install_path,
    :capabilities,
    :config_schema,
    :display_contracts,
    :signal_schemas,
    :producer_schedules,
    :artifacts,
    :requires,
    :source_type,
    :source_oci_ref,
    :source_oci_digest,
    :source_release_tag,
    :source_metadata,
    :imported_at,
    :verification_status,
    :verification_error,
    :resources
  ]

  @package_create_fields [:addon_id, :version | @package_fields]
  @approval_fields [:approved_capabilities, :approved_by]
  @denial_fields [:denied_reason]

  postgres do
    table "addon_packages"
    repo ServiceRadar.Repo
    schema "platform"
  end

  state_machine do
    initial_states [:staged]
    default_initial_state :staged
    state_attribute :status

    transitions do
      transition :approve, from: :staged, to: :approved
      transition :deny, from: :staged, to: :denied
      transition :revoke, from: [:approved], to: :revoked
      transition :restage, from: [:denied, :revoked], to: :staged
      transition :reimport, from: [:staged, :approved, :denied, :revoked], to: :staged
    end
  end

  actions do
    defaults [:read, :destroy]

    read :by_addon_id do
      argument :addon_id, :string, allow_nil?: false
      filter expr(addon_id == ^arg(:addon_id))
    end

    read :approved do
      description "Approved add-on packages"
      filter expr(status == :approved)
    end

    create :create do
      accept @package_create_fields
      validate DisplayContracts
      change &sync_producer_schedule_contracts/2
    end

    update :update do
      require_atomic? false
      accept @package_fields
      validate DisplayContracts
      change &sync_producer_schedule_contracts/2
    end

    update :reimport do
      description "Replace a previously reviewed package with newly verified artifacts"
      require_atomic? false
      accept @package_fields

      validate DisplayContracts
      change &guard_original_state/2
      change transition_state(:staged)
      change set_attribute(:approved_capabilities, [])
      change set_attribute(:approved_by, nil)
      change set_attribute(:approved_at, nil)
      change set_attribute(:denied_reason, nil)
      change &sync_producer_schedule_contracts/2
    end

    update :approve do
      description "Approve a staged add-on package for distribution"
      require_atomic? false
      accept @approval_fields

      change &guard_original_state/2
      change transition_state(:approved)
      change set_attribute(:approved_at, &DateTime.utc_now/0)
    end

    update :deny do
      description "Deny a staged add-on package"
      accept @denial_fields

      change transition_state(:denied)
    end

    update :revoke do
      description "Revoke an approved add-on package"
      accept @denial_fields

      change transition_state(:revoked)
    end

    update :restage do
      description "Move a denied or revoked package back to staged"
      accept []

      change transition_state(:staged)
      change set_attribute(:denied_reason, nil)
      change set_attribute(:approved_at, nil)
    end
  end

  policies do
    import ServiceRadar.Plugins.Policies

    manage_action_types()
  end

  attributes do
    uuid_primary_key :id

    attribute :addon_id, :string do
      allow_nil? false
      public? true
      description "Stable add-on identifier from the manifest (addon.yaml id)"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable name"
    end

    attribute :version, :string do
      allow_nil? false
      public? true
      description "Add-on version (semver)"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      default :native
      constraints one_of: [:native]
    end

    attribute :delivery, :atom do
      allow_nil? false
      public? true
      default :pushed_artifact
      constraints one_of: [:compiled_in, :pushed_artifact, :os_package]
    end

    attribute :supervision, :atom do
      allow_nil? false
      public? true
      default :agent_sidecar

      constraints one_of: [
                    :config_toggle,
                    :agent_sidecar,
                    :systemd_service,
                    :systemd_timer,
                    :ephemeral_helper
                  ]
    end

    attribute :binary, :string do
      allow_nil? true
      public? true
      description "Add-on plugin binary name (manifest exec.binary)"
    end

    attribute :install_path, :string do
      allow_nil? false
      public? true
      default "/usr/local/lib/serviceradar/bin"
      description "Directory the add-on binary is installed/staged to on the agent host"
    end

    attribute :capabilities, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "Capability identifiers the add-on advertises when active"
    end

    attribute :config_schema, :map do
      allow_nil? false
      public? true
      default %{}
      description "JSON Schema (config.schema.json) for the add-on configuration"
    end

    attribute :display_contracts, :map do
      allow_nil? false
      public? true
      default %{}

      description """
      Package-shipped display contract documents, keyed by "<contract_id>@<contract_version>". \
      Read at RUNTIME by the UI, which is what lets a third-party add-on ship a renderable \
      contract without a web-ng recompile. Validated by ServiceRadar.Plugins.DisplayContract \
      on the way in, never trusted on the way out.\
      """
    end

    attribute :signal_schemas, {:array, :map} do
      allow_nil? false
      public? true
      default []
      description "Package-owned log/event signal schemas and display contract references"
    end

    attribute :producer_schedules, {:array, :map} do
      allow_nil? false
      public? true
      default []

      description "Package-owned recurring producer schedule contracts"
    end

    attribute :artifacts, :map do
      allow_nil? false
      public? true
      default %{}

      description "Per-architecture signed artifacts keyed by os/arch -> object key, sha256, signature"
    end

    attribute :requires, :map do
      allow_nil? false
      public? true
      default %{}

      description "Manifest requirements: base_agent floor, platforms, agent_capabilities, os_capabilities, run_as"
    end

    attribute :resources, :map do
      allow_nil? false
      public? true
      default %{}

      description "Manifest resource limits: cpu_max_percent, memory_max_bytes, memory_high_bytes, tasks_max, slice"
    end

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      default :first_party
      constraints one_of: [:upload, :github, :first_party]
    end

    attribute :source_oci_ref, :string do
      allow_nil? true
      public? true
    end

    attribute :source_oci_digest, :string do
      allow_nil? true
      public? true
    end

    attribute :source_release_tag, :string do
      allow_nil? true
      public? true
    end

    attribute :source_metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :imported_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :verification_status, :string do
      allow_nil? true
      public? true
    end

    attribute :verification_error, :string do
      allow_nil? true
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :staged
      constraints one_of: [:staged, :approved, :denied, :revoked]
    end

    attribute :approved_capabilities, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :approved_by, :string do
      allow_nil? true
      public? true
    end

    attribute :approved_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :denied_reason, :string do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :assignments, ServiceRadar.Plugins.AddonAssignment do
      destination_attribute :addon_package_id
    end
  end

  identities do
    identity :unique_addon_version, [:addon_id, :version]
  end

  defp guard_original_state(changeset, _context) do
    original_updated_at = changeset.data.updated_at
    original_status = changeset.data.status
    original_artifacts = changeset.data.artifacts

    Ash.Changeset.filter(
      changeset,
      expr(
        updated_at == ^original_updated_at and status == ^original_status and
          artifacts == ^original_artifacts
      )
    )
  end

  defp sync_producer_schedule_contracts(changeset, _context) do
    AfterAction.after_action_result(changeset, &ProducerScheduleCatalog.sync_package/1)
  end
end
