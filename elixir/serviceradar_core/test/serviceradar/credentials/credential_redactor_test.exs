defmodule ServiceRadar.Credentials.CredentialRedactorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialRedactor

  test "redacts nested plaintext credential material but preserves secret references" do
    ref = "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"

    payload = %{
      "api_token_secret_ref" => ref,
      "credential_secret_ref" => ref,
      "credential_grant_ref" => "credentialref:network-credential-grant:opaque.sig",
      "external_secret_ref" => "secret-server/folder/prod-password",
      "api_token" => "PVEAPIToken=root@pam!sr=secret",
      "secret_payload" => Jason.encode!(%{"private_key" => private_key_fixture()}),
      "nested" => [
        %{"passphrase" => "key-passphrase"},
        %{"notes" => "safe"},
        private_key_fixture()
      ]
    }

    redacted = CredentialRedactor.redact(payload)

    assert redacted["api_token_secret_ref"] == ref
    assert redacted["credential_secret_ref"] == ref
    assert redacted["credential_grant_ref"] == "credentialref:network-credential-grant:opaque.sig"
    assert redacted["external_secret_ref"] == "REDACTED"
    assert redacted["api_token"] == "REDACTED"
    assert redacted["secret_payload"] == "REDACTED"
    assert Enum.at(redacted["nested"], 0)["passphrase"] == "REDACTED"
    assert Enum.at(redacted["nested"], 1)["notes"] == "safe"
    assert Enum.at(redacted["nested"], 2) == "REDACTED"

    refute inspect(redacted) =~ "PVEAPIToken="
    refute inspect(redacted) =~ "key-passphrase"
    refute inspect(redacted) =~ "PRIVATE KEY"
  end

  test "whole-key token, secret and header names are redacted without catching their lookalikes" do
    ref = "secretref:plugin:example/api-key"

    payload = %{
      "token" => "tok-sentinel",
      "access_token" => "access-sentinel",
      "refresh_token" => "refresh-sentinel",
      "client_secret" => "client-secret-sentinel",
      "secret" => "bare-secret-sentinel",
      "Authorization" => "Bearer header-sentinel",
      "X-Api-Key" => "header-key-sentinel",
      "api_key" => %{"value" => "nested-key-sentinel"},
      "secret_id" => "018f3f56-1111-7222-8333-123456789abc",
      "secret_ref" => "network-credential",
      "token_path" => "/oauth2/token",
      "token_ttl_seconds" => 300,
      "credential_profiles" => [%{"field" => "api_key", "secret" => true}],
      "callback" => %{"token" => nil},
      "bearer_token" => ref,
      "password" => ref,
      "external_secret_ref" => ref
    }

    redacted = CredentialRedactor.redact(payload)

    for key <-
          ~w(token access_token refresh_token client_secret secret Authorization X-Api-Key api_key) do
      assert redacted[key] == "REDACTED", key
    end

    for key <- ~w(secret_id secret_ref token_path token_ttl_seconds credential_profiles callback) do
      assert redacted[key] == payload[key], key
    end

    assert redacted["bearer_token"] == ref
    assert redacted["password"] == ref
    assert redacted["external_secret_ref"] == "REDACTED"
    refute inspect(redacted) =~ "sentinel"
  end

  test "oauth inject field_password metadata is not treated as a secret" do
    payload = %{
      "inject" => %{
        "type" => "oauth2_password_bearer",
        "field_username" => "username",
        "field_password" => "password",
        "fixed_grant_type" => "password",
        "token_path" => "/idp/oauth2/token"
      },
      "password" => "actual-secret"
    }

    redacted = CredentialRedactor.redact(payload)

    assert redacted["inject"] == payload["inject"]
    assert redacted["password"] == "REDACTED"
  end

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
