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

  test "a stored crash reason whose value sat behind an earlier marker is redacted" do
    # Rows stored before the redaction fix kept the Erlang binary after the
    # marker, and the HMAC key bytes in the clear. Invented values.
    stored =
      ~S(#{state => error,key => <<203,17,254,8,99>>,) <>
        ~S(password =[REDACTED] <<"synthetic-stored-password">>,realm => <<"realm.example.com">>})

    html =
      render_component(&Show.log_meta_strip/1,
        log: %{"attributes" => %{"error" => stored}, "service_name" => "core-elx"},
        timezone: "Etc/UTC"
      )

    refute html =~ "synthetic-stored-password"
    refute html =~ "203,17,254"
    refute html =~ "[REDACTED]]"
    assert html =~ "realm.example.com"
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
