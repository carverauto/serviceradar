defmodule ServiceRadar.NetworkDiscovery.MapperUnifiController do
  @moduledoc """
  Ubiquiti UniFi controller configuration for mapper discovery jobs.
  """

  use Ash.Resource,
    domain: ServiceRadar.NetworkDiscovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "mapper_unifi_controllers"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:mapper_job_id], name: "mapper_unifi_controllers_job_idx"
    end
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:api_key])
    decrypt_by_default([:api_key])
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :base_url,
        :api_key,
        :insecure_skip_verify,
        :mapper_job_id
      ]
    end

    update :update do
      accept [
        :name,
        :base_url,
        :api_key,
        :insecure_skip_verify
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
      description "Optional controller name"
    end

    attribute :base_url, :string do
      allow_nil? false
      public? true
      description "UniFi controller base URL"
    end

    attribute :api_key, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "UniFi API key"
    end

    attribute :insecure_skip_verify, :boolean do
      allow_nil? false
      public? true
      default false
      description "Skip TLS verification for UniFi API"
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
    calculate :api_key_present, :boolean, fn records, _opts ->
      Enum.map(records, fn record ->
        # Access the raw struct field - AshCloak stores ciphertext
        has_value?(Map.get(record, :api_key))
      end)
    end
  end

  identities do
    identity :unique_base_url_per_job, [:mapper_job_id, :base_url]
  end

  # Check if an encrypted field has a value (ciphertext is a binary)
  defp has_value?(nil), do: false
  defp has_value?(""), do: false
  defp has_value?(value) when is_binary(value), do: byte_size(value) > 0
  defp has_value?(_), do: false
end
