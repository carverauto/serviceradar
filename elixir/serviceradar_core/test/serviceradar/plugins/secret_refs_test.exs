defmodule ServiceRadar.Plugins.SecretRefsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.SecretRefs

  @schema %{
    "type" => "object",
    "properties" => %{
      "host" => %{"type" => "string"},
      "password_secret_ref" => %{"type" => "string", "secretRef" => true},
      "stream_auth_mode" => %{"type" => "string"}
    }
  }

  setup do
    original = Application.get_env(:serviceradar_core, :crypto_secret)
    Application.put_env(:serviceradar_core, :crypto_secret, String.duplicate("a", 32))

    on_exit(fn ->
      if original do
        Application.put_env(:serviceradar_core, :crypto_secret, original)
      else
        Application.delete_env(:serviceradar_core, :crypto_secret)
      end
    end)

    :ok
  end

  test "stores secret fields as refs plus encrypted material and redacts public params" do
    stored =
      SecretRefs.prepare_params_for_storage(@schema, %{
        "host" => "camera.local",
        "password_secret_ref" => "super-secret"
      })

    assert stored["host"] == "camera.local"
    assert String.starts_with?(stored["password_secret_ref"], "secretref:")
    assert is_map(stored["_secret_material"])
    refute stored["_secret_material"][stored["password_secret_ref"]] == "super-secret"

    assert %{
             "host" => "camera.local",
             "password_secret_ref" => ref
           } = SecretRefs.public_params(stored)

    assert String.starts_with?(ref, "secretref:")
  end

  test "preserves existing secret refs when update leaves field blank" do
    existing =
      SecretRefs.prepare_params_for_storage(@schema, %{
        "password_secret_ref" => "super-secret"
      })

    updated =
      SecretRefs.prepare_params_for_storage(
        @schema,
        %{"host" => "camera.local", "password_secret_ref" => ""},
        existing
      )

    assert updated["password_secret_ref"] == existing["password_secret_ref"]

    assert updated["_secret_material"][existing["password_secret_ref"]] ==
             existing["_secret_material"][existing["password_secret_ref"]]
  end

  test "resolves runtime params by decrypting secret refs" do
    stored =
      SecretRefs.prepare_params_for_storage(@schema, %{
        "host" => "camera.local",
        "password_secret_ref" => "super-secret"
      })

    assert {:ok, runtime} = SecretRefs.resolve_runtime_params(@schema, stored)
    assert runtime["host"] == "camera.local"
    assert runtime["password"] == "super-secret"
    assert runtime["password_secret_ref"] == stored["password_secret_ref"]
    refute Map.has_key?(runtime, "_secret_material")
  end

  test "validates linked secret material for secret refs" do
    assert {:error, [message]} =
             SecretRefs.validate_secret_linkage(@schema, %{
               "password_secret_ref" => "secretref:password:missing"
             })

    assert message =~ "missing linked secret material"
  end

  test "stores and resolves secret refs in plugin input templates" do
    stored =
      SecretRefs.prepare_params_for_storage(
        @schema,
        plugin_inputs_payload(%{
          "host" => "pve.local",
          "password_secret_ref" => "proxmox-token"
        })
      )

    template = stored["template"]
    assert template["host"] == "pve.local"
    assert String.starts_with?(template["password_secret_ref"], "secretref:")
    assert is_map(template["_secret_material"])
    refute template["_secret_material"][template["password_secret_ref"]] == "proxmox-token"

    public = SecretRefs.public_params(stored)
    refute Map.has_key?(public, "_secret_material")
    refute Map.has_key?(public["template"], "_secret_material")

    assert {:ok, runtime} = SecretRefs.resolve_runtime_params(@schema, stored)
    assert runtime["template"]["host"] == "pve.local"
    assert runtime["template"]["password"] == "proxmox-token"
    assert runtime["template"]["password_secret_ref"] == template["password_secret_ref"]
    refute Map.has_key?(runtime["template"], "_secret_material")
  end

  test "validates missing secret material in plugin input templates" do
    params =
      plugin_inputs_payload(%{
        "password_secret_ref" => "secretref:password:missing"
      })

    assert {:error, [message]} = SecretRefs.validate_secret_linkage(@schema, params)
    assert message =~ "template.password_secret_ref is missing linked secret material"
  end

  test "network credential refs are accepted without embedded secret material" do
    secret_id = "018f3f56-1111-7222-8333-123456789abc"
    ref = SecretRefs.network_credential_ref(secret_id)

    assert SecretRefs.secret_ref?(ref)
    assert {:ok, ^secret_id} = SecretRefs.network_credential_secret_ref_id(ref)

    assert :ok =
             SecretRefs.validate_secret_linkage(@schema, %{
               "password_secret_ref" => ref
             })

    assert :ok =
             SecretRefs.validate_secret_linkage(
               @schema,
               plugin_inputs_payload(%{"password_secret_ref" => ref})
             )
  end

  test "network credential grant refs are signed expiring opaque refs" do
    secret_id = "018f3f56-1111-7222-8333-123456789abc"

    ref =
      SecretRefs.network_credential_grant_ref(secret_id,
        ttl_seconds: 60,
        claims: %{
          "session_id" => "session-1",
          "agent_id" => "agent-1",
          "gateway_id" => "gateway-1",
          "protocol" => "ssh"
        }
      )

    assert SecretRefs.secret_ref?(ref)
    assert String.starts_with?(ref, "credentialref:network-credential-grant:")

    assert {:error, "is not a stored network credential reference"} =
             SecretRefs.network_credential_secret_ref_id(ref)

    assert {:ok, ^secret_id} = SecretRefs.network_credential_ref_id(ref)
    assert {:error, "has already been used"} = SecretRefs.network_credential_ref_id(ref)
  end

  test "network credential grant refs reject tampering and expiry" do
    secret_id = "018f3f56-1111-7222-8333-123456789abc"
    ref = SecretRefs.network_credential_grant_ref(secret_id, ttl_seconds: 60)

    [payload, _signature] = String.split(ref, ".", parts: 2)
    tampered = payload <> ".tampered"
    assert {:error, reason} = SecretRefs.network_credential_ref_id(tampered)
    assert reason =~ "invalid network credential grant"

    expired =
      SecretRefs.network_credential_grant_ref(secret_id,
        ttl_seconds: 60,
        expires_at_unix: System.system_time(:second) - 1
      )

    assert {:error, reason} = SecretRefs.network_credential_ref_id(expired)
    assert reason =~ "expired network credential grant"
  end

  defp plugin_inputs_payload(template) do
    %{
      "schema" => "serviceradar.plugin_inputs.v1",
      "policy_id" => "policy-1",
      "policy_version" => 1,
      "agent_id" => "agent-1",
      "generated_at" => "2026-05-06T19:00:00Z",
      "template" => template,
      "inputs" => [
        %{
          "name" => "targets",
          "entity" => "devices",
          "query" => "in:devices",
          "chunk_index" => 0,
          "chunk_total" => 1,
          "chunk_hash" => String.duplicate("a", 64),
          "items" => [%{"uid" => "sr:device:1"}]
        }
      ]
    }
  end

  describe "credential selection" do
    # The settings form renders the credential select AND the raw-entry input
    # together. Two controls sharing one name means the last submitted wins, so
    # the empty password box would clobber a chosen credential every time. The
    # select therefore posts to a sidecar key that gets folded in here.

    defp secret_schema do
      %{
        "type" => "object",
        "properties" => %{
          "api_key_secret_ref" => %{"type" => "string", "secretRef" => true}
        }
      }
    end

    test "a selected credential becomes the field value" do
      ref = SecretRefs.network_credential_ref("11111111-1111-1111-1111-111111111111")

      stored =
        SecretRefs.prepare_params_for_storage(
          secret_schema(),
          %{SecretRefs.credential_select_key("api_key_secret_ref") => ref}
        )

      assert stored["api_key_secret_ref"] == ref
    end

    test "the sidecar key never reaches stored params" do
      ref = SecretRefs.network_credential_ref("22222222-2222-2222-2222-222222222222")

      stored =
        SecretRefs.prepare_params_for_storage(
          secret_schema(),
          %{SecretRefs.credential_select_key("api_key_secret_ref") => ref}
        )

      refute Map.has_key?(stored, SecretRefs.credential_select_key("api_key_secret_ref"))
    end

    test "a blank selection does not clobber an existing value" do
      # This is the regression the sidecar exists to prevent: submitting the form
      # without touching the credential select must leave the field alone.
      existing = %{
        "api_key_secret_ref" =>
          SecretRefs.network_credential_ref("33333333-3333-3333-3333-333333333333")
      }

      stored =
        SecretRefs.prepare_params_for_storage(
          secret_schema(),
          %{SecretRefs.credential_select_key("api_key_secret_ref") => ""},
          existing
        )

      assert stored["api_key_secret_ref"] == existing["api_key_secret_ref"]
    end

    test "a selected credential wins over a blank raw entry" do
      ref = SecretRefs.network_credential_ref("44444444-4444-4444-4444-444444444444")

      stored =
        SecretRefs.prepare_params_for_storage(
          secret_schema(),
          %{
            "api_key_secret_ref" => "",
            SecretRefs.credential_select_key("api_key_secret_ref") => ref
          }
        )

      assert stored["api_key_secret_ref"] == ref
    end
  end
end
