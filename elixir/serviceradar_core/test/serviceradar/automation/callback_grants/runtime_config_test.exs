defmodule ServiceRadar.Automation.CallbackGrants.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.FileCallbackResponsePolicyProvider
  alias ServiceRadar.Automation.CallbackGrants.RuntimeConfig

  test "decodes an exact bounded rotating keyring" do
    key = :crypto.strong_rand_bytes(32)

    assert {:ok, config} =
             RuntimeConfig.verifier_config(%{
               "active_key_id" => "callback-v2",
               "keys" => %{
                 "callback-v1" => Base.encode64(:crypto.strong_rand_bytes(32)),
                 "callback-v2" => Base.encode64(key)
               }
             })

    assert config[:active_key_id] == "callback-v2"
    assert config[:keys]["callback-v2"] == key
  end

  test "rejects inline ambiguity, short keys, and absent active keys" do
    valid_key = Base.encode64(:crypto.strong_rand_bytes(32))

    assert {:error, :invalid_verifier_config} =
             RuntimeConfig.verifier_config(%{
               "active_key_id" => "callback-v1",
               "keys" => %{"callback-v1" => valid_key},
               "unexpected" => true
             })

    assert {:error, :invalid_verifier_config} =
             RuntimeConfig.verifier_config(%{
               "active_key_id" => "callback-v1",
               "keys" => %{"callback-v1" => Base.encode64("short")}
             })

    assert {:error, :invalid_verifier_config} =
             RuntimeConfig.verifier_config(%{
               "active_key_id" => "callback-v2",
               "keys" => %{"callback-v1" => valid_key}
             })
  end

  test "keeps callback deployment explicitly disabled without placeholder IDs" do
    assert :disabled =
             RuntimeConfig.callback_deployment_config!(%{
               enabled: false,
               credential_type_id: 0,
               organization_id: 0,
               injector_digest: "",
               response_policy_file: ""
             })
  end

  @tag :tmp_dir
  test "accepts only a complete enabled callback deployment", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "response-policy.json")
    File.write!(path, Jason.encode!(response_policy_document()))
    File.chmod!(path, 0o600)

    assert %{
             credential_contract: [
               credential_type_id: 91,
               organization_id: 2,
               injector_digest: injector_digest
             ],
             response_policy_provider: FileCallbackResponsePolicyProvider,
             response_policy_provider_config: [path: ^path]
           } =
             RuntimeConfig.callback_deployment_config!(%{
               enabled: true,
               credential_type_id: "91",
               organization_id: 2,
               injector_digest: String.duplicate("c", 64),
               response_policy_file: path
             })

    assert injector_digest == String.duplicate("c", 64)

    assert_raise RuntimeError,
                 "invalid enabled automation callback deployment configuration",
                 fn ->
                   RuntimeConfig.callback_deployment_config!(%{
                     enabled: true,
                     credential_type_id: 0,
                     organization_id: 2,
                     injector_digest: String.duplicate("c", 64),
                     response_policy_file: path
                   })
                 end

    File.chmod!(path, 0o604)

    assert_raise RuntimeError,
                 "invalid enabled automation callback deployment configuration",
                 fn ->
                   RuntimeConfig.callback_deployment_config!(%{
                     enabled: true,
                     credential_type_id: 91,
                     organization_id: 2,
                     injector_digest: String.duplicate("c", 64),
                     response_policy_file: path
                   })
                 end
  end

  @tag :tmp_dir
  test "loads only a bounded non-world-readable keyring file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "callback-keyring.json")

    document = %{
      "active_key_id" => "callback-v1",
      "keys" => %{"callback-v1" => Base.encode64(:crypto.strong_rand_bytes(32))}
    }

    File.write!(path, Jason.encode!(document))
    File.chmod!(path, 0o600)
    assert RuntimeConfig.load_verifier_file!(path)[:active_key_id] == "callback-v1"

    File.chmod!(path, 0o604)

    assert_raise RuntimeError, "invalid automation callback HMAC keyring file", fn ->
      RuntimeConfig.load_verifier_file!(path)
    end
  end

  @tag :tmp_dir
  test "loads a distinct envelope key only from a securely owned file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "launch-envelope-key")
    key = :crypto.strong_rand_bytes(32)

    File.write!(path, Base.encode64(key))
    File.chmod!(path, 0o640)
    assert RuntimeConfig.load_envelope_key_file!(path) == key

    File.chmod!(path, 0o660)

    assert_raise RuntimeError, "invalid automation callback launch-envelope key file", fn ->
      RuntimeConfig.load_envelope_key_file!(path)
    end

    File.chmod!(path, 0o600)
    File.write!(path, Base.encode64("short"))

    assert_raise RuntimeError, "invalid automation callback launch-envelope key file", fn ->
      RuntimeConfig.load_envelope_key_file!(path)
    end
  end

  test "canonicalizes only a bare HTTPS callback origin" do
    assert {:ok, "https://demo.example.com"} =
             RuntimeConfig.canonical_callback_origin(" HTTPS://Demo.Example.COM ")

    assert {:ok, "https://demo.example.com:8443"} =
             RuntimeConfig.canonical_callback_origin("https://demo.example.com:8443")

    for rejected <- [
          "http://demo.example.com",
          "https://user@demo.example.com",
          "https://demo.example.com/",
          "https://demo.example.com/callback",
          "https://demo.example.com?target=other",
          "https://demo.example.com#fragment"
        ] do
      assert {:error, :automation_callback_origin_unavailable} =
               RuntimeConfig.canonical_callback_origin(rejected)
    end
  end

  defp response_policy_document do
    %{
      "schema" => "serviceradar.automation.callback_response_policy/v1",
      "policies" => [
        %{
          "enabled" => true,
          "action" => "remote_access.ssh_ca.bundle.read",
          "action_version" => "1.0.0",
          "policy_version" => "ssh-policy-v1",
          "scope" => %{
            "tenant_id" => "platform",
            "controller_id" => "controller-farm01",
            "inventory_id" => 34,
            "job_template_id" => 42,
            "binding_id" => "binding-7",
            "binding_version" => 7,
            "approval_id" => "approval-8",
            "scm_revision" => String.duplicate("a", 40),
            "content_sha256" => String.duplicate("b", 64)
          },
          "review" => %{
            "state" => "approved",
            "reviewed_by_principal_type" => "human",
            "reviewed_by_principal_id" => "reviewer-1",
            "reviewed_at" => "2026-07-13T01:00:00.000000Z",
            "expires_at" => "2026-07-13T03:00:00.000000Z"
          },
          "signer_key_id" => "ca-main",
          "ca_keys" => [ca_key()],
          "targets" => [
            %{
              "state" => "ready",
              "target_identity" => %{
                "controller_id" => "controller-farm01",
                "inventory_id" => 34,
                "awx_host_id" => 100,
                "canonical_device_uid" => "device:linux-01"
              },
              "ca_key_ids" => ["ca-main"],
              "accounts" => [
                %{
                  "name" => "mfreeman",
                  "principals" => ["srp_v1_0123456789abcdefghijklmnop"]
                }
              ],
              "transaction" => %{}
            }
          ]
        }
      ]
    }
  end

  defp ca_key do
    type = "ssh-ed25519"
    key_bytes = :binary.copy(<<7>>, 32)
    blob = <<byte_size(type)::32, type::binary, byte_size(key_bytes)::32, key_bytes::binary>>

    %{
      "id" => "ca-main",
      "public_key" => type <> " " <> Base.encode64(blob),
      "fingerprint" => "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)
    }
  end
end
