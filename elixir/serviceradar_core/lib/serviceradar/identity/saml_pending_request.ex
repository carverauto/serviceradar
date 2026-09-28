defmodule ServiceRadar.Identity.SAMLPendingRequest do
  @moduledoc """
  Server-side record of an SP-initiated SAML login in progress.

  `GET /auth/saml` opens one row per AuthnRequest, keyed by the RelayState it
  sends to the IdP. The IdP posts that RelayState back to the assertion
  consumer with its response, and the consumer takes the row with `take/2`:
  one atomic `DELETE ... RETURNING`, so a RelayState answers at most one
  response even when two submissions race. The response's `InResponseTo` must
  then equal the row's `request_id`.

  The row lives in CNPG rather than the browser session because the IdP's POST
  is a cross-site request: with a `SameSite=Lax` session cookie the browser
  usually does not send the session with it.

  Only a SHA-256 hash of the RelayState is stored, so a database read does not
  hand out usable RelayState values. Expired rows are removed by
  `ServiceRadar.Identity.SAMLAssertionCleanupWorker`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  postgres do
    table "saml_pending_requests"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :open, args: [:relay_state, :request_id, :expires_at]
    define :take, args: [:relay_state]
  end

  actions do
    defaults [:read, :destroy]

    create :open do
      description "Records an AuthnRequest sent to the IdP under the given RelayState."
      accept [:request_id, :expires_at, :return_to]

      argument :relay_state, :string do
        allow_nil? false
        sensitive? true
        constraints min_length: 22, max_length: 80
      end

      change fn changeset, _context ->
        relay_state = Ash.Changeset.get_argument(changeset, :relay_state)

        Ash.Changeset.force_change_attribute(
          changeset,
          :relay_state_hash,
          hash_relay_state(relay_state)
        )
      end
    end

    action :take, :struct do
      description "Deletes and returns the pending request for a RelayState, or nil."
      constraints instance_of: __MODULE__
      allow_nil? true

      argument :relay_state, :string do
        allow_nil? false
        sensitive? true
      end

      run fn input, context ->
        hash = hash_relay_state(input.arguments.relay_state)

        result =
          __MODULE__
          |> Ash.Query.filter(relay_state_hash == ^hash)
          |> Ash.bulk_destroy(:destroy, %{},
            actor: Map.get(context, :actor),
            strategy: [:atomic],
            return_records?: true,
            return_errors?: true
          )

        case result do
          %Ash.BulkResult{status: :success, records: [record]} -> {:ok, record}
          %Ash.BulkResult{status: :success} -> {:ok, nil}
          %Ash.BulkResult{errors: errors} -> {:error, errors}
        end
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type([:read, :create, :destroy, :action]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :relay_state_hash, :string do
      allow_nil? false
      sensitive? true
      public? false
    end

    attribute :request_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 256
    end

    attribute :return_to, :string do
      public? true
      constraints max_length: 2048
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :issued_at
  end

  identities do
    identity :unique_relay_state, [:relay_state_hash]
  end

  defp hash_relay_state(relay_state) do
    :sha256
    |> :crypto.hash(relay_state)
    |> Base.encode16(case: :lower)
  end
end
