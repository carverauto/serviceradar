defmodule ServiceRadarWebNGWeb.Settings.TelemetryOnboardingLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures

  @trace_id "aabbccddeeff00112233445566778899"

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    conn = log_in_user(conn, user)

    old_srql = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.RecordingSRQLStub)

    old_onboarding = Application.get_env(:serviceradar_web_ng, :otlp_onboarding)
    Application.delete_env(:serviceradar_web_ng, :otlp_onboarding)

    :persistent_term.put({__MODULE__, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})

      if is_nil(old_srql) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old_srql)
      end

      if is_nil(old_onboarding) do
        Application.delete_env(:serviceradar_web_ng, :otlp_onboarding)
      else
        Application.put_env(:serviceradar_web_ng, :otlp_onboarding, old_onboarding)
      end
    end)

    %{conn: conn}
  end

  test "renders the onboarding sections with an operator note when endpoints are unset", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings/agents/telemetry-onboarding")

    assert html =~ "Send your telemetry"
    assert html =~ "OTLP endpoints"
    assert html =~ "Ingestion key"
    assert html =~ "Configure your exporter"
    assert html =~ "Confirm first data"

    # No endpoints configured: operator note + placeholders in snippets.
    assert has_element?(lv, "#otlp-endpoints-unset-note")
    assert html =~ "SERVICERADAR_OTLP_GRPC_ENDPOINT"
    assert html =~ "SERVICERADAR_OTLP_HTTP_ENDPOINT"
    assert html =~ "Not configured"
    assert html =~ "&lt;otlp-host&gt;:4317"

    # No key generated yet: snippets carry the placeholder.
    assert html =~ "x-serviceradar-ingestion-key: &lt;ingestion-key&gt;"
    refute has_element?(lv, "#generated-ingestion-key")
  end

  test "configured endpoints feed the matrix and the language snippets", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :otlp_onboarding,
      grpc_endpoint: "otlp-demo.grpc.serviceradar.cloud:50052",
      http_endpoint: "https://otlp-demo.serviceradar.cloud",
      grpc_requires_private_ca: true
    )

    {:ok, lv, html} = live(conn, ~p"/settings/agents/telemetry-onboarding")

    refute has_element?(lv, "#otlp-endpoints-unset-note")
    assert html =~ "otlp-demo.grpc.serviceradar.cloud:50052"
    assert html =~ "https://otlp-demo.serviceradar.cloud"

    # Default language is the OTel Collector exporter yaml.
    assert html =~ "endpoint: otlp-demo.grpc.serviceradar.cloud:50052"
    assert html =~ "otlphttp/serviceradar"
    assert html =~ "ca_file: /etc/otelcol/serviceradar-root.pem"

    # Switching language re-templates the snippets with the same endpoints.
    html = lv |> element("#snippet-language-java") |> render_click()

    assert html =~ "OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp-demo.grpc.serviceradar.cloud:50052"
    assert html =~ "OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp-demo.serviceradar.cloud"
    assert html =~ "OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf"
    assert html =~ "java -javaagent:opentelemetry-javaagent.jar"
  end

  test "generating a key shows it once and threads it through the operator snippets", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/agents/telemetry-onboarding")

    # Customize identity + secret name first (sanitized to k8s-safe values).
    lv
    |> form("#ingestion-key form", key_form: %{identity: "tenant-a", secret_name: "Tenant-A-Keys"})
    |> render_change()

    html =
      lv
      |> form("#ingestion-key form")
      |> render_submit()

    assert [_, key] = Regex.run(~r/data-ingestion-key="([A-Za-z0-9_-]+)"/, html)
    assert String.length(key) == 43

    # Key surfaces once with the operator kubectl + helm snippets.
    assert html =~ "create secret generic tenant-a-keys"
    assert html =~ "--from-literal=tenant-a="
    assert html =~ "secretName: tenant-a-keys"
    assert html =~ "secretKey: tenant-a"
    assert html =~ key

    # Per-language quickstarts pick up the generated key.
    assert html =~ "x-serviceradar-ingestion-key: #{key}"
    refute html =~ "x-serviceradar-ingestion-key: &lt;ingestion-key&gt;"
  end

  test "checker issues the three SRQL queries and renders per-signal status", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/agents/telemetry-onboarding")

    lv
    |> form("#first-data-checker form", checker: %{service_name: "checkout"})
    |> render_submit()

    assert drain_srql_calls() == [
             ~s(in:traces service_name:"checkout" time:last_15m limit:1),
             ~s(in:logs service_name:"checkout" time:last_15m limit:1),
             ~s(in:otel_metric_points service_name:"checkout" time:last_15m limit:1)
           ]

    html = render(lv)

    # Traces found (with trace detail link); logs and metrics still pending.
    assert has_element?(lv, "#first-data-traces", "Data arrived")
    assert has_element?(lv, "#first-data-logs", "No data yet")
    assert has_element?(lv, "#first-data-metrics", "No data yet")
    assert html =~ "/observability/traces/#{@trace_id}"

    # Not all signals arrived: auto-polling stays on until found-all or Stop.
    assert has_element?(lv, "#first-data-polling")

    lv |> element("#first-data-stop") |> render_click()
    refute has_element?(lv, "#first-data-polling")
  end

  test "checker stops polling once every signal has arrived", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/agents/telemetry-onboarding")

    lv
    |> form("#first-data-checker form", checker: %{service_name: "allfound"})
    |> render_submit()

    assert length(drain_srql_calls()) == 3

    assert has_element?(lv, "#first-data-traces", "Data arrived")
    assert has_element?(lv, "#first-data-logs", "Data arrived")
    assert has_element?(lv, "#first-data-metrics", "Data arrived")
    refute has_element?(lv, "#first-data-polling")
  end

  defp drain_srql_calls(acc \\ []) do
    receive do
      {:srql_query, query} ->
        drain_srql_calls([query | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defmodule RecordingSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @trace_id "aabbccddeeff00112233445566778899"

    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, _opts) when is_binary(query) do
      case :persistent_term.get({ServiceRadarWebNGWeb.Settings.TelemetryOnboardingLiveTest, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:srql_query, query})
        _ -> :ok
      end

      {:ok, %{"results" => results_for(query), "pagination" => %{}, "error" => nil}}
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp results_for(query) do
      all_found? = String.contains?(query, ~s(service_name:"allfound"))

      cond do
        String.starts_with?(query, "in:traces") ->
          [%{"trace_id" => @trace_id, "service_name" => "checkout"}]

        String.starts_with?(query, "in:logs") ->
          if all_found?, do: [%{"body" => "hello"}], else: []

        String.starts_with?(query, "in:otel_metric_points") ->
          if all_found?, do: [%{"metric_name" => "gen"}], else: []

        true ->
          []
      end
    end
  end
end
