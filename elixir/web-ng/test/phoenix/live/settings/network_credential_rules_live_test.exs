defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query

  defmodule FakeCredentialRulePreviewResolver do
    @moduledoc false

    def resolve(input_defs, _opts) do
      rows_by_query =
        Application.get_env(
          :serviceradar_web_ng,
          :network_credential_rule_preview_rows,
          %{}
        )

      {:ok,
       Enum.map(input_defs, fn input_def ->
         query = input_def.query

         %{
           name: input_def.name,
           entity: input_def.entity,
           query: query,
           rows: Map.get(rows_by_query, query, [])
         }
       end)}
    end
  end

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
        "ssh_host_key_policy" => "known_hosts",
        "auto_discovery_enabled" => "true"
      }
    )
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/credentials")
    html = render(lv)
    assert html =~ "PVE inventory"
    assert html =~ "Auto"

    rule = get_rule_by_name!(scope, "PVE inventory")
    assert rule.target_query == "in:devices"
    assert rule.metadata["auto_discovery_enabled"] == true
  end

  test "creates a Proxmox token secret from the provider preset", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    assert lv
           |> element("button[phx-click='new_proxmox_secret']")
           |> render_click() =~ "New Proxmox Token"

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "name" => "Lab PVE token",
          "description" => "Lab cluster",
          "user" => "root",
          "realm" => "pam",
          "token_id" => "serviceradar",
          "tls_policy" => "verify",
          "token_secret" => "super-secret-token"
        }
      )
      |> render_submit()

    assert html =~ "Proxmox token saved"
    refute html =~ "super-secret-token"

    secret = get_secret_by_name!(scope, "Lab PVE token")
    assert secret.provider == "proxmox"
    assert secret.credential_kind == :api_token
    assert secret.username == "root@pam!serviceradar"
    assert secret.public_fingerprint =~ "sha256:"
    assert secret.metadata["realm"] == "pam"
    assert secret.metadata["token_id"] == "serviceradar"
    assert secret.metadata["tls_policy"] == "verify"
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
        "ssh_host_key_policy" => "known_hosts",
        "auto_discovery_enabled" => "false"
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

  test "previews SRQL target scope and agent distribution", %{conn: conn, scope: scope} do
    previous_resolver =
      Application.get_env(:serviceradar_web_ng, :network_credential_rule_preview_resolver)

    previous_rows = Application.get_env(:serviceradar_web_ng, :network_credential_rule_preview_rows)

    Application.put_env(
      :serviceradar_web_ng,
      :network_credential_rule_preview_resolver,
      FakeCredentialRulePreviewResolver
    )

    Application.put_env(:serviceradar_web_ng, :network_credential_rule_preview_rows, %{
      "in:devices protocol:proxmox-api" => [
        %{"uid" => "device-1", "hostname" => "pve-a", "ip" => "192.0.2.10", "agent_id" => "agent-a"},
        %{"uid" => "device-2", "hostname" => "pve-b", "ip" => "192.0.2.11", "agent_id" => "agent-a"},
        %{"uid" => "device-3", "hostname" => "pve-c", "ip" => "192.0.2.12", "agent_id" => "agent-b"}
      ]
    })

    on_exit(fn ->
      restore_env(:network_credential_rule_preview_resolver, previous_resolver)
      restore_env(:network_credential_rule_preview_rows, previous_rows)
    end)

    secret = credential_secret_fixture(scope)
    rule = credential_rule_fixture(scope, secret, %{target_query: "in:devices protocol:proxmox-api"})

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    html =
      lv
      |> element("button[phx-click='preview_rule'][phx-value-id='#{rule.id}']")
      |> render_click()

    assert html =~ "Target Preview"
    assert html =~ "3"
    assert html =~ "2"
    assert html =~ "agent-a"
    assert html =~ "pve-a"
    assert html =~ "192.0.2.10"
    refute html =~ "pve-c"
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

  defp get_rule_by_name!(scope, name) do
    NetworkCredentialRule
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(name == ^name)
    |> Ash.read!(scope: scope)
    |> List.first()
  end

  defp get_secret_by_name!(scope, name) do
    NetworkCredentialSecret
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(name == ^name)
    |> Ash.read!(scope: scope)
    |> List.first()
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
