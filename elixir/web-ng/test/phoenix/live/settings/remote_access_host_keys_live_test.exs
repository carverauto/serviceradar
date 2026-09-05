defmodule ServiceRadarWebNGWeb.Settings.RemoteAccessHostKeysLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias ServiceRadar.Edge.RemoteAccessHostKeys
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  @xss_payloads [
    "<script>alert(1)</script>",
    "\"><img src=x onerror=alert(1)>",
    "' onmouseover='alert(1)",
    "<svg><animate onbegin=alert(1) attributeName=x /></svg>"
  ]

  setup :register_and_log_in_admin_user

  test "renders the host-key settings route", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/host-keys")

    assert html =~ "Remote Access Host Keys"
    assert html =~ "No host keys found"
  end

  test "viewer is blocked from host-key settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/networks/host-keys")
    assert to == ~p"/settings/profile"
  end

  test "rechecks manage permission before host-key mutation events", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    user = grant_permissions(user, ["settings.remote_access_host_keys.manage"])
    conn = log_in_user(conn, user)

    {:ok, %{host_key: host_key}} =
      RemoteAccessHostKeys.observe(observation("reauth"), actor: system_actor())

    {:ok, lv, html} = live(conn, ~p"/settings/networks/host-keys")
    assert html =~ host_key.fingerprint_sha256

    ServiceRadar.Identity.RBAC.Cache.put(user.id, MapSet.new())

    lv
    |> element("button[phx-click='trust_host_key'][phx-value-id='#{host_key.id}']")
    |> render_click()

    assert_redirect(lv, ~p"/settings/profile")

    assert {:ok, reloaded} = RemoteAccessHostKeys.get(host_key.id, actor: system_actor())
    assert reloaded.status == :pending
  end

  test "trusts a pending host key", %{conn: conn} do
    {:ok, %{host_key: host_key}} =
      RemoteAccessHostKeys.observe(observation("trust"), actor: system_actor())

    {:ok, lv, html} = live(conn, ~p"/settings/networks/host-keys")

    assert html =~ host_key.target_host
    assert html =~ "Pending"

    lv
    |> element("button[phx-click='trust_host_key'][phx-value-id='#{host_key.id}']")
    |> render_click()

    html = render(lv)
    assert html =~ "Host key trusted"
    assert html =~ "Trusted"
  end

  property "host-key table text fields are HTML escaped", %{conn: conn} do
    check all(payload <- StreamData.member_of(@xss_payloads), max_runs: length(@xss_payloads)) do
      {:ok, %{host_key: _host_key}} =
        RemoteAccessHostKeys.observe(
          observation("escaped",
            target_host: payload,
            agent_id: payload,
            gateway_id: payload,
            key_type: payload,
            fingerprint_sha256: payload
          ),
          actor: system_actor()
        )

      {:ok, _lv, html} = live(conn, ~p"/settings/networks/host-keys")

      escaped_payload =
        payload
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string()

      refute html =~ payload
      assert html =~ escaped_payload
    end
  end

  test "rotates a trusted host key to an observed replacement", %{conn: conn} do
    target_host = unique_host("rotate")

    {:ok, %{host_key: trusted}} =
      RemoteAccessHostKeys.observe(
        observation(target_host,
          fingerprint_sha256: "SHA256:old-#{target_host}",
          source: :trust_on_first_use
        ),
        actor: system_actor()
      )

    {:ok, %{host_key: conflict}} =
      RemoteAccessHostKeys.observe(
        observation(target_host, fingerprint_sha256: "SHA256:new-#{target_host}"),
        actor: system_actor()
      )

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/host-keys")

    lv
    |> element("button[phx-click='show_rotate'][phx-value-id='#{trusted.id}']")
    |> render_click()

    assert render(lv) =~ conflict.fingerprint_sha256

    lv
    |> form("form[phx-submit='rotate_host_key']",
      rotation: %{
        "replacement_host_key_id" => conflict.id,
        "reason" => "test rotation"
      }
    )
    |> render_submit()

    html = render(lv)
    assert html =~ "Host key rotated"
    assert html =~ "Rotated"
    assert html =~ "Trusted"
  end

  test "rejects conflict host keys instead of trusting them directly", %{conn: conn} do
    target_host = unique_host("reject")

    {:ok, %{host_key: trusted}} =
      RemoteAccessHostKeys.observe(
        observation(target_host,
          fingerprint_sha256: "SHA256:old-#{target_host}",
          source: :trust_on_first_use
        ),
        actor: system_actor()
      )

    {:ok, %{host_key: conflict}} =
      RemoteAccessHostKeys.observe(
        observation(target_host, fingerprint_sha256: "SHA256:new-#{target_host}"),
        actor: system_actor()
      )

    {:ok, lv, html} = live(conn, ~p"/settings/networks/host-keys")

    assert html =~ trusted.fingerprint_sha256
    assert html =~ conflict.fingerprint_sha256
    refute has_element?(lv, "button[phx-click='trust_host_key'][phx-value-id='#{conflict.id}']")

    lv
    |> element("button[phx-click='reject_host_key'][phx-value-id='#{conflict.id}']")
    |> render_click()

    html = render(lv)
    assert html =~ "Host key rejected"
    assert html =~ "Rejected"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp grant_permissions(user, permissions) do
    unique = System.unique_integer([:positive])

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Host key LiveView #{unique}",
          description: "Test profile for host-key LiveView permissions",
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

  defp observation(label, overrides \\ %{}) do
    target_host = if String.contains?(label, "."), do: label, else: unique_host(label)

    Map.merge(
      %{
        device_uid: "device-#{target_host}",
        target_host: target_host,
        target_port: 22,
        protocol: :ssh,
        agent_id: "agent-host-key-live-test",
        gateway_id: "gateway-host-key-live-test",
        key_type: "ssh-ed25519",
        fingerprint_sha256: "SHA256:#{target_host}",
        public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI#{target_host}",
        source: :agent_observed,
        metadata: %{}
      },
      Map.new(overrides)
    )
  end

  defp unique_host(label) do
    "remote-access-host-key-#{label}-#{System.unique_integer([:positive])}.example.test"
  end
end
