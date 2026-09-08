defmodule ServiceRadarWebNGWeb.Api.NetworkCredentialRuleControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.NetworkCredentialsStub

  setup %{conn: conn} do
    previous = Application.get_env(:serviceradar_web_ng, :network_credentials)
    previous_pid = Application.get_env(:serviceradar_web_ng, :network_credentials_test_pid)

    Application.put_env(:serviceradar_web_ng, :network_credentials, NetworkCredentialsStub)
    Application.put_env(:serviceradar_web_ng, :network_credentials_test_pid, self())

    on_exit(fn ->
      restore_env(:network_credentials, previous)
      restore_env(:network_credentials_test_pid, previous_pid)
    end)

    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn}
  end

  describe "GET /api/admin/network-credential-rules" do
    test "lists rules including TLS and CA fields", %{conn: conn} do
      conn = get(conn, ~p"/api/admin/network-credential-rules")
      body = json_response(conn, 200)

      assert hd(body)["name"] == "demo-proxmox-inventory"
      assert hd(body)["tls_policy"] == "verify"
      assert hd(body)["ca_bundle_pem"] =~ "BEGIN CERTIFICATE"
      assert hd(body)["scope_type"] == "agent"
    end

    test "rejects viewers", %{conn: _conn} do
      viewer = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/admin/network-credential-rules")

      assert conn.status == 403
    end
  end

  describe "POST /api/admin/network-credential-rules" do
    test "creates a rule with CA trust material", %{conn: conn} do
      conn =
        post(conn, ~p"/api/admin/network-credential-rules", %{
          "name" => "demo-proxmox-inventory",
          "provider" => "proxmox",
          "auth_method" => "proxmox_api_token",
          "purpose" => "inventory_enrichment",
          "secret_id" => NetworkCredentialsStub.secret().id,
          "scope_type" => "agent",
          "scope_value" => "agent-site01-01",
          "target_query" => "in:devices metadata.proxmox_candidate:true",
          "tls_policy" => "verify",
          "allowed_ports" => [8006],
          "ca_bundle_pem" => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
        })

      body = json_response(conn, 201)
      assert body["tls_policy"] == "verify"

      assert_receive {:network_credentials_create_rule, attrs, _opts}
      assert attrs[:tls_policy] == :verify
      assert attrs[:ca_bundle_pem] =~ "BEGIN CERTIFICATE"
      assert attrs[:scope_type] == :agent
    end
  end

  describe "POST /api/admin/network-credential-rules/:id/disable" do
    test "disables the rule", %{conn: conn} do
      id = NetworkCredentialsStub.rule().id
      conn = post(conn, ~p"/api/admin/network-credential-rules/#{id}/disable")
      body = json_response(conn, 200)
      assert body["enabled"] == false
      assert_receive {:network_credentials_set_rule_enabled, ^id, false, _opts}
    end
  end

  test "PATCH does not turn convenience inputs into metadata replacements", %{conn: conn} do
    id = NetworkCredentialsStub.rule().id

    conn =
      patch(conn, ~p"/api/admin/network-credential-rules/#{id}", %{
        "controller_host" => "host.example.com"
      })

    assert json_response(conn, 200)
    assert_receive {:network_credentials_update_rule, ^id, attrs, _opts}
    refute Map.has_key?(attrs, :metadata)
  end

  test "PATCH clears explicit trust material", %{conn: conn} do
    id = NetworkCredentialsStub.rule().id

    conn =
      patch(conn, ~p"/api/admin/network-credential-rules/#{id}", %{
        "ca_bundle_pem" => nil,
        "server_cert_fingerprint" => nil
      })

    assert %{"ca_bundle_pem" => nil, "server_cert_fingerprint" => nil} =
             json_response(conn, 200)

    assert_receive {:network_credentials_update_rule, ^id, attrs, _opts}
    assert attrs == %{ca_bundle_pem: nil, server_cert_fingerprint: nil}
  end

  test "PATCH preserves omitted trust material", %{conn: conn} do
    rule = NetworkCredentialsStub.rule()
    conn = patch(conn, ~p"/api/admin/network-credential-rules/#{rule.id}", %{"priority" => 200})
    body = json_response(conn, 200)
    assert body["ca_bundle_pem"] == rule.ca_bundle_pem
    assert_receive {:network_credentials_update_rule, _id, attrs, _opts}
    assert attrs == %{priority: 200}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
