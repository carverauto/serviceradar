defmodule ServiceRadar.Infrastructure.NatsOperator do
  @moduledoc """
  NATS Operator resource for managing the platform-level NATS operator.

  The operator is the root of trust for the NATS multi-tenant system. There is
  exactly one operator per platform installation. The operator key is used to
  sign all tenant account JWTs.

  ## Bootstrap Flow

  1. Initial platform setup triggers `bootstrap` action
  2. datasvc generates/imports operator keys and signs JWTs
  3. Operator JWT and public key are stored in this resource
  4. System account (if generated) is also tracked here

  ## Security

  - Operator seed is stored in environment (not in database)
  - Only public key and signed JWT are persisted
  - All actions require super_admin role

  ## Status Values

  - `pending` - Operator bootstrap initiated
  - `ready` - Operator is bootstrapped and ready for use
  - `error` - Bootstrap failed
  """

  use Ash.Resource,
    domain: ServiceRadar.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  cloak do
    vault ServiceRadar.Vault

    attributes [:system_account_seed_ciphertext]

    decrypt_by_default []
  end

  postgres do
    table "nats_operators"
    repo ServiceRadar.Repo
  end

  actions do
    defaults [:read]

    read :get_current do
      description "Get the current operator (there should be at most one)"
      get? true
      filter expr(status == :ready or status == :pending)
    end

    create :bootstrap do
      description "Bootstrap a new NATS operator for the platform"
      accept [:name]

      argument :public_key, :string, allow_nil?: false
      argument :operator_jwt, :string, allow_nil?: true
      argument :system_account_public_key, :string, allow_nil?: true
      argument :system_account_seed, :string, allow_nil?: true

      change fn changeset, _context ->
        system_seed = Ash.Changeset.get_argument(changeset, :system_account_seed)

        changeset
        |> Ash.Changeset.change_attribute(
          :public_key,
          Ash.Changeset.get_argument(changeset, :public_key)
        )
        |> Ash.Changeset.change_attribute(
          :operator_jwt,
          Ash.Changeset.get_argument(changeset, :operator_jwt)
        )
        |> Ash.Changeset.change_attribute(
          :system_account_public_key,
          Ash.Changeset.get_argument(changeset, :system_account_public_key)
        )
        |> then(fn cs ->
          if system_seed && system_seed != "" do
            AshCloak.encrypt_and_set(cs, :system_account_seed_ciphertext, system_seed)
          else
            cs
          end
        end)
        |> Ash.Changeset.change_attribute(:status, :ready)
        |> Ash.Changeset.change_attribute(:bootstrapped_at, DateTime.utc_now())
      end
    end

    update :set_ready do
      description "Mark operator as ready after successful bootstrap"
      accept []
      require_atomic? false

      argument :public_key, :string, allow_nil?: false
      argument :operator_jwt, :string, allow_nil?: false
      argument :system_account_public_key, :string

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:public_key, Ash.Changeset.get_argument(changeset, :public_key))
        |> Ash.Changeset.change_attribute(:operator_jwt, Ash.Changeset.get_argument(changeset, :operator_jwt))
        |> Ash.Changeset.change_attribute(:system_account_public_key, Ash.Changeset.get_argument(changeset, :system_account_public_key))
        |> Ash.Changeset.change_attribute(:status, :ready)
        |> Ash.Changeset.change_attribute(:bootstrapped_at, DateTime.utc_now())
      end
    end

    update :set_error do
      description "Record bootstrap failure"
      accept []
      require_atomic? false

      argument :error_message, :string, allow_nil?: false

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:status, :error)
        |> Ash.Changeset.change_attribute(:error_message, Ash.Changeset.get_argument(changeset, :error_message))
      end
    end
  end

  policies do
    # All operations require super_admin
    policy always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      default "serviceradar"
      public? true
      description "Operator name (e.g., 'serviceradar')"
    end

    attribute :public_key, :string do
      allow_nil? true
      public? false
      description "Operator's public NKey (starts with 'O')"
    end

    attribute :operator_jwt, :string do
      allow_nil? true
      public? false
      constraints max_length: 8192
      description "Signed operator JWT"
    end

    attribute :system_account_public_key, :string do
      allow_nil? true
      public? false
      description "System account's public key (starts with 'A')"
    end

    attribute :system_account_seed_ciphertext, :binary do
      allow_nil? true
      public? false
      description "Encrypted system account seed for JWT push operations"
    end

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :ready, :error]
      description "Bootstrap status"
    end

    attribute :error_message, :string do
      allow_nil? true
      public? false
      description "Error message if bootstrap failed"
    end

    attribute :bootstrapped_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When the operator was successfully bootstrapped"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  calculations do
    calculate :is_ready?, :boolean, expr(status == :ready and not is_nil(public_key))
  end

  identities do
    identity :unique_name, [:name]
  end
end
