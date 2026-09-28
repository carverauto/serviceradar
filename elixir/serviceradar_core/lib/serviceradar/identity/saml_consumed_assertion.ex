defmodule ServiceRadar.Identity.SAMLConsumedAssertion do
  @moduledoc """
  One-time-use ledger for SAML assertions accepted by the web SSO flow.

  A SAML bearer assertion is valid for every POST made before its
  `NotOnOrAfter`, so a captured response can be submitted again by anyone who
  can start their own login flow. The assertion consumer records each accepted
  assertion here, keyed by `(issuer, assertion_id)`, before it establishes a
  session. The unique identity turns a second submission into an insert
  conflict, which the consumer treats as a replay and rejects. The ledger lives
  in CNPG so every web node sees the same decision.

  Rows are only needed while the assertion could still be accepted, so
  `ServiceRadar.Identity.SAMLAssertionCleanupWorker` deletes rows whose
  `not_on_or_after` has passed.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "saml_consumed_assertions"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :record, args: [:issuer, :assertion_id, :not_on_or_after]
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      description "Records an accepted assertion; fails on a second use of the same assertion."
      accept [:issuer, :assertion_id, :not_on_or_after]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type([:read, :create, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :issuer, :string do
      allow_nil? false
      public? true
      constraints max_length: 1024
    end

    attribute :assertion_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 1024
    end

    attribute :not_on_or_after, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  identities do
    identity :unique_assertion, [:issuer, :assertion_id]
  end
end
