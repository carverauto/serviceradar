defmodule ServiceRadar.Credentials.NetworkCredentialSecretRedactionTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SshPrivateKeyCredential

  @credential_manager %{
    id: "user-1",
    role: :admin,
    permissions: ["settings.credentials.manage"]
  }

  @system_actor ServiceRadar.Actors.SystemActor.system(:network_credential_secret_redaction_test)
  @secret_id "018f3f56-1111-7222-8333-123456789abc"

  test "public read actions select only redacted credential metadata" do
    for action <- [:read, :by_id, :by_provider] do
      selected =
        action
        |> public_read_query()
        |> selected_fields()

      assert :id in selected
      assert :name in selected
      assert :provider in selected
      assert :credential_kind in selected
      assert :username in selected
      assert :public_fingerprint in selected
      assert :source_type in selected
      assert :external_secret_ref in selected
      assert :last_rotated_at in selected
      assert :next_rotation_due_at in selected

      refute :secret_payload in selected
      refute :encrypted_secret_payload in selected
    end
  end

  test "system secret resolution action is narrow and not the public read path" do
    selected =
      NetworkCredentialSecret
      |> Ash.Query.for_read(:by_id_with_secret, %{id: @secret_id}, actor: @system_actor)
      |> selected_fields()

    assert :id in selected
    assert :provider in selected
    assert :credential_kind in selected
    assert :username in selected
    assert :metadata in selected
    assert :source_type in selected
    assert :external_secret_ref in selected
    assert :encrypted_secret_payload in selected

    refute :name in selected
    refute :secret_payload in selected
    refute :public_fingerprint in selected
  end

  test "encrypted backing field is non-public and sensitive" do
    encrypted = Info.attribute(NetworkCredentialSecret, :encrypted_secret_payload)

    assert encrypted.public? == false
    assert encrypted.sensitive? == true
    assert Map.has_key?(struct(NetworkCredentialSecret), :secret_payload)
  end

  test "external reference metadata is public but not plaintext secret material" do
    for attr <- [
          :source_type,
          :secret_provider_id,
          :external_secret_ref,
          :external_secret_version,
          :external_secret_fields,
          :resolution_location,
          :cache_policy,
          :cache_ttl_seconds
        ] do
      assert Info.attribute(NetworkCredentialSecret, attr).public? == true
    end

    refute Info.attribute(NetworkCredentialSecret, :encrypted_secret_payload).public?
    assert Map.has_key?(struct(NetworkCredentialSecret), :secret_payload)
  end

  test "ssh private key helper stores key and passphrase only in encrypted payload attrs" do
    rotated_at = ~U[2026-05-06 18:10:00Z]
    due_at = ~U[2026-08-06 18:10:00Z]

    assert {:ok, attrs} =
             SshPrivateKeyCredential.build_attrs(%{
               name: "pve-shell",
               provider: "proxmox",
               username: "root",
               private_key: private_key_fixture(),
               passphrase: "key-passphrase",
               last_rotated_at: rotated_at,
               next_rotation_due_at: due_at,
               metadata: %{
                 "note" => "console key",
                 "passphrase" => "drop-me",
                 "nested" => %{"private_key" => private_key_fixture()}
               }
             })

    assert attrs.credential_kind == :ssh_private_key
    assert attrs.provider == "proxmox"
    assert attrs.username == "root"
    assert attrs.last_rotated_at == rotated_at
    assert attrs.next_rotation_due_at == due_at
    assert attrs.public_fingerprint =~ "SHA256:"
    assert attrs.metadata["fingerprint_display"] =~ "SHA256:"
    assert attrs.metadata["secret_payload_format"] == "ssh_private_key.v1"
    assert attrs.metadata["note"] == "console key"

    refute inspect(Map.delete(attrs, :secret_payload)) =~ "key-passphrase"
    refute inspect(Map.delete(attrs, :secret_payload)) =~ "PRIVATE KEY"
    refute inspect(attrs.metadata) =~ "drop-me"

    assert %{"private_key" => private_key, "passphrase" => "key-passphrase", "username" => "root"} =
             Jason.decode!(attrs.secret_payload)

    assert private_key =~ "OPENSSH PRIVATE KEY"
  end

  test "ssh private key helper rejects missing or invalid private key material" do
    assert {:error, :missing_private_key} =
             SshPrivateKeyCredential.build_attrs(%{name: "missing", private_key: ""})

    assert {:error, :invalid_private_key} =
             SshPrivateKeyCredential.build_attrs(%{name: "invalid", private_key: "not a key"})
  end

  defp public_read_query(:read) do
    Ash.Query.for_read(NetworkCredentialSecret, :read, %{}, actor: @credential_manager)
  end

  defp public_read_query(:by_id) do
    Ash.Query.for_read(NetworkCredentialSecret, :by_id, %{id: @secret_id},
      actor: @credential_manager
    )
  end

  defp public_read_query(:by_provider) do
    Ash.Query.for_read(NetworkCredentialSecret, :by_provider, %{provider: "proxmox"},
      actor: @credential_manager
    )
  end

  defp selected_fields(%Ash.Query{select: select}) when is_list(select), do: select

  defp private_key_fixture do
    private_key_fixture_header() <>
      """
      b3BlbnNzaC10ZXN0LWtleS1tYXRlcmlhbA==
      #{private_key_fixture_footer()}
      """
  end

  defp private_key_fixture_header, do: "-----BEGIN OPENSSH " <> "PRIVATE KEY-----\n"
  defp private_key_fixture_footer, do: "-----END OPENSSH " <> "PRIVATE KEY-----"
end
