defmodule ServiceRadar.Integrations.OutboundMailSettings do
  @moduledoc """
  Deployment-level outbound mail provider settings.
  """

  use Ash.Resource,
    domain: ServiceRadar.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Integrations.Changes.SetOutboundMailSecrets
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_check {ActorHasPermission, permission: "settings.mail.manage"}
  @fields [
    :enabled,
    :adapter,
    :from_name,
    :from_email,
    :relay,
    :port,
    :hostname,
    :username,
    :password_secret_id,
    :api_key_secret_id,
    :auth,
    :tls,
    :ssl,
    :retries,
    :provider_options
  ]

  @adapters ~w(local test smtp mailgun mandrill sendgrid postmark sparkpost amazon_ses mailjet brevo mailtrap smtp2go)
  @auth_modes ~w(always never if_available)
  @tls_modes ~w(always never if_available)

  postgres do
    table "outbound_mail_settings"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    references do
      reference :password_secret, on_delete: :restrict
      reference :api_key_secret, on_delete: :restrict
    end
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:password, :api_key])
    decrypt_by_default([:password, :api_key])
  end

  code_interface do
    define :get_settings, action: :get_singleton
    define :create, action: :create
    define :update_settings, action: :update
  end

  actions do
    defaults [:read]

    read :get_singleton do
      get? true

      prepare fn query, _ ->
        query
        |> Ash.Query.limit(1)
        |> Ash.Query.load([:password_present, :api_key_present])
      end
    end

    create :create do
      accept @fields
      argument :password, :string, sensitive?: true
      argument :api_key, :string, sensitive?: true
      argument :clear_password, :boolean, default: false
      argument :clear_api_key, :boolean, default: false
      change SetOutboundMailSecrets
    end

    update :update do
      accept @fields
      argument :password, :string, sensitive?: true
      argument :api_key, :string, sensitive?: true
      argument :clear_password, :boolean, default: false
      argument :clear_api_key, :boolean, default: false
      change SetOutboundMailSecrets
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @manage_check
    end

    action_type_with_permission([:create, :update], @manage_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :enabled, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :adapter, :string do
      allow_nil? false
      default "local"
      public? true
    end

    attribute :from_name, :string do
      allow_nil? false
      default "ServiceRadar"
      public? true
    end

    attribute :from_email, :string do
      allow_nil? false
      default "noreply@serviceradar.cloud"
      public? true
    end

    attribute :relay, :string do
      public? true
    end

    attribute :port, :integer do
      public? true
      constraints min: 1, max: 65_535
    end

    attribute :hostname, :string do
      public? true
    end

    attribute :username, :string do
      public? true
    end

    attribute :password_secret_id, :uuid do
      public? true
    end

    attribute :api_key_secret_id, :uuid do
      public? true
    end

    attribute :password, :string do
      public? false
      sensitive? true
    end

    attribute :api_key, :string do
      public? false
      sensitive? true
    end

    attribute :auth, :string do
      allow_nil? false
      default "if_available"
      public? true
    end

    attribute :tls, :string do
      allow_nil? false
      default "if_available"
      public? true
    end

    attribute :ssl, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :retries, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 0, max: 10
    end

    attribute :provider_options, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :password_secret, NetworkCredentialSecret do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :password_secret_id
    end

    belongs_to :api_key_secret, NetworkCredentialSecret do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :api_key_secret_id
    end
  end

  calculations do
    calculate :password_present, :boolean, fn records, _opts ->
      Enum.map(records, &present_ciphertext?(&1, :encrypted_password))
    end

    calculate :api_key_present, :boolean, fn records, _opts ->
      Enum.map(records, &present_ciphertext?(&1, :encrypted_api_key))
    end
  end

  def adapters, do: @adapters
  def auth_modes, do: @auth_modes
  def tls_modes, do: @tls_modes

  defp present_ciphertext?(record, field) do
    case Map.get(record, field) do
      value when is_binary(value) -> byte_size(value) > 0
      _ -> false
    end
  end
end
