defmodule ServiceRadar.Credentials.NetworkCredentialSecretRedactionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.NetworkCredentialSecret

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
    assert :encrypted_secret_payload in selected

    refute :name in selected
    refute :username in selected
    refute :public_fingerprint in selected
  end

  test "encrypted backing field is non-public and sensitive" do
    encrypted = Ash.Resource.Info.attribute(NetworkCredentialSecret, :encrypted_secret_payload)

    assert encrypted.public? == false
    assert encrypted.sensitive? == true
    assert Map.has_key?(struct(NetworkCredentialSecret), :secret_payload)
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
end
