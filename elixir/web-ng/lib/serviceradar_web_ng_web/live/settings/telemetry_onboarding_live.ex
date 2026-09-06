defmodule ServiceRadarWebNGWeb.Settings.TelemetryOnboardingLive do
  @moduledoc """
  "Send your telemetry" onboarding surface.

  Gives a user everything needed to point an OpenTelemetry SDK or collector
  at this deployment: the OTLP endpoints, an ingestion key, per-language
  exporter snippets, and a live "first data arrived" checker backed by SRQL.

  V1 honesty: ingestion keys are file/Secret-based collector configuration
  (`logCollector.otlp.auth` in the Helm chart, mounted as `[[auth.tokens]]`
  `token_file` entries). There is no runtime token store, so "issuing" a key
  here generates a cryptographically random value and renders the exact
  operator commands required to activate it. Nothing is written to the
  cluster from this page.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @poll_interval_ms 10_000

  @signals [
    {:traces, "Traces"},
    {:logs, "Logs"},
    {:metrics, "Metrics"}
  ]

  @languages [
    {"collector", "OTel Collector"},
    {"java", "Java"},
    {"python", "Python"},
    {"node", "Node.js"},
    {"go", "Go"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.edge.manage") do
      onboarding = Application.get_env(:serviceradar_web_ng, :otlp_onboarding, [])

      {:ok,
       socket
       |> assign(:page_title, "Telemetry Onboarding")
       |> assign(:current_path, "/settings/agents/telemetry-onboarding")
       |> assign(:grpc_endpoint, config_string(onboarding, :grpc_endpoint))
       |> assign(:http_endpoint, config_string(onboarding, :http_endpoint))
       |> assign(:grpc_requires_private_ca, Keyword.get(onboarding, :grpc_requires_private_ca, true) != false)
       |> assign(:identity, "default")
       |> assign(:secret_name, "otlp-ingestion-key")
       |> assign(:generated_key, nil)
       |> assign(:snippet_language, "collector")
       |> assign(:check_service, "")
       |> assign(:check_error, nil)
       |> assign(:checking?, false)
       |> assign(:check_results, nil)
       |> assign(:poll_ref, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to view telemetry onboarding")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("update_key_form", %{"key_form" => params}, socket) do
    {:noreply,
     socket
     |> assign(:identity, sanitize_identity(params["identity"]))
     |> assign(:secret_name, sanitize_secret_name(params["secret_name"]))}
  end

  def handle_event("generate_key", _params, socket) do
    key = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    {:noreply, assign(socket, :generated_key, key)}
  end

  def handle_event("select_language", %{"language" => language}, socket) do
    if language in Enum.map(@languages, &elem(&1, 0)) do
      {:noreply, assign(socket, :snippet_language, language)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("check_first_data", %{"checker" => %{"service_name" => service_name}}, socket) do
    service = sanitize_service_name(service_name)

    if service == "" do
      {:noreply,
       socket
       |> assign(:check_error, "Enter the service.name your SDK exports (OTEL_SERVICE_NAME).")
       |> assign(:check_results, nil)
       |> stop_polling()}
    else
      socket =
        socket
        |> assign(:check_error, nil)
        |> assign(:check_service, service)
        |> assign(:checking?, true)
        |> stop_polling()
        |> run_checks()

      {:noreply, socket}
    end
  end

  def handle_event("stop_check", _params, socket) do
    {:noreply, socket |> assign(:checking?, false) |> stop_polling()}
  end

  @impl true
  def handle_info(:poll_first_data, socket) do
    socket = assign(socket, :poll_ref, nil)

    if socket.assigns.checking? do
      {:noreply, run_checks(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :languages, @languages)
    assigns = assign(assigns, :signals, @signals)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      shell={:operations}
    >
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <section class="space-y-2">
          <p class="text-sm font-medium text-sr-brand">Edge Ops</p>
          <h1 class="text-2xl font-semibold tracking-normal">Send your telemetry</h1>
          <p class="max-w-3xl text-sm text-sr-ink/65">
            Point an OpenTelemetry SDK or collector at this deployment, issue an ingestion key,
            and confirm the first data arrived.
          </p>
        </section>

        <section
          id="otlp-endpoints"
          class="space-y-4 rounded-lg border border-sr-line bg-sr-surface p-4"
        >
          <div>
            <h2 class="text-lg font-semibold">1. OTLP endpoints</h2>
            <p class="text-sm text-sr-ink/65">
              The collector accepts OTLP over gRPC and HTTP (binary protobuf only; OTLP/JSON is rejected).
            </p>
          </div>

          <div
            :if={@grpc_endpoint == "" or @http_endpoint == ""}
            id="otlp-endpoints-unset-note"
            class={ui_alert_class(variant: "info", class: "text-sm")}
          >
            <.icon name="hero-information-circle" class="size-5" />
            <span>
              Endpoints are not configured for this deployment yet. An operator can set
              <code class="font-mono text-xs">SERVICERADAR_OTLP_GRPC_ENDPOINT</code>
              (host:port, e.g. <code class="font-mono text-xs">otlp.example.com:50052</code>) and
              <code class="font-mono text-xs">SERVICERADAR_OTLP_HTTP_ENDPOINT</code>
              (URL, e.g. <code class="font-mono text-xs">https://otlp.example.com</code>) on the web
              service to fill this matrix. Snippets below fall back to placeholders.
            </span>
          </div>

          <div class="grid gap-3 md:grid-cols-2">
            <.endpoint_card
              id="otlp-endpoint-grpc"
              label="OTLP/gRPC"
              value={@grpc_endpoint}
              hint="Exporter endpoint (host:port). TLS passthrough to the collector."
            />
            <.endpoint_card
              id="otlp-endpoint-http"
              label="OTLP/HTTP"
              value={@http_endpoint}
              hint="POST /v1/traces, /v1/logs, /v1/metrics (binary protobuf)."
            />
          </div>

          <div :if={@grpc_requires_private_ca} class="space-y-2 text-sm text-sr-ink/65">
            <p>
              The gRPC listener presents a certificate from the ServiceRadar private CA, so exporters
              must trust the root bundle:
            </p>
            <.snippet_block id="root-ca-snippet" content={root_ca_snippet()} />
          </div>
        </section>

        <section
          id="ingestion-key"
          class="space-y-4 rounded-lg border border-sr-line bg-sr-surface p-4"
        >
          <div>
            <h2 class="text-lg font-semibold">2. Ingestion key</h2>
            <p class="max-w-3xl text-sm text-sr-ink/65">
              External producers authenticate every export with
              <code class="font-mono text-xs">x-serviceradar-ingestion-key: &lt;key&gt;</code>
              (or <code class="font-mono text-xs">authorization: Bearer &lt;key&gt;</code>).
            </p>
          </div>

          <div class={ui_alert_class(variant: "warning", class: "text-sm")}>
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>
              Operator apply required: keys are Secret-mounted collector configuration
              (<code class="font-mono text-xs">logCollector.otlp.auth</code>). Generating a key here
              does not activate it &mdash; an operator must create the Secret and roll out the chart
              values below. Nothing is written to the cluster from this page.
            </span>
          </div>

          <form
            phx-change="update_key_form"
            phx-submit="generate_key"
            class="flex flex-wrap items-end gap-3"
          >
            <label class="flex flex-col gap-1.5">
              <span class="text-xs font-medium text-sr-ink">Sender identity (Secret key)</span>
              <input
                type="text"
                name="key_form[identity]"
                value={@identity}
                class={ui_field_class(size: "sm", mono: true, class: "w-48")}
              />
            </label>
            <label class="flex flex-col gap-1.5">
              <span class="text-xs font-medium text-sr-ink">Secret name</span>
              <input
                type="text"
                name="key_form[secret_name]"
                value={@secret_name}
                class={ui_field_class(size: "sm", mono: true, class: "w-56")}
              />
            </label>
            <.ui_button type="submit" id="generate-ingestion-key" size="sm" variant="primary">
              <.icon name="hero-key" class="size-4" /> Generate key
            </.ui_button>
          </form>

          <div
            :if={@generated_key}
            id="generated-ingestion-key"
            data-ingestion-key={@generated_key}
            class="space-y-4"
          >
            <div class="flex flex-wrap items-center gap-2 rounded-lg border border-sr-line bg-sr-subtle/40 p-3">
              <span class="font-mono text-sm break-all">{@generated_key}</span>
              <.ui_button
                type="button"
                id="copy-ingestion-key"
                phx-hook=".CopyText"
                data-copy={@generated_key}
                title="Copy ingestion key"
                size="xs"
                variant="ghost"
              >
                Copy
              </.ui_button>
            </div>
            <p class="text-xs text-sr-muted">
              This key is shown once and is not stored anywhere by ServiceRadar. Copy it now. The
              sender identity (<span class="font-mono">{@identity}</span>) is stamped on every
              ingested message for attribution.
            </p>

            <div class="space-y-2">
              <h3 class="text-sm font-semibold">Create the Kubernetes Secret (operator)</h3>
              <.snippet_block
                id="kubectl-secret-snippet"
                content={kubectl_secret_snippet(@secret_name, @identity, @generated_key)}
              />
            </div>

            <div class="space-y-2">
              <h3 class="text-sm font-semibold">Enable auth in Helm values (operator)</h3>
              <.snippet_block
                id="helm-values-snippet"
                content={helm_values_snippet(@secret_name, @identity)}
              />
              <p class="text-xs text-sr-muted">
                Then roll out: <span class="font-mono">helm upgrade &lt;release&gt; ... -f values.yaml</span>.
                Until auth is enabled, the listeners accept anonymous exports.
              </p>
            </div>
          </div>
        </section>

        <section
          id="telemetry-snippets"
          class="space-y-4 rounded-lg border border-sr-line bg-sr-surface p-4"
        >
          <div>
            <h2 class="text-lg font-semibold">3. Configure your exporter</h2>
            <p class="text-sm text-sr-ink/65">
              Quickstarts use the endpoints above {if @generated_key,
                do: "and your generated ingestion key",
                else: "and an <ingestion-key> placeholder"}.
            </p>
          </div>

          <div class="flex flex-wrap gap-2" role="tablist">
            <.ui_button
              :for={{value, label} <- @languages}
              type="button"
              id={"snippet-language-#{value}"}
              phx-click="select_language"
              phx-value-language={value}
              size="xs"
              variant={if(@snippet_language == value, do: "primary", else: "ghost")}
              active={@snippet_language == value}
            >
              {label}
            </.ui_button>
          </div>

          <div class="grid gap-4 xl:grid-cols-2">
            <div class="space-y-2">
              <h3 class="text-sm font-semibold">OTLP/gRPC</h3>
              <.snippet_block id="snippet-grpc" content={snippet(@snippet_language, :grpc, assigns)} />
            </div>
            <div class="space-y-2">
              <h3 class="text-sm font-semibold">OTLP/HTTP (http/protobuf)</h3>
              <.snippet_block id="snippet-http" content={snippet(@snippet_language, :http, assigns)} />
            </div>
          </div>
        </section>

        <section
          id="first-data-checker"
          class="space-y-4 rounded-lg border border-sr-line bg-sr-surface p-4"
        >
          <div>
            <h2 class="text-lg font-semibold">4. Confirm first data</h2>
            <p class="text-sm text-sr-ink/65">
              Checks the last 15 minutes of traces, logs, and metric points for your <code class="font-mono text-xs">service.name</code>. Re-checks every 10 seconds until
              all three signals arrive.
            </p>
          </div>

          <form phx-submit="check_first_data" class="flex flex-wrap items-end gap-3">
            <label class="flex flex-col gap-1.5">
              <span class="text-xs font-medium text-sr-ink">service.name (OTEL_SERVICE_NAME)</span>
              <input
                type="text"
                name="checker[service_name]"
                value={@check_service}
                placeholder="checkout"
                class={ui_field_class(size: "sm", mono: true, class: "w-64")}
              />
            </label>
            <.ui_button type="submit" id="first-data-check" size="sm" variant="primary">
              <.icon name="hero-magnifying-glass" class="size-4" /> Check
            </.ui_button>
            <.ui_button
              :if={@checking?}
              type="button"
              id="first-data-stop"
              phx-click="stop_check"
              size="sm"
              variant="neutral"
            >
              Stop
            </.ui_button>
            <span :if={@checking?} id="first-data-polling" class="text-xs text-sr-muted">
              <.ui_spinner size="xs" /> watching for data&hellip;
            </span>
          </form>

          <div :if={@check_error} class={ui_alert_class(variant: "error", class: "text-sm")}>
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>{@check_error}</span>
          </div>

          <div :if={@check_results} class="grid gap-3 md:grid-cols-3">
            <div
              :for={{signal, label} <- @signals}
              id={"first-data-#{signal}"}
              class="space-y-2 rounded-lg border border-sr-line p-3"
            >
              <div class="flex items-center justify-between">
                <span class="text-sm font-medium">{label}</span>
                <.signal_status result={@check_results[signal]} />
              </div>
              <div :if={signal == :traces && trace_link(@check_results[signal])} class="text-xs">
                <.link
                  navigate={trace_link(@check_results[signal])}
                  class="text-sr-brand hover:underline"
                >
                  Open first trace
                </.link>
              </div>
            </div>
          </div>
        </section>
      </Shell.settings_chrome>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const text = this.el.dataset.copy
              if (!text || !navigator.clipboard) return
              navigator.clipboard.writeText(text).then(() => {
                const original = this.el.textContent
                this.el.textContent = "Copied"
                setTimeout(() => { this.el.textContent = original }, 1200)
              })
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:hint, :string, default: nil)

  defp endpoint_card(assigns) do
    ~H"""
    <div id={@id} class="space-y-1 rounded-lg border border-sr-line p-3">
      <div class="flex items-center justify-between">
        <span class="text-sm font-medium">{@label}</span>
        <.ui_button
          :if={@value != ""}
          type="button"
          id={"#{@id}-copy"}
          phx-hook=".CopyText"
          data-copy={@value}
          title={"Copy #{@label} endpoint"}
          size="xs"
          variant="ghost"
        >
          Copy
        </.ui_button>
      </div>
      <div class="font-mono text-sm break-all">
        {if @value == "", do: "Not configured", else: @value}
      </div>
      <p :if={@hint} class="text-xs text-sr-muted">{@hint}</p>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:content, :string, required: true)

  defp snippet_block(assigns) do
    ~H"""
    <div id={@id} class="relative">
      <.ui_button
        type="button"
        id={"#{@id}-copy"}
        phx-hook=".CopyText"
        data-copy={@content}
        title="Copy snippet"
        size="xs"
        variant="ghost"
        class="absolute right-2 top-2"
      >
        Copy
      </.ui_button>
      <pre class="overflow-x-auto rounded-lg bg-sr-subtle/60 p-3 pr-16 font-mono text-xs leading-relaxed"><code>{@content}</code></pre>
    </div>
    """
  end

  attr(:result, :any, default: nil)

  defp signal_status(assigns) do
    ~H"""
    <.ui_badge :if={match?({:found, _}, @result)} size="sm" variant="success">Data arrived</.ui_badge>
    <.ui_badge :if={@result == :not_found} size="sm" variant="ghost">No data yet</.ui_badge>
    <.ui_badge
      :if={match?({:error, _}, @result)}
      size="sm"
      variant="error"
      title={error_detail(@result)}
    >
      Query failed
    </.ui_badge>
    """
  end

  # -- first-data checker ----------------------------------------------------

  defp run_checks(socket) do
    srql = srql_module()
    service = socket.assigns.check_service

    results =
      Map.new(check_queries(service), fn {signal, query} ->
        {signal, run_query(srql, query, socket.assigns.current_scope)}
      end)

    all_found? = Enum.all?(@signals, fn {signal, _label} -> match?({:found, _}, results[signal]) end)

    socket = assign(socket, :check_results, results)

    if all_found? do
      socket |> assign(:checking?, false) |> stop_polling()
    else
      schedule_poll(socket)
    end
  end

  defp check_queries(service) do
    [
      {:traces, ~s(in:traces service_name:"#{service}" time:last_15m limit:1)},
      {:logs, ~s(in:logs service_name:"#{service}" time:last_15m limit:1)},
      {:metrics, ~s(in:otel_metric_points service_name:"#{service}" time:last_15m limit:1)}
    ]
  end

  defp run_query(srql, query, scope) do
    case srql.query(query, %{scope: scope}) do
      {:ok, %{"results" => [row | _]}} when is_map(row) -> {:found, row}
      {:ok, _} -> :not_found
      {:error, reason} -> {:error, format_error(reason)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp schedule_poll(socket) do
    if connected?(socket) do
      assign(socket, :poll_ref, Process.send_after(self(), :poll_first_data, @poll_interval_ms))
    else
      socket
    end
  end

  defp stop_polling(socket) do
    case socket.assigns[:poll_ref] do
      nil ->
        socket

      ref ->
        Process.cancel_timer(ref)
        assign(socket, :poll_ref, nil)
    end
  end

  defp trace_link({:found, row}) when is_map(row) do
    case row["trace_id"] do
      trace_id when is_binary(trace_id) and trace_id != "" -> ~p"/observability/traces/#{trace_id}"
      _ -> nil
    end
  end

  defp trace_link(_), do: nil

  defp error_detail({:error, detail}), do: detail
  defp error_detail(_), do: nil

  # -- snippets ----------------------------------------------------------------

  defp root_ca_snippet do
    """
    kubectl -n <namespace> get secret serviceradar-runtime-certs \\
      -o jsonpath='{.data.root\\.pem}' | base64 -d > serviceradar-root.pem\
    """
  end

  defp kubectl_secret_snippet(secret_name, identity, key) do
    """
    kubectl -n <namespace> create secret generic #{secret_name} \\
      --from-literal=#{identity}="#{key}"\
    """
  end

  defp helm_values_snippet(secret_name, identity) do
    """
    logCollector:
      otlp:
        auth:
          enabled: true
          secretName: #{secret_name}
          secretKey: #{identity}\
    """
  end

  defp snippet("collector", :grpc, assigns) do
    """
    exporters:
      otlp/serviceradar:
        endpoint: #{grpc_display(assigns.grpc_endpoint)}
        compression: gzip
        headers:
          x-serviceradar-ingestion-key: #{key_display(assigns.generated_key)}
    #{collector_tls_block(assigns.grpc_requires_private_ca)}service:
      pipelines:
        traces:
          exporters: [otlp/serviceradar]
        metrics:
          exporters: [otlp/serviceradar]
        logs:
          exporters: [otlp/serviceradar]\
    """
  end

  defp snippet("collector", :http, assigns) do
    """
    exporters:
      otlphttp/serviceradar:
        endpoint: #{http_display(assigns.http_endpoint)}
        compression: gzip
        headers:
          x-serviceradar-ingestion-key: #{key_display(assigns.generated_key)}
    service:
      pipelines:
        traces:
          exporters: [otlphttp/serviceradar]
        metrics:
          exporters: [otlphttp/serviceradar]
        logs:
          exporters: [otlphttp/serviceradar]\
    """
  end

  defp snippet("java", variant, assigns) do
    sdk_env_snippet(variant, assigns, "java -javaagent:opentelemetry-javaagent.jar -jar app.jar")
  end

  defp snippet("python", variant, assigns) do
    sdk_env_snippet(variant, assigns, "opentelemetry-instrument python app.py")
  end

  defp snippet("node", variant, assigns) do
    sdk_env_snippet(variant, assigns, "node --require @opentelemetry/auto-instrumentations-node/register app.js")
  end

  defp snippet("go", :grpc, assigns) do
    sdk_env_snippet(
      :grpc,
      assigns,
      "# exporter: otlptracegrpc.New(context.Background()) honors these env vars"
    )
  end

  defp snippet("go", :http, assigns) do
    sdk_env_snippet(
      :http,
      assigns,
      "# exporter: otlptracehttp.New(context.Background()) honors these env vars"
    )
  end

  defp sdk_env_snippet(:grpc, assigns, run_line) do
    [
      "export OTEL_SERVICE_NAME=checkout",
      "export OTEL_EXPORTER_OTLP_PROTOCOL=grpc",
      "export OTEL_EXPORTER_OTLP_ENDPOINT=https://#{grpc_display(assigns.grpc_endpoint)}",
      ~s(export OTEL_EXPORTER_OTLP_HEADERS="x-serviceradar-ingestion-key=#{key_display(assigns.generated_key)}"),
      assigns.grpc_requires_private_ca &&
        "export OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/serviceradar-root.pem",
      run_line
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp sdk_env_snippet(:http, assigns, run_line) do
    Enum.join(
      [
        "export OTEL_SERVICE_NAME=checkout",
        "export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf",
        "export OTEL_EXPORTER_OTLP_ENDPOINT=#{http_display(assigns.http_endpoint)}",
        ~s(export OTEL_EXPORTER_OTLP_HEADERS="x-serviceradar-ingestion-key=#{key_display(assigns.generated_key)}"),
        run_line
      ],
      "\n"
    )
  end

  defp collector_tls_block(true) do
    "    tls:\n      ca_file: /etc/otelcol/serviceradar-root.pem\n"
  end

  defp collector_tls_block(false), do: ""

  defp grpc_display(""), do: "<otlp-host>:4317"
  defp grpc_display(value), do: value

  defp http_display(""), do: "https://<otlp-host>:4318"
  defp http_display(value), do: value

  defp key_display(nil), do: "<ingestion-key>"
  defp key_display(key), do: key

  # -- input sanitizers --------------------------------------------------------

  # Kubernetes Secret data keys: alphanumeric plus "-", "_", ".".
  defp sanitize_identity(value) when is_binary(value) do
    case String.replace(value, ~r/[^A-Za-z0-9._-]/, "") do
      "" -> "default"
      cleaned -> cleaned
    end
  end

  defp sanitize_identity(_), do: "default"

  # Kubernetes object names: DNS-1123 subdomain.
  defp sanitize_secret_name(value) when is_binary(value) do
    case value |> String.downcase() |> String.replace(~r/[^a-z0-9.-]/, "") do
      "" -> "otlp-ingestion-key"
      cleaned -> cleaned
    end
  end

  defp sanitize_secret_name(_), do: "otlp-ingestion-key"

  # service.name is interpolated into a quoted SRQL string; strip quotes and
  # backslashes so user input cannot escape the literal.
  defp sanitize_service_name(value) when is_binary(value) do
    value |> String.replace(~r/["\\]/, "") |> String.trim()
  end

  defp sanitize_service_name(_), do: ""

  defp config_string(config, key) do
    case Keyword.get(config, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
