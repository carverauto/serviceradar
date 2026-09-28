defmodule ServiceRadar.Repo.Migrations.CreateSamlConsumedAssertions do
  @moduledoc """
  One-time-use ledger for accepted SAML assertions
  (`ServiceRadar.Identity.SAMLConsumedAssertion`).

  The unique index on `(issuer, assertion_id)` is the replay check: the SAML
  consumer inserts before it establishes a session and rejects the login when
  the insert conflicts. Its name matches the resource's `:unique_assertion`
  identity so AshPostgres reports the conflict as an identity error rather than
  a raw constraint exception. The `not_on_or_after` index serves the expiry
  sweep.
  """
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:saml_consumed_assertions, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :issuer, :text, null: false
      add :assertion_id, :text, null: false
      add :not_on_or_after, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")
    end

    create unique_index(:saml_consumed_assertions, [:issuer, :assertion_id],
             prefix: @prefix,
             name: "saml_consumed_assertions_unique_assertion_index"
           )

    create index(:saml_consumed_assertions, [:not_on_or_after], prefix: @prefix)
  end

  def down do
    drop_if_exists table(:saml_consumed_assertions, prefix: @prefix)
  end
end
