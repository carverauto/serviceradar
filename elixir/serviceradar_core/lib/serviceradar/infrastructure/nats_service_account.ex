defmodule ServiceRadar.Infrastructure.NatsServiceAccount do
  @moduledoc """
  Stores NATS service accounts used by platform operators and internal services.

  Service accounts are platform-scoped (non-tenant) and hold dedicated NATS
  account credentials plus a service user credential for runtime access.
  """

  use Ash.Resource,
    domain: ServiceRadar.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:account_seed_ciphertext, :user_creds_ciphertext])
    decrypt_by_default([])
  end

  postgres do
    table("nats_service_accounts")
    schema("public")
    repo(ServiceRadar.Repo)
  end

  actions do
    defaults([:read])

    read :by_name do
      argument(:name, :string, allow_nil?: false)
      get?(true)
      filter(expr(name == ^arg(:name)))
    end

    create :provision do
      accept([:name])

      argument(:account_public_key, :string, allow_nil?: false)
      argument(:account_seed, :string, allow_nil?: false)
      argument(:account_jwt, :string, allow_nil?: false)
      argument(:user_public_key, :string, allow_nil?: false)
      argument(:user_creds, :string, allow_nil?: false)

      change(fn changeset, _context ->
        account_seed = Ash.Changeset.get_argument(changeset, :account_seed)
        user_creds = Ash.Changeset.get_argument(changeset, :user_creds)

        changeset
        |> Ash.Changeset.change_attribute(
          :account_public_key,
          Ash.Changeset.get_argument(changeset, :account_public_key)
        )
        |> Ash.Changeset.change_attribute(
          :account_jwt,
          Ash.Changeset.get_argument(changeset, :account_jwt)
        )
        |> Ash.Changeset.change_attribute(
          :user_public_key,
          Ash.Changeset.get_argument(changeset, :user_public_key)
        )
        |> AshCloak.encrypt_and_set(:account_seed_ciphertext, account_seed)
        |> AshCloak.encrypt_and_set(:user_creds_ciphertext, user_creds)
        |> Ash.Changeset.change_attribute(:status, :ready)
        |> Ash.Changeset.change_attribute(:error_message, nil)
        |> Ash.Changeset.change_attribute(:provisioned_at, DateTime.utc_now())
      end)
    end

    update :set_ready do
      require_atomic?(false)
      accept([])

      argument(:account_public_key, :string, allow_nil?: false)
      argument(:account_seed, :string, allow_nil?: false)
      argument(:account_jwt, :string, allow_nil?: false)
      argument(:user_public_key, :string, allow_nil?: false)
      argument(:user_creds, :string, allow_nil?: false)

      change(fn changeset, _context ->
        account_seed = Ash.Changeset.get_argument(changeset, :account_seed)
        user_creds = Ash.Changeset.get_argument(changeset, :user_creds)

        changeset
        |> Ash.Changeset.change_attribute(
          :account_public_key,
          Ash.Changeset.get_argument(changeset, :account_public_key)
        )
        |> Ash.Changeset.change_attribute(
          :account_jwt,
          Ash.Changeset.get_argument(changeset, :account_jwt)
        )
        |> Ash.Changeset.change_attribute(
          :user_public_key,
          Ash.Changeset.get_argument(changeset, :user_public_key)
        )
        |> AshCloak.encrypt_and_set(:account_seed_ciphertext, account_seed)
        |> AshCloak.encrypt_and_set(:user_creds_ciphertext, user_creds)
        |> Ash.Changeset.change_attribute(:status, :ready)
        |> Ash.Changeset.change_attribute(:error_message, nil)
        |> Ash.Changeset.change_attribute(:provisioned_at, DateTime.utc_now())
      end)
    end

    update :set_error do
      require_atomic?(false)
      accept([])

      argument(:error_message, :string, allow_nil?: false)

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:status, :error)
        |> Ash.Changeset.change_attribute(
          :error_message,
          Ash.Changeset.get_argument(changeset, :error_message)
        )
      end)
    end
  end

  policies do

    bypass always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      description("Service account name (e.g., tenant-workload-operator)")
    end

    attribute :account_public_key, :string do
      allow_nil?(true)
      public?(false)
      description("NATS account public key (starts with 'A')")
    end

    attribute :account_seed_ciphertext, :binary do
      allow_nil?(true)
      public?(false)
      description("Encrypted NATS account seed")
    end

    attribute :account_jwt, :string do
      allow_nil?(true)
      public?(false)
      constraints(max_length: 8192)
      description("Signed NATS account JWT")
    end

    attribute :user_public_key, :string do
      allow_nil?(true)
      public?(false)
      description("NATS user public key (starts with 'U')")
    end

    attribute :user_creds_ciphertext, :binary do
      allow_nil?(true)
      public?(false)
      description("Encrypted .creds file content")
    end

    attribute :status, :atom do
      allow_nil?(false)
      default(:pending)
      public?(true)
      constraints(one_of: [:pending, :ready, :error])
      description("Provisioning status")
    end

    attribute :error_message, :string do
      allow_nil?(true)
      public?(false)
      description("Error details when provisioning failed")
    end

    attribute :provisioned_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
      description("When the service account was provisioned")
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_name, [:name])
  end
end
