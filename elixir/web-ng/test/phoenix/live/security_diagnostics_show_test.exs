defmodule ServiceRadarWebNGWeb.SecurityDiagnosticsShowTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures

  setup %{conn: conn} do
    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.SRQLStub)

    on_exit(fn ->
      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)

    user = AccountsFixtures.user_fixture(%{role: :operator})
    {:ok, conn: log_in_user(conn, user)}
  end

  test "event detail renders Falco runtime diagnostics with partial attribution", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/events/falco-event-1")

    assert html =~ "Falco Runtime Event"
    assert html =~ "Drop and execute new binary in container"
    assert html =~ "/tmp/.build/tool --lint"
    assert html =~ "/workspace/carverauto/serviceradar"
    assert html =~ "forgejo-runner"
    assert html =~ "code.forgejo.org/forgejo/runner:latest"
    assert html =~ "partial (missing kubernetes.namespace, kubernetes.pod)"
  end

  test "alert detail renders stateful incident diagnostics and source samples", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/alerts/alert-1")

    assert html =~ "Stateful Incident"
    assert html =~ "falco-incident"
    assert html =~ "rule=Drop and execute new binary in container|hostname=k8s-cp2-worker2"
    assert html =~ "/tmp/.build/tool --lint"
    assert html =~ "forgejo-runner"
    assert html =~ "code.forgejo.org/forgejo/runner:latest"
    assert html =~ "partial (missing kubernetes.namespace, kubernetes.pod)"
  end

  test "event detail does not classify generic syslog events with blank waf attributes as WAF", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/events/syslog-event-1")

    assert html =~ "UniFi Network has updated to 10.4.57"
    refute html =~ "WAF Finding"
    refute html =~ "View source log"
  end

  test "alert detail derives generic event alert titles from the triggering message", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/alerts/syslog-alert-1")

    assert html =~ "UniFi Network has updated to 10.4.57"
    refute html =~ "Event: logs.syslog.processed"
  end

  defmodule SRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, _opts) when is_binary(query) do
      {:ok,
       %{
         "results" => results(query),
         "pagination" => %{},
         "error" => nil
       }}
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp results(query) do
      cond do
        String.contains?(query, "syslog-event-1") ->
          [syslog_event()]

        String.contains?(query, "syslog-alert-1") ->
          [syslog_alert()]

        String.contains?(query, ~s(in:events)) ->
          [falco_event()]

        String.contains?(query, ~s(in:alerts)) ->
          [stateful_alert()]

        true ->
          []
      end
    end

    defp syslog_event do
      %{
        "id" => "syslog-event-1",
        "time" => "2026-05-26T17:34:18Z",
        "severity" => "Medium",
        "message" => syslog_message(),
        "log_name" => "logs.syslog.processed",
        "log_provider" => "farm01",
        "metadata" => %{
          "serviceradar" => %{
            "source_log_id" => "2d88cb92-37d7-4e28-904f-d69fa5301b40"
          }
        },
        "unmapped" => %{
          "log_attributes" => %{
            "waf" => %{
              "source" => nil,
              "rule_id" => nil,
              "client_ip" => nil,
              "request_id" => nil,
              "waf_policy" => nil,
              "request_path" => nil,
              "rule_message" => nil,
              "rule_severity" => nil
            },
            "event_type" => nil
          }
        }
      }
    end

    defp syslog_alert do
      %{
        "id" => "syslog-alert-1",
        "title" => "Event: logs.syslog.processed",
        "description" => syslog_message(),
        "severity" => "Medium",
        "status" => "pending",
        "triggered_at" => "2026-05-26T17:34:18Z",
        "event_id" => "syslog-event-1",
        "metadata" => %{
          "event_id" => "syslog-event-1",
          "log_name" => "logs.syslog.processed",
          "log_provider" => "farm01"
        }
      }
    end

    defp syslog_message do
      "CEF:0|Ubiquiti|UniFi Network|10.4.57|578|Network Updated|4|UNIFIcategory=Software Updates UNIFIhost=farm01 UNIFIapplication=UniFi Network UNIFIapplicationVersion=10.4.57 UNIFIapplicationPriorVersion=10.3.58 UNIFIutcTime=2026-05-26T22:34:18.940Z msg=UniFi Network has updated to 10.4.57"
    end

    defp falco_event do
      %{
        "id" => "falco-event-1",
        "time" => "2026-05-03T19:25:42Z",
        "severity" => "Critical",
        "message" => "Drop and execute new binary in container",
        "log_name" => "falco.logs",
        "log_provider" => "falco",
        "metadata" => %{
          "security_signal" => %{
            "kind" => "runtime",
            "source" => "falco",
            "diagnostics" => falco_diagnostics()
          }
        },
        "unmapped" => %{
          "falco" => %{"diagnostics" => falco_diagnostics()}
        }
      }
    end

    defp stateful_alert do
      %{
        "id" => "alert-1",
        "title" => "Falco security incident detected",
        "severity" => "critical",
        "status" => "pending",
        "triggered_at" => "2026-05-03T19:25:42Z",
        "event_id" => "stateful-event-1",
        "metadata" => %{
          "incident_rule_id" => "rule-1",
          "incident_diagnostics" => %{
            "rule_id" => "rule-1",
            "rule_name" => "falco-incident",
            "group_key" => "rule=Drop and execute new binary in container|hostname=k8s-cp2-worker2",
            "threshold" => 1,
            "window_seconds" => 300,
            "window_count" => 915,
            "first_seen_at" => "2026-05-03T19:25:42Z",
            "last_seen_at" => "2026-05-03T19:30:12Z",
            "representative_event_ids" => ["falco-event-1"],
            "samples" => %{
              "processes" => [
                %{
                  "name" => "tool",
                  "command" => "/tmp/.build/tool --lint",
                  "cwd" => "/workspace/carverauto/serviceradar"
                }
              ],
              "containers" => [
                %{
                  "id" => "d2d34c8e90ab",
                  "name" => "forgejo-runner",
                  "image_repository" => "code.forgejo.org/forgejo/runner",
                  "image_tag" => "latest"
                }
              ],
              "kubernetes" => [
                %{
                  "attribution_status" => "partial",
                  "missing" => ["kubernetes.namespace", "kubernetes.pod"]
                }
              ]
            }
          }
        }
      }
    end

    defp falco_diagnostics do
      %{
        "rule" => %{"name" => "Drop and execute new binary in container", "priority" => "Critical"},
        "host" => %{"name" => "k8s-cp2-worker2"},
        "process" => %{
          "name" => "tool",
          "command" => "/tmp/.build/tool --lint",
          "cwd" => "/workspace/carverauto/serviceradar",
          "executable" => "/tmp/.build/tool",
          "executable_flags" => %{"upper_layer" => true, "from_memfd" => false}
        },
        "parent_process" => %{"name" => "bash"},
        "user" => %{"name" => "root"},
        "container" => %{
          "id" => "d2d34c8e90ab",
          "name" => "forgejo-runner",
          "image_repository" => "code.forgejo.org/forgejo/runner",
          "image_tag" => "latest"
        },
        "kubernetes" => %{},
        "attribution" => %{
          "status" => "partial",
          "missing" => ["kubernetes.namespace", "kubernetes.pod"]
        }
      }
    end
  end
end
