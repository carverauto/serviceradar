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

  describe "snmp credential kind" do
    # SNMP is one kind rather than three because v1/v2c community strings and
    # v3 auth/priv material are the same credential to an operator -- the SNMP
    # version decides which fields apply, not which secret is chosen. So a
    # single JSON payload has to be able to carry either shape, and it has to
    # be the shape SNMPProfiles.CredentialResolver already reads.
    defp snmp_profile(fields) do
      %{
        "provider" => "snmp",
        "plugin_id" => "snmp",
        "plugin_version" => "native",
        "auth_methods" => [
          %{
            "id" => "snmp",
            "credential_kind" => "snmp",
            "fields" => fields
          }
        ]
      }
    end

    test "stores a v2c community string as a json payload" do
      profile =
        snmp_profile([
          %{"id" => "community", "secret" => true, "required" => true}
        ])

      assert {:ok, attrs} =
               CredentialSecretBuilder.build(
                 profile,
                 "snmp",
                 %{"community" => "s3cret-community"},
                 %{name: "Core switches v2c", description: nil}
               )

      assert attrs.credential_kind == :snmp
      assert attrs.provider == "snmp"
      assert Jason.decode!(attrs.secret_payload) == %{"community" => "s3cret-community"}
      assert attrs.public_fingerprint =~ "sha256:"
      refute inspect(attrs.metadata) =~ "s3cret-community"
    end

    test "stores v3 auth and privacy material in the same kind" do
      profile =
        snmp_profile([
          %{"id" => "username", "secret" => false, "required" => true, "public" => true},
          %{"id" => "auth_password", "secret" => true, "required" => true},
          %{"id" => "priv_password", "secret" => true, "required" => false}
        ])

      assert {:ok, attrs} =
               CredentialSecretBuilder.build(
                 profile,
                 "snmp",
                 %{
                   "username" => "monitor",
                   "auth_password" => "auth-secret",
                   "priv_password" => "priv-secret"
                 },
                 %{name: "Core switches v3", description: nil}
               )

      assert attrs.credential_kind == :snmp

      # The resolver reads these exact keys out of the decoded payload.
      assert %{
               "username" => "monitor",
               "auth_password" => "auth-secret",
               "priv_password" => "priv-secret"
             } = Jason.decode!(attrs.secret_payload)

      refute inspect(attrs.metadata) =~ "auth-secret"
      refute inspect(attrs.metadata) =~ "priv-secret"
    end

    test "a required field left blank is rejected rather than stored empty" do
      profile =
        snmp_profile([
          %{"id" => "community", "secret" => true, "required" => true}
        ])

      assert {:error, _} =
               CredentialSecretBuilder.build(
                 profile,
                 "snmp",
                 %{"community" => ""},
                 %{name: "Blank", description: nil}
               )
    end
  end
end
