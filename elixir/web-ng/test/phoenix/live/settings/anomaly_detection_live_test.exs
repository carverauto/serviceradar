defmodule ServiceRadarWebNGWeb.Settings.AnomalyDetectionLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "renders anomaly settings page", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings/anomaly-detection")

    assert html =~ "Anomaly Detection"
    assert html =~ "Streaming Detector"
    assert html =~ "Capacity Forecast"
    assert html =~ "N-sigma threshold"
    assert html =~ "Emission Governance"
    assert html =~ "Metric denylist"
    assert html =~ "Metric Classes"
    assert html =~ "Deseasonalized only"
    assert html =~ "Additional forecast sources"
    assert html =~ "CPU usage (daily p95)"
    assert html =~ "Interface utilization (daily p95)"
    assert html =~ "Flow volume"
    assert html =~ "statistically weaker"
    refute html =~ "Edge spike scalar knobs are managed"

    # The opt-in checkbox list derives from the core source definitions, so a
    # source added there must surface here without a web-ng edit.
    for source_key <- ServiceRadar.Observability.CapacityForecasting.Source.opt_in_names() do
      assert has_element?(
               lv,
               ~s(#capacity-forecast-settings-form input[name="forecast[default_source_opt_ins][]"][value="#{source_key}"])
             )
    end
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
        "metric_denylist" => "cpu.frequency_hz\ncustom.metric",
        "emission_cooldown_secs" => "120",
        "emission_budget_per_tick" => "25",
        "episode_update_interval_secs" => "900",
        "reopen_cooldown_secs" => "300",
        "classes" => %{
          "interface" => %{
            "enabled" => "true",
            "drift_mode" => "deseasonalized_only",
            "drift_min_effect" => "2.5",
            "drift_clear_slots" => "30",
            "drift_adopt_after_samples" => "600",
            "drift_escalate_after_secs" => "3600",
            "severity_cap" => "high",
            "severity_bands" => ~s({"medium":4,"high":8})
          },
          "cpu" => %{"enabled" => "false", "drift_mode" => "deseasonalized_only"}
        }
      }
    })
    |> render_submit()

    assert render(lv) =~ "Saved anomaly detection settings"
  end

  test "rejects invalid anomaly numeric input instead of silently defaulting it", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/anomaly-detection")

    html =
      lv
      |> form("#anomaly-settings-form", %{
        "anomaly" => %{
          "n_sigma" => "not-a-number",
          "window_size" => "600",
          "window_duration_seconds" => "1200",
          "confirm_slots" => "7",
          "min_samples" => "45",
          "metric_denylist" => "cpu.frequency_hz",
          "emission_cooldown_secs" => "120",
          "emission_budget_per_tick" => "25",
          "episode_update_interval_secs" => "900",
          "reopen_cooldown_secs" => "300",
          "classes" => %{}
        }
      })
      |> render_submit()

    assert html =~ "Fix anomaly settings errors before saving"
    assert html =~ "must be a number"
  end

  test "surfaces anomaly cross-field validation errors", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/anomaly-detection")

    html =
      lv
      |> form("#anomaly-settings-form", %{
        "anomaly" => %{
          "n_sigma" => "4.5",
          "window_size" => "10",
          "window_duration_seconds" => "1200",
          "confirm_slots" => "7",
          "min_samples" => "45",
          "metric_denylist" => "cpu.frequency_hz",
          "emission_cooldown_secs" => "120",
          "emission_budget_per_tick" => "25",
          "episode_update_interval_secs" => "900",
          "reopen_cooldown_secs" => "300",
          "classes" => %{}
        }
      })
      |> render_submit()

    assert html =~ "Fix anomaly settings errors before saving"
    assert html =~ "less than or equal to window size"
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
        "default_source_opt_ins" => ["cpu_usage", "flow_bytes_per_hour"],
        "metric_class_overrides" => ~s({"disk":{"minimum_history_points":120}})
      }
    })
    |> render_submit()

    assert render(lv) =~ "Saved capacity forecast settings"

    assert has_element?(
             lv,
             ~s(#capacity-forecast-settings-form input[name="forecast[default_source_opt_ins][]"][value="cpu_usage"][checked])
           )

    assert has_element?(
             lv,
             ~s(#capacity-forecast-settings-form input[name="forecast[default_source_opt_ins][]"][value="flow_bytes_per_hour"][checked])
           )

    refute has_element?(
             lv,
             ~s(#capacity-forecast-settings-form input[name="forecast[default_source_opt_ins][]"][value="interface_rate"][checked])
           )
  end

  test "rejects invalid capacity forecast numeric input instead of silently defaulting it", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/anomaly-detection")

    html =
      lv
      |> form("#capacity-forecast-settings-form", %{
        "forecast" => %{
          "forecast_horizon_seconds" => "15552000",
          "warning_horizon_seconds" => "not-an-int",
          "warning_threshold_percent" => "75.5",
          "model" => "seasonal_linear",
          "minimum_history_points" => "96",
          "metric_class_overrides" => ~s({"disk":{"minimum_history_points":120}})
        }
      })
      |> render_submit()

    assert html =~ "Fix capacity forecast settings errors before saving"
    assert html =~ "must be an integer"
  end

  test "surfaces capacity forecast cross-field validation errors", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/anomaly-detection")

    html =
      lv
      |> form("#capacity-forecast-settings-form", %{
        "forecast" => %{
          "forecast_horizon_seconds" => "3600",
          "warning_horizon_seconds" => "7200",
          "warning_threshold_percent" => "75.5",
          "model" => "seasonal_linear",
          "minimum_history_points" => "96",
          "metric_class_overrides" => ~s({"disk":{"minimum_history_points":120}})
        }
      })
      |> render_submit()

    assert html =~ "Fix capacity forecast settings errors before saving"
    assert html =~ "less than or equal to forecast horizon"
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
