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
        String.contains?(query, ~s(in:events)) ->
          [falco_event()]

        String.contains?(query, ~s(in:alerts)) ->
          [stateful_alert()]

        true ->
          []
      end
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
