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

  describe "native SNMP descriptor" do
    # SNMP has no package to publish a descriptor, so NativeDescriptors supplies
    # one in the shape a manifest would. The point of that shape is that the
    # builder is unchanged -- these assert it really does go through the same
    # path, and that the field ids match what
    # SNMPProfiles.CredentialResolver.broker_json_credential/3 reads. Renaming a
    # field id there would otherwise silently stop the value reaching the poller.
    alias ServiceRadar.Credentials.NativeDescriptors

    test "the community method builds through the ordinary builder" do
      assert {:ok, attrs} =
               CredentialSecretBuilder.build(
                 NativeDescriptors.snmp(),
                 "community",
                 %{"community" => "public-ish"},
                 %{name: "Edge switches", description: nil}
               )

      assert attrs.provider == "snmp"
      assert attrs.credential_kind == :snmp
      assert NativeDescriptors.snmp()["supports_rules"] == true
      assert Jason.decode!(attrs.secret_payload) == %{"community" => "public-ish"}
      assert attrs.metadata["plugin_id"] == "snmp"
      assert attrs.metadata["plugin_version"] == "native"
    end

    test "the v3 method stores the username publicly and the rest encrypted" do
      assert {:ok, attrs} =
               CredentialSecretBuilder.build(
                 NativeDescriptors.snmp(),
                 "v3",
                 %{
                   "username" => "monitor",
                   "security_level" => "authPriv",
                   "auth_protocol" => "sha",
                   "auth_password" => "auth-secret",
                   "priv_protocol" => "aes",
                   "priv_password" => "priv-secret"
                 },
                 %{name: "Core switches", description: nil}
               )

      # Public username is readable without decrypting anything.
      assert attrs.username == "monitor"

      assert %{
               "username" => "monitor",
               "security_level" => "authPriv",
               "auth_protocol" => "sha",
               "auth_password" => "auth-secret",
               "priv_protocol" => "aes",
               "priv_password" => "priv-secret"
             } = Jason.decode!(attrs.secret_payload)

      refute inspect(attrs.metadata) =~ "auth-secret"
    end

    test "v3 privacy is optional but authentication is not" do
      assert {:ok, _attrs} =
               CredentialSecretBuilder.build(
                 NativeDescriptors.snmp(),
                 "v3",
                 %{"username" => "monitor", "auth_password" => "auth-secret"},
                 %{name: "No privacy", description: nil}
               )

      assert {:error, {:missing_credential_field, "auth_password"}} =
               CredentialSecretBuilder.build(
                 NativeDescriptors.snmp(),
                 "v3",
                 %{"username" => "monitor"},
                 %{name: "No auth", description: nil}
               )
    end

    test "a field the descriptor does not declare is rejected" do
      assert {:error, :undeclared_credential_field} =
               CredentialSecretBuilder.build(
                 NativeDescriptors.snmp(),
                 "community",
                 %{"community" => "public", "smuggled" => "value"},
                 %{name: "Smuggler", description: nil}
               )
    end

    test "native? distinguishes protocols from package-owned providers" do
      assert NativeDescriptors.native?("snmp")
      assert NativeDescriptors.native?("vulncheck")
      refute NativeDescriptors.native?("proxmox")
      refute NativeDescriptors.native?(nil)
    end
  end

  describe "native VulnCheck descriptor" do
    alias ServiceRadar.Credentials.NativeDescriptors

    test "stores the API token as a scalar payload" do
      assert {:ok, attrs} =
               CredentialSecretBuilder.build(
                 NativeDescriptors.vulncheck(),
                 "api_token",
                 %{"api_token" => "vc-community-token"},
                 %{name: "VulnCheck community", description: nil}
               )

      assert attrs.provider == "vulncheck"
      assert attrs.credential_kind == :api_token
      assert attrs.secret_payload == "vc-community-token"
      assert attrs.metadata["plugin_id"] == "vulncheck"
      assert attrs.metadata["plugin_version"] == "native"
      assert attrs.metadata["auth_method"] == "api_token"
    end

    test "rejects an empty token" do
      assert {:error, {:missing_credential_field, "api_token"}} =
               CredentialSecretBuilder.build(
                 NativeDescriptors.vulncheck(),
                 "api_token",
                 %{"api_token" => ""},
                 %{name: "Blank", description: nil}
               )
    end
  end

  describe "build_rotation/4" do
    test "builds only replacement-safe attributes and preserves the due date" do
      due_at = ~U[2027-01-02 03:04:05.000000Z]

      secret =
        rotatable_secret(%{
          secret_payload: "old-material-must-never-be-merged",
          next_rotation_due_at: due_at
        })

      assert {:ok, attrs} =
               CredentialSecretBuilder.build_rotation(
                 secret,
                 CredentialIntegrationFixtures.target_policy_profile(),
                 %{"username" => "new-operator", "password" => "new-password"},
                 []
               )

      assert Enum.sort(Map.keys(attrs)) ==
               Enum.sort([
                 :secret_payload,
                 :username,
                 :public_fingerprint,
                 :metadata,
                 :next_rotation_due_at
               ])

      assert attrs.secret_payload == "new-password"
      assert attrs.username == "new-operator"
      assert attrs.next_rotation_due_at == due_at
      assert attrs.metadata["credential_descriptor"] == "package_manifest.v1"
      assert attrs.metadata["auth_method"] == "username_password"
      refute inspect(attrs) =~ "old-material-must-never-be-merged"
    end

    test "requires a complete replacement instead of falling back to old material" do
      marker = "old-secret-must-not-fill-required-field"
      secret = rotatable_secret(%{secret_payload: marker})

      assert {:error, {:missing_credential_field, "password"}} =
               CredentialSecretBuilder.build_rotation(
                 secret,
                 CredentialIntegrationFixtures.target_policy_profile(),
                 %{"username" => "new-operator"},
                 []
               )

      refute inspect(
               CredentialSecretBuilder.build_rotation(
                 secret,
                 CredentialIntegrationFixtures.target_policy_profile(),
                 %{"username" => "new-operator"},
                 []
               )
             ) =~ marker
    end

    test "rejects external, rotating, and disabled credentials before reading submitted material" do
      marker = "rotation-state-secret-marker"
      profile = CredentialIntegrationFixtures.target_policy_profile()

      cases = [
        {rotatable_secret(%{source_type: :external_reference}),
         :credential_rotation_not_supported},
        {rotatable_secret(%{rotation_state: :rotating}), :credential_rotation_not_allowed},
        {rotatable_secret(%{rotation_state: :disabled}), :credential_rotation_not_allowed}
      ]

      for {secret, expected_error} <- cases do
        result =
          CredentialSecretBuilder.build_rotation(
            secret,
            profile,
            %{"username" => "operator", "password" => marker},
            []
          )

        assert {:error, ^expected_error} = result
        refute inspect(result) =~ marker
      end
    end

    test "rejects stale descriptor identity, provider, kind, and auth method" do
      profile = CredentialIntegrationFixtures.target_policy_profile()
      values = %{"username" => "operator", "password" => "replacement"}

      cases = [
        {rotatable_secret(%{
           metadata: %{"credential_descriptor" => "package_manifest.v1"}
         }), profile, :credential_descriptor_unavailable},
        {rotatable_secret(), Map.put(profile, "provider", "other-provider"),
         :credential_provider_mismatch},
        {rotatable_secret(%{credential_kind: :api_token}), profile, :credential_kind_mismatch},
        {rotatable_secret(%{
           metadata: %{
             "credential_descriptor" => "package_manifest.v1",
             "auth_method" => "removed-method"
           }
         }), profile, :credential_method_not_found}
      ]

      for {secret, fresh_profile, expected_error} <- cases do
        assert {:error, ^expected_error} =
                 CredentialSecretBuilder.build_rotation(secret, fresh_profile, values, [])
      end
    end

    test "allows every declared rotatable lifecycle state" do
      profile = CredentialIntegrationFixtures.target_policy_profile()
      values = %{"username" => "operator", "password" => "replacement"}

      for state <- [:active, :rotation_due, :rotation_failed] do
        assert {:ok, %{secret_payload: "replacement"}} =
                 CredentialSecretBuilder.build_rotation(
                   rotatable_secret(%{rotation_state: state}),
                   profile,
                   values,
                   []
                 )
      end
    end

    test "backfills descriptor metadata for an unambiguous legacy credential" do
      profile =
        CredentialIntegrationFixtures.target_policy_profile()
        |> Map.put("plugin_id", "example-network-package")
        |> Map.put("plugin_version", "9.8.7")

      legacy_secret =
        rotatable_secret(%{
          metadata: %{
            "legacy_username_key" => "api_username",
            "legacy_password_key" => "api_password"
          }
        })

      assert {:ok, attrs} =
               CredentialSecretBuilder.build_rotation(
                 legacy_secret,
                 profile,
                 %{"username" => "new-operator", "password" => "replacement"},
                 []
               )

      assert attrs.metadata == %{
               "auth_method" => "username_password",
               "credential_descriptor" => "package_manifest.v1",
               "plugin_id" => "example-network-package",
               "plugin_version" => "9.8.7"
             }
    end

    test "fails closed when a legacy credential kind maps to multiple current methods" do
      profile = CredentialIntegrationFixtures.target_policy_profile()
      username_password = Enum.at(profile["auth_methods"], 1)

      ambiguous_profile =
        Map.put(profile, "auth_methods", [
          Map.put(username_password, "id", "password_primary"),
          Map.put(username_password, "id", "password_secondary")
        ])

      assert {:error, :credential_auth_method_ambiguous} =
               CredentialSecretBuilder.build_rotation(
                 rotatable_secret(%{metadata: %{}}),
                 ambiguous_profile,
                 %{"username" => "new-operator", "password" => "replacement"},
                 []
               )
    end

    test "does not infer over partial or stale explicit descriptor metadata" do
      profile = CredentialIntegrationFixtures.target_policy_profile()
      values = %{"username" => "operator", "password" => "replacement"}

      metadata_cases = [
        %{"credential_descriptor" => "package_manifest.v1"},
        %{"auth_method" => "username_password"},
        %{
          "credential_descriptor" => "package_manifest.v0",
          "auth_method" => "username_password"
        }
      ]

      for metadata <- metadata_cases do
        assert {:error, :credential_descriptor_unavailable} =
                 CredentialSecretBuilder.build_rotation(
                   rotatable_secret(%{metadata: metadata}),
                   profile,
                   values,
                   []
                 )
      end
    end
  end

  defp rotatable_secret(overrides \\ %{}) do
    Map.merge(
      %{
        id: "01900000-0000-7000-8000-000000000001",
        provider: "example-network",
        credential_kind: :username_password,
        source_type: :internal_encrypted,
        rotation_state: :active,
        next_rotation_due_at: nil,
        metadata: %{
          "credential_descriptor" => "package_manifest.v1",
          "auth_method" => "username_password"
        }
      },
      overrides
    )
  end
end
