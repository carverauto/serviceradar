defmodule ServiceRadar.Edge.RemoteAccessDesktopTarget do
  @moduledoc """
  Registered desktop/RDP targets that can be opened through ServiceRadar remote access.

  Target records are trusted operator-managed policy. Browser clients choose a
  target ID, but the upstream host, route, credential mode, redirection policy,
  screen policy, and recording policy are derived from this resource.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Edge.Changes.RedactDesktopTargetPolicy
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @rdp_open_check {ActorHasPermission, permission: "devices.remote_access.rdp.open"}
  @manage_check {ActorHasPermission, permission: "settings.edge.manage"}

  @fields [
    :name,
    :description,
    :enabled,
    :device_uid,
    :target_kind,
    :target_host,
    :target_port,
    :agent_id,
    :gateway_id,
    :credential_custody_mode,
    :credential_rule_id,
    :approval_required,
    :allowed_principals,
    :target_tls,
    :nla,
    :screen_policy,
    :redirection_policy,
    :recording_policy,
    :metadata
  ]

  postgres do
    table "remote_access_desktop_targets"
    repo ServiceRadar.Repo
    schema "platform"
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "remote_access_desktop_target_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? false
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_enabled, action: :enabled
    define :create_target, action: :create
    define :update_target, action: :update
    define :enable_target, action: :enable
    define :disable_target, action: :disable
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :enabled do
      filter expr(enabled == true)
      prepare build(sort: [name: :asc, inserted_at: :asc])
    end

    read :list do
      prepare build(sort: [name: :asc, inserted_at: :asc])
    end

    create :create do
      accept @fields
      change RedactDesktopTargetPolicy
    end

    update :update do
      accept @fields
      change RedactDesktopTargetPolicy
    end

    update :enable do
      change set_attribute(:enabled, true)
    end

    update :disable do
      change set_attribute(:enabled, false)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @rdp_open_check
      authorize_if @manage_check
    end

    action_type_with_permission([:create, :update], @manage_check)
    action_with_permission([:enable, :disable], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :protocol, :atom do
      allow_nil? false
      public? true
      default :rdp
      constraints one_of: [:rdp]
    end

    attribute :target_kind, :atom do
      allow_nil? false
      public? true
      default :inventory_device
      constraints one_of: [:inventory_device, :freeform_target]
    end

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :target_host, :string do
      allow_nil? false
      public? true
    end

    attribute :target_port, :integer do
      allow_nil? false
      public? true
      default 3389
      constraints min: 1, max: 65_535
    end

    attribute :agent_id, :string do
      public? true
    end

    attribute :gateway_id, :string do
      public? true
    end

    attribute :credential_custody_mode, :atom do
      allow_nil? false
      public? true
      default :user_present

      constraints one_of: [
                    :domain_delegation,
                    :smart_card,
                    :certificate,
                    :user_present,
                    :centrally_brokered
                  ]
    end

    attribute :credential_rule_id, :uuid do
      public? true
    end

    attribute :approval_required, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :allowed_principals, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :target_tls, :map do
      allow_nil? false
      public? true
      default %{"mode" => "verify_ca"}
    end

    attribute :nla, :map do
      allow_nil? false
      public? true
      default %{"required" => true}
    end

    attribute :screen_policy, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :redirection_policy, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :recording_policy, :map do
      allow_nil? false
      public? true
      default %{"mode" => "metadata_only"}
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
    belongs_to :credential_rule, ServiceRadar.Credentials.NetworkCredentialRule do
      source_attribute :credential_rule_id
      destination_attribute :id
      define_attribute? false
      public? true
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
