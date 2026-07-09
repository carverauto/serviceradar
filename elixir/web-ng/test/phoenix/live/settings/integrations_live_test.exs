defmodule ServiceRadarWebNGWeb.Settings.IntegrationsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.AgentConfig.DependencyDiagnostics
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query

  setup :register_and_log_in_admin_user

  test "create form persists armis credentials from rendered credential inputs", %{
    conn: conn,
    scope: scope
  } do
    agent = create_connected_agent!()
    source_name = "Armis Credential Source #{System.unique_integer([:positive])}"

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/integrations/new")

    lv
    |> form("#create_source_form", %{
      "form" => %{
        "name" => source_name,
        "source_type" => "armis",
        "endpoint" => "https://armis.example.test",
        "agent_id" => agent.uid,
        "discovery_interval_seconds" => "3600"
      },
      "cred_api_key" => "armis-api-key",
      "cred_api_secret" => "armis-secret",
      "cred_v3_client_id" => "armis-client@example.test",
      "cred_v3_client_secret" => "armis-client-secret",
      "cred_v3_vendor_id" => "armis-vendor"
    })
    |> render_submit()

    source = get_source_by_name!(source_name, scope)

    assert source.credentials == %{
             "api_key" => "armis-api-key",
             "api_secret" => "armis-secret",
             "client_id" => "armis-client@example.test",
             "client_secret" => "armis-client-secret",
             "vendor_id" => "armis-vendor"
           }
  end

  test "edit form updates armis credentials from rendered credential inputs", %{
    conn: conn,
    scope: scope
  } do
    agent = create_connected_agent!()

    source =
      create_armis_source!(scope, %{
        name: "Armis Credential Edit #{System.unique_integer([:positive])}",
        agent_id: agent.uid
      })

    {:ok, lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}/edit")

    assert has_element?(lv, "input[name='cred_api_key'][value='key']")
    assert has_element?(lv, "input[name='cred_v3_client_id']")
    assert has_element?(lv, "input[name='cred_v3_vendor_id']")
    refute has_element?(lv, "input[name='form[gateway_id]']")
    refute has_element?(lv, "input[name='form[poll_interval_seconds]']")
    refute has_element?(lv, "input[name='form[sweep_interval_seconds]']")
    assert html =~ "API secret:"
    assert html =~ "saved"

    lv
    |> form("#edit_source_form", %{
      "form" => %{
        "name" => source.name,
        "endpoint" => source.endpoint,
        "agent_id" => agent.uid,
        "discovery_interval_seconds" => "3600"
      },
      "cred_api_key" => "updated-api-key",
      "cred_api_secret" => "updated-secret",
      "cred_v3_client_id" => "updated-client@example.test",
      "cred_v3_client_secret" => "updated-client-secret",
      "cred_v3_vendor_id" => "updated-vendor"
    })
    |> render_submit()

    updated_source = get_source_by_name!(source.name, scope)

    assert updated_source.credentials == %{
             "api_key" => "updated-api-key",
             "api_secret" => "updated-secret",
             "client_id" => "updated-client@example.test",
             "client_secret" => "updated-client-secret",
             "vendor_id" => "updated-vendor"
           }
  end

  test "edit form preserves existing armis secret when secret field is blank", %{
    conn: conn,
    scope: scope
  } do
    agent = create_connected_agent!()

    source =
      create_armis_source!(scope, %{
        name: "Armis Credential Preserve #{System.unique_integer([:positive])}",
        agent_id: agent.uid,
        credentials: %{
          api_key: "existing-api-key",
          api_secret: "existing-secret",
          client_id: "existing-client@example.test",
          client_secret: "existing-client-secret",
          vendor_id: "existing-vendor"
        }
      })

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/integrations/#{source.id}/edit")

    lv
    |> form("#edit_source_form", %{
      "form" => %{
        "name" => source.name,
        "endpoint" => source.endpoint,
        "agent_id" => agent.uid,
        "discovery_interval_seconds" => "3600"
      },
      "cred_api_key" => "updated-api-key",
      "cred_api_secret" => "",
      "cred_v3_client_id" => "updated-client@example.test",
      "cred_v3_client_secret" => "",
      "cred_v3_vendor_id" => "updated-vendor"
    })
    |> render_submit()

    updated_source = get_source_by_name!(source.name, scope)

    assert updated_source.credentials == %{
             "api_key" => "updated-api-key",
             "api_secret" => "existing-secret",
             "client_id" => "updated-client@example.test",
             "client_secret" => "existing-client-secret",
             "vendor_id" => "updated-vendor"
           }
  end

  test "edit modal exposes armis northbound settings", %{conn: conn, scope: scope} do
    source =
      create_armis_source!(scope, %{
        name: "Armis Edit Source",
        custom_fields: ["availability_status"],
        northbound_enabled: true,
        northbound_interval_seconds: 900
      })

    {:ok, lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}/edit")

    assert html =~ "Armis Northbound"
    assert has_element?(lv, "input[name='custom_fields_text'][value='availability_status']")
    assert has_element?(lv, "input[name='form[northbound_interval_seconds]'][value='900']")
    assert has_element?(lv, "input[name='form[northbound_enabled]'][type='checkbox'][checked]")
  end

  test "details modal shows separate armis northbound status and recent runs", %{
    conn: conn,
    scope: scope
  } do
    source =
      create_armis_source!(scope, %{
        name: "Armis Detail Source",
        custom_fields: ["availability_status"],
        northbound_enabled: true,
        northbound_interval_seconds: 1800
      })

    source =
      source
      |> Ash.Changeset.for_update(:northbound_success, %{
        result: :success,
        device_count: 12,
        updated_count: 9,
        skipped_count: 3
      })
      |> Ash.update!(scope: scope)

    _success_run =
      create_run!(scope, source.id, %{
        status_action: :finish_success,
        device_count: 12,
        updated_count: 9,
        skipped_count: 3,
        error_count: 0
      })

    _failed_run =
      create_run!(scope, source.id, %{
        status_action: :finish_failed,
        device_count: 12,
        updated_count: 5,
        skipped_count: 4,
        error_count: 3,
        error_message: "bulk update rejected"
      })

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

    assert html =~ "Discovery Status"
    assert html =~ "Armis Northbound"
    assert html =~ "availability_status"
    assert html =~ "Recent Runs"
    assert html =~ "bulk update rejected"
    assert html =~ "Last Updated"
    assert html =~ "9"
  end

  test "details modal shows armis credential presence without revealing the secret", %{
    conn: conn,
    scope: scope
  } do
    source =
      create_armis_source!(scope, %{
        name: "Armis Credential Detail",
        credentials: %{api_key: "visible-armis-api-key", api_secret: "hidden-armis-secret"}
      })

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

    assert html =~ "Credentials"
    assert html =~ "visible-armis-api-key"
    assert html =~ "Saved"
    refute html =~ "hidden-armis-secret"
  end

  test "details modal shows recent agent config dispatch diagnostics", %{
    conn: conn,
    scope: scope
  } do
    source =
      create_armis_source!(scope, %{
        name: "Armis Config Dispatch Detail",
        credentials: %{api_key: "dispatch-api-key", api_secret: "dispatch-secret"}
      })

    DependencyDiagnostics.record(%{
      dependency_id: :integration_source_sync_config,
      resource_id: source.id,
      resource_name: source.name,
      config_type: :sync,
      action_type: :update,
      affected_agents: [source.agent_id],
      affected_agent_count: 1,
      result: :ok,
      secrets: %{"api_secret" => true},
      recorded_at: DateTime.utc_now()
    })

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

    assert html =~ "Agent Config Dispatch"
    assert html =~ "sync"
    assert html =~ "Pushed"
    assert html =~ source.agent_id
    refute html =~ "dispatch-secret"
  end

  test "details modal suppresses stale internal timestamp precision errors", %{
    conn: conn,
    scope: scope
  } do
    raw_error = """
    %ArgumentError{message: ":utc_datetime expects microseconds to be empty, got: ~U[2026-05-15 18:00:08.246357Z]\n\nUse `DateTime.truncate(utc_datetime, :second)` (available in Elixir v1.6+) to remove microseconds.\n"}
    """

    source =
      create_armis_source!(scope, %{
        name: "Armis Stale Error Detail",
        credentials: %{api_key: "stale-error-key", api_secret: "stale-error-secret"}
      })

    source =
      source
      |> Ash.Changeset.for_update(:sync_start, %{device_count: 0})
      |> Ash.update!(scope: scope)

    source
    |> Ash.Changeset.for_update(:sync_failed, %{
      result: :failed,
      device_count: 0,
      error_message: raw_error
    })
    |> Ash.update!(scope: scope)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

    assert html =~ "Agent Config Dispatch"
    assert html =~ "No recent config dispatch recorded for this source."
    refute html =~ "%ArgumentError"
    refute html =~ ":utc_datetime expects microseconds"
    refute html =~ "DateTime.truncate(utc_datetime, :second)"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp create_connected_agent! do
    uid = "agent-#{System.unique_integer([:positive])}"

    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{uid: uid, name: uid},
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp get_source_by_name!(name, scope) do
    IntegrationSource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.load([:credentials_encrypted, :credentials])
    |> Ash.read_one!(scope: scope)
  end

  defp create_armis_source!(scope, attrs) do
    credentials = Map.get(attrs, :credentials, %{api_key: "key", api_secret: "secret"})
    attrs = Map.delete(attrs, :credentials)

    defaults = %{
      name: "Armis Source #{System.unique_integer([:positive])}",
      source_type: :armis,
      endpoint: "https://armis.example.test/#{System.unique_integer([:positive])}",
      agent_id: create_connected_agent!().uid,
      custom_fields: [],
      northbound_enabled: false,
      northbound_interval_seconds: 3600
    }

    IntegrationSource
    |> Ash.Changeset.for_create(
      :create,
      defaults |> Map.merge(attrs) |> Map.put(:credentials, credentials)
    )
    |> Ash.create!(scope: scope)
  end

  defp create_run!(scope, source_id, attrs) do
    start_attrs = %{
      integration_source_id: source_id,
      run_type: :armis_northbound,
      metadata: %{trigger: "manual"}
    }

    run =
      IntegrationUpdateRun
      |> Ash.Changeset.for_create(:start_run, start_attrs)
      |> Ash.create!(scope: scope)

    action = Map.fetch!(attrs, :status_action)

    finish_attrs =
      attrs
      |> Map.delete(:status_action)
      |> Map.put_new(:metadata, %{trigger: "manual"})

    run
    |> Ash.Changeset.for_update(action, finish_attrs)
    |> Ash.update!(scope: scope)
  end
end
