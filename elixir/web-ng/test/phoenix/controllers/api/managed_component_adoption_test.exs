defmodule ServiceRadarWebNGWeb.Api.ManagedComponentAdoptionTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.ManagedComponentController, as: Controller
  alias ServiceRadarWebNGWeb.Router

  @moduletag :db_free
  @validity {{2026, 1, 1}, {2027, 6, 1}}

  setup do
    scope = %Scope{
      user: %{id: "example-operator"},
      permissions: MapSet.new(["settings.edge.manage"])
    }

    %{conn: assign(build_conn(), :current_scope, scope)}
  end

  test "the adopt route stays on the managed-component API key pipeline" do
    info =
      Phoenix.Router.route_info(Router, "POST", "/api/admin/managed-components/adopt", "localhost")

    assert info.plug == Controller
    assert info.plug_opts == :adopt
    assert info.pipe_through == [:api_key_auth]
  end

  test "refuses adoption without settings.edge.manage before it reads the certificate", %{conn: conn} do
    denied = assign(conn, :current_scope, %Scope{user: %{id: "example-viewer"}, permissions: MapSet.new()})

    assert {:error, :forbidden} = Controller.adopt(denied, private_key_params())
  end

  test "maps a private key and a non-infrastructure type to conflict errors", %{conn: conn} do
    refused = Controller.adopt(conn, private_key_params())
    assert json_response(refused, 409) == %{"error" => "private_key"}

    leaf = Controller.adopt(conn, Map.put(public_params(), "component_type", "nats-leaf"))
    assert json_response(leaf, 409) == %{"error" => "not_infrastructure"}
  end

  defp private_key_params do
    Map.put(public_params(), "certificate_pem", "-----BEGIN PRIVATE KEY-----\nexample\n-----END PRIVATE KEY-----\n")
  end

  defp public_params do
    %{
      "component_id" => "example-gateway",
      "component_type" => "agent-gateway",
      "partition_id" => "example-partition",
      "server_hosts" => ["gateway.example.com"],
      "certificate_pem" => self_signed_pem(),
      "permissions" => %{
        "publish" => %{"allow" => ["metrics.example.>"]},
        "subscribe" => %{"allow" => [], "deny" => ["$SYS.>", "flow.example.>"]}
      }
    }
  end

  defp self_signed_pem do
    %{cert: der} = :public_key.pkix_test_root_cert(~c"example-gateway", validity: @validity)
    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end
end
