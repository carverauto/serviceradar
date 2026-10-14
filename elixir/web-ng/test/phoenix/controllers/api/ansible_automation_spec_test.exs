defmodule ServiceRadarWebNGWeb.Api.AnsibleAutomationSpecTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.OpenAPI.AdminSpec

  @moduletag :db_free

  test "published document describes review and operation routes without an upstream proxy" do
    spec = AdminSpec.document()
    paths = spec["paths"]
    schemas = spec["components"]["schemas"]

    approve = paths["/api/admin/ansible-memberships/{id}/approve"]["post"]
    approval = schemas["AnsibleMembershipApproval"]

    assert approval["required"] == [
             "controller_id",
             "inventory_id",
             "awx_host_id",
             "canonical_device_uid",
             "source_generation",
             "source_fingerprint",
             "link_evidence_digest"
           ]

    assert approval["additionalProperties"] == false
    assert approve["requestBody"]["content"]["application/json"]["schema"]["$ref"] =~ "AnsibleMembershipApproval"

    membership_query = paths["/api/admin/ansible-memberships"]["get"]["parameters"]
    assert Enum.map(membership_query, & &1["name"]) == ["controller_id", "inventory_id"]

    launch = paths["/api/admin/ansible-operations"]["post"]
    launch_schema = schemas["AnsibleOperationLaunch"]
    assert launch["responses"]["202"]
    assert launch_schema["required"] == ["device_uids", "playbook_id", "inputs", "mode"]
    refute Map.has_key?(launch_schema["properties"], "extra_vars")
    refute Map.has_key?(launch_schema["properties"], "limit")
    assert launch_schema["additionalProperties"] == false

    prepare = paths["/api/admin/ansible-operations/prepare"]["post"]
    assert schemas["AnsibleOperationPrepare"]["required"] == ["device_uids", "playbook_id"]
    assert prepare["responses"]["200"]

    cancel = paths["/api/admin/ansible-operations/{id}/cancel"]["post"]
    assert cancel["responses"]["501"]
    refute cancel["responses"]["202"]
    assert cancel["responses"]["501"]["content"]["application/json"]["schema"]["$ref"] =~ "Error"

    binding = paths["/api/admin/ansible-template-bindings"]
    assert binding["post"]["responses"]["201"]
    assert paths["/api/admin/ansible-template-bindings/prepare"]["post"]["responses"]["200"]
    assert "expected_review_digest" in schemas["AnsibleBindingCreate"]["required"]
    refute Map.has_key?(schemas["AnsibleBindingPrepare"]["properties"], "reviewed_launch_snapshot")

    membership = schemas["AnsibleMembership"]["properties"]
    assert membership["canonical_device_uid"] == %{"type" => "string", "nullable" => true}
    assert "canonical_device_uid" in schemas["AnsibleMembership"]["required"]
    assert schemas["AnsibleMembershipApproval"]["properties"]["canonical_device_uid"] == %{"type" => "string"}

    evidence = schemas["AnsibleLinkEvidence"]["properties"]
    assert evidence["inventory_id"] == membership["inventory_id"]
    assert evidence["awx_host_id"] == membership["awx_host_id"]
    assert evidence["inventory_id"]["type"] == "integer"
    assert evidence["awx_host_id"]["type"] == "integer"

    generation = schemas["AnsibleExecutionTarget"]["properties"]["membership_generation"]
    assert generation["type"] == "integer"
    assert generation["minimum"] == 1
    refute Map.has_key?(generation, "pattern")

    variable = schemas["AnsibleOperationVariable"]["properties"]
    assert variable["min"] == %{"type" => "number", "nullable" => true}
    assert variable["max"] == %{"type" => "number", "nullable" => true}
    assert variable["help"] == %{"type" => "string", "nullable" => true}

    reads = [
      paths["/api/admin/ansible-memberships"]["get"],
      paths["/api/admin/ansible-template-bindings"]["get"],
      paths["/api/admin/ansible-operations"]["get"],
      paths["/api/admin/ansible-operations/{id}"]["get"]
    ]

    for operation <- reads do
      refute operation["description"] =~ "human principal"
      refute operation["description"] =~ "OAuth clients"
      refute operation["responses"]["403"]["description"] =~ "non-human"
    end

    mutations = [
      approve,
      binding["post"],
      paths["/api/admin/ansible-template-bindings/prepare"]["post"],
      paths["/api/admin/ansible-template-bindings/{id}/revoke"]["post"],
      launch,
      prepare,
      cancel
    ]

    for operation <- mutations do
      assert operation["description"] =~ "Requires a human principal. OAuth clients are rejected."
      assert operation["responses"]["403"]["description"] =~ "non-human principal"
    end
  end
end
