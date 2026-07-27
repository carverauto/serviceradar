defmodule ServiceRadar.Credentials.CredentialParameterTemplateTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialParameterTemplate

  test "validates and renders only bounded public context sources" do
    template = %{
      "credential_broker" => %{"$source" => "grant"},
      "credential_secret_ref" => %{"$source" => "secret_ref"},
      "credential_rule_id" => %{"$source" => "rule", "field" => "id"},
      "verify_tls" => %{
        "$source" => "rule",
        "field" => "tls_policy",
        "equals" => "verify"
      },
      "endpoint" => %{
        "$source" => "metadata_first",
        "keys" => ["controller_url", "host"],
        "normalize" => "hostname"
      },
      "timeout_ms" => %{
        "$source" => "metadata",
        "key" => "timeout_ms",
        "type" => "integer",
        "default" => 30_000
      },
      "username" => %{"$source" => "public_username", "omit_if_blank" => true}
    }

    assert {:ok, normalized} = CredentialParameterTemplate.validate(template)

    context = %{
      grant: %{"grant_id" => "grant-1"},
      secret_ref: "credentialref:network-credential-secret:secret-1",
      public_username: nil,
      rule: %{
        id: "rule-1",
        tls_policy: "verify",
        metadata: %{
          "controller_url" => "https://controller.example.test:8443/path",
          "timeout_ms" => "45000"
        }
      }
    }

    assert {:ok, rendered} = CredentialParameterTemplate.render(normalized, context)

    assert rendered == %{
             "credential_broker" => %{"grant_id" => "grant-1"},
             "credential_secret_ref" => "credentialref:network-credential-secret:secret-1",
             "credential_rule_id" => "rule-1",
             "endpoint" => "controller.example.test",
             "timeout_ms" => 45_000,
             "verify_tls" => true
           }

    refute Map.has_key?(rendered, "username")
  end

  test "does not expose a source for plaintext credential values" do
    assert {:error, errors} =
             CredentialParameterTemplate.validate(%{
               "password" => %{"$source" => "secret_payload"}
             })

    assert Enum.any?(errors, &String.contains?(&1, "contains an unsupported value"))

    assert {:error, errors} =
             CredentialParameterTemplate.validate(%{
               "token" => %{"$source" => "secret_ref", "field" => "plaintext"}
             })

    assert Enum.any?(errors, &String.contains?(&1, "is not allowed"))
  end

  test "rejects excessive nesting and collection sizes" do
    nested =
      Enum.reduce(1..10, %{"value" => true}, fn index, acc ->
        %{"level#{index}" => acc}
      end)

    assert {:error, depth_errors} = CredentialParameterTemplate.validate(nested)
    assert Enum.any?(depth_errors, &String.contains?(&1, "maximum nesting depth"))

    oversized = Map.new(1..129, &{"field#{&1}", &1})
    assert {:error, [collection_error]} = CredentialParameterTemplate.validate(oversized)
    assert collection_error =~ "too many entries"
  end

  test "detects grant references without interpreting unrelated values" do
    assert CredentialParameterTemplate.references_source?(
             %{"nested" => [%{"$source" => "grant"}]},
             "grant"
           )

    refute CredentialParameterTemplate.references_source?(
             %{"literal" => "grant", "source" => "$source"},
             "grant"
           )
  end
end
