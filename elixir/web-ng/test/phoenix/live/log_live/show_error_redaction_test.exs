defmodule ServiceRadarWebNGWeb.LogLive.ShowErrorRedactionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNGWeb.LogLive.Show

  @moduletag :db_free

  test "the log detail meta strip redacts a promoted error attribute" do
    html =
      render_component(&Show.log_meta_strip/1,
        log: %{
          "attributes" => %{
            "error" => "password=synthetic-log-secret disk full",
            "err" => "ignored because error wins"
          },
          "service_name" => "collector"
        },
        timezone: "Etc/UTC"
      )

    assert html =~ "password=[REDACTED]"
    refute html =~ "synthetic-log-secret"
  end

  test "the log detail meta strip redacts a promoted err attribute" do
    html =
      render_component(&Show.log_meta_strip/1,
        log: %{
          "attributes" => %{"err" => ~s({"token":"synthetic-log-secret"})},
          "service_name" => "collector"
        },
        timezone: "Etc/UTC"
      )

    assert html =~ "[REDACTED]"
    refute html =~ "synthetic-log-secret"
  end

  test "an ordinary error string stays visible" do
    html =
      render_component(&Show.log_meta_strip/1,
        log: %{
          "attributes" => %{"error" => "disk full on host01.example.com"},
          "service_name" => "collector"
        },
        timezone: "Etc/UTC"
      )

    assert html =~ "disk full on host01.example.com"
  end
end
