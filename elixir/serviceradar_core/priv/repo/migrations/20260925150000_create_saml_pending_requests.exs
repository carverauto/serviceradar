defmodule ServiceRadar.Repo.Migrations.CreateSamlPendingRequests do
  @moduledoc """
  Server-side SP-initiated SAML logins (`ServiceRadar.Identity.SAMLPendingRequest`).

  One row per AuthnRequest, keyed by a SHA-256 hash of the RelayState sent to
  the IdP. The unique index is named for the resource's `:unique_relay_state`
  identity. The assertion consumer deletes a row as it reads it, so each
  RelayState answers one response; the `expires_at` index serves the expiry
  sweep.
  """
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:saml_pending_requests, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :relay_state_hash, :text, null: false
      add :request_id, :text, null: false
      add :return_to, :text
      add :expires_at, :utc_datetime_usec, null: false

      add :issued_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")
    end

    create unique_index(:saml_pending_requests, [:relay_state_hash],
             prefix: @prefix,
             name: "saml_pending_requests_unique_relay_state_index"
           )

    create index(:saml_pending_requests, [:expires_at], prefix: @prefix)
  end

  def down do
    drop_if_exists table(:saml_pending_requests, prefix: @prefix)
  end
end
