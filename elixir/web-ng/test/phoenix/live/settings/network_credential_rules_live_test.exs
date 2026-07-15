defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Credentials.CredentialUsePolicy
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.Plugins.Packages

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
    assert html =~ "Read the Proxmox setup guide"
    assert html =~ "UniFi Protect"
    refute html =~ "New Console SSH Key"
    refute html =~ "New Console Rule"
    assert html =~ "No credential rules found"
  end

  test "viewer is blocked from credential rules settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/networks/credentials")
    assert to == ~p"/settings/profile"
  end

  test "creates a credential rule from the settings form", %{conn: conn, scope: scope} do
    secret = credential_secret_fixture(scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    lv
    |> form("#credential-rule-form",
      credential_rule: %{
        "name" => "PVE inventory",
        "description" => "",
        "provider" => "proxmox",
        "auth_method" => "proxmox_api_token",
        "purposes" => ["inventory_enrichment"],
        "target_query" => "in:devices",
        "scope_type" => "agent",
        "scope_value" => "agent-a",
        "secret_id" => secret.id,
        "priority" => "25",
        "allowed_ports" => "8006",
        "tls_policy" => "verify",
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

  test "creates an explicit console actor-use policy from the settings form", %{
    conn: conn,
    scope: scope
  } do
    secret = credential_secret_fixture(scope)

    {:ok, lv, html} = live(conn, ~p"/settings/networks/credentials/new")

    assert html =~ "Console credential users"
    assert html =~ ~s(name="credential_rule[credential_use_roles]")
    assert html =~ ~s(value="admin")

    lv
    |> form("#credential-rule-form",
      credential_rule: %{
        "name" => "PVE console",
        "description" => "",
        "provider" => "proxmox",
        "auth_method" => "proxmox_api_token",
        "purposes" => ["inventory_enrichment", "console_access"],
        "target_query" => "in:devices",
        "scope_type" => "agent",
        "scope_value" => "agent-a",
        "secret_id" => secret.id,
        "priority" => "25",
        "allowed_ports" => "8006",
        "tls_policy" => "verify",
        "credential_use_roles" => "admin, operator",
        "credential_use_principals" => "oidc|pve-user",
        "credential_use_groups" => "pve-console-operators",
        "auto_discovery_enabled" => "false"
      }
    )
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/credentials")

    rule = get_rule_by_name!(scope, "PVE console")

    assert rule.metadata["credential_use_policy"] == %{
             "schema" => CredentialUsePolicy.schema(),
             "roles" => ["admin", "operator"],
             "principals" => ["oidc|pve-user"],
             "groups" => ["pve-console-operators"]
           }
  end

  test "rejects console rules without an actor-use selector", %{conn: conn, scope: scope} do
    secret = credential_secret_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule: %{
          "name" => "Unrestricted console",
          "description" => "",
          "provider" => "proxmox",
          "auth_method" => "proxmox_api_token",
          "purposes" => ["console_access"],
          "target_query" => "in:devices",
          "scope_type" => "agent",
          "scope_value" => "agent-a",
          "secret_id" => secret.id,
          "priority" => "25",
          "allowed_ports" => "8006",
          "tls_policy" => "verify",
          "credential_use_roles" => "",
          "credential_use_principals" => "",
          "credential_use_groups" => "",
          "auto_discovery_enabled" => "false"
        }
      )
      |> render_submit()

    assert html =~ "Console access requires at least one allowed role, user, or IdP group"
    refute get_rule_by_name!(scope, "Unrestricted console")
  end

  test "rejects Proxmox API rules that disable TLS certificate verification", %{
    conn: conn,
    scope: scope
  } do
    secret = credential_secret_fixture(scope)
    {:ok, lv, html} = live(conn, ~p"/settings/networks/credentials/new")

    refute html =~ ~s(<option value="skip_verify">)

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule: %{
          "name" => "Insecure PVE",
          "provider" => "proxmox",
          "auth_method" => "proxmox_api_token",
          "purposes" => ["inventory_enrichment"],
          "target_query" => "in:devices",
          "scope_type" => "agent",
          "scope_value" => "agent-a",
          "secret_id" => secret.id,
          "priority" => "25",
          "allowed_ports" => "8006",
          "tls_policy" => "skip_verify"
        }
      )
      |> render_submit()

    assert html =~ "Proxmox API access requires TLS certificate verification"
    refute get_rule_by_name!(scope, "Insecure PVE")
  end

  test "validates required credential rule fields", %{conn: conn, scope: scope} do
    secret = credential_secret_fixture(scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule: %{
          "name" => "",
          "description" => "",
          "provider" => "proxmox",
          "auth_method" => "proxmox_api_token",
          "purposes" => ["inventory_enrichment"],
          "target_query" => "in:devices metadata.proxmox_candidate:true",
          "scope_type" => "agent",
          "scope_value" => "agent-a",
          "secret_id" => secret.id,
          "priority" => "25",
          "allowed_ports" => "8006",
          "tls_policy" => "verify",
          "auto_discovery_enabled" => "false"
        }
      )
      |> render_submit()

    assert html =~ "Required fields are missing"
    refute get_rule_by_name!(scope, "")
  end

  test "agent scope value uses active agent dropdown and gateway scope uses freeform input", %{
    conn: conn
  } do
    gateway = gateway_fixture(%{id: "credential-gw", component_id: "credential-component"})
    agent_fixture(gateway, %{uid: "agent-a", name: "Agent A"})

    stale_agent = agent_fixture(gateway, %{uid: "agent-stale", name: "Agent Stale"})

    stale_agent
    |> Ash.Changeset.for_update(
      :update,
      %{},
      actor: system_actor()
    )
    |> Ash.Changeset.force_change_attribute(:status, :unavailable)
    |> Ash.Changeset.force_change_attribute(
      :last_seen_time,
      DateTime.add(DateTime.utc_now(), -3_600, :second)
    )
    |> Ash.update!()

    {:ok, lv, html} = live(conn, ~p"/settings/networks/credentials/new")

    assert scope_value_control(html) == :select
    assert html =~ "agent-a"
    refute html =~ "agent-stale"

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule:
          Map.merge(default_rule_form_params(), %{
            "scope_type" => "gateway",
            "scope_value" => ""
          })
      )
      |> render_change()

    assert scope_value_control(html) == :input

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule:
          Map.merge(default_rule_form_params(), %{
            "scope_type" => "gateway",
            "scope_value" => "credential-gw"
          })
      )
      |> render_change()

    assert scope_value_control(html) == :input
    assert html =~ ~s(value="credential-gw")

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule:
          Map.merge(default_rule_form_params(), %{
            "scope_type" => "agent",
            "scope_value" => "agent-a"
          })
      )
      |> render_change()

    assert scope_value_control(html) == :select
    assert html =~ "agent-a"
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

    assert html =~ "Credential secret saved"
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

  test "creates an SSH console credential secret when the advanced preset event is invoked", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    html = render_hook(lv, "new_ssh_secret")
    assert html =~ "New Console SSH Key"

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "ssh_private_key",
          "name" => "PVE console key",
          "description" => "Shell access for pve hosts",
          "username" => "root",
          "private_key" => private_key_fixture(),
          "passphrase" => "key-passphrase"
        }
      )
      |> render_submit()

    assert html =~ "Credential secret saved"
    refute html =~ "OPENSSH PRIVATE KEY"
    refute html =~ "key-passphrase"

    secret = get_secret_by_name!(scope, "PVE console key")
    assert secret.provider == "proxmox"
    assert secret.credential_kind == :ssh_private_key
    assert secret.username == "root"
    assert secret.public_fingerprint =~ "SHA256:"
    assert secret.metadata["auth_method"] == "ssh_private_key"
    assert secret.metadata["usage"] == "console_access"

    assert %Ash.NotLoaded{} = secret.secret_payload
  end

  test "validates Proxmox token preset fields without storing partial secrets", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    lv
    |> element("button[phx-click='new_proxmox_secret']")
    |> render_click()

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "name" => "Incomplete PVE token",
          "description" => "",
          "user" => "root",
          "realm" => "pam",
          "token_id" => "serviceradar",
          "tls_policy" => "verify",
          "token_secret" => ""
        }
      )
      |> render_submit()

    assert html =~ "Required token fields are missing"
    refute html =~ "root@pam!serviceradar="
    refute get_secret_by_name!(scope, "Incomplete PVE token")
  end

  test "unifi-protect preset seeds an api_key camera rule form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/credentials/new?provider=unifi-protect")

    assert html =~ ~s(value="unifi-protect")
    assert html =~ ~r/<option selected[^>]*value="api_key"/
    assert html =~ ~s(in:devices vendor:&quot;Ubiquiti&quot;)
    assert checked_purpose?(html, "camera_inventory")
    assert checked_purpose?(html, "camera_stream")
    refute html =~ ~s(value="inventory_enrichment")
    refute html =~ ~s(value="console_access")
    refute html =~ "SSH Host Key Policy"
    refute html =~ "Allow auto-discovery credential trials"
    assert html =~ "Controller Host Override"
    assert html =~ "New secret for this rule"
  end

  test "axis preset seeds a username_password camera rule form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/credentials/new?provider=axis")

    assert html =~ ~s(value="axis")
    assert html =~ ~r/<option selected[^>]*value="username_password"/
    assert html =~ ~s(in:devices vendor:&quot;Axis&quot;)
    assert checked_purpose?(html, "camera_inventory")
    assert checked_purpose?(html, "camera_stream")
    refute html =~ ~s(value="api_key")
    refute html =~ "SSH Host Key Policy"
    refute html =~ "Allow auto-discovery credential trials"
  end

  test "package descriptor seeds selected-agent schedule settings", %{conn: conn} do
    seed_example_inventory_package!()
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/credentials/new?provider=example-inventory")

    assert html =~ ~s(value="example-inventory")
    assert html =~ ~r/<option selected[^>]*value="username_password"/
    assert checked_purpose?(html, "device_inventory")
    assert html =~ "Example Inventory"
    assert html =~ "Instance ID"
    assert html =~ "OAuth Token URL"
    assert html =~ "Inventory API URL"
    assert html =~ "Query Sets"
    assert html =~ "Switch"
    assert html =~ "Enable recurring inventory refresh"
    refute html =~ "Target Query"
    refute html =~ "Allowed Ports"
  end

  test "creates a bounded package-declared inventory credential rule", %{conn: conn, scope: scope} do
    seed_example_inventory_package!()
    secret = username_password_secret_fixture(scope, "example-inventory")

    {:ok, lv, _html} =
      live(conn, ~p"/settings/networks/credentials/new?provider=example-inventory")

    lv
    |> form("#credential-rule-form",
      credential_rule: example_inventory_rule_form_params(secret.id)
    )
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/credentials")
    html = render(lv)
    assert html =~ "Example production inventory"
    assert html =~ "Pending"

    rule = get_rule_by_name!(scope, "Example production inventory")
    assert rule.provider == "example-inventory"
    assert rule.auth_method == :username_password
    assert rule.purpose == :device_inventory
    assert rule.scope_type == :agent
    assert rule.scope_value == "agent-k8s"
    assert rule.target_query == "in:agents"
    assert rule.metadata["plugin_integration"]
    assert rule.metadata["plugin_config"]["instance_id"] == "example-prod"

    assert rule.metadata["plugin_config"]["queries"] == [
             %{"name" => "switches", "parameters" => %{"type" => "Switch"}}
           ]

    assert rule.metadata["schedule_enabled"] == false
    assert rule.metadata["cadence_seconds"] == 86_400
  end

  test "rejects config outside the package JSON Schema", %{conn: conn, scope: scope} do
    seed_example_inventory_package!()
    secret = username_password_secret_fixture(scope, "example-inventory")

    {:ok, lv, _html} =
      live(conn, ~p"/settings/networks/credentials/new?provider=example-inventory")

    params =
      secret.id
      |> example_inventory_rule_form_params()
      |> put_in(
        ["plugin_config", "queries"],
        [
          %{"name" => "unsafe", "parameters" => %{"command" => "show device"}}
        ]
      )

    html =
      lv
      |> form("#credential-rule-form", credential_rule: params)
      |> render_submit()

    assert html =~ "Invalid plugin configuration"
    refute get_rule_by_name!(scope, "Example production inventory")
  end

  test "provider changes clamp auth methods and purposes to provider preset", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule:
          Map.merge(default_rule_form_params(), %{
            "provider" => "axis",
            "auth_method" => "proxmox_api_token",
            "purposes" => ["inventory_enrichment", "console_access"]
          })
      )
      |> render_change()

    assert html =~ ~s(value="axis")
    assert html =~ ~r/<option selected[^>]*value="username_password"/
    assert checked_purpose?(html, "camera_inventory")
    assert checked_purpose?(html, "camera_stream")
    refute html =~ ~s(value="inventory_enrichment")
    refute html =~ ~s(value="console_access")
  end

  test "creates a camera credential rule with api_key auth and camera purposes", %{
    conn: conn,
    scope: scope
  } do
    secret = api_key_secret_fixture(scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new?provider=unifi-protect")

    lv
    |> form("#credential-rule-form",
      credential_rule: %{
        "name" => "Protect cameras",
        "description" => "",
        "provider" => "unifi-protect",
        "auth_method" => "api_key",
        "purposes" => ["camera_inventory", "camera_stream"],
        "target_query" => ~s(in:devices vendor:"Ubiquiti"),
        "scope_type" => "agent",
        "scope_value" => "agent-cam",
        "secret_id" => secret.id,
        "priority" => "100",
        "allowed_ports" => "443, 7447",
        "tls_policy" => "skip_verify",
        "controller_host" => "protect-controller.local"
      }
    )
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/credentials")
    html = render(lv)
    assert html =~ "Protect cameras"
    assert html =~ "camera inventory, camera stream"

    rule = get_rule_by_name!(scope, "Protect cameras")
    assert rule.provider == "unifi-protect"
    assert rule.auth_method == :api_key
    assert rule.purpose == :camera_inventory
    assert rule.target_query == ~s(in:devices vendor:"Ubiquiti")
    assert rule.tls_policy == :skip_verify
    assert rule.metadata["purposes"] == ["camera_inventory", "camera_stream"]
    assert rule.metadata["host"] == "protect-controller.local"
    assert rule.metadata["auto_discovery_enabled"] == false
  end

  test "camera rule secret picker filters by provider and auth method", %{conn: conn, scope: scope} do
    pve_secret = credential_secret_fixture(scope)
    protect_secret = api_key_secret_fixture(scope)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/credentials/new?provider=unifi-protect")

    assert html =~ "unifi-protect / #{protect_secret.name} / api token"
    refute html =~ "proxmox / #{pve_secret.name} / api token"
  end

  test "inline rule secret creation preserves and selects the current rule provider", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new?provider=unifi-protect")

    assert lv
           |> element("#credential-rule-new-secret")
           |> render_click() =~ "New API Key Secret"

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "api_key",
          "name" => "Inline Protect key",
          "description" => "",
          "provider" => "unifi-protect",
          "api_key" => "inline-protect-key"
        }
      )
      |> render_submit()

    assert html =~ "Credential secret saved"
    assert html =~ "Inline Protect key"
    assert html =~ ~s(value="unifi-protect")
    assert html =~ ~r/<option selected[^>]*value="api_key"/
    assert checked_purpose?(html, "camera_inventory")

    secret = get_secret_by_name!(scope, "Inline Protect key")
    assert secret.provider == "unifi-protect"

    assert has_element?(
             lv,
             "select[name='credential_rule[secret_id]'] option[value='#{secret.id}'][selected]"
           )
  end

  test "creates an API key secret for the rule's provider", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    assert lv
           |> element("button[phx-click='new_api_key_secret']")
           |> render_click() =~ "New API Key Secret"

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "api_key",
          "name" => "Protect controller key",
          "description" => "UDM Pro",
          "provider" => "unifi-protect",
          "api_key" => "protect-api-key-value"
        }
      )
      |> render_submit()

    assert html =~ "Credential secret saved"
    refute html =~ "protect-api-key-value"

    secret = get_secret_by_name!(scope, "Protect controller key")
    assert secret.provider == "unifi-protect"
    assert secret.credential_kind == :api_token
    assert secret.public_fingerprint =~ "sha256:"
    assert secret.metadata["auth_method"] == "api_key"
  end

  test "validates API key secret fields without storing partial secrets", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    lv
    |> element("button[phx-click='new_api_key_secret']")
    |> render_click()

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "api_key",
          "name" => "Incomplete key",
          "description" => "",
          "provider" => "unifi-protect",
          "api_key" => ""
        }
      )
      |> render_submit()

    assert html =~ "Required API key fields are missing"
    refute get_secret_by_name!(scope, "Incomplete key")
  end

  test "creates an AWX bearer-token secret from the credential-rules page", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    assert lv
           |> element("button[phx-click='new_awx_secret']")
           |> render_click() =~ "New AWX API Token"

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "awx_api_token",
          "name" => "Prod AWX token",
          "description" => "AAP controller",
          "api_token" => "awx-oauth2-bearer-token"
        }
      )
      |> render_submit()

    assert html =~ "Credential secret saved"
    refute html =~ "awx-oauth2-bearer-token"

    secret = get_secret_by_name!(scope, "Prod AWX token")
    assert secret.provider == "awx"
    assert secret.credential_kind == :api_token
    assert secret.public_fingerprint =~ "sha256:"
    assert secret.metadata["auth_method"] == "bearer_token"
    assert secret.metadata["source"] == "credential_rules_form"
    assert %Ash.NotLoaded{} = secret.secret_payload
  end

  test "validates AWX token secret fields without storing partial secrets", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    lv
    |> element("button[phx-click='new_awx_secret']")
    |> render_click()

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "awx_api_token",
          "name" => "Incomplete AWX token",
          "description" => "",
          "api_token" => ""
        }
      )
      |> render_submit()

    assert html =~ "Required AWX token fields are missing"
    refute get_secret_by_name!(scope, "Incomplete AWX token")
  end

  test "creates a username/password secret for camera providers", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    assert lv
           |> element("button[phx-click='new_username_password_secret']")
           |> render_click() =~ "New Username &amp; Password Secret"

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "username_password",
          "name" => "Axis viewer",
          "description" => "",
          "provider" => "axis",
          "username" => "viewer",
          "password" => "vapix-password-value"
        }
      )
      |> render_submit()

    assert html =~ "Credential secret saved"
    refute html =~ "vapix-password-value"

    secret = get_secret_by_name!(scope, "Axis viewer")
    assert secret.provider == "axis"
    assert secret.credential_kind == :username_password
    assert secret.username == "viewer"
    assert secret.metadata["auth_method"] == "username_password"
  end

  test "camera rules do not offer the proxmox-only credential test", %{conn: conn, scope: scope} do
    proxmox_secret = credential_secret_fixture(scope)
    proxmox_rule = credential_rule_fixture(scope, proxmox_secret, %{name: "PVE testable"})

    camera_secret = api_key_secret_fixture(scope)

    camera_rule =
      credential_rule_fixture(scope, camera_secret, %{
        name: "Protect cameras",
        provider: "unifi-protect",
        auth_method: :api_key,
        purpose: :camera_inventory,
        allowed_ports: [443],
        metadata: %{"purposes" => ["camera_inventory"]}
      })

    {:ok, lv, html} = live(conn, ~p"/settings/networks/credentials")

    assert has_element?(lv, "button[phx-click='test_rule'][phx-value-id='#{proxmox_rule.id}']")
    refute has_element?(lv, "button[phx-click='test_rule'][phx-value-id='#{camera_rule.id}']")
    assert html =~ "Credential test is not yet available for this provider"
  end

  test "edits and disables a credential rule", %{conn: conn, scope: scope} do
    secret = credential_secret_fixture(scope)
    rule = credential_rule_fixture(scope, secret, %{name: "Original rule"})

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/#{rule.id}/edit")

    lv
    |> form("#credential-rule-form",
      credential_rule: %{
        "name" => "Updated rule",
        "description" => "",
        "provider" => "proxmox",
        "auth_method" => "proxmox_api_token",
        "purposes" => ["inventory_enrichment"],
        "target_query" => "in:devices",
        "scope_type" => "agent",
        "scope_value" => "agent-a",
        "secret_id" => secret.id,
        "priority" => "30",
        "allowed_ports" => "8006",
        "tls_policy" => "verify",
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

    previous_rows =
      Application.get_env(:serviceradar_web_ng, :network_credential_rule_preview_rows)

    Application.put_env(
      :serviceradar_web_ng,
      :network_credential_rule_preview_resolver,
      FakeCredentialRulePreviewResolver
    )

    Application.put_env(:serviceradar_web_ng, :network_credential_rule_preview_rows, %{
      "in:devices metadata.proxmox_candidate:true" => [
        %{
          "uid" => "device-1",
          "hostname" => "pve-a",
          "ip" => "192.0.2.10",
          "agent_id" => "agent-a"
        },
        %{
          "uid" => "device-2",
          "hostname" => "pve-b",
          "ip" => "192.0.2.11",
          "agent_id" => "agent-a"
        },
        %{
          "uid" => "device-3",
          "hostname" => "pve-c",
          "ip" => "192.0.2.12",
          "agent_id" => "agent-b"
        }
      ]
    })

    on_exit(fn ->
      restore_env(:network_credential_rule_preview_resolver, previous_resolver)
      restore_env(:network_credential_rule_preview_rows, previous_rows)
    end)

    secret = credential_secret_fixture(scope)

    rule =
      credential_rule_fixture(scope, secret, %{
        target_query: "in:devices metadata.proxmox_candidate:true"
      })

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

  defp api_key_secret_fixture(scope) do
    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Protect key #{System.unique_integer([:positive])}",
          provider: "unifi-protect",
          credential_kind: :api_token,
          public_fingerprint: "sha256:test",
          secret_payload: "protect-api-key",
          metadata: %{"auth_method" => "api_key"}
        },
        scope: scope
      )
      |> Ash.create(scope: scope)

    secret
  end

  defp username_password_secret_fixture(scope, provider) do
    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "#{provider} service account #{System.unique_integer([:positive])}",
          provider: provider,
          credential_kind: :username_password,
          username: "service-account",
          secret_payload: "service-account-password",
          metadata: %{"auth_method" => "username_password"}
        },
        scope: scope
      )
      |> Ash.create(scope: scope)

    secret
  end

  defp example_inventory_rule_form_params(secret_id) do
    %{
      "name" => "Example production inventory",
      "description" => "Daily switch inventory",
      "provider" => "example-inventory",
      "auth_method" => "username_password",
      "purposes" => ["device_inventory"],
      "target_query" => "in:agents",
      "scope_type" => "agent",
      "scope_value" => "agent-k8s",
      "secret_id" => secret_id,
      "priority" => "100",
      "allowed_ports" => "",
      "tls_policy" => "verify",
      "plugin_config" => %{
        "instance_id" => "example-prod",
        "token_url" => "https://identity.example.test/oauth/token",
        "api_url" => "https://inventory.example.test/api",
        "queries" => [
          %{"name" => "switches", "parameters" => %{"type" => "Switch"}}
        ]
      },
      "schedule_enabled" => "false",
      "cadence_seconds" => "86400"
    }
  end

  defp seed_example_inventory_package! do
    actor = system_actor()
    plugin_id = "example-inventory-plugin-#{System.unique_integer([:positive])}"

    Plugin
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "Example Inventory",
        description: "Package-declared inventory provider"
      },
      actor: actor
    )
    |> Ash.create!()

    manifest = example_inventory_manifest(plugin_id)

    package =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Example Inventory",
          version: "1.0.0",
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          config_schema: example_inventory_config_schema(),
          signature: %{},
          source_type: :github,
          source_commit: "test-#{plugin_id}"
        },
        actor: actor
      )
      |> Ash.create!()

    assert {:ok, _approved} = Packages.approve(package.id, %{}, actor: actor)
  end

  defp example_inventory_manifest(plugin_id) do
    %{
      "id" => plugin_id,
      "name" => "Example Inventory",
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["get_config", "producer-schedule:v1"],
      "permissions" => %{"allowed_domains" => ["*"]},
      "resources" => %{
        "requested_cpu_ms" => 5_000,
        "requested_memory_mb" => 64,
        "max_open_connections" => 2
      },
      "producer_schedules" => [
        %{
          "schedule_id" => "example-inventory.refresh",
          "label" => "Refresh example inventory",
          "action_id" => "example-inventory.refresh",
          "command_type" => "plugin.run_action",
          "default_cadence_seconds" => 86_400,
          "min_cadence_seconds" => 3_600,
          "max_cadence_seconds" => 2_592_000,
          "dispatch_scope" => "assignment",
          "timeout_seconds" => 900,
          "credential_requirements" => %{
            "inventory_account" => %{
              "required" => true,
              "resolution_location" => "agent",
              "grants" => []
            }
          }
        }
      ],
      "integrations" => %{
        "documentation" => %{
          "title" => "Example inventory configuration",
          "path" => "docs/configuration.md"
        },
        "credential_profiles" => [
          %{
            "provider" => "example-inventory",
            "label" => "Example Inventory",
            "auth_methods" => [
              %{"id" => "username_password", "credential_kind" => "username_password"}
            ],
            "purposes" => ["device_inventory"],
            "scope_types" => ["agent"],
            "provisioning" => %{
              "mode" => "producer_schedule",
              "schedule_id" => "example-inventory.refresh",
              "credential_requirement" => "inventory_account"
            }
          }
        ],
        "inventory_sources" => [
          %{
            "source" => "example-inventory",
            "label" => "Example Inventory",
            "metadata_fields" => []
          }
        ]
      }
    }
  end

  defp example_inventory_config_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["instance_id", "token_url", "api_url", "queries"],
      "properties" => %{
        "instance_id" => %{
          "type" => "string",
          "title" => "Instance ID",
          "pattern" => "^[A-Za-z0-9._-]+$"
        },
        "token_url" => %{
          "type" => "string",
          "title" => "OAuth Token URL",
          "format" => "uri",
          "pattern" => "^https://"
        },
        "api_url" => %{
          "type" => "string",
          "title" => "Inventory API URL",
          "format" => "uri",
          "pattern" => "^https://"
        },
        "queries" => %{
          "type" => "array",
          "title" => "Query Sets",
          "minItems" => 1,
          "default" => [
            %{"name" => "switches", "parameters" => %{"type" => "Switch"}}
          ],
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["name", "parameters"],
            "properties" => %{
              "name" => %{"type" => "string"},
              "parameters" => %{
                "type" => "object",
                "additionalProperties" => false,
                "properties" => %{"type" => %{"type" => "string"}}
              }
            }
          }
        }
      }
    }
  end

  defp checked_purpose?(html, purpose) do
    html =~ ~r/checked[^>]*value="#{purpose}"|value="#{purpose}"[^>]*checked/
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

  defp private_key_fixture do
    private_key_fixture_header() <>
      """
      b3BlbnNzaC10ZXN0LWtleS1tYXRlcmlhbA==
      #{private_key_fixture_footer()}
      """
  end

  defp private_key_fixture_header, do: "-----BEGIN OPENSSH " <> "PRIVATE KEY-----\n"
  defp private_key_fixture_footer, do: "-----END OPENSSH " <> "PRIVATE KEY-----"

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

  defp default_rule_form_params do
    %{
      "name" => "",
      "description" => "",
      "provider" => "proxmox",
      "auth_method" => "proxmox_api_token",
      "purposes" => ["inventory_enrichment"],
      "target_query" => "in:devices metadata.proxmox_candidate:true",
      "scope_type" => "agent",
      "scope_value" => "",
      "secret_id" => "",
      "priority" => "100",
      "allowed_ports" => "8006",
      "tls_policy" => "verify",
      "auto_discovery_enabled" => "false"
    }
  end

  defp scope_value_control(html) do
    cond do
      html =~ ~r/<select[^>]+name="credential_rule\[scope_value\]"/ -> :select
      html =~ ~r/<input[^>]+name="credential_rule\[scope_value\]"/ -> :input
      true -> :missing
    end
  end
end
