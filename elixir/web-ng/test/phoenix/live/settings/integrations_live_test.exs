defmodule ServiceRadarWebNGWeb.Settings.IntegrationsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

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

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp create_armis_source!(scope, attrs) do
    defaults = %{
      name: "Armis Source #{System.unique_integer([:positive])}",
      source_type: :armis,
      endpoint: "https://armis.example.test/#{System.unique_integer([:positive])}",
      custom_fields: [],
      northbound_enabled: false,
      northbound_interval_seconds: 3600
    }

    IntegrationSource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:credentials, %{api_key: "key", api_secret: "secret"})
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs))
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
