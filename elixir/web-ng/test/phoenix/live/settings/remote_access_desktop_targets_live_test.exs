defmodule ServiceRadarWebNGWeb.Settings.RemoteAccessDesktopTargetsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

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

  test "renders the RDP desktop target settings route", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/desktop-targets")

    assert html =~ "RDP Desktop Targets"
    assert html =~ "No RDP desktop targets found"
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

  test "creates an RDP desktop target from the settings form", %{conn: conn, scope: scope} do
    target_name = "Finance RDP #{System.unique_integer([:positive])}"

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
    assert target.allowed_principals == ["CARVER\\alice", "CARVER\\bob"]
    assert target.screen_policy["max_width"] == 1920
    assert target.redirection_policy["clipboard"] == "disabled"
    assert target.metadata["rdp.kdc_proxy_url"] == "tcp://kdc.finance.example.test:88"
    assert target.metadata["rdp.kerberos_hostname"] == "win-finance-1.example.test"
  end

  test "edits and disables an RDP desktop target", %{conn: conn, scope: scope} do
    target = desktop_target_fixture("patch")

    {:ok, lv, html} = live(conn, ~p"/settings/networks/desktop-targets/#{target.id}/edit")
    assert html =~ "Edit RDP Desktop Target"

    lv
    |> form("form[phx-submit='save_target']",
      desktop_target:
        Map.merge(target_form_params(target), %{
          "description" => "Updated target",
          "target_port" => "3390",
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
    assert updated.redirection_policy["clipboard"] == "local_to_remote"
    assert updated.metadata["rdp.kdc_proxy_url"] == "tcp://kdc.patch.example.test:88"
    assert updated.metadata["rdp.kerberos_hostname"] == "rdp-patch.example.test"
    assert updated.metadata["existing"] == "kept"

    lv
    |> element("button[phx-click='disable_target'][phx-value-id='#{target.id}']")
    |> render_click()

    html = render(lv)
    assert html =~ "RDP desktop target disabled"
    assert get_target_by_name!(scope, target.name).enabled == false
  end

  test "rejects non-TCP KDC proxy URLs in the settings form", %{conn: conn} do
    target_name = "Invalid KDC #{System.unique_integer([:positive])}"

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

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp desktop_target_fixture(label) do
    unique = System.unique_integer([:positive])

    RemoteAccessDesktopTarget.create_target!(
      %{
        name: "RDP #{label} #{unique}",
        description: "Initial target",
        device_uid: "rdp-#{label}-#{unique}",
        target_host: "rdp-#{label}-#{unique}.example.test",
        target_port: 3389,
        agent_id: "agent-#{label}",
        gateway_id: "gateway-#{label}",
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
        actor: system_actor()
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

  defp target_form_params(%RemoteAccessDesktopTarget{} = target) do
    %{
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
    }
  end

  defp get_target_by_name!(scope, name) do
    {:ok, targets} = RemoteAccessDesktopTargets.list_managed(scope)
    Enum.find(targets, &(&1.name == name))
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
