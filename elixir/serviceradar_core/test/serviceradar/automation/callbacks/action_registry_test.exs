defmodule ServiceRadar.Automation.Callbacks.ActionRegistryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Callbacks.ActionRegistry

  @action "remote_access.ssh_ca.bundle.read"
  @version "1.0.0"

  test "the closed registry contains only the reviewed SSH CA bundle read action" do
    assert [%{action: @action, version: @version} = contract] = ActionRegistry.all()
    assert {:ok, ^contract} = ActionRegistry.fetch(@action, @version)

    assert {:error, :action_not_registered} =
             ActionRegistry.fetch("serviceradar.api.proxy", "1.0.0")

    assert {:error, :action_not_registered} = ActionRegistry.fetch(@action, "2.0.0")

    assert contract.effect == :read_only
    assert contract.sensitivity == :target_scoped_internal
    assert contract.target_binding == :exact_execution_snapshot
    assert contract.credential_rule == :short_lived_bearer
    assert contract.max_budget == 1
    assert contract.max_response_bytes == 262_144

    assert contract.required_permissions == [
             "ansible.runs.launch",
             "devices.remote_access.ssh.ca_bundle.read"
           ]

    assert contract.deployment_maximum == %{
             "operations" => ["enroll"],
             "phases" => ["preflight", "stage", "verify", "commit"],
             "states" => ["present"],
             "max_targets" => 100
           }
  end

  test "request schema matches the exact callback body posted by the public collection" do
    assert {:ok, contract} = ActionRegistry.fetch(@action, @version)
    schema = contract.request_schema

    assert schema["additionalProperties"] == false

    assert MapSet.new(schema["required"]) ==
             MapSet.new(~w(action schema_version manifest_sha256 job_id phase operation state))

    assert schema["properties"]["action"] == %{"const" => @action}

    assert schema["properties"]["schema_version"] == %{
             "const" => "serviceradar.remote_access.ssh_ca_bundle/v1"
           }

    assert schema["properties"]["job_id"] == %{"type" => "integer", "minimum" => 1}

    assert schema["properties"]["phase"]["enum"] ==
             ~w(preflight stage verify commit)
  end

  test "response schema is the exact collection envelope, not a simplified parallel format" do
    assert {:ok, contract} = ActionRegistry.fetch(@action, @version)
    schema = contract.response_schema

    assert schema["$id"] == "serviceradar.remote_access.ssh_ca_bundle/v1"
    assert schema["additionalProperties"] == false

    assert schema["required"] ==
             ~w(schema_version action manifest_sha256 job_id phase operation state authorization targets)

    assert schema["properties"]["job_id"] == %{"type" => "integer", "minimum" => 1}

    target = schema["definitions"]["target"]

    assert target["required"] ==
             ~w(inventory_hostname inventory_address target_identity operation phase state ca_keys accounts transaction authorization)

    assert target["properties"]["target_identity"] == %{
             "$ref" => "#/definitions/targetIdentity"
           }

    assert target["properties"]["transaction"] == %{
             "$ref" => "#/definitions/transaction"
           }

    assert target["properties"]["retirement_proof"] == %{"type" => "object"}

    authorization = schema["definitions"]["authorization"]

    assert authorization["required"] ==
             ~w(permissions policy_approved binding_verified)
  end
end
