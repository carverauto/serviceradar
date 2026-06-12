defmodule ServiceRadarWebNGWeb.Settings.AnomalyDetectionLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "renders anomaly settings page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/anomaly-detection")

    assert html =~ "Anomaly Detection"
    assert html =~ "Streaming Detector"
    assert html =~ "Capacity Forecast"
    assert html =~ "N-sigma threshold"
  end

  test "updates anomaly detector settings", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/anomaly-detection")

    lv
    |> form("#anomaly-settings-form", %{
      "anomaly" => %{
        "n_sigma" => "4.5",
        "window_size" => "600",
        "window_duration_seconds" => "1200",
        "confirm_slots" => "7",
        "min_samples" => "45",
        "metric_class_overrides" => ~s({"interface":{"n_sigma":5.0}})
      }
    })
    |> render_submit()

    assert render(lv) =~ "Saved anomaly detection settings"
  end

  test "updates capacity forecast settings", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/anomaly-detection")

    lv
    |> form("#capacity-forecast-settings-form", %{
      "forecast" => %{
        "forecast_horizon_seconds" => "15552000",
        "warning_horizon_seconds" => "1209600",
        "warning_threshold_percent" => "75.5",
        "model" => "seasonal_linear",
        "minimum_history_points" => "96",
        "metric_class_overrides" => ~s({"disk":{"minimum_history_points":120}})
      }
    })
    |> render_submit()

    assert render(lv) =~ "Saved capacity forecast settings"
  end

  test "viewer is blocked from anomaly detection settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/anomaly-detection")
    assert to == ~p"/settings/profile"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end
end
