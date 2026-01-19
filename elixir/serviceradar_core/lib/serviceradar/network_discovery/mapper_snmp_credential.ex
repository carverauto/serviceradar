defmodule ServiceRadar.NetworkDiscovery.MapperSNMPCredential do
  @moduledoc """
  SNMP credentials for mapper discovery jobs.
  """

  use Ash.Resource,
    domain: ServiceRadar.NetworkDiscovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak],
    notifiers: [ServiceRadar.NetworkDiscovery.MapperConfigNotifier]

  postgres do
    table "mapper_snmp_credentials"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:mapper_job_id], name: "mapper_snmp_credentials_job_idx"
    end
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:community, :auth_password, :privacy_password])
    decrypt_by_default([:community, :auth_password, :privacy_password])
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :version,
        :community,
        :username,
        :auth_protocol,
        :auth_password,
        :privacy_protocol,
        :privacy_password,
        :mapper_job_id
      ]
    end

    update :update do
      accept [
        :name,
        :version,
        :community,
        :username,
        :auth_protocol,
        :auth_password,
        :privacy_protocol,
        :privacy_password
      ]
    end

    read :by_job do
      argument :mapper_job_id, :uuid, allow_nil?: false
      filter expr(mapper_job_id == ^arg(:mapper_job_id))
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? true
      public? true
      description "Credential name"
    end

    attribute :version, :atom do
      allow_nil? false
      public? true
      default :v2c
      constraints one_of: [:v1, :v2c, :v3]
      description "SNMP protocol version"
    end

    attribute :community, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "SNMP community (v1/v2c)"
    end

    attribute :username, :string do
      allow_nil? true
      public? true
      description "SNMPv3 username"
    end

    attribute :auth_protocol, :string do
      allow_nil? true
      public? true
      description "SNMPv3 auth protocol (MD5/SHA)"
    end

    attribute :auth_password, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "SNMPv3 auth password"
    end

    attribute :privacy_protocol, :string do
      allow_nil? true
      public? true
      description "SNMPv3 privacy protocol (DES/AES)"
    end

    attribute :privacy_password, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "SNMPv3 privacy password"
    end

    attribute :mapper_job_id, :uuid do
      allow_nil? false
      public? true
      description "Parent mapper job ID"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :mapper_job, ServiceRadar.NetworkDiscovery.MapperJob do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :mapper_job_id
      destination_attribute :id
    end
  end

  calculations do
    calculate :secrets_present, :map, fn records, _opts ->
      Enum.map(records, fn record ->
        %{
          "community" => present?(record.community),
          "auth_password" => present?(record.auth_password),
          "privacy_password" => present?(record.privacy_password)
        }
      end)
    end
  end

  identities do
    identity :unique_job_credential, [:mapper_job_id]
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
