defmodule ServiceRadar.Identity.AccessCredentialChangesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.AccessCredentialChanges
  alias ServiceRadar.Identity.ApiToken

  test "record_use increments use_count and sets last_used_at" do
    changeset =
      ApiToken
      |> Ash.Changeset.new()
      |> Ash.Changeset.change_attribute(:name, "token")
      |> Ash.Changeset.change_attribute(:token_hash, String.duplicate("a", 64))
      |> Ash.Changeset.change_attribute(:token_prefix, "prefix123")
      |> Ash.Changeset.change_attribute(:user_id, Ecto.UUID.generate())
      |> Ash.Changeset.change_attribute(:use_count, 2)

    updated = AccessCredentialChanges.record_use(changeset)

    assert updated.attributes.use_count == 3
    assert %DateTime{} = updated.attributes.last_used_at
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
          :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
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
