defmodule ServiceRadarWebNGWeb.Api.ManagedComponentAdoptionDbTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.ManagedComponentController, as: Controller

  @moduletag :web_ng_shared_fixture_db
  @validity {{2026, 1, 1}, {2027, 6, 1}}

  test "returns the projected grant and leaves the certificate pem out of the response", %{conn: conn} do
    %{pem: pem, der: der} = self_signed()
    id = "example-gateway-#{System.unique_integer([:positive])}"

    conn =
      conn
      |> assign(:current_scope, operator_scope())
      |> Controller.adopt(params(id, pem))

    refute conn.resp_body =~ "BEGIN CERTIFICATE"
    body = json_response(conn, 201)
    data = body["data"]

    assert data["component_id"] == id
    assert data["service"] == "agent-gateway"
    assert data["host_agent_id"] == nil
    assert data["partition_id"] == "example-partition"
    assert data["generation"] == 1
    assert data["blocked"] == false
    assert data["server_hosts"] == ["gateway.example.com"]
    assert data["nats_permissions"]["publish"] == ["metrics.example.>"]
    assert data["nats_permissions"]["publish_deny"] == []
    assert data["nats_permissions"]["subscribe"] == [">"]
    assert data["nats_permissions"]["subscribe_deny"] == ["$SYS.>", "flow.example.>"]
    assert data["certificate"]["fingerprint"] == fingerprint(der)
    assert data["certificate"]["issuer_fingerprint"] == data["certificate"]["fingerprint"]
    assert data["certificate"]["role"] == "client"
    assert String.starts_with?(data["certificate"]["not_before"], "2026-01-01T13:00:00")
    assert String.starts_with?(data["certificate"]["not_after"], "2027-06-01T13:00:00")
    refute Map.has_key?(data, "certificate_pem")

    assert {:ok, stored} = Ash.get(ManagedComponent, id, scope: operator_scope())
    assert stored.generation_started_by == "example-operator"
    assert stored.nats_permissions["subscribe"] == [">"]
  end

  defp operator_scope do
    %Scope{
      user: %{id: "example-operator", role: :operator},
      permissions: MapSet.new(["settings.edge.manage"])
    }
  end

  defp params(id, pem) do
    %{
      "component_id" => id,
      "component_type" => "agent-gateway",
      "partition_id" => "example-partition",
      "server_hosts" => ["gateway.example.com"],
      "certificate_pem" => pem,
      "permissions" => %{
        "publish" => %{"allow" => ["metrics.example.>"], "deny" => []},
        "subscribe" => %{"allow" => [], "deny" => ["$SYS.>", "flow.example.>"]}
      }
    }
  end

  defp self_signed do
    %{cert: der} = :public_key.pkix_test_root_cert(~c"example-gateway", validity: @validity)

    %{
      der: der,
      pem: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    }
  end

  defp fingerprint(der), do: :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower)
end
