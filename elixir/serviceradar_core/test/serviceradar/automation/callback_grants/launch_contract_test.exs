defmodule ServiceRadar.Automation.CallbackGrants.LaunchContractTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.CallbackGrants.LaunchContract

  test "accepts one exact immutable registry-backed callback contract" do
    assert {:ok, contract} = LaunchContract.from_binding(binding_fixture())

    assert contract == %{
             action: "remote_access.ssh_ca.bundle.read",
             action_version: "1.0.0",
             request_schema: "serviceradar.remote_access.ssh_ca_bundle_request/v1",
             response_schema: "serviceradar.remote_access.ssh_ca_bundle/v1",
             manifest_sha256: String.duplicate("a", 64),
             phase: "stage",
             operation: "enroll",
             state: "present",
             policy_version: "ssh-policy-v1",
             ttl_seconds: 120
           }
  end

  test "rejects unreviewed actions, schema drift, and arbitrary fields" do
    assert {:error, :callback_action_binding_mismatch} =
             binding_fixture()
             |> Map.put(:callback_actions, ["remote_access.ssh_ca.bundle.read", "future.action"])
             |> LaunchContract.from_binding()

    assert {:error, :callback_schema_mismatch} =
             binding_fixture()
             |> put_contract("response_schema", "future.schema/v2")
             |> LaunchContract.from_binding()

    assert {:error, :unexpected_callback_contract_field} =
             binding_fixture()
             |> update_in(
               [:review_metadata, "callback_contract"],
               &Map.put(&1, "url", "https://evil")
             )
             |> LaunchContract.from_binding()
  end

  test "rejects policy, manifest, credential slot, and TTL drift" do
    assert {:error, :callback_policy_version_mismatch} =
             binding_fixture()
             |> put_in([:review_metadata, "policy_version"], "ssh-policy-v2")
             |> LaunchContract.from_binding()

    assert {:error, :invalid_callback_manifest_digest} =
             binding_fixture()
             |> put_contract("manifest_sha256", String.duplicate("A", 64))
             |> LaunchContract.from_binding()

    assert {:error, :callback_credential_slot_mismatch} =
             binding_fixture()
             |> Map.put(:callback_credential_slot, "ordinary_extra_var")
             |> LaunchContract.from_binding()

    assert {:error, :callback_credential_prompt_not_enabled} =
             binding_fixture()
             |> Map.put(:ask_credential_on_launch, false)
             |> LaunchContract.from_binding()

    assert {:error, :callback_ttl_outside_deployment_maximum} =
             binding_fixture()
             |> put_contract("ttl_seconds", 601)
             |> LaunchContract.from_binding()
  end

  test "enforces the action registry deployment maximum" do
    assert {:error, :operation_outside_deployment_maximum} =
             binding_fixture()
             |> put_contract("operation", "remove")
             |> put_contract("state", "absent")
             |> LaunchContract.from_binding()
  end

  defp binding_fixture do
    %{
      callback_actions: ["remote_access.ssh_ca.bundle.read"],
      ask_credential_on_launch: true,
      callback_credential_slot: "ssh_ca_callback",
      review_metadata: %{
        "policy_version" => "ssh-policy-v1",
        "callback_contract" => %{
          "schema" => "serviceradar.automation_callback_launch_contract/v1",
          "action" => "remote_access.ssh_ca.bundle.read",
          "action_version" => "1.0.0",
          "request_schema" => "serviceradar.remote_access.ssh_ca_bundle_request/v1",
          "response_schema" => "serviceradar.remote_access.ssh_ca_bundle/v1",
          "manifest_sha256" => String.duplicate("a", 64),
          "phase" => "stage",
          "operation" => "enroll",
          "state" => "present",
          "policy_version" => "ssh-policy-v1",
          "ttl_seconds" => 120
        }
      }
    }
  end

  defp put_contract(binding, key, value) do
    put_in(binding, [:review_metadata, "callback_contract", key], value)
  end
end
