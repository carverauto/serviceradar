defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "renders the credential rules settings route", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/credentials")

    assert html =~ "Credential Rules"
    assert html =~ "No credential rules found"
  end

  test "creates a credential rule from the settings form", %{conn: conn, scope: scope} do
    secret = credential_secret_fixture(scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    lv
    |> form("form",
      credential_rule: %{
        "name" => "PVE inventory",
        "description" => "",
        "provider" => "proxmox",
        "auth_method" => "proxmox_api_token",
        "purpose" => "inventory_enrichment",
        "target_query" => "in:devices",
        "scope_type" => "agent",
        "scope_value" => "agent-a",
        "secret_id" => secret.id,
        "priority" => "25",
        "allowed_ports" => "8006",
        "tls_policy" => "verify",
        "ssh_host_key_policy" => "known_hosts"
      }
    )
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/credentials")
    assert render(lv) =~ "PVE inventory"
  end

  test "edits and disables a credential rule", %{conn: conn, scope: scope} do
    secret = credential_secret_fixture(scope)
    rule = credential_rule_fixture(scope, secret, %{name: "Original rule"})

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/#{rule.id}/edit")

    lv
    |> form("form",
      credential_rule: %{
        "name" => "Updated rule",
        "description" => "",
        "provider" => "proxmox",
        "auth_method" => "proxmox_api_token",
        "purpose" => "inventory_enrichment",
        "target_query" => "in:devices",
        "scope_type" => "agent",
        "scope_value" => "agent-a",
        "secret_id" => secret.id,
        "priority" => "30",
        "allowed_ports" => "8006",
        "tls_policy" => "verify",
        "ssh_host_key_policy" => "known_hosts"
      }
    )
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/credentials")
    assert render(lv) =~ "Updated rule"

    html =
      lv
      |> element("button[phx-click='disable_rule'][phx-value-id='#{rule.id}']")
      |> render_click()

    assert html =~ "Disabled"
  end

  test "credential test action reports scoped target failures without exposing secrets", %{
    conn: conn,
    scope: scope
  } do
    secret = credential_secret_fixture(scope)
    rule = credential_rule_fixture(scope, secret, %{name: "Testable rule"})

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    html =
      lv
      |> element("button[phx-click='test_rule'][phx-value-id='#{rule.id}']")
      |> render_click()

    assert html =~ "Credential test failed"
    refute html =~ "root@pam!token=secret"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp credential_secret_fixture(scope) do
    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "PVE token #{System.unique_integer([:positive])}",
          provider: "proxmox",
          credential_kind: :api_token,
          username: "root@pam!token",
          public_fingerprint: "sha256:test",
          secret_payload: "root@pam!token=secret",
          metadata: %{}
        },
        scope: scope
      )
      |> Ash.create(scope: scope)

    secret
  end

  defp credential_rule_fixture(scope, secret, attrs) do
    defaults = %{
      name: "PVE rule #{System.unique_integer([:positive])}",
      provider: "proxmox",
      auth_method: :proxmox_api_token,
      purpose: :inventory_enrichment,
      target_query: "in:devices",
      scope_type: :agent,
      scope_value: "agent-a",
      secret_id: secret.id,
      priority: 50,
      allowed_ports: [8006],
      tls_policy: :verify,
      ssh_host_key_policy: :known_hosts,
      metadata: %{}
    }

    {:ok, rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), scope: scope)
      |> Ash.create(scope: scope)

    rule
  end
end
