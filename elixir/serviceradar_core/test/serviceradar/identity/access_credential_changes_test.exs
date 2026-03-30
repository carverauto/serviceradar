defmodule ServiceRadar.Identity.AccessCredentialChangesTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Identity.AccessCredentialChanges
  alias ServiceRadar.Identity.ApiToken
  alias ServiceRadar.Identity.OAuthClient

  test "api token and oauth client record_use actions remain atomic" do
    api_token_action = Info.action(ApiToken, :record_use)
    oauth_client_action = Info.action(OAuthClient, :record_use)

    refute api_token_action.require_atomic? == false
    refute oauth_client_action.require_atomic? == false
  end

  test "init_secret hashes the raw secret and sets shared credential fields" do
    changeset =
      ApiToken
      |> Ash.Changeset.new()
      |> Ash.Changeset.change_attribute(:name, "token")
      |> Ash.Changeset.change_attribute(:user_id, Ecto.UUID.generate())
      |> Ash.Changeset.set_argument(:token, "abcdefgh12345678")

    updated =
      AccessCredentialChanges.init_secret(changeset,
        argument: :token,
        hash_attribute: :token_hash,
        prefix_attribute: :token_prefix,
        timestamp_attribute: :created_at,
        hash_fun: fn raw_token ->
          :sha256 |> :crypto.hash(raw_token) |> Base.encode16(case: :lower)
        end
      )

    assert updated.attributes.token_prefix == "abcdefgh"
    assert updated.attributes.enabled == true
    assert updated.attributes.use_count == 0
    assert %DateTime{} = updated.attributes.created_at
    assert is_binary(updated.attributes.token_hash)
  end

  test "revoke disables the credential and sets revocation fields" do
    changeset =
      ApiToken
      |> Ash.Changeset.new()
      |> Ash.Changeset.change_attribute(:name, "token")
      |> Ash.Changeset.change_attribute(:token_hash, String.duplicate("a", 64))
      |> Ash.Changeset.change_attribute(:token_prefix, "prefix123")
      |> Ash.Changeset.change_attribute(:user_id, Ecto.UUID.generate())

    updated = AccessCredentialChanges.revoke(changeset, revoked_by: "admin")

    assert updated.attributes.enabled == false
    assert updated.attributes.revoked_by == "admin"
    assert %DateTime{} = updated.attributes.revoked_at
  end
end
