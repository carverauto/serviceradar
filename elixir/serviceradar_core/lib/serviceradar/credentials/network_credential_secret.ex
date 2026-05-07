defmodule ServiceRadar.Credentials.NetworkCredentialSecret do
  @moduledoc """
  Encrypted reusable credential material for network integrations.

  Public reads expose metadata such as provider, kind, username, and
  fingerprint. The `secret_payload` plaintext attribute is encrypted by
  AshCloak into `encrypted_secret_payload` and is never public.
  """

  use Ash.Resource,
    domain: ServiceRadar.Credentials,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @credential_manage_check {ActorHasPermission, permission: "settings.credentials.manage"}

  @fields [
    :name,
    :description,
    :provider,
    :credential_kind,
    :username,
    :public_fingerprint,
    :metadata
  ]

  postgres do
    table "network_credential_secrets"
    repo ServiceRadar.Repo
    schema "platform"
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:secret_payload])
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "network_credential_secret_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at, :secret_payload]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_provider, action: :by_provider, args: [:provider]
    define :create_secret, action: :create
    define :update_secret, action: :update
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_provider do
      argument :provider, :string, allow_nil?: false
      filter expr(provider == ^arg(:provider))
    end

    create :create do
      accept [:secret_payload | @fields]
    end

    update :update do
      accept [:secret_payload | @fields]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@credential_manage_check)
    action_type_with_permission([:create, :update], @credential_manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Operator-facing credential name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :provider, :string do
      allow_nil? false
      public? true
      description "Integration provider, for example proxmox"
    end

    attribute :credential_kind, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :api_token,
                    :username_password,
                    :ssh_private_key,
                    :certificate,
                    :opaque
                  ]
    end

    attribute :username, :string do
      allow_nil? true
      public? true
      description "Optional non-secret username or API token ID"
    end

    attribute :public_fingerprint, :string do
      allow_nil? true
      public? true
      description "Optional public key, certificate, or token fingerprint"
    end

    attribute :secret_payload, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "Credential payload encrypted at rest by AshCloak"
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  calculations do
    calculate :secret_payload_present, :boolean, fn records, _opts ->
      Enum.map(records, fn record ->
        case Map.get(record, :encrypted_secret_payload) do
          value when is_binary(value) -> byte_size(value) > 0
          _ -> false
        end
      end)
    end
  end

  identities do
    identity :unique_provider_name, [:provider, :name]
  end
end
