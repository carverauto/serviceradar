defmodule ServiceRadarWebNGWeb.CatalogLive.PackDetailComponents do
  @moduledoc """
  Pack Detail & Preview Drawer components (`4.2`) for `CatalogLive.Index`:
  - Sanitized `README.md` renderer
  - Sanitized SVG / architecture asset preview
  - Read-only Check DAG preview (mounting `DeclarativeCheckCanvasHook` with
    `canManage: false, canEvaluate: false` alongside an SSR SVG pipeline diagram)
  - Canonical JSON inspector for checks, rules, dashboards, and `manifest.json`
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Catalog.SvgSanitizer

  attr :pack, :map, required: true
  attr :active_tab, :string, default: "overview"
  attr :selected_check_slug, :string, default: nil
  attr :vantage_worker_summary, :map, default: %{}
  attr :can_install, :boolean, default: false
  attr :can_export, :boolean, default: false
  attr :can_gitops_sync, :boolean, default: false

  def pack_detail_drawer(assigns) do
    checks = Map.get(assigns.pack, "checks", [])
    rules = Map.get(assigns.pack, "rules", [])
    dashboards = Map.get(assigns.pack, "dashboards", [])

    selected_check =
      Enum.find(checks, &(&1["slug"] == assigns.selected_check_slug)) || List.first(checks)

    readme_html = render_safe_readme_blocks(Map.get(assigns.pack, "readme", ""))

    assigns =
      assigns
      |> assign(:checks, checks)
      |> assign(:rules, rules)
      |> assign(:dashboards, dashboards)
      |> assign(:selected_check, selected_check)
      |> assign(:readme_blocks, readme_html)

    ~H"""
    <div
      id="pack-detail-drawer"
      data-role="pack-detail-drawer"
      class="fixed inset-0 z-40 flex justify-end bg-black/50 backdrop-blur-xs"
      role="dialog"
      aria-modal="true"
      aria-label={"Pack detail: #{@pack["name"]}"}
    >
      <div class="flex h-full w-full max-w-4xl flex-col border-l border-sr-line bg-sr-surface shadow-2xl">
        <div class="flex items-start justify-between gap-4 border-b border-sr-line px-6 py-4">
          <div class="flex min-w-0 items-start gap-3">
            <div class="flex size-12 shrink-0 items-center justify-center rounded-xl border border-sr-line bg-sr-subtle p-1.5">
              <img
                :if={
                  is_binary(@pack["icon"]) and
                    String.starts_with?(@pack["icon"], "data:image/svg+xml;base64,")
                }
                src={@pack["icon"]}
                alt=""
                class="size-9 object-contain"
              />
              <.icon
                :if={
                  not (is_binary(@pack["icon"]) and
                         String.starts_with?(@pack["icon"], "data:image/svg+xml;base64,"))
                }
                name="hero-cube-transparent"
                class="size-7 text-sr-brand"
              />
            </div>

            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="truncate text-lg font-semibold text-sr-ink">{@pack["name"]}</h2>
                <.ui_badge variant="outline" size="xs">v{@pack["version"]}</.ui_badge>
                <.ui_badge :if={@pack["installed"]} variant="success" size="xs">
                  Installed v{@pack["installed_version"] || @pack["version"]}
                </.ui_badge>
                <.ui_badge :if={@pack["update_available"]} variant="warning" size="xs">
                  Update v{@pack["available_version"]}
                </.ui_badge>
              </div>
              <p class="mt-0.5 text-xs font-mono text-sr-muted">
                {@pack["id"]} · by {@pack["author"] || "ServiceRadar"}
              </p>
              <p class="mt-1.5 text-sm text-sr-muted">{@pack["description"]}</p>
            </div>
          </div>

          <div class="flex shrink-0 items-center gap-2">
            <.ui_button
              :if={@can_install and @pack["installed"]}
              id="detail-uninstall-pack-btn"
              type="button"
              size="sm"
              variant="outline"
              phx-click="open_uninstall_confirm"
              phx-value-slug={@pack["slug"]}
            >
              Uninstall
            </.ui_button>
            <.ui_button
              :if={@can_install}
              id="detail-open-install-wizard-btn"
              type="button"
              size="sm"
              variant="primary"
              phx-click="open_install_wizard"
              phx-value-slug={@pack["slug"]}
            >
              {if(@pack["installed"], do: "Upgrade / Configure", else: "Install Pack")}
            </.ui_button>
            <.ui_button
              type="button"
              size="sm"
              variant="ghost"
              phx-click="close_pack_detail"
              aria-label="Close pack detail"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </.ui_button>
          </div>
        </div>

        <div class="flex flex-wrap items-center justify-between gap-2 border-b border-sr-line bg-sr-subtle/50 px-6 py-2.5">
          <div class="flex flex-wrap items-center gap-1" role="tablist">
            <button
              :for={
                {tab_id, label} <- [
                  {"overview", "Overview & README"},
                  {"dag", "Check DAG (#{length(@checks)})"},
                  {"resources", "Rules & Dashboards"},
                  {"json", "JSON Inspector"}
                ]
              }
              id={"detail-tab-#{tab_id}"}
              type="button"
              role="tab"
              aria-selected={@active_tab == tab_id}
              phx-click="select_detail_tab"
              phx-value-tab={tab_id}
              class={[
                "rounded-sr-control px-3 py-1.5 text-xs font-medium transition-colors",
                if(@active_tab == tab_id,
                  do: "bg-sr-brand text-white shadow-xs",
                  else: "text-sr-muted hover:bg-sr-subtle hover:text-sr-ink"
                )
              ]}
            >
              {label}
            </button>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <a
              :if={@can_export}
              id="detail-export-srpack-link"
              href={~p"/api/v2/catalog/packs/#{@pack["slug"]}/export?format=srpack"}
              class="inline-flex items-center gap-1 rounded-sr-control border border-sr-line bg-sr-control px-2.5 py-1 text-xs font-medium text-sr-ink hover:bg-sr-subtle"
            >
              <.icon name="hero-arrow-down-tray" class="size-3.5" /> Export .srpack
            </a>
            <a
              :if={@can_export}
              id="detail-export-json-link"
              href={~p"/api/v2/catalog/packs/#{@pack["slug"]}/export?format=json"}
              class="inline-flex items-center gap-1 rounded-sr-control border border-sr-line bg-sr-control px-2.5 py-1 text-xs font-medium text-sr-ink hover:bg-sr-subtle"
            >
              <.icon name="hero-code-bracket" class="size-3.5" /> Export .json
            </a>
            <.ui_button
              :if={@can_gitops_sync}
              id="detail-push-gitops-btn"
              type="button"
              size="xs"
              variant="outline"
              phx-click="open_gitops_push"
              phx-value-slug={@pack["slug"]}
            >
              <.icon name="hero-cloud-arrow-up" class="size-3.5" /> Push to Git
            </.ui_button>
          </div>
        </div>

        <div class="flex-1 overflow-y-auto p-6 space-y-6">
          <%= case @active_tab do %>
            <% "overview" -> %>
              <.overview_tab pack={@pack} readme_blocks={@readme_blocks} />
            <% "dag" -> %>
              <.dag_tab checks={@checks} selected_check={@selected_check} />
            <% "resources" -> %>
              <.resources_tab
                pack={@pack}
                rules={@rules}
                dashboards={@dashboards}
                vantage_worker_summary={@vantage_worker_summary}
              />
            <% "json" -> %>
              <.json_tab pack={@pack} selected_check={@selected_check} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp pipeline_route_badge_variant(pipeline, workers) do
    case resolve_pack_pipeline_route(pipeline, workers) do
      :ramp_2 -> "success"
      :ramp_1_fallback -> "warning"
      :camera_vlm -> "info"
      :held -> "error"
    end
  end

  defp pipeline_route_badge_label(pipeline, workers) do
    case resolve_pack_pipeline_route(pipeline, workers) do
      :ramp_2 -> "Ramp 2: vantage.worker.v1 ready"
      :ramp_1_fallback -> "Ramp 1 fallback: camera_vlm"
      :camera_vlm -> "Ramp 1: camera_vlm"
      :held -> "Held (no eligible worker)"
    end
  end

  defp resolve_pack_pipeline_route(pipeline, workers) do
    runner = to_string(pipeline["runner"] || "camera_vlm")
    capability = pipeline["capability"]
    fallback = pipeline["fallback_runner"]
    source_mode = to_string(pipeline["source_mode"] || "recorded_block")

    eligible? =
      Enum.any?(workers, fn w ->
        Map.get(w, :online?, false) and
          Map.get(w, :health) == "ready" and
          not Map.get(w, :saturated?, false) and
          is_binary(capability) and capability in List.wrap(Map.get(w, :capabilities)) and
          source_mode in List.wrap(Map.get(w, :supported_source_modes))
      end)

    cond do
      runner == "camera_vlm" -> :camera_vlm
      eligible? -> :ramp_2
      fallback == "camera_vlm" and source_mode == "recorded_block" -> :ramp_1_fallback
      true -> :held
    end
  end

  defp overview_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span class="rounded-full border border-sr-line bg-sr-subtle px-2.5 py-1 font-medium text-sr-ink">
          {get_in(@pack, ["counts", "checks"]) || 0} checks
          * {get_in(@pack, ["counts", "rules"]) || 0} alert rules
          * {get_in(@pack, ["counts", "dashboards"]) || 0} dashboards
        </span>
        <.ui_badge :for={cat <- @pack["categories"] || []} variant="ghost" size="xs">
          {cat}
        </.ui_badge>
      </div>

      <div :if={(@pack["assets"] || []) != []} class="space-y-2">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
          Architecture & Preview Assets
        </h3>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <figure
            :for={asset <- @pack["assets"] || []}
            class="overflow-hidden rounded-lg border border-sr-line bg-sr-subtle p-3"
          >
            <img
              src={asset["data_uri"]}
              alt={asset["path"]}
              class="max-h-56 w-full object-contain"
            />
            <figcaption class="mt-2 text-xs font-mono text-sr-muted">{asset["path"]}</figcaption>
          </figure>
        </div>
      </div>

      <section class="space-y-3">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
          Documentation (README.md)
        </h3>
        <div
          id="pack-readme-content"
          class="rounded-lg border border-sr-line bg-sr-subtle/40 p-4 space-y-2 text-sm text-sr-ink"
        >
          <%= if @readme_blocks == [] do %>
            <p class="text-sr-muted">No README.md provided for this pack.</p>
          <% else %>
            <%= for block <- @readme_blocks do %>
              <%= case block do %>
                <% {:h1, text} -> %>
                  <h4 class="text-base font-bold text-sr-ink">{text}</h4>
                <% {:h2, text} -> %>
                  <h5 class="pt-2 text-sm font-semibold text-sr-ink">{text}</h5>
                <% {:h3, text} -> %>
                  <h6 class="pt-1 text-xs font-semibold uppercase tracking-wide text-sr-muted">
                    {text}
                  </h6>
                <% {:li, text} -> %>
                  <div class="flex items-start gap-2 pl-2 text-sm text-sr-muted">
                    <span class="mt-1.5 size-1.5 shrink-0 rounded-full bg-sr-brand"></span>
                    <span>{text}</span>
                  </div>
                <% {:code, text} -> %>
                  <pre
                    class="overflow-x-auto rounded bg-sr-canvas p-2.5 text-xs font-mono text-sr-ink"
                    phx-no-curly-interpolation
                  ><%= text %></pre>
                <% {:p, text} -> %>
                  <p class="leading-relaxed text-sr-muted">{text}</p>
              <% end %>
            <% end %>
          <% end %>
        </div>
      </section>

      <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
        <section class="rounded-lg border border-sr-line bg-sr-surface p-4 space-y-2">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
            Typed Config Inputs ({length(@pack["config"] || [])})
          </h3>
          <p :if={(@pack["config"] || []) == []} class="text-xs text-sr-muted">
            No configurable parameters declared.
          </p>
          <ul :if={(@pack["config"] || []) != []} class="divide-y divide-sr-line text-xs">
            <li :for={cfg <- @pack["config"] || []} class="py-2">
              <div class="flex items-center justify-between gap-2">
                <span class="font-mono font-semibold text-sr-ink">{cfg["key"]}</span>
                <.ui_badge variant="ghost" size="xs">{cfg["type"]}</.ui_badge>
              </div>
              <p :if={cfg["description"]} class="mt-0.5 text-sr-muted">{cfg["description"]}</p>
              <p class="mt-0.5 font-mono text-[11px] text-sr-muted">
                default: {inspect(cfg["default"])}
                <span :if={cfg["min"] != nil}> · min: {cfg["min"]}</span>
                <span :if={cfg["max"] != nil}> · max: {cfg["max"]}</span>
              </p>
            </li>
          </ul>
        </section>

        <section class="rounded-lg border border-sr-line bg-sr-surface p-4 space-y-2">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
            Credential Slots ({length(@pack["credential_slots"] || [])})
          </h3>
          <p :if={(@pack["credential_slots"] || []) == []} class="text-xs text-sr-muted">
            Zero external credentials required (secret-free core posture pack).
          </p>
          <ul :if={(@pack["credential_slots"] || []) != []} class="divide-y divide-sr-line text-xs">
            <li :for={slot <- @pack["credential_slots"] || []} class="py-2">
              <div class="flex items-center justify-between gap-2">
                <span class="font-mono font-semibold text-sr-ink">{slot["slot"]}</span>
                <.ui_badge
                  variant={if(slot["required"] != false, do: "warning", else: "ghost")}
                  size="xs"
                >
                  {if(slot["required"] != false, do: "Required", else: "Optional")}
                </.ui_badge>
              </div>
              <p class="mt-0.5 text-sr-muted">{slot["purpose"]}</p>
              <p class="mt-0.5 font-mono text-[11px] text-sr-muted">
                provider: {slot["provider"]} · role: {slot["role"]}
              </p>
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end

  defp dag_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div
        :if={@checks == []}
        class="rounded-lg border border-sr-line bg-sr-subtle p-6 text-center text-sm text-sr-muted"
      >
        This pack does not bundle any Declarative Checks.
      </div>

      <div :if={@checks != []} class="space-y-4">
        <div class="flex flex-wrap items-center gap-2">
          <button
            :for={chk <- @checks}
            type="button"
            phx-click="select_detail_check"
            phx-value-slug={chk["slug"]}
            class={[
              "rounded-sr-control border px-3 py-1.5 text-xs font-mono transition-colors",
              if(@selected_check && @selected_check["slug"] == chk["slug"],
                do: "border-sr-brand bg-sr-brand/10 font-semibold text-sr-brand",
                else: "border-sr-line bg-sr-surface text-sr-muted hover:text-sr-ink"
              )
            ]}
          >
            {chk["slug"]}
          </button>
        </div>

        <div :if={@selected_check} class="space-y-3">
          <.ssr_check_pipeline_svg document={@selected_check["document"]} />

          <div
            id={"pack-readonly-dag-canvas-#{@selected_check["slug"]}"}
            phx-hook="DeclarativeCheckCanvasHook"
            phx-update="ignore"
            data-props={
              Jason.encode!(%{
                initialDocument: @selected_check["document"],
                initialBindings: [],
                credentialOptions: %{secrets: [], rules: []},
                isNew: false,
                canManage: false,
                canEvaluate: false
              })
            }
            class="min-h-[380px] overflow-hidden rounded-lg border border-sr-line bg-sr-canvas"
          >
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp ssr_check_pipeline_svg(assigns) do
    doc = assigns.document || %{}
    nodes = List.wrap(doc["nodes"])
    edges = List.wrap(doc["edges"])

    assigns =
      assigns
      |> assign(:nodes, nodes)
      |> assign(:edges, edges)

    ~H"""
    <div
      data-role="check-dag-summary"
      class="rounded-lg border border-sr-line bg-sr-subtle/60 p-4"
    >
      <div class="mb-2 flex items-center justify-between text-xs text-sr-muted">
        <span class="font-semibold text-sr-ink">Read-Only Pipeline Preview</span>
        <span>{length(@nodes)} nodes · {length(@edges)} edges</span>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <%= for {node, idx} <- Enum.with_index(@nodes) do %>
          <span
            :if={idx > 0}
            class="text-sr-muted"
            aria-hidden="true"
          >
            &rarr;
          </span>
          <div class="inline-flex items-center gap-1.5 rounded-md border border-sr-line bg-sr-surface px-2.5 py-1 text-xs">
            <span class="font-mono font-semibold text-sr-brand">{node["kind"]}</span>
            <span class="text-sr-muted">({node["id"]})</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp resources_tab(assigns) do
    vantage_pipelines = List.wrap(assigns.pack["vantage_pipelines"])
    signal_schemas = List.wrap(assigns.pack["signal_schemas"])
    dashboard_packages = List.wrap(assigns.pack["dashboard_packages"])
    worker_summary = Map.get(assigns, :vantage_worker_summary) || %{}
    workers = List.wrap(Map.get(worker_summary, :workers))

    assigns =
      assigns
      |> assign(:vantage_pipelines, vantage_pipelines)
      |> assign(:signal_schemas, signal_schemas)
      |> assign(:dashboard_packages, dashboard_packages)
      |> assign(:vantage_workers, workers)

    ~H"""
    <div class="space-y-6">
      <section :if={@vantage_pipelines != []} class="space-y-2">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
          Bundled Vantage ML Pipelines ({length(@vantage_pipelines)})
        </h3>
        <div class="space-y-2">
          <div
            :for={pipeline <- @vantage_pipelines}
            class="flex items-center justify-between gap-3 rounded-lg border border-sr-line bg-sr-surface px-4 py-3 text-sm"
          >
            <div>
              <div class="font-mono font-medium text-sr-ink">
                {pipeline["name"] || pipeline["pipeline_id"]}
              </div>
              <div class="text-xs font-mono text-sr-muted">
                {pipeline["pipeline_id"]} · v{pipeline["version"] || "1.0.0"} · {pipeline[
                  "capability"
                ] ||
                  "vantage.vlm.v1"}
              </div>
            </div>
            <div class="flex flex-wrap items-center gap-1.5">
              <.ui_badge
                variant={pipeline_route_badge_variant(pipeline, @vantage_workers)}
                size="xs"
              >
                {pipeline_route_badge_label(pipeline, @vantage_workers)}
              </.ui_badge>
              <.ui_badge
                variant={if(pipeline["install_state"] == "paused", do: "warning", else: "success")}
                size="xs"
              >
                install_state: {pipeline["install_state"] || "enabled"}
              </.ui_badge>
            </div>
          </div>
        </div>
      </section>

      <section :if={@signal_schemas != []} class="space-y-2">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
          Bundled Signal Schemas ({length(@signal_schemas)})
        </h3>
        <div class="space-y-2">
          <div
            :for={schema <- @signal_schemas}
            class="flex items-center justify-between gap-3 rounded-lg border border-sr-line bg-sr-surface px-4 py-3 text-sm"
          >
            <div>
              <div class="font-mono font-medium text-sr-ink">
                {schema["schema_id"] || schema["id"]}
              </div>
              <div class="text-xs text-sr-muted">
                v{schema["version"] || "1.0.0"} · display: {schema["display_contract_id"] ||
                  schema["schema_id"]}
              </div>
            </div>
            <.ui_badge variant="info" size="xs">JSON Schema + Display</.ui_badge>
          </div>
        </div>
      </section>

      <section :if={@dashboard_packages != []} class="space-y-2">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
          Bundled Dashboard SDK Modules ({length(@dashboard_packages)})
        </h3>
        <div class="space-y-2">
          <div
            :for={pkg <- @dashboard_packages}
            class="flex items-center justify-between gap-3 rounded-lg border border-sr-line bg-sr-surface px-4 py-3 text-sm"
          >
            <div>
              <div class="font-medium text-sr-ink">
                {pkg["name"] || pkg["dashboard_id"] || pkg["slug"]}
              </div>
              <div class="text-xs font-mono text-sr-muted">
                {pkg["dashboard_id"] || pkg["slug"]} · route: /dashboards/{pkg["route_slug"] ||
                  pkg["slug"]}
              </div>
            </div>
            <.ui_badge variant="outline" size="xs">
              {pkg["interface_version"] || "dashboard-browser-module-v1"}
            </.ui_badge>
          </div>
        </div>
      </section>

      <section class="space-y-2">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
          Bundled Alert & Normalization Rules ({length(@rules)})
        </h3>
        <div
          :if={@rules == []}
          class="rounded-lg border border-sr-line bg-sr-subtle p-4 text-xs text-sr-muted"
        >
          No rules bundled.
        </div>
        <div :if={@rules != []} class="space-y-2">
          <div
            :for={rule <- @rules}
            class="flex items-center justify-between gap-3 rounded-lg border border-sr-line bg-sr-surface px-4 py-3 text-sm"
          >
            <div>
              <div class="font-mono font-medium text-sr-ink">{rule["name"]}</div>
              <div class="text-xs text-sr-muted">{rule["kind"]} · {rule["file"]}</div>
            </div>
            <.ui_badge
              variant={if(rule["install_state"] == "paused", do: "warning", else: "success")}
              size="xs"
            >
              install_state: {rule["install_state"] || "enabled"}
            </.ui_badge>
          </div>
        </div>
      </section>

      <section class="space-y-2">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
          Bundled Authored Dashboards ({length(@dashboards)})
        </h3>
        <div
          :if={@dashboards == []}
          class="rounded-lg border border-sr-line bg-sr-subtle p-4 text-xs text-sr-muted"
        >
          No dashboards bundled.
        </div>
        <div :if={@dashboards != []} class="space-y-2">
          <div
            :for={dash <- @dashboards}
            class="flex items-center justify-between gap-3 rounded-lg border border-sr-line bg-sr-surface px-4 py-3 text-sm"
          >
            <div>
              <div class="font-medium text-sr-ink">
                {get_in(dash, ["document", "title"]) || dash["slug"]}
              </div>
              <div class="font-mono text-xs text-sr-muted">{dash["slug"]} · {dash["file"]}</div>
            </div>
            <.ui_badge variant="info" size="xs">
              {length(List.wrap(get_in(dash, ["document", "panels"])))} panels
            </.ui_badge>
          </div>
        </div>
      </section>
    </div>
    """
  end

  defp json_tab(assigns) do
    manifest_json =
      assigns.pack
      |> Map.get("manifest", %{})
      |> Jason.encode!(pretty: true)

    assigns = assign(assigns, :manifest_json, manifest_json)

    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
          manifest.json (pack_format_version: {@pack["pack_format_version"] || 1})
        </h3>
        <span class="text-xs font-mono text-sr-muted">Secret-free canonical JSON</span>
      </div>
      <pre
        id="pack-manifest-json-inspector"
        class="max-h-[540px] overflow-auto rounded-lg border border-sr-line bg-sr-canvas p-4 text-xs font-mono text-sr-ink"
        phx-no-curly-interpolation
      ><%= @manifest_json %></pre>
    </div>
    """
  end

  defp render_safe_readme_blocks(raw) when is_binary(raw) do
    clean =
      case SvgSanitizer.sanitize_markdown(raw) do
        {:ok, sanitized} -> sanitized
        _ -> ""
      end

    clean
    |> String.split("\n")
    |> Enum.reduce({[], false, []}, fn line, {blocks, in_code?, code_lines} ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, "```") and not in_code? ->
          {blocks, true, []}

        String.starts_with?(trimmed, "```") and in_code? ->
          code_text = code_lines |> Enum.reverse() |> Enum.join("\n")
          {[{:code, code_text} | blocks], false, []}

        in_code? ->
          {blocks, true, [line | code_lines]}

        trimmed == "" ->
          {blocks, false, []}

        String.starts_with?(trimmed, "### ") ->
          {[{:h3, String.trim_leading(trimmed, "### ")} | blocks], false, []}

        String.starts_with?(trimmed, "## ") ->
          {[{:h2, String.trim_leading(trimmed, "## ")} | blocks], false, []}

        String.starts_with?(trimmed, "# ") ->
          {[{:h1, String.trim_leading(trimmed, "# ")} | blocks], false, []}

        String.starts_with?(trimmed, "- ") or String.starts_with?(trimmed, "* ") ->
          {[{:li, String.slice(trimmed, 2..-1//1)} | blocks], false, []}

        true ->
          {[{:p, trimmed} | blocks], false, []}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp render_safe_readme_blocks(_), do: []
end
