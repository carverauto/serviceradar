defmodule ServiceRadarWebNGWeb.Settings.RemoteAccessDesktopTargetsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Edge.RemoteAccessDesktopTarget
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.RemoteAccessDesktopTargets

  setup :register_and_log_in_admin_user

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled)
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

    on_exit(fn ->
      restore_env(:remote_access_desktop_rdp_enabled, previous)
    end)
  end

  test "renders the RDP access settings route", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/desktop-targets")

    assert html =~ "RDP Access"
    assert html =~ "No RDP hosts are configured yet"
    assert html =~ "Add RDP Host"
  end

  test "viewer is blocked from RDP desktop target settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/networks/desktop-targets")
    assert to == ~p"/settings/profile"
  end

  test "rechecks manage permission before desktop target mutation events", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    user = grant_permissions(user, ["settings.edge.manage"])
    conn = log_in_user(conn, user)
    target = desktop_target_fixture("reauth")

    {:ok, lv, html} = live(conn, ~p"/settings/networks/desktop-targets")
    assert html =~ target.name

    ServiceRadar.Identity.RBAC.Cache.put(user.id, MapSet.new())

    lv
    |> element("button[phx-click='disable_target'][phx-value-id='#{target.id}']")
    |> render_click()

    assert_redirect(lv, ~p"/settings/profile")

    {:ok, reloaded} = RemoteAccessDesktopTarget.get_by_id(target.id, actor: system_actor())
    assert reloaded.enabled
  end

  test "route is blocked when RDP desktop access is disabled", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, false)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/networks/desktop-targets")
    assert to == ~p"/settings/profile"
  end

  test "creates an RDP host from the settings form without a credential rule", %{
    conn: conn,
    scope: scope
  } do
    target_name = "Finance RDP #{System.unique_integer([:positive])}"
    rdp_route_fixture("finance")

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/desktop-targets/new")

    lv
    |> form("form[phx-submit='save_target']",
      desktop_target: %{
        "name" => target_name,
        "description" => "Finance jump desktop",
        "enabled" => "true",
        "target_kind" => "inventory_device",
        "device_uid" => "win-finance-1",
        "target_host" => "win-finance-1.example.test",
        "target_port" => "3389",
        "agent_id" => "agent-finance",
        "gateway_id" => "gateway-finance",
        "credential_custody_mode" => "user_present",
        "credential_rule_id" => "",
        "target_tls_mode" => "verify_ca",
        "target_tls_server_name" => "win-finance-1.example.test",
        "target_tls_ca_bundle_pem" => test_ca_bundle_pem(),
        "nla_required" => "true",
        "recording_mode" => "metadata_only",
        "kdc_proxy_url" => "tcp://kdc.finance.example.test:88",
        "kerberos_hostname" => "win-finance-1.example.test",
        "max_width" => "1920",
        "max_height" => "1080",
        "frame_rate" => "30",
        "bitrate_kbps" => "4096",
        "clipboard" => "disabled",
        "allowed_principals" => "CARVER\\alice\nCARVER\\bob"
      }
    )
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/desktop-targets")
    html = render(lv)
    assert html =~ target_name
    assert html =~ "win-finance-1.example.test:3389"

    target = get_target_by_name!(scope, target_name)
    assert target.agent_id == "agent-finance"
    assert target.credential_custody_mode == :user_present
    assert target.credential_rule_id == nil
    assert target.target_tls["mode"] == "verify_ca"
    assert target.target_tls["server_name"] == "win-finance-1.example.test"
    assert target.target_tls["ca_bundle_id"] == "rdp-ca-win-finance-1-example-test"
    assert target.target_tls["ca_bundle_pem"] == test_ca_bundle_pem()
    assert target.allowed_principals == ["CARVER\\alice", "CARVER\\bob"]
    assert target.screen_policy["max_width"] == 1920
    assert target.redirection_policy["clipboard"] == "disabled"
    assert target.metadata["rdp.kdc_proxy_url"] == "tcp://kdc.finance.example.test:88"
    assert target.metadata["rdp.kerberos_hostname"] == "win-finance-1.example.test"
  end

  test "prefills target details from an inventory device selection", %{conn: conn} do
    gateway =
      gateway_fixture(%{
        id: "rdp-prefill-gw",
        component_id: "rdp-prefill-component"
      })

    agent =
      agent_fixture(gateway, %{
        uid: "rdp-prefill-agent",
        name: "RDP Prefill Agent"
      })

    device =
      device_fixture(%{
        uid: "rdp-prefill-device",
        hostname: "win-prefill.example.test",
        ip: "192.0.2.126",
        agent_id: agent.uid,
        availability_source_agent_id: agent.uid,
        gateway_id: gateway.id
      })

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/settings/networks/desktop-targets/new?device_uid=#{device.uid}&target_host=#{device.ip}"
      )

    assert html =~ "Enable RDP Access"
    assert html =~ "RDP Prefill Agent"
    assert html =~ "rdp-prefill-gw"
    assert html =~ ~s(value="192.0.2.126")
    refute html =~ "Device UID"
    refute html =~ "Agent ID"
    refute html =~ "Credential Rule ID"
  end

  test "lists credential rules but still defaults to prompt-at-connect", %{
    conn: conn,
    scope: scope
  } do
    secret = credential_secret_fixture(scope)

    rule =
      credential_rule_fixture(scope, secret, %{
        name: "Windows admin credential",
        provider: "rdp",
        auth_method: :username_password,
        purpose: :console_access,
        target_query: "in:devices",
        scope_type: :agent,
        scope_value: "agent-finance",
        allowed_ports: [3389]
      })

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/desktop-targets/new")

    assert html =~ "Prompt user when connecting"
    assert html =~ "Use a credential rule"
    assert html =~ "Windows admin credential"
    assert html =~ rule.id
    assert html =~ ~s(value="user_present")
  end

  test "requires a credential rule only when brokered sign-in is selected", %{conn: conn} do
    target_name = "Brokered missing rule #{System.unique_integer([:positive])}"
    rdp_route_fixture("brokered")

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/desktop-targets/new")

    html =
      lv
      |> form("form[phx-submit='save_target']",
        desktop_target:
          default_target_form_params(%{
            "name" => target_name,
            "device_uid" => "win-brokered-1",
            "target_host" => "win-brokered-1.example.test",
            "agent_id" => "agent-brokered",
            "gateway_id" => "gateway-brokered",
            "credential_custody_mode" => "centrally_brokered",
            "credential_rule_id" => ""
          })
      )
      |> render_submit()

    assert html =~ "Choose a credential rule or use Prompt user when connecting"
  end

  test "edits and disables an RDP desktop target", %{conn: conn, scope: scope} do
    target = desktop_target_fixture("patch")

    {:ok, lv, html} = live(conn, ~p"/settings/networks/desktop-targets/#{target.id}/edit")
    assert html =~ "Edit RDP Access"

    lv
    |> form("form[phx-submit='save_target']",
      desktop_target:
        Map.merge(target_form_params(target), %{
          "description" => "Updated target",
          "target_port" => "3390",
          "target_tls_server_name" => "rdp-patch.example.test",
          "target_tls_ca_bundle_pem" => test_ca_bundle_pem(),
          "clipboard" => "local_to_remote",
          "kdc_proxy_url" => "tcp://kdc.patch.example.test:88",
          "kerberos_hostname" => "rdp-patch.example.test"
        })
    )
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/desktop-targets")
    html = render(lv)
    assert html =~ "Updated target"
    assert html =~ "local_to_remote"

    updated = get_target_by_name!(scope, target.name)
    assert updated.target_port == 3390
    assert updated.target_tls["server_name"] == "rdp-patch.example.test"
    assert updated.target_tls["ca_bundle_id"] == "rdp-ca-rdp-patch-example-test"
    assert updated.target_tls["ca_bundle_pem"] == test_ca_bundle_pem()
    assert updated.redirection_policy["clipboard"] == "local_to_remote"
    assert updated.metadata["rdp.kdc_proxy_url"] == "tcp://kdc.patch.example.test:88"
    assert updated.metadata["rdp.kerberos_hostname"] == "rdp-patch.example.test"
    assert updated.metadata["existing"] == "kept"

    lv
    |> element("button[phx-click='disable_target'][phx-value-id='#{target.id}']")
    |> render_click()

    html = render(lv)
    assert html =~ "RDP host disabled"
    assert get_target_by_name!(scope, target.name).enabled == false
  end

  test "rejects non-TCP KDC proxy URLs in the settings form", %{conn: conn} do
    target_name = "Invalid KDC #{System.unique_integer([:positive])}"
    rdp_route_fixture("invalid-kdc")

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/desktop-targets/new")

    html =
      lv
      |> form("form[phx-submit='save_target']",
        desktop_target: %{
          "name" => target_name,
          "description" => "",
          "enabled" => "true",
          "target_kind" => "inventory_device",
          "device_uid" => "win-invalid-kdc-1",
          "target_host" => "win-invalid-kdc-1.example.test",
          "target_port" => "3389",
          "agent_id" => "agent-invalid-kdc",
          "gateway_id" => "gateway-invalid-kdc",
          "credential_custody_mode" => "user_present",
          "credential_rule_id" => "",
          "target_tls_mode" => "verify_ca",
          "target_tls_server_name" => "",
          "target_tls_ca_bundle_id" => "",
          "target_tls_ca_bundle_pem" => "",
          "nla_required" => "true",
          "recording_mode" => "metadata_only",
          "kdc_proxy_url" => "https://kdc.example.test",
          "kerberos_hostname" => "win-invalid-kdc-1.example.test",
          "max_width" => "",
          "max_height" => "",
          "frame_rate" => "",
          "bitrate_kbps" => "",
          "clipboard" => "disabled",
          "allowed_principals" => ""
        }
      )
      |> render_submit()

    assert html =~ "KDC Proxy URL must use tcp://"
  end

  test "generates a TLS CA bundle identifier when CA PEM is provided", %{conn: conn, scope: scope} do
    target_name = "Generated CA bundle #{System.unique_integer([:positive])}"
    rdp_route_fixture("invalid-ca")

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/desktop-targets/new")

    lv
    |> form("form[phx-submit='save_target']",
      desktop_target: %{
        "name" => target_name,
        "description" => "",
        "enabled" => "true",
        "target_kind" => "inventory_device",
        "device_uid" => "win-invalid-ca-1",
        "target_host" => "win-invalid-ca-1.example.test",
        "target_port" => "3389",
        "agent_id" => "agent-invalid-ca",
        "gateway_id" => "gateway-invalid-ca",
        "credential_custody_mode" => "user_present",
        "credential_rule_id" => "",
        "target_tls_mode" => "verify_ca",
        "target_tls_server_name" => "win-invalid-ca-1.example.test",
        "target_tls_ca_bundle_pem" => test_ca_bundle_pem(),
        "nla_required" => "true",
        "recording_mode" => "metadata_only",
        "kdc_proxy_url" => "",
        "kerberos_hostname" => "",
        "max_width" => "",
        "max_height" => "",
        "frame_rate" => "",
        "bitrate_kbps" => "",
        "clipboard" => "disabled",
        "allowed_principals" => ""
      }
    )
    |> render_submit()

    assert_patch(lv, ~p"/settings/networks/desktop-targets")
    target = get_target_by_name!(scope, target_name)
    assert target.target_tls["ca_bundle_id"] == "rdp-ca-win-invalid-ca-1-example-test"
    assert target.target_tls["ca_bundle_pem"] == test_ca_bundle_pem()
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp desktop_target_fixture(label) do
    unique = System.unique_integer([:positive])
    route = rdp_route_fixture(label, unique: unique)

    RemoteAccessDesktopTarget.create_target!(
      %{
        name: "RDP #{label} #{unique}",
        description: "Initial target",
        device_uid: route.device.uid,
        target_host: "rdp-#{label}-#{unique}.example.test",
        target_port: 3389,
        agent_id: route.agent.uid,
        gateway_id: route.gateway.id,
        credential_custody_mode: :user_present,
        target_tls: %{"mode" => "verify_ca"},
        nla: %{"required" => true},
        redirection_policy: %{"clipboard" => "disabled"},
        recording_policy: %{"mode" => "metadata_only"},
        metadata: %{"existing" => "kept"}
      },
      actor: system_actor()
    )
  end

  defp rdp_route_fixture(label, opts \\ []) do
    unique = Keyword.get(opts, :unique, System.unique_integer([:positive]))

    gateway =
      gateway_fixture(%{
        id: "gateway-#{label}",
        component_id: "component-rdp-#{label}-#{unique}"
      })

    agent =
      agent_fixture(gateway, %{
        uid: "agent-#{label}",
        name: "Agent #{label}"
      })

    device =
      device_fixture(%{
        uid: "win-#{label}-1",
        hostname: "win-#{label}-1.example.test",
        ip: "192.0.2.#{rem(unique, 200) + 1}",
        agent_id: agent.uid,
        availability_source_agent_id: agent.uid,
        gateway_id: gateway.id
      })

    %{gateway: gateway, agent: agent, device: device}
  end

  defp grant_permissions(user, permissions) do
    unique = System.unique_integer([:positive])

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "RDP target LiveView #{unique}",
          description: "Test profile for RDP desktop target LiveView permissions",
          permissions: permissions
        },
        actor: system_actor(),
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    updated =
      user
      |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id}, actor: system_actor())
      |> Ash.update!()

    RBAC.clear_process_cache()
    RBAC.Cache.put(updated.id, MapSet.new(permissions))

    updated
  end

  defp credential_secret_fixture(scope) do
    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "RDP password #{System.unique_integer([:positive])}",
          provider: "rdp",
          credential_kind: :username_password,
          username: "administrator",
          public_fingerprint: "username:administrator",
          secret_payload: ~s({"username":"administrator","password":"secret"}),
          metadata: %{}
        },
        scope: scope
      )
      |> Ash.create(scope: scope)

    secret
  end

  defp credential_rule_fixture(scope, secret, attrs) do
    defaults = %{
      name: "RDP rule #{System.unique_integer([:positive])}",
      provider: "rdp",
      auth_method: :username_password,
      purpose: :console_access,
      target_query: "in:devices",
      scope_type: :agent,
      scope_value: "agent-rdp",
      secret_id: secret.id,
      priority: 50,
      allowed_ports: [3389],
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

  defp target_form_params(%RemoteAccessDesktopTarget{} = target) do
    default_target_form_params(%{
      "name" => target.name,
      "description" => target.description || "",
      "enabled" => if(target.enabled, do: "true", else: "false"),
      "target_kind" => to_string(target.target_kind),
      "device_uid" => target.device_uid,
      "target_host" => target.target_host,
      "target_port" => to_string(target.target_port),
      "agent_id" => target.agent_id || "",
      "gateway_id" => target.gateway_id || "",
      "credential_custody_mode" => to_string(target.credential_custody_mode),
      "credential_rule_id" => target.credential_rule_id || "",
      "target_tls_mode" => target.target_tls["mode"],
      "target_tls_server_name" => target.target_tls["server_name"] || "",
      "target_tls_ca_bundle_id" => target.target_tls["ca_bundle_id"] || "",
      "target_tls_ca_bundle_pem" => target.target_tls["ca_bundle_pem"] || "",
      "nla_required" => "true",
      "recording_mode" => target.recording_policy["mode"],
      "kdc_proxy_url" => target.metadata["rdp.kdc_proxy_url"] || "",
      "kerberos_hostname" => target.metadata["rdp.kerberos_hostname"] || "",
      "max_width" => "",
      "max_height" => "",
      "frame_rate" => "",
      "bitrate_kbps" => "",
      "clipboard" => target.redirection_policy["clipboard"],
      "allowed_principals" => ""
    })
  end

  defp default_target_form_params(overrides) do
    Map.merge(
      %{
        "name" => "",
        "description" => "",
        "enabled" => "true",
        "target_kind" => "inventory_device",
        "device_uid" => "win-default-1",
        "target_host" => "win-default-1.example.test",
        "target_port" => "3389",
        "agent_id" => "",
        "gateway_id" => "",
        "credential_custody_mode" => "user_present",
        "credential_rule_id" => "",
        "target_tls_mode" => "verify_ca",
        "target_tls_server_name" => "",
        "target_tls_ca_bundle_id" => "",
        "target_tls_ca_bundle_pem" => "",
        "nla_required" => "true",
        "recording_mode" => "metadata_only",
        "kdc_proxy_url" => "",
        "kerberos_hostname" => "",
        "max_width" => "",
        "max_height" => "",
        "frame_rate" => "",
        "bitrate_kbps" => "",
        "clipboard" => "disabled",
        "allowed_principals" => ""
      },
      overrides
    )
  end

  defp get_target_by_name!(scope, name) do
    {:ok, targets} = RemoteAccessDesktopTargets.list_managed(scope)
    Enum.find(targets, &(&1.name == name))
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  defp test_ca_bundle_pem do
    Enum.join(
      [
        "-----BEGIN CERTIFICATE-----",
        "MIIB",
        "-----END CERTIFICATE-----"
      ],
      "\n"
    )
  end
end
