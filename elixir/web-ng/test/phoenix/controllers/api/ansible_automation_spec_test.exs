defmodule ServiceRadarWebNGWeb.Api.AnsibleAutomationSpecTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.AnsibleAutomationController, as: Controller
  alias ServiceRadarWebNGWeb.OpenAPI.AdminSpec

  @moduletag :db_free
  @endpoint ServiceRadarWebNGWeb.Endpoint

  test "published document describes review and operation routes without an upstream proxy" do
    spec = served_admin_document()
    assert spec == AdminSpec.document()

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

    upstream =
      Enum.filter(Map.keys(paths), fn path ->
        String.contains?(path, [
          "/ansible-projects",
          "/ansible-inventories",
          "/ansible-inventory-sources",
          "/ansible-execution-environments",
          "/ansible-roles"
        ])
      end)

    assert upstream == []

    for path <- [
          "/api/admin/ansible-projects",
          "/api/admin/ansible-inventories",
          "/api/admin/ansible-inventory-sources",
          "/api/admin/ansible-execution-environments",
          "/api/admin/ansible-roles"
        ] do
      assert {:ok, 404, _body} = http(:get, path)
    end

    IO.puts(
      "ANSIBLE_OPENAPI_EVIDENCE " <>
        Jason.encode!(%{
          openapi: spec["openapi"],
          canonical_device_uid: schemas["AnsibleMembership"]["properties"]["canonical_device_uid"],
          link_evidence_inventory_id: schemas["AnsibleLinkEvidence"]["properties"]["inventory_id"],
          membership_generation: schemas["AnsibleExecutionTarget"]["properties"]["membership_generation"],
          variable_min: schemas["AnsibleOperationVariable"]["properties"]["min"],
          variable_help: schemas["AnsibleOperationVariable"]["properties"]["help"],
          cancel: Map.keys(cancel["responses"]),
          read_human: Enum.map(reads, &String.contains?(&1["description"], "human principal")),
          mutation_human: Enum.map(mutations, &String.contains?(&1["description"], "Requires a human principal"))
        })
    )
  end

  test "anonymous cancel is refused before any job cancellation" do
    assert {:ok, 401, body} =
             http(
               :post,
               "/api/admin/ansible-operations/00000000-0000-4000-8000-000000000453/cancel",
               "{}"
             )

    assert body["error"] == "unauthorized"
    refute body["error"] == "cancellation_not_implemented"
  end

  test "authorized cancel stays unimplemented and reads accept an OAuth client" do
    scope = %Scope{
      user: %{id: "00000000-0000-4000-8000-000000000451"},
      permissions:
        MapSet.new([
          "ansible.runs.launch",
          "ansible.runs.view",
          "ansible.runs.cancel",
          "ansible.catalog.view",
          "ansible.controllers.manage"
        ])
    }

    cancel =
      call(scope, :cancel, %{"id" => "00000000-0000-4000-8000-000000000453"}, oauth: false)

    assert json_response(cancel, 501)["error"] == "cancellation_not_implemented"

    prepare = call(scope, :prepare, %{}, oauth: true)
    assert json_response(prepare, 403)["error"] == "human_principal_required"

    for {action, params, status} <- [
          {:memberships, %{}, 422},
          {:bindings, %{}, 422},
          {:index, %{"state" => "not-a-real-state"}, 422},
          {:show, %{"id" => 0}, 404}
        ] do
      conn = call(scope, action, params, oauth: true)
      body = Jason.decode!(conn.resp_body)
      refute body["error"] == "human_principal_required"
      assert conn.status == status
    end

    IO.puts(
      "ANSIBLE_ROUTE_EVIDENCE " <>
        Jason.encode!(%{
          cancel: cancel.status,
          oauth_prepare: prepare.status,
          oauth_memberships: 422,
          oauth_bindings: 422,
          oauth_operation_list: 422,
          oauth_operation_show: 404
        })
    )
  end

  defp served_admin_document do
    assert {:ok, 200, body} = http(:get, "/api/docs/v1/admin/openapi.json")
    body
  end

  defp http(method, path, body \\ nil) do
    port = listener_port()
    url = String.to_charlist("http://127.0.0.1:#{port}#{path}")
    headers = [{~c"accept", ~c"application/json"}]

    request =
      case method do
        :get -> {url, headers}
        :post -> {url, [{~c"content-type", ~c"application/json"} | headers], ~c"application/json", body}
      end

    {:ok, _} = Application.ensure_all_started(:inets)

    case :httpc.request(method, request, [], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response}} ->
        decoded =
          case Jason.decode(response) do
            {:ok, value} -> value
            _ -> response
          end

        {:ok, status, decoded}

      other ->
        other
    end
  end

  defp listener_port do
    case Process.get(:ansible_openapi_port) do
      port when is_integer(port) ->
        port

      _ ->
        {:ok, pid} =
          Bandit.start_link(
            plug: @endpoint,
            ip: {127, 0, 0, 1},
            port: 0,
            startup_log: false
          )

        {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
        Process.put(:ansible_openapi_port, port)
        port
    end
  end

  defp call(scope, action, params, opts) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> assign(:current_scope, scope)
      |> then(fn conn ->
        if opts[:oauth], do: assign(conn, :oauth_client_id, "synthetic-client"), else: conn
      end)

    Controller.call(%{conn | params: params}, Controller.init(action))
  end

  defp json_response(conn, status) do
    assert conn.status == status
    Jason.decode!(conn.resp_body)
  end
end
