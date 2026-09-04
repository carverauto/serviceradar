defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Credentials.CredentialUsePolicy
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.SNMPProfiles.SNMPProfile
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
         %{
           name: input_def.name,
           entity: input_def.entity,
           query: input_def.query,
           rows: Map.get(rows_by_query, input_def.query, [])
         }
       end)}
    end
  end

  setup :register_and_log_in_admin_user
  setup :seed_target_policy_package

  test "renders only credential providers declared by approved packages", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/credentials")

    assert html =~ "Credential Rules"
    assert html =~ "Example Network"
    assert html =~ "Example Cameras"
    assert html =~ "New Credential"
    assert html =~ "No credential rules found"
    assert html =~ "VulnCheck"
    assert html =~ "VulnCheck · API token"
    refute html =~ "Read the Proxmox setup guide"
    refute html =~ "Axis (VAPIX)"
  end

  test "lists, focuses, and links reusable credentials independently of credential rules", %{
    conn: conn,
    scope: scope
  } do
    secret =
      credential_secret_fixture(scope, %{
        name: "Core switches #{System.unique_integer([:positive])}",
        provider: "snmp",
        credential_kind: :snmp,
        username: "snmp-operator",
        public_fingerprint: "sha256:snmp-test",
        secret_payload: Jason.encode!(%{"username" => "snmp-operator"}),
        metadata: descriptor_metadata("v3")
      })

    profile_name = "Core SNMP #{System.unique_integer([:positive])}"

    {:ok, profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(:create, %{
        name: profile_name,
        version: :v3,
        credential_secret_id: secret.id
      })
      |> Ash.create(scope: scope)

    {:ok, lv, _html} =
      live(conn, ~p"/settings/networks/credentials?credential_id=#{secret.id}")

    row = "#credential-secret-#{secret.id}"

    assert has_element?(lv, "#reusable-credentials")
    assert has_element?(lv, "#{row}[data-focused='true']", secret.name)
    assert has_element?(lv, row, "SNMP")
    assert has_element?(lv, row, "SNMPv3 user")
    assert has_element?(lv, "#{row} [data-role='credential-usage-counts']", "1 SNMP profile · 0 rules")

    assert has_element?(
             lv,
             "#{row} a[href='/settings/snmp/#{profile.id}/edit']",
             "1 SNMP profile · #{profile_name}"
           )
  end

  test "editing credential details preserves encrypted material", %{conn: conn, scope: scope} do
    marker = "credential-edit-secret-#{System.unique_integer([:positive])}"

    secret =
      credential_secret_fixture(scope, %{
        name: "Edit details source",
        description: "Before edit",
        provider: "example-network",
        credential_kind: :api_token,
        secret_payload: marker,
        metadata: descriptor_metadata("api_token")
      })

    assert {:ok, %{value: ^marker}} =
             SecretBroker.resolve_network_credential_secret(secret.id, actor: system_actor())

    {:ok, lv, initial_html} = live(conn, ~p"/settings/networks/credentials")
    refute initial_html =~ marker

    lv
    |> element("button[phx-click='edit_credential'][phx-value-id='#{secret.id}']")
    |> render_click()

    html =
      lv
      |> form("#credential-edit-form",
        credential_details: %{
          "id" => to_string(secret.id),
          "name" => "Edited credential details",
          "description" => "After edit"
        }
      )
      |> render_submit()

    assert html =~ "Credential details saved"
    refute html =~ marker

    assert {:ok, updated} = NetworkCredentialSecret.get_by_id(secret.id, scope: scope)
    assert updated.name == "Edited credential details"
    assert updated.description == "After edit"
    assert updated.provider == "example-network"
    assert updated.credential_kind == :api_token

    assert {:ok, %{value: ^marker}} =
             SecretBroker.resolve_network_credential_secret(secret.id, actor: system_actor())
  end

  test "rotation is write-only and replaces the encrypted material", %{conn: conn, scope: scope} do
    suffix = System.unique_integer([:positive])
    old_marker = "credential-rotation-old-#{suffix}"
    new_marker = "credential-rotation-new-#{suffix}"

    secret =
      credential_secret_fixture(scope, %{
        name: "Rotatable credential #{suffix}",
        provider: "example-network",
        credential_kind: :api_token,
        secret_payload: old_marker,
        metadata: descriptor_metadata("api_token")
      })

    {:ok, lv, initial_html} = live(conn, ~p"/settings/networks/credentials")
    refute initial_html =~ old_marker

    open_html =
      lv
      |> element("button[phx-click='rotate_credential'][phx-value-id='#{secret.id}']")
      |> render_click()

    assert open_html =~ "Rotate #{secret.name}"
    refute open_html =~ old_marker

    assert has_element?(
             lv,
             "#credential-rotate-form input[name='credential_rotation[fields][token]'][value='']"
           )

    html =
      lv
      |> form("#credential-rotate-form",
        credential_rotation: %{
          "id" => to_string(secret.id),
          "fields" => %{"token" => new_marker}
        }
      )
      |> render_submit()

    assert html =~ "Credential rotated"
    refute html =~ old_marker
    refute html =~ new_marker

    assert {:ok, %{value: ^new_marker}} =
             SecretBroker.resolve_network_credential_secret(secret.id, actor: system_actor())
  end

  test "used SNMP credential blocks deletion until the named profile is detached", %{
    conn: conn,
    scope: scope
  } do
    secret = snmp_secret_fixture(scope)
    profile = snmp_profile_fixture(scope, secret, "Delete blocker")
    row = "#credential-secret-#{secret.id}"

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    lv
    |> element("button[phx-click='delete_credential'][phx-value-id='#{secret.id}']")
    |> render_click()

    assert has_element?(lv, "#credential-delete-modal", "Can't delete #{secret.name}")

    assert has_element?(
             lv,
             "#credential-delete-modal a[href='/settings/snmp/#{profile.id}/edit']",
             profile.name
           )

    refute has_element?(
             lv,
             "#credential-delete-modal form[phx-submit='confirm_delete_credential']"
           )

    profile
    |> Ash.Changeset.for_update(:update, %{credential_secret_id: nil}, scope: scope)
    |> Ash.update!(scope: scope)

    render_click(lv, "delete_credential", %{"id" => to_string(secret.id)})

    assert has_element?(
             lv,
             "#credential-delete-modal form[phx-submit='confirm_delete_credential']"
           )

    html =
      lv
      |> form("#credential-delete-form",
        credential_delete: %{
          "id" => to_string(secret.id),
          "confirmation_id" => to_string(secret.id)
        }
      )
      |> render_submit()

    assert html =~ "Credential permanently deleted"
    refute has_element?(lv, row)
    assert {:error, _reason} = NetworkCredentialSecret.get_by_id(secret.id, actor: system_actor())
  end

  test "confirmation-time SNMP attachment wins the delete race", %{conn: conn, scope: scope} do
    secret = snmp_secret_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    lv
    |> element("button[phx-click='delete_credential'][phx-value-id='#{secret.id}']")
    |> render_click()

    assert has_element?(lv, "#credential-delete-form")

    profile = snmp_profile_fixture(scope, secret, "Last-moment consumer")

    html =
      lv
      |> form("#credential-delete-form",
        credential_delete: %{
          "id" => to_string(secret.id),
          "confirmation_id" => to_string(secret.id)
        }
      )
      |> render_submit()

    assert html =~ "Credential is still in use"

    assert has_element?(
             lv,
             "#credential-delete-modal a[href='/settings/snmp/#{profile.id}/edit']",
             profile.name
           )

    refute has_element?(
             lv,
             "#credential-delete-modal form[phx-submit='confirm_delete_credential']"
           )

    assert {:ok, %{id: id}} = NetworkCredentialSecret.get_by_id(secret.id, actor: system_actor())
    assert to_string(id) == to_string(secret.id)
  end

  test "successful focused-row deletion returns to the base credentials route", %{
    conn: conn,
    scope: scope
  } do
    secret = api_token_secret_fixture(scope)

    {:ok, lv, _html} =
      live(
        conn,
        "/settings/networks/credentials?credential_id=#{secret.id}#credential-secret-#{secret.id}"
      )

    assert has_element?(lv, "#credential-secret-#{secret.id}[data-focused='true']")

    lv
    |> element("button[phx-click='delete_credential'][phx-value-id='#{secret.id}']")
    |> render_click()

    lv
    |> form("#credential-delete-form",
      credential_delete: %{
        "id" => to_string(secret.id),
        "confirmation_id" => to_string(secret.id)
      }
    )
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/credentials")
    refute has_element?(lv, "#credential-secret-#{secret.id}")
  end

  test "a stale credential id cannot open a management action", %{conn: conn} do
    stale_id = Ecto.UUID.generate()
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    html = render_click(lv, "edit_credential", %{"id" => stale_id})

    assert html =~ "Credential not found"
    refute has_element?(lv, "#credential-edit-modal")
  end

  test "permission removed after mount rejects a forged credential event", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    _backup_admin = AccountsFixtures.user_fixture(%{role: :admin})
    secret = api_token_secret_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    user
    |> Ash.Changeset.for_update(:update_role, %{role: :viewer}, actor: system_actor())
    |> Ash.update!()

    render_click(lv, "delete_credential", %{"id" => to_string(secret.id)})

    assert_redirect(lv, ~p"/settings/profile")
    assert {:ok, %{id: id}} = NetworkCredentialSecret.get_by_id(secret.id, actor: system_actor())
    assert to_string(id) == to_string(secret.id)
  end

  test "viewer is blocked from credential rules settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/networks/credentials")
    assert to == ~p"/settings/profile"
  end

  test "creates a rule from package-declared defaults and controls", %{conn: conn, scope: scope} do
    secret = api_token_secret_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    lv
    |> form("#credential-rule-form", credential_rule: default_rule_form_params(secret.id))
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/credentials")
    assert render(lv) =~ "Example inventory rule"

    rule = get_rule_by_name!(scope, "Example inventory rule")
    assert rule.provider == "example-network"
    assert rule.auth_method == "api_token"
    assert rule.purpose == "device_inventory"
    assert rule.target_query == "in:devices vendor:Example"
    assert rule.scope_type == :agent
    assert rule.metadata["purposes"] == ["device_inventory"]
    assert rule.metadata["auto_discovery_enabled"] == true
  end

  test "creates an explicit actor-use policy for package-declared console access", %{
    conn: conn,
    scope: scope
  } do
    secret = username_password_secret_fixture(scope, "example-network")
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    lv
    |> form("#credential-rule-form",
      credential_rule: %{
        "auth_method" => "username_password",
        "purposes" => ["console_access"]
      }
    )
    |> render_change()

    params =
      secret.id
      |> default_rule_form_params()
      |> Map.merge(%{
        "name" => "Example console rule",
        "auth_method" => "username_password",
        "purposes" => ["console_access"],
        "credential_use_roles" => "admin, operator",
        "credential_use_principals" => "oidc|example-user",
        "credential_use_groups" => "example-console-operators"
      })

    lv
    |> form("#credential-rule-form", credential_rule: params)
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/credentials")
    rule = get_rule_by_name!(scope, "Example console rule")

    assert rule.metadata["credential_use_policy"] == %{
             "schema" => CredentialUsePolicy.schema(),
             "roles" => ["admin", "operator"],
             "principals" => ["oidc|example-user"],
             "groups" => ["example-console-operators"]
           }
  end

  test "rejects console rules without an actor-use selector", %{conn: conn, scope: scope} do
    secret = username_password_secret_fixture(scope, "example-network")
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    lv
    |> form("#credential-rule-form",
      credential_rule: %{
        "auth_method" => "username_password",
        "purposes" => ["console_access"]
      }
    )
    |> render_change()

    params =
      secret.id
      |> default_rule_form_params()
      |> Map.merge(%{
        "name" => "Unrestricted console",
        "auth_method" => "username_password",
        "purposes" => ["console_access"],
        "credential_use_roles" => "",
        "credential_use_principals" => "",
        "credential_use_groups" => ""
      })

    html =
      lv
      |> form("#credential-rule-form", credential_rule: params)
      |> render_submit()

    assert html =~ "Console access requires at least one allowed role, user, or IdP group"
    refute get_rule_by_name!(scope, "Unrestricted console")
  end

  test "enforces transport policy declared by the selected authentication method", %{
    conn: conn,
    scope: scope
  } do
    secret = api_token_secret_fixture(scope)
    {:ok, lv, html} = live(conn, ~p"/settings/networks/credentials/new")

    refute html =~ ~s(<option value="skip_verify">)

    params =
      secret.id
      |> default_rule_form_params()
      |> Map.merge(%{"name" => "Insecure rule", "tls_policy" => "skip_verify"})

    html = render_hook(lv, "save_rule", %{"credential_rule" => params})

    assert html =~ "Selected authentication method does not allow this TLS policy"
    refute get_rule_by_name!(scope, "Insecure rule")
  end

  test "offers every TLS policy when the auth method narrows none", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    lv
    |> form("#credential-rule-form", credential_rule: %{"provider" => "example-camera"})
    |> render_change()

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule: %{
          "provider" => "example-camera",
          "auth_method" => "api_key",
          "purposes" => ["camera_inventory"]
        }
      )
      |> render_change()

    assert html =~ "TLS Policy"
    assert html =~ ~s(value="verify")
    assert html =~ ~s(value="skip_verify")
  end

  test "saves a rule whose auth method narrows no TLS policy", %{conn: conn, scope: scope} do
    secret =
      credential_secret_fixture(scope, %{
        name: "Camera key #{System.unique_integer([:positive])}",
        provider: "example-camera",
        credential_kind: :api_token,
        public_fingerprint: "sha256:test",
        secret_payload: "sensitive-api-key",
        metadata: %{"auth_method" => "api_key"}
      })

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    params = %{
      "name" => "Camera api_key rule",
      "description" => "",
      "provider" => "example-camera",
      "auth_method" => "api_key",
      "purposes" => ["camera_inventory"],
      "target_query" => ~s(in:devices type:"Camera"),
      "scope_type" => "agent",
      "scope_value" => "agent-a",
      "secret_id" => secret.id,
      "priority" => "100",
      "tls_policy" => "skip_verify"
    }

    render_hook(lv, "save_rule", %{"credential_rule" => params})

    rule = get_rule_by_name!(scope, "Camera api_key rule")
    assert rule
    assert rule.tls_policy == :skip_verify
  end

  test "an omitted TLS policy param falls back to verify rather than failing the save", %{
    conn: conn,
    scope: scope
  } do
    secret = api_token_secret_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    params =
      secret.id
      |> default_rule_form_params()
      |> Map.put("name", "Defaulted transport")
      |> Map.delete("tls_policy")

    html = render_hook(lv, "save_rule", %{"credential_rule" => params})

    refute html =~ "Invalid TLS policy"

    rule = get_rule_by_name!(scope, "Defaulted transport")
    assert rule
    assert rule.tls_policy == :verify
  end

  test "names the controller host from the descriptor without provider-specific copy", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    lv
    |> form("#credential-rule-form", credential_rule: %{"provider" => "example-camera"})
    |> render_change()

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule: %{
          "provider" => "example-camera",
          "auth_method" => "api_key",
          "purposes" => ["camera_inventory"]
        }
      )
      |> render_change()

    assert html =~ ~s(name="credential_rule[controller_host]")
    assert html =~ "Example Cameras controller host"
    assert html =~ "ServiceRadar strips the URL down to the host"

    # controller_host is a generic rule control; the form must not describe a
    # non-UniFi provider's host in UniFi terms.
    refute html =~ "Protect controller"
    refute html =~ "Dream Machine"
    refute html =~ "unifi.lan"
    refute html =~ "camera IP"
  end

  test "uses credential kind rather than method id for SSH policy controls", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule: %{
          "provider" => "example-network",
          "auth_method" => "key_pair",
          "purposes" => ["console_access"]
        }
      )
      |> render_change()

    assert html =~ "SSH Host Key Policy"
    assert html =~ ~s(value="known_hosts")
    assert html =~ ~s(value="trust_on_first_use")
    refute html =~ "TLS Policy"
  end

  test "agent scope uses active agents while gateway scope remains freeform", %{conn: conn} do
    gateway = gateway_fixture(%{id: "credential-gw", component_id: "credential-component"})
    agent_fixture(gateway, %{uid: "agent-a", name: "Agent A"})

    stale_agent = agent_fixture(gateway, %{uid: "agent-stale", name: "Agent Stale"})

    stale_agent
    |> Ash.Changeset.for_update(:update, %{}, actor: system_actor())
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

    lv
    |> form("#credential-rule-form", credential_rule: %{"scope_type" => "gateway"})
    |> render_change()

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule: %{"scope_type" => "gateway", "scope_value" => "credential-gw"}
      )
      |> render_change()

    assert scope_value_control(html) == :input
    assert html =~ ~s(value="credential-gw")
  end

  test "creates a scalar API token using package-declared credential fields", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    assert lv
           |> element(
             "button[phx-click='new_descriptor_secret'][phx-value-provider='example-network'][phx-value-method='api_token']"
           )
           |> render_click() =~ "New Example Network credential"

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "descriptor",
          "provider" => "example-network",
          "auth_method" => "api_token",
          "name" => "Example API token",
          "description" => "",
          "fields" => %{"token" => "sensitive-token"}
        }
      )
      |> render_submit()

    assert html =~ "Credential secret saved"
    refute html =~ "sensitive-token"

    secret = get_secret_by_name!(scope, "Example API token")
    assert secret.provider == "example-network"
    assert secret.credential_kind == :api_token
    assert secret.metadata["auth_method"] == "api_token"
    assert secret.metadata["credential_descriptor"] == "package_manifest.v1"
    assert %Ash.NotLoaded{} = secret.secret_payload
  end

  test "creates a native VulnCheck API token from New Credential", %{conn: conn, scope: scope} do
    {:ok, lv, html} = live(conn, ~p"/settings/networks/credentials")

    assert html =~
             ~s(phx-click="new_descriptor_secret")

    assert html =~ ~s(phx-value-provider="vulncheck")
    assert html =~ ~s(phx-value-method="api_token")

    assert lv
           |> element(
             "button[phx-click='new_descriptor_secret'][phx-value-provider='vulncheck'][phx-value-method='api_token']"
           )
           |> render_click() =~ "New VulnCheck credential"

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "descriptor",
          "provider" => "vulncheck",
          "auth_method" => "api_token",
          "name" => "VulnCheck community",
          "description" => "",
          "fields" => %{"api_token" => "vc-sensitive-token"}
        }
      )
      |> render_submit()

    assert html =~ "Credential secret saved"
    refute html =~ "vc-sensitive-token"

    secret = get_secret_by_name!(scope, "VulnCheck community")
    assert secret.provider == "vulncheck"
    assert secret.credential_kind == :api_token
    assert secret.metadata["auth_method"] == "api_token"
    assert secret.metadata["plugin_id"] == "vulncheck"
    assert secret.metadata["plugin_version"] == "native"
  end

  test "creates a username/password credential without exposing the password", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    lv
    |> element(
      "button[phx-click='new_descriptor_secret'][phx-value-provider='example-network'][phx-value-method='username_password']"
    )
    |> render_click()

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "descriptor",
          "provider" => "example-network",
          "auth_method" => "username_password",
          "name" => "Example account",
          "description" => "",
          "fields" => %{
            "username" => "operator",
            "password" => "sensitive-password"
          }
        }
      )
      |> render_submit()

    assert html =~ "Credential secret saved"
    refute html =~ "sensitive-password"

    secret = get_secret_by_name!(scope, "Example account")
    assert secret.provider == "example-network"
    assert secret.credential_kind == :username_password
    assert secret.username == "operator"
    assert secret.metadata["auth_method"] == "username_password"
  end

  test "rejects missing descriptor fields without storing a partial credential", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    lv
    |> element(
      "button[phx-click='new_descriptor_secret'][phx-value-provider='example-network'][phx-value-method='api_token']"
    )
    |> render_click()

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "descriptor",
          "provider" => "example-network",
          "auth_method" => "api_token",
          "name" => "Incomplete token",
          "fields" => %{"token" => ""}
        }
      )
      |> render_submit()

    assert html =~ "API token is required"
    refute get_secret_by_name!(scope, "Incomplete token")
  end

  test "provider changes clamp methods, purposes, and defaults to the selected descriptor", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/new")

    html =
      lv
      |> form("#credential-rule-form",
        credential_rule: %{
          "provider" => "example-camera",
          "auth_method" => "api_token",
          "purposes" => ["device_inventory", "console_access"]
        }
      )
      |> render_change()

    assert html =~ ~s(value="example-camera")
    assert html =~ ~r/<option selected[^>]*value="username_password"/
    assert checked_purpose?(html, "camera_inventory")
    refute html =~ ~s(value="device_inventory")
    refute html =~ ~s(value="console_access")
    assert html =~ ~s(in:devices type:&quot;Camera&quot;)
  end

  test "secret picker filters by provider and credential method", %{conn: conn, scope: scope} do
    network_secret = api_token_secret_fixture(scope)
    camera_secret = username_password_secret_fixture(scope, "example-camera")

    {:ok, _lv, html} =
      live(conn, ~p"/settings/networks/credentials/new?provider=example-camera")

    assert html =~ "example-camera / #{camera_secret.name} / username password"
    refute html =~ "example-network / #{network_secret.name} / api token"
  end

  test "inline credential creation preserves and selects the current rule provider", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} =
      live(conn, ~p"/settings/networks/credentials/new?provider=example-camera")

    assert lv
           |> element("#credential-rule-new-secret")
           |> render_click() =~ "New Example Cameras credential"

    html =
      lv
      |> form("form[phx-submit='save_secret']",
        credential_secret: %{
          "kind" => "descriptor",
          "provider" => "example-camera",
          "auth_method" => "username_password",
          "name" => "Inline camera account",
          "description" => "",
          "fields" => %{"username" => "viewer", "password" => "sensitive-password"}
        }
      )
      |> render_submit()

    assert html =~ "Credential secret saved"
    assert html =~ "Inline camera account"
    assert html =~ ~s(value="example-camera")

    secret = get_secret_by_name!(scope, "Inline camera account")

    assert has_element?(
             lv,
             "select[name='credential_rule[secret_id]'] option[value='#{secret.id}'][selected]"
           )
  end

  test "edits and disables a package-declared credential rule", %{conn: conn, scope: scope} do
    secret = api_token_secret_fixture(scope)
    rule = credential_rule_fixture(scope, secret, %{name: "Original rule"})

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials/#{rule.id}/edit")

    params =
      secret.id
      |> default_rule_form_params()
      |> Map.merge(%{"name" => "Updated rule", "priority" => "30"})

    lv
    |> form("#credential-rule-form", credential_rule: params)
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/credentials")
    assert render(lv) =~ "Updated rule"

    html =
      lv
      |> element("button[phx-click='disable_rule'][phx-value-id='#{rule.id}']")
      |> render_click()

    assert html =~ "Disabled"
  end

  test "previews SRQL scope without resolving credential material", %{conn: conn, scope: scope} do
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
      "in:devices vendor:Example" => [
        %{
          "uid" => "device-1",
          "hostname" => "example-a",
          "ip" => "192.0.2.10",
          "agent_id" => "agent-a"
        },
        %{
          "uid" => "device-2",
          "hostname" => "example-b",
          "ip" => "192.0.2.11",
          "agent_id" => "agent-a"
        }
      ]
    })

    on_exit(fn ->
      restore_env(:network_credential_rule_preview_resolver, previous_resolver)
      restore_env(:network_credential_rule_preview_rows, previous_rows)
    end)

    secret = api_token_secret_fixture(scope)
    rule = credential_rule_fixture(scope, secret, %{})
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

    html =
      lv
      |> element("button[phx-click='preview_rule'][phx-value-id='#{rule.id}']")
      |> render_click()

    assert html =~ "Target Preview"
    assert html =~ "example-a"
    assert html =~ "192.0.2.10"
    assert html =~ "credentialref:network-credential-secret:"
    refute html =~ "sensitive-token"
  end

  test "renders and saves a producer-schedule integration from its package schema", %{
    conn: conn,
    scope: scope
  } do
    seed_scheduled_package!()
    secret = username_password_secret_fixture(scope, "example-scheduled")

    {:ok, lv, html} =
      live(conn, ~p"/settings/networks/credentials/new?provider=example-scheduled")

    assert html =~ "Example Scheduled Inventory"
    assert html =~ "Instance ID"
    assert html =~ "Enable recurring inventory refresh"
    assert html =~ "Do not assign this plugin from Admin"
    refute html =~ "Target Query"

    lv
    |> form("#credential-rule-form",
      credential_rule: scheduled_rule_form_params(secret.id)
    )
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/credentials")
    rule = get_rule_by_name!(scope, "Scheduled inventory")
    assert rule.provider == "example-scheduled"
    assert rule.auth_method == "username_password"
    assert rule.purpose == "device_inventory"
    assert rule.target_query == "in:agents"
    assert rule.metadata["plugin_config"]["instance_id"] == "example-prod"
    assert rule.metadata["cadence_seconds"] == 86_400
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp seed_target_policy_package(_context) do
    plugin_id = "example-credential-plugin"

    create_approved_package!(
      plugin_id,
      "Example Credential Plugin",
      target_policy_manifest(plugin_id),
      %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    )

    :ok
  end

  defp target_policy_manifest(plugin_id) do
    plugin_id
    |> base_manifest("Example Credential Plugin")
    |> Map.put("integrations", %{
      "documentation" => %{"path" => "docs/configuration.md"},
      "credential_profiles" => [
        target_profile(plugin_id),
        camera_profile(plugin_id)
      ],
      "inventory_sources" => []
    })
  end

  defp target_profile(plugin_id) do
    %{
      "provider" => "example-network",
      "label" => "Example Network",
      "description" => "Package-defined network credentials.",
      "default" => true,
      "auth_methods" => [
        api_token_method(),
        username_password_method(),
        key_pair_method()
      ],
      "purposes" => ["device_inventory", "console_access"],
      "scope_types" => ["agent", "gateway", "partition"],
      "rule_defaults" => %{
        "auth_method" => "api_token",
        "purposes" => ["device_inventory"],
        "target_query" => "in:devices vendor:Example",
        "scope_type" => "agent",
        "allowed_ports" => "443",
        "tls_policy" => "verify",
        "ssh_host_key_policy" => "known_hosts",
        "auto_discovery_enabled" => false
      },
      "rule_controls" => %{
        "allowed_ports" => true,
        "auto_discovery_enabled" => true,
        "target_query" => true,
        "transport" => true
      },
      "provisioning" => %{
        "mode" => "target_policy",
        "consumers" => [
          consumer(plugin_id, "device_inventory", ["api_token", "username_password"]),
          consumer(plugin_id, "console_access", ["username_password", "key_pair"])
        ]
      }
    }
  end

  defp camera_profile(plugin_id) do
    %{
      "provider" => "example-camera",
      "label" => "Example Cameras",
      "auth_methods" => [username_password_method(), api_key_method()],
      "purposes" => ["camera_inventory"],
      "scope_types" => ["agent"],
      "rule_defaults" => %{
        "auth_method" => "username_password",
        "purposes" => ["camera_inventory"],
        "target_query" => ~s(in:devices type:"Camera"),
        "scope_type" => "agent",
        "tls_policy" => "verify"
      },
      # Mirrors the shipped unifi-protect manifest: a second, non-UniFi provider
      # that enables the generic controller_host rule control.
      "rule_controls" => %{
        "controller_host" => true,
        "target_query" => true,
        "transport" => true
      },
      "provisioning" => %{
        "mode" => "target_policy",
        "consumers" => [
          consumer(plugin_id, "camera_inventory", ["username_password", "api_key"])
        ]
      }
    }
  end

  defp api_token_method do
    %{
      "id" => "api_token",
      "label" => "API token",
      "credential_kind" => "api_token",
      "tls_policies" => ["verify"],
      "fields" => [
        %{
          "id" => "token",
          "label" => "API token",
          "control" => "password",
          "required" => true,
          "secret" => true,
          "public" => false
        }
      ],
      "payload" => %{"format" => "scalar", "field" => "token"}
    }
  end

  # Mirrors the shipped unifi-protect and axis manifests: transport rule
  # controls are declared, but the auth method narrows no tls_policies.
  defp api_key_method do
    %{
      "id" => "api_key",
      "label" => "API key",
      "credential_kind" => "api_token",
      "fields" => [
        %{
          "id" => "api_key",
          "label" => "API key",
          "control" => "password",
          "required" => true,
          "secret" => true,
          "public" => false
        }
      ],
      "payload" => %{"format" => "scalar", "field" => "api_key"}
    }
  end

  defp username_password_method do
    %{
      "id" => "username_password",
      "label" => "Username and password",
      "credential_kind" => "username_password",
      "tls_policies" => ["verify", "skip_verify"],
      "fields" => [
        %{
          "id" => "username",
          "label" => "Username",
          "control" => "text",
          "required" => true,
          "secret" => false,
          "public" => true
        },
        %{
          "id" => "password",
          "label" => "Password",
          "control" => "password",
          "required" => true,
          "secret" => true,
          "public" => false
        }
      ],
      "payload" => %{
        "format" => "scalar",
        "field" => "password",
        "username_field" => "username"
      }
    }
  end

  defp key_pair_method do
    %{
      "id" => "key_pair",
      "label" => "Key pair",
      "credential_kind" => "ssh_private_key",
      "ssh_host_key_policies" => ["known_hosts", "trust_on_first_use"],
      "fields" => [
        %{
          "id" => "username",
          "label" => "Username",
          "control" => "text",
          "required" => true,
          "secret" => false,
          "public" => true
        },
        %{
          "id" => "private_key",
          "label" => "Private key",
          "control" => "textarea",
          "required" => true,
          "secret" => true,
          "public" => false
        }
      ],
      "payload" => %{"format" => "json", "username_field" => "username"}
    }
  end

  defp consumer(plugin_id, purpose, auth_methods) do
    %{
      "purpose" => purpose,
      "plugin_id" => plugin_id,
      "auth_methods" => auth_methods,
      "constraints" => %{},
      "failure_mode" => "skip",
      "grant" => %{
        "grant_type" => "example_credential",
        "resolution_location" => "agent",
        "ttl_seconds" => 300
      },
      "params" => %{
        "credential_broker" => %{"$source" => "grant"},
        "credential_secret_ref" => %{"$source" => "secret_ref"},
        "credential_rule_id" => %{"$source" => "rule", "field" => "id"}
      }
    }
  end

  defp seed_scheduled_package! do
    plugin_id = "example-scheduled-plugin"
    schedule_id = "example-scheduled.refresh"

    manifest =
      plugin_id
      |> base_manifest("Example Scheduled Inventory")
      |> Map.update!("capabilities", &(&1 ++ ["producer-schedule:v1"]))
      |> Map.put("producer_schedules", [
        %{
          "schedule_id" => schedule_id,
          "label" => "Refresh scheduled inventory",
          "action_id" => schedule_id,
          "command_type" => "plugin.run_action",
          "default_cadence_seconds" => 86_400,
          "min_cadence_seconds" => 3_600,
          "max_cadence_seconds" => 2_592_000,
          "dispatch_scope" => "assignment",
          "credential_requirements" => %{
            "inventory_account" => %{
              "required" => true,
              "resolution_location" => "agent",
              "grants" => []
            }
          }
        }
      ])
      |> Map.put("integrations", %{
        "documentation" => %{"path" => "docs/configuration.md"},
        "credential_profiles" => [
          %{
            "provider" => "example-scheduled",
            "label" => "Example Scheduled Inventory",
            "auth_methods" => [username_password_method()],
            "purposes" => ["device_inventory"],
            "scope_types" => ["agent"],
            "provisioning" => %{
              "mode" => "producer_schedule",
              "schedule_id" => schedule_id,
              "credential_requirement" => "inventory_account"
            }
          }
        ],
        "inventory_sources" => []
      })

    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["instance_id"],
      "properties" => %{
        "instance_id" => %{
          "type" => "string",
          "title" => "Instance ID",
          "pattern" => "^[A-Za-z0-9._-]+$"
        }
      }
    }

    create_approved_package!(plugin_id, "Example Scheduled Inventory", manifest, schema)
  end

  defp base_manifest(plugin_id, name) do
    %{
      "id" => plugin_id,
      "name" => name,
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["get_config", "log", "submit_result"],
      "permissions" => %{"allowed_domains" => ["*"]},
      "resources" => %{
        "requested_cpu_ms" => 5_000,
        "requested_memory_mb" => 64,
        "max_open_connections" => 2
      }
    }
  end

  defp create_approved_package!(plugin_id, name, manifest, config_schema) do
    actor = system_actor()

    Plugin
    |> Ash.Changeset.for_create(
      :create,
      %{plugin_id: plugin_id, name: name, description: "Test package descriptor"},
      actor: actor
    )
    |> Ash.create!()

    package =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: name,
          version: "1.0.0",
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          config_schema: config_schema,
          signature: %{},
          source_type: :github,
          source_commit: "test-#{plugin_id}"
        },
        actor: actor
      )
      |> Ash.create!()

    assert {:ok, _approved} = Packages.approve(package.id, %{}, actor: actor)
  end

  defp api_token_secret_fixture(scope) do
    credential_secret_fixture(scope, %{
      name: "Example token #{System.unique_integer([:positive])}",
      provider: "example-network",
      credential_kind: :api_token,
      public_fingerprint: "sha256:test",
      secret_payload: "sensitive-token",
      metadata: descriptor_metadata("api_token")
    })
  end

  defp username_password_secret_fixture(scope, provider) do
    credential_secret_fixture(scope, %{
      name: "#{provider} account #{System.unique_integer([:positive])}",
      provider: provider,
      credential_kind: :username_password,
      username: "operator",
      public_fingerprint: "sha256:test",
      secret_payload: "sensitive-password",
      metadata: descriptor_metadata("username_password")
    })
  end

  defp snmp_secret_fixture(scope) do
    suffix = System.unique_integer([:positive])

    credential_secret_fixture(scope, %{
      name: "SNMP credential #{suffix}",
      provider: "snmp",
      credential_kind: :snmp,
      username: "snmp-operator",
      secret_payload: Jason.encode!(%{"username" => "snmp-operator"}),
      metadata: descriptor_metadata("v3")
    })
  end

  defp snmp_profile_fixture(scope, secret, prefix) do
    SNMPProfile
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "#{prefix} #{System.unique_integer([:positive])}",
        version: :v3,
        credential_secret_id: secret.id
      },
      scope: scope
    )
    |> Ash.create!(scope: scope)
  end

  defp descriptor_metadata(auth_method) do
    %{
      "auth_method" => auth_method,
      "credential_descriptor" => "package_manifest.v1"
    }
  end

  defp credential_secret_fixture(scope, attrs) do
    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(:create, attrs, scope: scope)
      |> Ash.create(scope: scope)

    secret
  end

  defp credential_rule_fixture(scope, secret, attrs) do
    defaults = %{
      name: "Example rule #{System.unique_integer([:positive])}",
      provider: "example-network",
      auth_method: "api_token",
      purpose: "device_inventory",
      target_query: "in:devices vendor:Example",
      scope_type: :agent,
      scope_value: "agent-a",
      secret_id: secret.id,
      priority: 50,
      allowed_ports: [443],
      tls_policy: :verify,
      ssh_host_key_policy: :known_hosts,
      metadata: %{"purposes" => ["device_inventory"]}
    }

    {:ok, rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), scope: scope)
      |> Ash.create(scope: scope)

    rule
  end

  defp default_rule_form_params(secret_id) do
    %{
      "name" => "Example inventory rule",
      "description" => "",
      "provider" => "example-network",
      "auth_method" => "api_token",
      "purposes" => ["device_inventory"],
      "target_query" => "in:devices vendor:Example",
      "scope_type" => "agent",
      "scope_value" => "agent-a",
      "secret_id" => secret_id,
      "priority" => "25",
      "allowed_ports" => "443",
      "tls_policy" => "verify",
      "auto_discovery_enabled" => "true"
    }
  end

  defp scheduled_rule_form_params(secret_id) do
    %{
      "name" => "Scheduled inventory",
      "description" => "",
      "provider" => "example-scheduled",
      "auth_method" => "username_password",
      "purposes" => ["device_inventory"],
      "target_query" => "in:agents",
      "scope_type" => "agent",
      "scope_value" => "agent-k8s",
      "secret_id" => secret_id,
      "priority" => "100",
      "tls_policy" => "verify",
      "plugin_config" => %{"instance_id" => "example-prod"},
      "schedule_enabled" => "false",
      "cadence_seconds" => "86400"
    }
  end

  defp checked_purpose?(html, purpose) do
    html =~ ~r/checked[^>]*value="#{purpose}"|value="#{purpose}"[^>]*checked/
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

  defp scope_value_control(html) do
    cond do
      html =~ ~r/<select[^>]+name="credential_rule\[scope_value\]"/ -> :select
      html =~ ~r/<input[^>]+name="credential_rule\[scope_value\]"/ -> :input
      true -> :missing
    end
  end
end
