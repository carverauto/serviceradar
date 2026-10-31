defmodule ServiceRadarWebNGWeb.Api.ManagedComponentAdoptionTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.ManagedComponentController, as: Controller
  alias ServiceRadarWebNGWeb.Auth.NarrowScopes
  alias ServiceRadarWebNGWeb.Router

  @moduletag :db_free
  @validity {{2026, 1, 1}, {2027, 6, 1}}
  @fingerprint "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

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

  test "the successor route stays on the managed-component API key pipeline" do
    info =
      Phoenix.Router.route_info(
        Router,
        "POST",
        "/api/admin/managed-components/example-gateway/certificates",
        "localhost"
      )

    assert info.plug == Controller
    assert info.plug_opts == :record_successor
    assert info.pipe_through == [:api_key_auth]
  end

  test "refuses a successor without settings.edge.manage before it reads the certificate", %{
    conn: conn
  } do
    denied =
      assign(conn, :current_scope, %Scope{user: %{id: "example-viewer"}, permissions: MapSet.new()})

    assert {:error, :forbidden} =
             Controller.record_successor(denied, Map.put(private_key_params(), "id", "example-gateway"))
  end

  test "maps a successor private key to a conflict error", %{conn: conn} do
    refused =
      Controller.record_successor(conn, Map.put(private_key_params(), "id", "example-gateway"))

    assert json_response(refused, 409) == %{"error" => "private_key"}
  end

  test "a narrow edge.manage token cannot record a successor certificate" do
    refute NarrowScopes.allowed?(
             ["edge.manage"],
             "POST",
             "/api/admin/managed-components/example-gateway/certificates"
           )
  end

  test "the fingerprint revoke route stays on the managed-component API key pipeline" do
    info =
      Phoenix.Router.route_info(
        Router,
        "POST",
        "/api/admin/managed-components/example-gateway/certificates/#{@fingerprint}/revoke",
        "localhost"
      )

    assert info.plug == Controller
    assert info.plug_opts == :revoke_certificate
    assert info.pipe_through == [:api_key_auth]
  end

  test "refuses fingerprint revocation without settings.edge.manage", %{conn: conn} do
    denied =
      assign(conn, :current_scope, %Scope{user: %{id: "example-viewer"}, permissions: MapSet.new()})

    assert {:error, :forbidden} =
             Controller.revoke_certificate(denied, %{"id" => "example-gateway", "fingerprint" => @fingerprint})
  end

  test "a narrow edge.manage token cannot revoke one certificate fingerprint" do
    refute NarrowScopes.allowed?(
             ["edge.manage"],
             "POST",
             "/api/admin/managed-components/example-gateway/certificates/#{@fingerprint}/revoke"
           )
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
