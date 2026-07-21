defmodule ServiceRadar.Credentials.CredentialSecretBuilderTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  test "builds a scalar secret from an arbitrary package descriptor" do
    profile =
      Map.merge(CredentialIntegrationFixtures.target_policy_profile(), %{
        "plugin_id" => "example-network",
        "plugin_version" => "1.2.3"
      })

    assert {:ok, attrs} =
             CredentialSecretBuilder.build(
               profile,
               "api_token",
               %{"token" => "sensitive-token"},
               %{name: "Example token", description: nil}
             )

    assert attrs.name == "Example token"
    assert attrs.provider == "example-network"
    assert attrs.credential_kind == :api_token
    assert attrs.secret_payload == "sensitive-token"
    assert attrs.username == nil
    assert attrs.public_fingerprint =~ "sha256:"

    assert attrs.metadata == %{
             "auth_method" => "api_token",
             "credential_descriptor" => "package_manifest.v1",
             "plugin_id" => "example-network",
             "plugin_version" => "1.2.3"
           }

    refute inspect(attrs.metadata) =~ "sensitive-token"
  end

  test "stores only a declared public username outside the encrypted payload" do
    profile = CredentialIntegrationFixtures.target_policy_profile()

    assert {:ok, attrs} =
             CredentialSecretBuilder.build(
               profile,
               "username_password",
               %{"username" => "operator", "password" => "sensitive-password"},
               %{name: "Example account"}
             )

    assert attrs.credential_kind == :username_password
    assert attrs.username == "operator"
    assert attrs.secret_payload == "sensitive-password"
    refute inspect(attrs.metadata) =~ "sensitive-password"
  end

  test "supports bounded template and JSON storage encodings" do
    profile = %{
      "provider" => "example-provider",
      "auth_methods" => [
        method("template", "opaque", %{
          "format" => "template",
          "template" => "{{client_id}}:{{client_secret}}",
          "username_field" => "client_id"
        }),
        method("json", "certificate", %{"format" => "json"})
      ]
    }

    assert {:ok, template_attrs} =
             CredentialSecretBuilder.build(
               profile,
               "template",
               %{"client_id" => "client-a", "client_secret" => "secret-a"},
               %{name: "Template credential"}
             )

    assert template_attrs.secret_payload == "client-a:secret-a"
    assert template_attrs.username == "client-a"

    assert {:ok, json_attrs} =
             CredentialSecretBuilder.build(
               profile,
               "json",
               %{"client_id" => "client-b", "client_secret" => "secret-b"},
               %{name: "JSON credential"}
             )

    assert Jason.decode!(json_attrs.secret_payload) == %{
             "client_id" => "client-b",
             "client_secret" => "secret-b"
           }
  end

  test "rejects missing, oversized, and undeclared values" do
    profile = CredentialIntegrationFixtures.target_policy_profile()

    assert {:error, {:missing_credential_field, "token"}} =
             CredentialSecretBuilder.build(profile, "api_token", %{"token" => ""}, %{})

    assert {:error, :undeclared_credential_field} =
             CredentialSecretBuilder.build(
               profile,
               "api_token",
               %{"token" => "ok", "unexpected" => "must-not-be-stored"},
               %{}
             )

    assert {:error, {:invalid_credential_field, "token"}} =
             CredentialSecretBuilder.build(
               profile,
               "api_token",
               %{"token" => String.duplicate("x", 16_385)},
               %{}
             )

    assert {:error, :credential_method_not_found} =
             CredentialSecretBuilder.build(profile, "core-special-case", %{}, %{})
  end

  test "validates SSH private-key material and preserves key fingerprint semantics" do
    method = %{
      "id" => "key_pair",
      "credential_kind" => "ssh_private_key",
      "fields" => [
        %{
          "id" => "private_key",
          "required" => true,
          "secret" => true,
          "public" => false
        }
      ],
      "payload" => %{"format" => "json"}
    }

    profile = %{"provider" => "example-provider", "auth_methods" => [method]}

    assert {:error, :invalid_private_key} =
             CredentialSecretBuilder.build(
               profile,
               "key_pair",
               %{"private_key" => "not-a-private-key"},
               %{name: "Invalid key"}
             )

    private_key =
      "-----BEGIN OPENSSH PRIVATE KEY-----\n" <>
        "b3BlbnNzaC10ZXN0LWtleS1tYXRlcmlhbA==\n" <>
        "-----END OPENSSH PRIVATE KEY-----"

    assert {:ok, attrs} =
             CredentialSecretBuilder.build(
               profile,
               "key_pair",
               %{"private_key" => private_key},
               %{name: "Valid key"}
             )

    assert attrs.public_fingerprint =~ "SHA256:"
    assert Jason.decode!(attrs.secret_payload) == %{"private_key" => private_key}
  end

  defp method(id, credential_kind, payload) do
    %{
      "id" => id,
      "credential_kind" => credential_kind,
      "fields" => [
        %{
          "id" => "client_id",
          "required" => true,
          "secret" => false,
          "public" => true
        },
        %{
          "id" => "client_secret",
          "required" => true,
          "secret" => true,
          "public" => false
        }
      ],
      "payload" => payload
    }
  end
end
