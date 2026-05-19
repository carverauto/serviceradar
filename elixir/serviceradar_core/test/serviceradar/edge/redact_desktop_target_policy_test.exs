defmodule ServiceRadar.Edge.Changes.RedactDesktopTargetPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.Changes.RedactDesktopTargetPolicy

  test "redacts known policy fields while preserving non-secret posture" do
    attrs = %{
      name: "Finance Desktop",
      target_tls: %{
        "mode" => "verify_ca",
        "password" => "tls-password",
        "nested" => %{"private_key" => private_key_fixture()}
      },
      metadata: %{
        "environment" => "lab",
        "api_token" => "PVEAPIToken=root@pam!rdp=secret"
      }
    }

    assert RedactDesktopTargetPolicy.redact_attributes(attrs) == %{
             name: "Finance Desktop",
             target_tls: %{
               "mode" => "verify_ca",
               "password" => "REDACTED",
               "nested" => %{"private_key" => "REDACTED"}
             },
             metadata: %{
               "environment" => "lab",
               "api_token" => "REDACTED"
             }
           }
  end

  test "strips unlisted future fields by default" do
    attrs = %{
      future_secret_blob: %{"safe" => "should-not-pass-through"},
      future_secret_list: [%{"password" => "secret"}],
      future_secret_string: "plain text that should not persist",
      future_secret_flag: true
    }

    assert RedactDesktopTargetPolicy.redacted_change_payload(attrs) == %{
             future_secret_blob: %{"redacted" => true},
             future_secret_list: [],
             future_secret_string: "REDACTED",
             future_secret_flag: nil
           }

    refute inspect(RedactDesktopTargetPolicy.redacted_change_payload(attrs)) =~
             "should-not-pass-through"

    refute inspect(RedactDesktopTargetPolicy.redacted_change_payload(attrs)) =~
             "plain text that should not persist"
  end

  test "change payload only includes attributes that need redaction" do
    assert RedactDesktopTargetPolicy.redacted_change_payload(%{
             name: "Safe Desktop",
             metadata: %{"note" => "safe", "password" => "secret"}
           }) == %{metadata: %{"note" => "safe", "password" => "REDACTED"}}
  end

  defp private_key_fixture do
    "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----"
  end
end
