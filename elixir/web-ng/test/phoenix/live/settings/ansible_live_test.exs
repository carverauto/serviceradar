defmodule ServiceRadarWebNGWeb.Settings.AnsibleLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.PlaybookRepository
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNGWeb.Settings.AnsibleLive

  setup :register_and_log_in_admin_user

  test "disconnected mount builds inert state from cached permissions", %{user: user} do
    scope =
      Scope.for_user(user,
        permissions: MapSet.new(["ansible.controllers.manage"])
      )

    disconnected_socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: scope},
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }

    assert {:ok, mounted_socket} = AnsibleLive.mount(%{}, %{}, disconnected_socket)

    assert mounted_socket.assigns.settings_loaded == false
    assert mounted_socket.assigns.controller_count == 0
    assert mounted_socket.assigns.repository_count == 0
    assert mounted_socket.assigns.awx_credential_secrets == []
    assert mounted_socket.assigns.tabs == [controllers: "Controllers"]
    refute mounted_socket.assigns.can_manage_ansible_repositories
  end

  test "controller-only role sees and invokes only the controller workflow", %{
    conn: conn,
    user: user
  } do
    user = grant_permissions(user, ["ansible.controllers.manage"])
    conn = log_in_user(conn, user)

    {:ok, live_view, _html} = live(conn, ~p"/settings/ansible")

    assert has_element?(live_view, "[role='tab'][phx-value-tab='controllers']")
    refute has_element?(live_view, "[role='tab'][phx-value-tab='repositories']")
    refute has_element?(live_view, "[role='tab'][phx-value-tab='retention']")
    assert has_element?(live_view, "button[phx-click='new_controller']")
    refute has_element?(live_view, "button[phx-click='new_repository']")

    render_click(live_view, "new_controller", %{})
    refute has_element?(live_view, "input[name='controller[run_pulse_interval_ms]']")

    html = render_click(live_view, "new_repository", %{})

    assert html =~ "Your Ansible settings permissions changed"
    refute has_element?(live_view, "#ansible-repository-form")
  end

  test "repository-only role sees and invokes only the repository workflow", %{
    conn: conn,
    user: user
  } do
    user = grant_permissions(user, ["ansible.repositories.manage"])
    conn = log_in_user(conn, user)

    {:ok, live_view, _html} = live(conn, ~p"/settings/ansible")

    assert has_element?(live_view, "#settings-view-tree a[href='/settings/ansible']")
    assert has_element?(live_view, "[role='tab'][href='/settings/ansible']")
    assert has_element?(live_view, "nav[aria-label='Breadcrumb'] a[href='/settings/ansible']")

    assert has_element?(
             live_view,
             "[data-command-palette-item] a[href='/settings/ansible']"
           )

    assert has_element?(live_view, "[role='tab'][phx-value-tab='repositories']")
    refute has_element?(live_view, "[role='tab'][phx-value-tab='controllers']")
    refute has_element?(live_view, "[role='tab'][phx-value-tab='retention']")
    assert has_element?(live_view, "button[phx-click='new_repository']")
    refute has_element?(live_view, "button[phx-click='new_controller']")

    html = render_click(live_view, "new_controller", %{})

    assert html =~ "Your Ansible settings permissions changed"
    refute has_element?(live_view, "#ansible-controller-form")
  end

  test "repository cancel closes only the repository form", %{conn: conn, user: user} do
    user = grant_permissions(user, ["ansible.repositories.manage"])
    conn = log_in_user(conn, user)

    {:ok, live_view, _html} = live(conn, ~p"/settings/ansible")

    live_view
    |> element("button[phx-click='new_repository']")
    |> render_click()

    assert has_element?(live_view, "#ansible-repository-form")

    live_view
    |> element("button[phx-click='cancel_repository_form']")
    |> render_click()

    refute has_element?(live_view, "#ansible-repository-form")
    refute has_element?(live_view, "#ansible-controller-form")
  end

  test "does not expose the fail-closed schedule workflow", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, ~p"/settings/ansible")

    refute has_element?(
             live_view,
             "[role='tab'][phx-click='select_tab'][phx-value-tab='schedules']"
           )

    refute has_element?(live_view, "button[phx-click='new_schedule']")
    refute has_element?(live_view, "button[phx-click='toggle_schedule']")

    html = render_click(live_view, "select_tab", %{"tab" => "schedules"})

    refute html =~ "+ Add schedule"
    refute html =~ ~s(name="schedule[enabled]")
    refute html =~ "Schedule evaluator interval"
  end

  test "creates a sync-only controller from a raw AWX token without elevating other purposes", %{
    conn: conn
  } do
    controller_name = "AWX Controller #{System.unique_integer([:positive])}"
    raw_token = "awx-test-token-#{System.unique_integer([:positive])}"

    {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

    lv
    |> element("button", "+ Add controller")
    |> render_click()

    html =
      lv
      |> form("#ansible-controller-form", %{
        "controller" => %{
          "name" => controller_name,
          "agent_id" => "k8s-agent",
          "description" => "",
          "base_url" => "http://awx-service.awx.svc.cluster.local",
          "sync_awx_api_token" => raw_token,
          "credential_secret_id" => "",
          "sync_credential_secret_id" => "",
          "execution_credential_secret_id" => "",
          "callback_credential_secret_id" => "",
          "inventory_sync_interval_seconds" => "300",
          "catalog_sync_interval_seconds" => "600"
        }
      })
      |> render_submit()

    refute html =~ raw_token

    controller = controller_by_name!(controller_name)
    assert controller.agent_id == "k8s-agent"
    assert controller.base_url == "http://awx-service.awx.svc.cluster.local"
    assert controller.sync_credential_secret_id
    assert controller.credential_secret_id == controller.sync_credential_secret_id
    assert controller.execution_credential_secret_id == nil
    assert controller.callback_credential_secret_id == nil

    secret =
      NetworkCredentialSecret.get_by_id!(controller.sync_credential_secret_id,
        actor: system_actor()
      )

    assert secret.provider == "awx"
    assert secret.credential_kind == :api_token
    assert secret.metadata["source"] == "ansible_controller_form"
    assert secret.metadata["credential_purpose"] == "sync"
    refute inspect(secret) =~ raw_token
  end

  test "keeps a pasted sync token across phx-change so save does not report missing sync", %{
    conn: conn
  } do
    controller_name = "AWX Controller #{System.unique_integer([:positive])}"
    raw_token = "awx-test-token-#{System.unique_integer([:positive])}"

    {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

    form_html =
      lv
      |> element("button", "+ Add controller")
      |> render_click()

    assert form_html =~ ~s(id="controller-sync-awx-api-token")
    assert form_html =~ ~s(phx-update="ignore")
    assert form_html =~ ~s(id="controller-execution-awx-api-token")
    assert form_html =~ ~s(id="controller-callback-awx-api-token")

    lv
    |> form("#ansible-controller-form", %{
      "controller" => %{
        "name" => controller_name,
        "agent_id" => "k8s-agent",
        "description" => "",
        "base_url" => "http://awx-service.awx.svc.cluster.local",
        "sync_awx_api_token" => raw_token,
        "credential_secret_id" => "",
        "sync_credential_secret_id" => "",
        "execution_credential_secret_id" => "",
        "callback_credential_secret_id" => "",
        "inventory_sync_interval_seconds" => "300",
        "catalog_sync_interval_seconds" => "600"
      }
    })
    |> render_change()

    # Browser LiveView patches wipe hardcoded value="" password inputs. Save
    # after validate therefore often arrives with an empty token field; the
    # pending assign must still create the controller.
    html =
      lv
      |> form("#ansible-controller-form", %{
        "controller" => %{
          "name" => controller_name,
          "agent_id" => "k8s-agent",
          "description" => "",
          "base_url" => "http://awx-service.awx.svc.cluster.local",
          "sync_awx_api_token" => "",
          "credential_secret_id" => "",
          "sync_credential_secret_id" => "",
          "execution_credential_secret_id" => "",
          "callback_credential_secret_id" => "",
          "inventory_sync_interval_seconds" => "300",
          "catalog_sync_interval_seconds" => "600"
        }
      })
      |> render_submit()

    refute html =~ "missing_awx_credential"
    refute html =~ "Ash.Error.Unknown"
    assert html =~ "Controller \"#{controller_name}\" created."

    controller = controller_by_name!(controller_name)
    assert controller.sync_credential_secret_id
  end

  test "missing sync credential flashes an operator message instead of Ash.Error", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

    lv
    |> element("button", "+ Add controller")
    |> render_click()

    html =
      lv
      |> form("#ansible-controller-form", %{
        "controller" => %{
          "name" => "Missing Sync #{System.unique_integer([:positive])}",
          "agent_id" => "k8s-agent",
          "base_url" => "http://awx-service.awx.svc.cluster.local",
          "sync_awx_api_token" => "",
          "sync_credential_secret_id" => "",
          "credential_secret_id" => ""
        }
      })
      |> render_submit()

    assert html =~ "Enter a sync AWX API token or select an existing sync credential."
    refute html =~ "Ash.Error.Unknown"
    refute html =~ "missing_awx_credential"
  end

  test "links a DB-backed AWX secret selected from the credential dropdown", %{
    conn: conn,
    scope: scope
  } do
    controller_name = "AWX From Secret #{System.unique_integer([:positive])}"
    sync_secret = awx_secret_fixture(scope, "sync")
    execution_secret = awx_secret_fixture(scope, "execution")

    {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

    form_html =
      lv
      |> element("button", "+ Add controller")
      |> render_click()

    # The DB-backed AWX secret is offered by name in a dropdown; no UUID typing.
    assert form_html =~ sync_secret.name
    assert form_html =~ execution_secret.name
    assert form_html =~ ~s(name="controller[sync_credential_secret_id]")
    assert form_html =~ ~s(name="controller[execution_credential_secret_id]")
    assert form_html =~ ~s(name="controller[callback_credential_secret_id]")
    assert form_html =~ "Existing sync credential secret"

    lv
    |> form("#ansible-controller-form", %{
      "controller" => %{
        "name" => controller_name,
        "agent_id" => "k8s-agent",
        "description" => "",
        "base_url" => "http://awx-service.awx.svc.cluster.local",
        "sync_awx_api_token" => "",
        "credential_secret_id" => "",
        "sync_credential_secret_id" => sync_secret.id,
        "execution_credential_secret_id" => execution_secret.id,
        "callback_credential_secret_id" => execution_secret.id,
        "inventory_sync_interval_seconds" => "300",
        "catalog_sync_interval_seconds" => "600"
      }
    })
    |> render_submit()

    controller = controller_by_name!(controller_name)
    assert to_string(controller.credential_secret_id) == to_string(sync_secret.id)
    assert to_string(controller.sync_credential_secret_id) == to_string(sync_secret.id)

    assert to_string(controller.execution_credential_secret_id) ==
             to_string(execution_secret.id)

    assert to_string(controller.callback_credential_secret_id) ==
             to_string(execution_secret.id)
  end

  describe "listing timestamps" do
    # `controllers_panel` and `repositories_panel` are function components, so
    # the socket's `current_scope` assign is not in their assigns. Reading
    # `@current_scope` there raised `KeyError key :current_scope not found` and
    # took the whole page down. Both timestamps sit behind an `:if`, so the
    # crash only appeared once a record had actually reported -- which is why
    # every other test on this page stayed green.

    @tag :web_ng_shared_fixture_db
    test "renders a controller that has reported health", %{conn: conn, scope: scope} do
      controller = controller_with_health!(scope)

      {:ok, lv, html} = live(conn, ~p"/settings/ansible")

      assert html =~ controller.name

      assert has_element?(
               lv,
               ~s(time#settings-ansible-controller-#{controller.id}-last-health-at)
             )
    end

    @tag :web_ng_shared_fixture_db
    test "renders a repository that has reported a sync", %{conn: conn} do
      repository = repository_with_sync!()

      {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

      html = render_click(lv, "select_tab", %{"tab" => "repositories"})

      # The count and the row have to agree. Seeding the repositories stream at
      # mount left the count at 1 above an empty table body, because the panel
      # was behind `:if @active_tab == :repositories` and the stream had already
      # been spent -- so the one repository could not be opened and edited.
      assert html =~ "registered git repositor"
      assert html =~ repository.name

      assert has_element?(
               lv,
               ~s(time#settings-ansible-repository-#{repository.id}-last-sync-at)
             )

      assert has_element?(lv, ~s(button[phx-click="edit_repository"][phx-value-id="#{repository.id}"]))
    end

    @tag :web_ng_shared_fixture_db
    test "localizes those timestamps in the acting user's timezone", %{conn: conn, user: user} do
      user =
        Ash.update!(user, %{timezone: "America/Chicago"},
          action: :update_timezone_preference,
          actor: user
        )

      conn = log_in_user(conn, user)
      scope = Scope.for_user(user)
      controller = controller_with_health!(scope)
      repository = repository_with_sync!()

      {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

      assert has_element?(
               lv,
               ~s(time#settings-ansible-controller-#{controller.id}-last-health-at) <>
                 ~s([data-user-time-zone="America/Chicago"])
             )

      render_click(lv, "select_tab", %{"tab" => "repositories"})

      assert has_element?(
               lv,
               ~s(time#settings-ansible-repository-#{repository.id}-last-sync-at) <>
                 ~s([data-user-time-zone="America/Chicago"])
             )
    end
  end

  defp controller_with_health!(scope) do
    secret = awx_secret_fixture(scope, "sync")

    {:ok, controller} =
      Controller.create_controller(
        %{
          name: "AWX Health #{System.unique_integer([:positive])}",
          agent_id: "k8s-agent",
          base_url: "http://awx-service.awx.svc.cluster.local",
          credential_secret_id: secret.id,
          sync_credential_secret_id: secret.id
        },
        actor: system_actor()
      )

    {:ok, controller} =
      Controller.record_health(
        controller,
        %{
          status: :ok,
          awx_version: "24.6.1",
          last_health_summary: "AWX reachable"
        },
        actor: system_actor()
      )

    assert controller.last_health_at
    controller
  end

  defp repository_with_sync! do
    {:ok, repository} =
      PlaybookRepository.create_repository(
        %{
          name: "Playbooks #{System.unique_integer([:positive])}",
          git_url: "https://github.com/example/playbooks.git",
          git_ref: "main"
        },
        actor: system_actor()
      )

    {:ok, repository} =
      PlaybookRepository.record_sync(
        repository,
        %{last_sync_status: :ok, last_sync_summary: "2 playbooks"},
        actor: system_actor()
      )

    assert repository.last_sync_at
    repository
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp controller_by_name!(name) do
    Controller
    |> Ash.read!(action: :read, actor: system_actor())
    |> Enum.find(&(&1.name == name))
  end

  defp awx_secret_fixture(_scope, purpose) do
    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "AWX #{purpose} token #{System.unique_integer([:positive])}",
          provider: "awx",
          credential_kind: :api_token,
          public_fingerprint: "sha256:test",
          secret_payload: "awx-bearer-token",
          metadata: %{
            "auth_method" => "bearer_token",
            "source" => "credential_rules_form",
            "credential_purpose" => purpose
          }
        },
        actor: system_actor()
      )
      |> Ash.create(actor: system_actor())

    secret
  end

  defp grant_permissions(user, permissions) do
    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Ansible settings LiveView #{System.unique_integer([:positive])}",
          description: "Test profile for resource-specific Ansible settings permissions",
          permissions: permissions
        },
        actor: system_actor(),
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    updated =
      user
      |> Ash.Changeset.for_update(
        :update_role_profile,
        %{role_profile_id: profile.id},
        actor: system_actor()
      )
      |> Ash.update!()

    RBAC.clear_process_cache()
    RBAC.Cache.put(updated.id, MapSet.new(permissions))

    updated
  end

  describe "execution and callback token entry" do
    # Sync already accepted a pasted token; execution and callback could only be
    # set by pasting a secret UUID. That is the copy-a-UUID step this change
    # removes, and the likely reason the two elevated purposes were routinely
    # left unset while sync was configured -- they were the harder ones to fill
    # in, and they are the ones that launch jobs and mint ephemeral credentials.

    test "each purpose gets its own secret, and none is shared", %{conn: conn} do
      controller_name = "AWX Three #{System.unique_integer([:positive])}"
      sync_token = "sync-tok-#{System.unique_integer([:positive])}"
      exec_token = "exec-tok-#{System.unique_integer([:positive])}"
      cb_token = "cb-tok-#{System.unique_integer([:positive])}"

      {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

      lv |> element("button", "+ Add controller") |> render_click()

      html =
        lv
        |> form("#ansible-controller-form", %{
          "controller" => %{
            "name" => controller_name,
            "agent_id" => "k8s-agent",
            "description" => "",
            "base_url" => "http://awx-service.awx.svc.cluster.local",
            "sync_awx_api_token" => sync_token,
            "execution_awx_api_token" => exec_token,
            "callback_awx_api_token" => cb_token,
            "credential_secret_id" => "",
            "sync_credential_secret_id" => "",
            "execution_credential_secret_id" => "",
            "callback_credential_secret_id" => "",
            "inventory_sync_interval_seconds" => "300",
            "catalog_sync_interval_seconds" => "600"
          }
        })
        |> render_submit()

      for token <- [sync_token, exec_token, cb_token] do
        refute html =~ token
      end

      controller = controller_by_name!(controller_name)

      ids = [
        controller.sync_credential_secret_id,
        controller.execution_credential_secret_id,
        controller.callback_credential_secret_id
      ]

      assert Enum.all?(ids, &is_binary/1)

      # The privilege ceilings only mean something if the three are distinct
      # secrets. Reusing one would silently give sync the ability to launch jobs
      # and delete credentials.
      assert Enum.uniq(ids) == ids

      for {id, purpose} <- Enum.zip(ids, ["sync", "execution", "callback"]) do
        secret = NetworkCredentialSecret.get_by_id!(id, actor: system_actor())
        assert secret.provider == "awx"
        assert secret.credential_kind == :api_token
        assert secret.metadata["credential_purpose"] == purpose
        assert secret.metadata["source"] == "ansible_controller_form"
        refute inspect(secret) =~ sync_token
        refute inspect(secret) =~ exec_token
        refute inspect(secret) =~ cb_token
      end
    end

    test "a pasted token wins over a selected secret for the same purpose", %{conn: conn} do
      # Same precedence sync already uses: you only paste when you mean to set or
      # rotate, and the select still holds whatever was bound before.
      controller_name = "AWX Precedence #{System.unique_integer([:positive])}"
      exec_token = "exec-wins-#{System.unique_integer([:positive])}"

      {:ok, existing} =
        NetworkCredentialSecret.create_secret(
          %{
            name: "Preexisting exec #{System.unique_integer([:positive])}",
            provider: "awx",
            credential_kind: :api_token,
            secret_payload: "should-not-be-used"
          },
          actor: system_actor()
        )

      {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

      lv |> element("button", "+ Add controller") |> render_click()

      lv
      |> form("#ansible-controller-form", %{
        "controller" => %{
          "name" => controller_name,
          "agent_id" => "k8s-agent",
          "description" => "",
          "base_url" => "http://awx-service.awx.svc.cluster.local",
          "sync_awx_api_token" => "sync-#{System.unique_integer([:positive])}",
          "execution_awx_api_token" => exec_token,
          "execution_credential_secret_id" => existing.id,
          "credential_secret_id" => "",
          "sync_credential_secret_id" => "",
          "callback_credential_secret_id" => "",
          "inventory_sync_interval_seconds" => "300",
          "catalog_sync_interval_seconds" => "600"
        }
      })
      |> render_submit()

      controller = controller_by_name!(controller_name)

      refute controller.execution_credential_secret_id == existing.id
      assert controller.execution_credential_secret_id
    end

    test "blank token fields leave the selected secrets alone", %{conn: conn} do
      # Editing a controller without rotating anything must not mint new secrets.
      controller_name = "AWX Blank #{System.unique_integer([:positive])}"

      {:ok, exec_secret} =
        NetworkCredentialSecret.create_secret(
          %{
            name: "Chosen exec #{System.unique_integer([:positive])}",
            provider: "awx",
            credential_kind: :api_token,
            secret_payload: "chosen"
          },
          actor: system_actor()
        )

      {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

      lv |> element("button", "+ Add controller") |> render_click()

      lv
      |> form("#ansible-controller-form", %{
        "controller" => %{
          "name" => controller_name,
          "agent_id" => "k8s-agent",
          "description" => "",
          "base_url" => "http://awx-service.awx.svc.cluster.local",
          "sync_awx_api_token" => "sync-#{System.unique_integer([:positive])}",
          "execution_awx_api_token" => "",
          "callback_awx_api_token" => "",
          "execution_credential_secret_id" => exec_secret.id,
          "credential_secret_id" => "",
          "sync_credential_secret_id" => "",
          "callback_credential_secret_id" => "",
          "inventory_sync_interval_seconds" => "300",
          "catalog_sync_interval_seconds" => "600"
        }
      })
      |> render_submit()

      controller = controller_by_name!(controller_name)

      assert controller.execution_credential_secret_id == exec_secret.id
      assert controller.callback_credential_secret_id == nil
    end
  end
end
