defmodule ServiceRadar.Automation.Ansible.FileCallbackResponsePolicyProviderTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.CallbackResponsePolicy
  alias ServiceRadar.Automation.Ansible.FileCallbackResponsePolicyProvider

  @now ~U[2026-07-13 02:00:00.000000Z]
  @expires_at ~U[2026-07-13 03:00:00.000000Z]

  defmodule RawProvider do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.CallbackResponsePolicyProvider

    @impl true
    def snapshot(_context), do: Process.get(:raw_callback_response_policy)
  end

  test "materializes only reviewed public policy for the exact immutable target tuple" do
    context = context()

    assert {:ok, %{"targets" => [target]}} =
             FileCallbackResponsePolicyProvider.snapshot_document(document(), context)

    assert target["inventory_hostname"] == "linux-01"
    assert target["inventory_address"] == "192.168.2.22"
    assert target["target_identity"] == hd(context.targets)["target_identity"]
    assert target["ca_keys"] == [ca_key()]
    assert target["accounts"] == [account()]

    refute Map.has_key?(target, "signer_key_id")
    refute inspect(target) =~ "private"
    refute inspect(target) =~ "password"
    refute inspect(target) =~ "token"
  end

  test "does not use hostname or address as policy selectors" do
    context =
      update_in(context().targets, fn [target] ->
        [
          target
          |> Map.put("inventory_hostname", "renamed-by-current-membership")
          |> Map.put("inventory_address", "10.10.10.10")
        ]
      end)

    assert {:ok, %{"targets" => [target]}} =
             FileCallbackResponsePolicyProvider.snapshot_document(document(), context)

    assert target["inventory_hostname"] == "renamed-by-current-membership"
    assert target["inventory_address"] == "10.10.10.10"
  end

  test "fails closed for tuple drift, disabled policy, and expired review" do
    tuple_drift = put_in(context().targets, [target(%{"awx_host_id" => 101})])

    assert {:error, :callback_response_target_scope_mismatch} =
             FileCallbackResponsePolicyProvider.snapshot_document(document(), tuple_drift)

    disabled = put_in(document(), ["policies", Access.at(0), "enabled"], false)

    assert {:error, :callback_response_policy_not_ready} =
             FileCallbackResponsePolicyProvider.snapshot_document(disabled, context())

    expired = put_in(context().now, DateTime.add(@expires_at, 1))

    assert {:error, :callback_response_policy_not_ready} =
             FileCallbackResponsePolicyProvider.snapshot_document(document(), expired)
  end

  test "rejects unverified CA keys, private fields, and reusable credentials" do
    wrong_fingerprint =
      put_in(
        document(),
        ["policies", Access.at(0), "ca_keys", Access.at(0), "fingerprint"],
        "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      )

    assert {:error, :invalid_callback_response_policy_document} =
             FileCallbackResponsePolicyProvider.snapshot_document(wrong_fingerprint, context())

    private_key =
      put_in(
        document(),
        ["policies", Access.at(0), "ca_keys", Access.at(0), "private_key"],
        "forbidden"
      )

    assert {:error, :invalid_callback_response_policy_document} =
             FileCallbackResponsePolicyProvider.snapshot_document(private_key, context())

    bearer =
      put_in(
        document(),
        ["policies", Access.at(0), "targets", Access.at(0), "transaction", "api_token"],
        "forbidden"
      )

    assert {:error, :invalid_callback_response_policy_document} =
             FileCallbackResponsePolicyProvider.snapshot_document(bearer, context())
  end

  test "requires every target trust set to include the declared active signer key" do
    old_key = ca_key("ca-old", :binary.copy(<<8>>, 32))

    missing_signer =
      document()
      |> put_in(["policies", Access.at(0), "ca_keys"], [ca_key(), old_key])
      |> put_in(
        ["policies", Access.at(0), "targets", Access.at(0), "ca_key_ids"],
        ["ca-old"]
      )

    assert {:error, :invalid_callback_response_policy_document} =
             FileCallbackResponsePolicyProvider.snapshot_document(missing_signer, context())
  end

  test "wrapper rejects broader provider output and exact-scope substitution" do
    {:ok, snapshot} =
      FileCallbackResponsePolicyProvider.snapshot_document(document(), context())

    Process.put(:raw_callback_response_policy, {:ok, Map.put(snapshot, "credential", "secret")})

    assert {:error, :invalid_callback_response_policy_snapshot} =
             CallbackResponsePolicy.snapshot(context(), provider: RawProvider)

    substituted = put_in(snapshot, ["targets", Access.at(0), "inventory_address"], "10.0.0.9")
    Process.put(:raw_callback_response_policy, {:ok, substituted})

    assert {:error, :callback_response_target_scope_mismatch} =
             CallbackResponsePolicy.snapshot(context(), provider: RawProvider)

    Process.put(:raw_callback_response_policy, {:ok, snapshot})

    assert {:ok, %{targets: [_target], digest: digest}} =
             CallbackResponsePolicy.snapshot(context(), provider: RawProvider)

    assert byte_size(digest) == 64
  end

  defp document do
    %{
      "schema" => "serviceradar.automation.callback_response_policy/v1",
      "policies" => [
        %{
          "enabled" => true,
          "action" => "remote_access.ssh_ca.bundle.read",
          "action_version" => "1.0.0",
          "policy_version" => "ssh-policy-v3",
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
            "expires_at" => DateTime.to_iso8601(@expires_at)
          },
          "signer_key_id" => "ca-main",
          "ca_keys" => [ca_key()],
          "targets" => [
            %{
              "state" => "ready",
              "target_identity" => target_identity(),
              "ca_key_ids" => ["ca-main"],
              "accounts" => [account()],
              "transaction" => %{
                "generation" => "generation-7",
                "machine_credential_ref" => "awx-credential-ref:5"
              }
            }
          ]
        }
      ]
    }
  end

  defp context do
    %{
      action: "remote_access.ssh_ca.bundle.read",
      action_version: "1.0.0",
      policy_version: "ssh-policy-v3",
      tenant_id: "platform",
      controller_id: "controller-farm01",
      inventory_id: 34,
      job_template_id: 42,
      binding_id: "binding-7",
      binding_version: 7,
      approval_id: "approval-8",
      approval_expires_at: @expires_at,
      reviewed_by_principal_type: :human,
      reviewed_by_principal_id: "reviewer-1",
      reviewed_at: ~U[2026-07-13 01:00:00.000000Z],
      scm_revision: String.duplicate("a", 40),
      content_sha256: String.duplicate("b", 64),
      now: @now,
      targets: [target()]
    }
  end

  defp target(overrides \\ %{}) do
    %{
      "inventory_hostname" => "linux-01",
      "inventory_address" => "192.168.2.22",
      "target_identity" => Map.merge(target_identity(), overrides)
    }
  end

  defp target_identity do
    %{
      "controller_id" => "controller-farm01",
      "inventory_id" => 34,
      "awx_host_id" => 100,
      "canonical_device_uid" => "device:linux-01"
    }
  end

  defp account do
    %{
      "name" => "mfreeman",
      "principals" => ["srp_v1_0123456789abcdefghijklmnop"]
    }
  end

  defp ca_key(id \\ "ca-main", key_bytes \\ :binary.copy(<<7>>, 32)) do
    type = "ssh-ed25519"
    blob = <<byte_size(type)::32, type::binary, byte_size(key_bytes)::32, key_bytes::binary>>

    %{
      "id" => id,
      "public_key" => type <> " " <> Base.encode64(blob),
      "fingerprint" => "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)
    }
  end
end
