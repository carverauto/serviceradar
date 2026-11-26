defmodule ServiceRadarWebNGWeb.CatalogLive.InstallWizardComponents do
  @moduledoc """
  4-Step Guided Install & Upgrade Wizard components (`4.3`):
  1. Typed `config` parameter inputs (defaults, `min`/`max`/`enum`, required)
  2. `credential_slots` binding selector (`NetworkCredentialRule` / `NetworkCredentialSecret`
     with inline link to Settings -> Credentials) + `plugin_dependencies` readiness check
  3. Dry-Run Preview & Upgrade Diff Viewer (showing created/updated/preserved overrides +
     `Keep Forked (managed: false)` vs `Reset to Upstream` controls for diverged resources)
  4. Atomic apply & verification summary
  """

  use ServiceRadarWebNGWeb, :html

  attr :wizard, :map, required: true
  attr :credential_options, :map, required: true
  attr :can_activate_dashboards, :boolean, default: false

  def install_wizard_modal(assigns) do
    pack = assigns.wizard.pack
    step = assigns.wizard.step

    assigns =
      assigns
      |> assign(:pack, pack)
      |> assign(:step, step)

    ~H"""
    <div
      id="pack-install-wizard-modal"
      data-role="pack-install-wizard"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-xs"
      role="dialog"
      aria-modal="true"
      aria-label={"Install wizard: #{@pack["name"]}"}
    >
      <div class="flex max-h-[92vh] w-full max-w-4xl flex-col overflow-hidden rounded-xl border border-sr-line bg-sr-surface shadow-2xl">
        <div class="flex items-center justify-between border-b border-sr-line px-6 py-4">
          <div>
            <h2 class="text-lg font-semibold text-sr-ink">
              {if(@pack["installed"], do: "Upgrade / Configure", else: "Install")} {@pack["name"]}
            </h2>
            <p class="text-xs font-mono text-sr-muted">
              {@pack["id"]} · target v{@pack["version"]}
              <span :if={@pack["installed_version"]}>
                (currently v{@pack["installed_version"]})
              </span>
            </p>
          </div>
          <.ui_button
            type="button"
            size="sm"
            variant="ghost"
            phx-click="close_install_wizard"
            aria-label="Close install wizard"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_button>
        </div>

        <ol class="grid grid-cols-4 border-b border-sr-line bg-sr-subtle/60 text-xs">
          <li
            :for={
              {num, label} <- [
                {1, "1. Parameters"},
                {2, "2. Credentials & Plugins"},
                {3, "3. Preview & Diff"},
                {4, "4. Apply & Verify"}
              ]
            }
            class={[
              "px-4 py-2.5 font-medium border-b-2 transition-colors",
              cond do
                @step == num -> "border-sr-brand text-sr-brand bg-sr-surface"
                @step > num -> "border-emerald-500 text-sr-ink"
                true -> "border-transparent text-sr-muted"
              end
            ]}
          >
            {label}
          </li>
        </ol>

        <div class="flex-1 overflow-y-auto p-6 space-y-5">
          <div
            :if={@wizard.error}
            id="wizard-error-banner"
            class="rounded-lg border border-red-500/40 bg-red-500/10 px-4 py-3 text-sm text-red-700 dark:text-red-300"
          >
            {@wizard.error}
          </div>

          <%= case @step do %>
            <% 1 -> %>
              <.step_one_parameters wizard={@wizard} pack={@pack} />
            <% 2 -> %>
              <.step_two_credentials_and_plugins
                wizard={@wizard}
                pack={@pack}
                credential_options={@credential_options}
                can_activate_dashboards={@can_activate_dashboards}
              />
            <% 3 -> %>
              <.step_three_preview_and_diff wizard={@wizard} pack={@pack} />
            <% 4 -> %>
              <.step_four_applied wizard={@wizard} pack={@pack} />
          <% end %>
        </div>

        <div class="flex items-center justify-between border-t border-sr-line bg-sr-subtle/40 px-6 py-3.5">
          <div>
            <.ui_button
              :if={@step in [2, 3]}
              id="wizard-back-btn"
              type="button"
              size="sm"
              variant="ghost"
              phx-click="wizard_prev_step"
            >
              Back
            </.ui_button>
          </div>

          <div class="flex items-center gap-2">
            <.ui_button
              :if={@step < 4}
              type="button"
              size="sm"
              variant="ghost"
              phx-click="close_install_wizard"
            >
              Cancel
            </.ui_button>

            <.ui_button
              :if={@step == 1}
              id="wizard-next-step-1-btn"
              type="button"
              size="sm"
              variant="primary"
              phx-click="wizard_next_step"
            >
              Next: Credentials & Plugins
            </.ui_button>

            <.ui_button
              :if={@step == 2}
              id="wizard-next-step-2-btn"
              type="button"
              size="sm"
              variant="primary"
              phx-click="wizard_next_step"
            >
              Next: Preview & Diff
            </.ui_button>

            <.ui_button
              :if={@step == 3}
              id="wizard-apply-btn"
              type="button"
              size="sm"
              variant="primary"
              phx-click="wizard_apply_install"
            >
              {if(@pack["installed"], do: "Apply Upgrade", else: "Install Solution Pack")}
            </.ui_button>

            <.ui_button
              :if={@step == 4}
              id="wizard-done-btn"
              type="button"
              size="sm"
              variant="primary"
              phx-click="close_install_wizard"
            >
              Done
            </.ui_button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp step_one_parameters(assigns) do
    descriptors = Map.get(assigns.pack, "config", [])
    assigns = assign(assigns, :descriptors, descriptors)

    ~H"""
    <div id="wizard-step-1" class="space-y-4">
      <div>
        <h3 class="text-sm font-semibold text-sr-ink">Configure Typed Pack Parameters</h3>
        <p class="mt-0.5 text-xs text-sr-muted">
          Values differing from defaults are stored in
          <code class="font-mono">parameter_overrides</code>
          and preserved across future pack upgrades.
        </p>
      </div>

      <div
        :if={@descriptors == []}
        class="rounded-lg border border-sr-line bg-sr-subtle p-4 text-sm text-sr-muted"
      >
        This pack has no configurable parameters. Continue to credential and plugin verification.
      </div>

      <.form
        :if={@descriptors != []}
        for={to_form(@wizard.config_values, as: :config)}
        id="wizard-config-form"
        phx-change="wizard_update_config"
        class="grid grid-cols-1 gap-4 md:grid-cols-2"
      >
        <div
          :for={cfg <- @descriptors}
          class="rounded-lg border border-sr-line bg-sr-subtle/40 p-3.5 space-y-1.5"
        >
          <div class="flex items-center justify-between gap-2">
            <label
              for={"wizard-cfg-#{cfg["key"]}"}
              class="text-xs font-mono font-semibold text-sr-ink"
            >
              {cfg["key"]}
              <span :if={cfg["required"] == true} class="text-red-500">*</span>
            </label>
            <.ui_badge variant="ghost" size="xs">{cfg["type"]}</.ui_badge>
          </div>

          <%= cond do %>
            <% is_list(cfg["enum"]) and cfg["enum"] != [] -> %>
              <select
                id={"wizard-cfg-#{cfg["key"]}"}
                name={"config[#{cfg["key"]}]"}
                class={ui_field_class(size: "sm", class: "w-full")}
              >
                <option
                  :for={opt <- cfg["enum"]}
                  value={to_string(opt)}
                  selected={
                    to_string(Map.get(@wizard.config_values, cfg["key"], cfg["default"])) ==
                      to_string(opt)
                  }
                >
                  {to_string(opt)}
                </option>
              </select>
            <% cfg["type"] == "boolean" -> %>
              <select
                id={"wizard-cfg-#{cfg["key"]}"}
                name={"config[#{cfg["key"]}]"}
                class={ui_field_class(size: "sm", class: "w-full")}
              >
                <option
                  value="true"
                  selected={
                    to_string(Map.get(@wizard.config_values, cfg["key"], cfg["default"])) == "true"
                  }
                >
                  true
                </option>
                <option
                  value="false"
                  selected={
                    to_string(Map.get(@wizard.config_values, cfg["key"], cfg["default"])) == "false"
                  }
                >
                  false
                </option>
              </select>
            <% cfg["type"] in ["integer", "number", "duration_seconds"] -> %>
              <input
                id={"wizard-cfg-#{cfg["key"]}"}
                type="number"
                step={if(cfg["type"] == "number", do: "any", else: "1")}
                min={cfg["min"]}
                max={cfg["max"]}
                name={"config[#{cfg["key"]}]"}
                value={Map.get(@wizard.config_values, cfg["key"], cfg["default"])}
                class={ui_field_class(size: "sm", class: "w-full")}
              />
            <% true -> %>
              <input
                id={"wizard-cfg-#{cfg["key"]}"}
                type="text"
                name={"config[#{cfg["key"]}]"}
                value={Map.get(@wizard.config_values, cfg["key"], cfg["default"])}
                class={ui_field_class(size: "sm", class: "w-full")}
              />
          <% end %>

          <p :if={cfg["description"]} class="text-xs text-sr-muted">{cfg["description"]}</p>
          <p class="font-mono text-[11px] text-sr-muted">
            Default: {inspect(cfg["default"])}
            <span :if={cfg["min"] != nil}> · Min: {cfg["min"]}</span>
            <span :if={cfg["max"] != nil}> · Max: {cfg["max"]}</span>
          </p>
        </div>
      </.form>
    </div>
    """
  end

  defp step_two_credentials_and_plugins(assigns) do
    slots = Map.get(assigns.pack, "credential_slots", [])

    dep_report =
      assigns.wizard.dependency_report ||
        %{
          ready?: true,
          dependencies: [],
          worker_dependencies: [],
          dashboard_package_dependencies: []
        }

    worker_deps = Map.get(dep_report, :worker_dependencies, [])
    dashboard_deps = Map.get(dep_report, :dashboard_package_dependencies, [])

    has_bundled_dashboards? =
      (get_in(assigns.pack, ["counts", "dashboard_packages"]) || 0) > 0 or
        List.wrap(assigns.pack["dashboard_packages"]) != []

    has_blocking_worker? = Enum.any?(worker_deps, &(Map.get(&1, :blocking?, false) == true))
    secrets = Map.get(assigns.credential_options, :secrets, [])
    rules = Map.get(assigns.credential_options, :rules, [])

    assigns =
      assigns
      |> assign(:slots, slots)
      |> assign(:dep_report, dep_report)
      |> assign(:worker_deps, worker_deps)
      |> assign(:dashboard_deps, dashboard_deps)
      |> assign(:has_bundled_dashboards?, has_bundled_dashboards?)
      |> assign(:has_blocking_worker?, has_blocking_worker?)
      |> assign(:secrets, secrets)
      |> assign(:rules, rules)

    ~H"""
    <div id="wizard-step-2" class="space-y-6">
      <section class="space-y-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h3 class="text-sm font-semibold text-sr-ink">Credential Slot Bindings</h3>
            <p class="text-xs text-sr-muted">
              Bind each abstract slot to a CNPG <code class="font-mono">NetworkCredentialRule</code>
              or <code class="font-mono">NetworkCredentialSecret</code>.
            </p>
          </div>
          <.link
            id="wizard-create-credential-link"
            navigate={~p"/settings/networks/credentials"}
            class="inline-flex items-center gap-1 rounded-sr-control border border-sr-line bg-sr-control px-3 py-1.5 text-xs font-medium text-sr-brand hover:bg-sr-subtle"
          >
            <.icon name="hero-key" class="size-3.5" /> Create Credential in Settings
          </.link>
        </div>

        <div
          :if={@slots == []}
          class="rounded-lg border border-sr-line bg-sr-subtle p-4 text-sm text-sr-muted"
        >
          No credential slots required by this pack.
        </div>

        <.form
          :if={@slots != []}
          for={to_form(@wizard.credential_bindings, as: :bindings)}
          id="wizard-bindings-form"
          phx-change="wizard_update_bindings"
          class="space-y-3"
        >
          <div
            :for={slot <- @slots}
            class="rounded-lg border border-sr-line bg-sr-subtle/40 p-4 space-y-2"
          >
            <div class="flex items-center justify-between gap-2">
              <div>
                <span class="font-mono text-xs font-semibold text-sr-ink">{slot["slot"]}</span>
                <span class="ml-2 text-xs text-sr-muted">
                  provider: {slot["provider"]} · role: {slot["role"]}
                </span>
              </div>
              <.ui_badge
                variant={if(slot["required"] != false, do: "warning", else: "ghost")}
                size="xs"
              >
                {if(slot["required"] != false, do: "Required", else: "Optional")}
              </.ui_badge>
            </div>
            <p class="text-xs text-sr-muted">{slot["purpose"]}</p>

            <select
              id={"wizard-slot-#{slot["slot"]}"}
              name={"bindings[#{slot["slot"]}]"}
              class={ui_field_class(size: "sm", class: "w-full")}
            >
              <option value="">-- Select credential rule or secret --</option>
              <optgroup :if={@rules != []} label="Credential Rules (Dynamic Target Scoped)">
                <option
                  :for={r <- @rules}
                  value={"rule:#{r["id"]}"}
                  selected={Map.get(@wizard.credential_bindings, slot["slot"]) == "rule:#{r["id"]}"}
                >
                  Rule: {r["name"]} ({r["provider"]})
                </option>
              </optgroup>
              <optgroup :if={@secrets != []} label="Reusable Credential Secrets">
                <option
                  :for={s <- @secrets}
                  value={"secret:#{s["id"]}"}
                  selected={Map.get(@wizard.credential_bindings, slot["slot"]) == "secret:#{s["id"]}"}
                >
                  Secret: {s["name"]} ({s["provider"]} / {s["credential_kind"]})
                </option>
              </optgroup>
            </select>
          </div>
        </.form>
      </section>

      <section class="space-y-3">
        <div class="flex items-center justify-between">
          <h3 class="text-sm font-semibold text-sr-ink">Wasm Plugin Dependencies</h3>
          <.ui_badge
            variant={if(@dep_report.ready?, do: "success", else: "error")}
            size="xs"
          >
            {if(@dep_report.ready?, do: "Ready", else: "Action Required")}
          </.ui_badge>
        </div>

        <div
          :if={@dep_report.dependencies == []}
          class="rounded-lg border border-sr-line bg-sr-subtle p-4 text-xs text-sr-muted"
        >
          Zero external Wasm plugin dependencies declared. Runs on built-in core evaluators and runner.
        </div>

        <div :if={@dep_report.dependencies != []} class="space-y-2">
          <div
            :for={dep <- @dep_report.dependencies}
            class="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-sr-line bg-sr-surface p-3 text-xs"
          >
            <div>
              <div class="font-mono font-semibold text-sr-ink">
                {dep.package_id} ({dep.version_constraint})
              </div>
              <div class="text-sr-muted">{dep.message}</div>
            </div>
            <div class="flex items-center gap-2">
              <.ui_badge
                variant={
                  case dep.status do
                    :satisfied -> "success"
                    :staged_approval_required -> "warning"
                    _ -> "error"
                  end
                }
                size="xs"
              >
                {dep.status}
              </.ui_badge>
              <.link
                :if={dep.review_path}
                navigate={dep.review_path}
                class="font-medium text-sr-brand hover:underline"
              >
                Review Plugins
              </.link>
            </div>
          </div>
        </div>
      </section>

      <section :if={@worker_deps != []} id="wizard-worker-deps-section" class="space-y-3">
        <div class="flex items-center justify-between">
          <h3 class="text-sm font-semibold text-sr-ink">Vantage Worker Dependencies</h3>
          <.ui_badge
            variant={if(@has_blocking_worker?, do: "error", else: "success")}
            size="xs"
          >
            {if(@has_blocking_worker?, do: "Worker Required", else: "Ready")}
          </.ui_badge>
        </div>

        <div class="space-y-2">
          <div
            :for={dep <- @worker_deps}
            data-role="worker-dependency-item"
            class="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-sr-line bg-sr-surface p-3 text-xs"
          >
            <div>
              <div class="font-mono font-semibold text-sr-ink">
                {dep.capability}
                <span :if={dep[:min_protocol_version]}> ({dep.min_protocol_version})</span>
                <span :if={dep[:fallback_runner]} class="ml-1 font-normal text-sr-muted">
                  · fallback: {dep.fallback_runner}
                </span>
              </div>
              <div class="text-sr-muted">{dep.message}</div>
            </div>
            <.ui_badge
              variant={
                case dep.status do
                  :satisfied -> "success"
                  :fallback_ready -> "info"
                  _ -> if(dep[:optional], do: "warning", else: "error")
                end
              }
              size="xs"
            >
              {dep.status}
            </.ui_badge>
          </div>
        </div>

        <label
          :if={@has_blocking_worker?}
          class="flex items-center gap-2 rounded-lg border border-amber-500/30 bg-amber-500/5 p-3 text-xs text-sr-ink cursor-pointer"
        >
          <input
            id="wizard-install-paused-checkbox"
            type="checkbox"
            checked={@wizard.install_paused == true}
            phx-click="wizard_toggle_install_paused"
            class="checkbox checkbox-xs"
          />
          <span>
            Install pipelines in <strong>paused</strong>
            state until a compatible Vantage worker connects
          </span>
        </label>
      </section>

      <section :if={@dashboard_deps != []} id="wizard-dashboard-deps-section" class="space-y-3">
        <h3 class="text-sm font-semibold text-sr-ink">External Dashboard Package Dependencies</h3>
        <div class="space-y-2">
          <div
            :for={dep <- @dashboard_deps}
            data-role="dashboard-dependency-item"
            class="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-sr-line bg-sr-surface p-3 text-xs"
          >
            <div>
              <div class="font-mono font-semibold text-sr-ink">
                {dep.dashboard_id} ({dep.version_constraint})
              </div>
              <div class="text-sr-muted">{dep.message}</div>
            </div>
            <div class="flex items-center gap-2">
              <.ui_badge
                variant={
                  case dep.status do
                    :satisfied -> "success"
                    :staged_approval_required -> "warning"
                    _ -> "error"
                  end
                }
                size="xs"
              >
                {dep.status}
              </.ui_badge>
              <.link
                :if={dep[:review_path]}
                navigate={dep.review_path}
                class="font-medium text-sr-brand hover:underline"
              >
                Review Dashboard Packages
              </.link>
            </div>
          </div>
        </div>
      </section>

      <section
        :if={@has_bundled_dashboards?}
        id="wizard-bundled-dashboards-activation"
        class="rounded-lg border border-sr-line bg-sr-subtle/50 p-4 space-y-2.5"
      >
        <div class="flex items-center justify-between gap-2">
          <h3 class="text-sm font-semibold text-sr-ink">
            Bundled Dashboard SDK Browser Modules
          </h3>
          <.ui_badge
            variant={
              if(@wizard.activate_dashboard_packages == true and @can_activate_dashboards,
                do: "success",
                else: "warning"
              )
            }
            size="xs"
          >
            {if(@wizard.activate_dashboard_packages == true and @can_activate_dashboards,
              do: "Activate & Bind Routes",
              else: "Stage Only (Approval Required)"
            )}
          </.ui_badge>
        </div>

        <%= if @can_activate_dashboards do %>
          <label class="flex items-start gap-2.5 text-xs text-sr-ink cursor-pointer">
            <input
              id="wizard-activate-dashboards-checkbox"
              type="checkbox"
              checked={@wizard.activate_dashboard_packages == true}
              phx-click="wizard_toggle_activate_dashboards"
              class="checkbox checkbox-xs mt-0.5"
            />
            <span>
              Enable bundled JavaScript dashboard module(s) and bind dashboard route(s) immediately.
              Leave unchecked to stage in <code class="font-mono">:staged</code>
              status for later review.
            </span>
          </label>
        <% else %>
          <p class="text-xs text-sr-muted">
            You do not hold <code class="font-mono">dashboards.packages.manage</code>
            (or <code class="font-mono">dashboards.packages.publish</code>
            + <code class="font-mono">dashboards.packages.enable</code>). Bundled dashboard modules
            will be imported in <code class="font-mono">:staged</code>
            status for a dashboard
            administrator to approve at <.link
              navigate={~p"/settings/dashboards/packages"}
              class="text-sr-brand hover:underline"
            >
              Settings → Dashboard Packages
            </.link>.
          </p>
        <% end %>
      </section>
    </div>
    """
  end

  defp step_three_preview_and_diff(assigns) do
    plan = assigns.wizard.preview_plan || %{}
    items = build_preview_rows(plan)
    assigns = assigns |> assign(:plan, plan) |> assign(:items, items)

    ~H"""
    <div id="wizard-step-3" class="space-y-5">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h3 class="text-sm font-semibold text-sr-ink">
            Dry-Run Reconciliation Preview ({@plan[:mode] || :install})
          </h3>
          <p class="text-xs text-sr-muted">
            Review every check, rule, and dashboard action before writing to CNPG.
          </p>
        </div>
        <.ui_badge :if={@plan[:has_diverged?]} variant="warning" size="xs">
          Diverged Resources Detected
        </.ui_badge>
      </div>

      <div
        :if={map_size(@plan[:config_values] || %{}) > 0}
        class="rounded-lg border border-sr-line bg-sr-subtle/40 p-3.5"
      >
        <div class="text-xs font-semibold text-sr-ink">Resolved Parameter Overrides</div>
        <div class="mt-2 flex flex-wrap gap-2">
          <span
            :for={{k, v} <- @plan[:config_values] || %{}}
            class="rounded border border-sr-line bg-sr-surface px-2 py-0.5 font-mono text-xs text-sr-ink"
          >
            {k}={inspect(v)}
          </span>
        </div>
      </div>

      <div class="space-y-2.5">
        <div
          :for={item <- @items}
          data-role="preview-plan-item"
          data-resource-key={item.key}
          class="rounded-lg border border-sr-line bg-sr-surface p-4 space-y-3"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div>
              <div class="flex items-center gap-2">
                <.ui_badge variant="ghost" size="xs">{item.kind}</.ui_badge>
                <span class="font-mono text-xs font-semibold text-sr-ink">{item.name}</span>
              </div>
              <p :if={item.note} class="mt-1 text-xs text-sr-muted">{item.note}</p>
            </div>

            <.ui_badge variant={action_badge_variant(item.action)} size="xs">
              {item.action}
            </.ui_badge>
          </div>

          <div
            :if={item.diverged?}
            class="rounded-lg border border-amber-500/30 bg-amber-500/5 p-3 space-y-2.5"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <span class="text-xs font-medium text-amber-700 dark:text-amber-300">
                Structural customization detected. Choose reconciliation strategy:
              </span>
              <div class="flex items-center gap-2">
                <button
                  id={"decision-keep-#{item.dom_id}"}
                  type="button"
                  phx-click="wizard_set_decision"
                  phx-value-key={item.key}
                  phx-value-decision="keep_customized"
                  class={[
                    "rounded-sr-control border px-2.5 py-1 text-xs font-medium",
                    if(Map.get(@wizard.decisions, item.key, "keep_customized") == "keep_customized",
                      do: "border-sr-brand bg-sr-brand text-white",
                      else: "border-sr-line bg-sr-surface text-sr-ink"
                    )
                  ]}
                >
                  Keep Forked (managed: false)
                </button>
                <button
                  id={"decision-reset-#{item.dom_id}"}
                  type="button"
                  phx-click="wizard_set_decision"
                  phx-value-key={item.key}
                  phx-value-decision="reset_to_upstream"
                  class={[
                    "rounded-sr-control border px-2.5 py-1 text-xs font-medium",
                    if(Map.get(@wizard.decisions, item.key) == "reset_to_upstream",
                      do: "border-sr-brand bg-sr-brand text-white",
                      else: "border-sr-line bg-sr-surface text-sr-ink"
                    )
                  ]}
                >
                  Reset to Upstream v{@pack["version"]}
                </button>
              </div>
            </div>

            <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
              <div class="rounded border border-sr-line bg-sr-canvas p-2">
                <div class="mb-1 text-[11px] font-semibold text-sr-muted">Current (Local)</div>
                <pre
                  class="max-h-40 overflow-auto text-[11px] font-mono text-sr-ink"
                  phx-no-curly-interpolation
                ><%= item.current_json %></pre>
              </div>
              <div class="rounded border border-sr-line bg-sr-canvas p-2">
                <div class="mb-1 text-[11px] font-semibold text-sr-muted">
                  Upstream v{@pack["version"]}
                </div>
                <pre
                  class="max-h-40 overflow-auto text-[11px] font-mono text-sr-ink"
                  phx-no-curly-interpolation
                ><%= item.upstream_json %></pre>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp step_four_applied(assigns) do
    result = assigns.wizard.apply_result || %{}

    dashboard_results =
      Map.get(result, :applied_dashboard_packages) ||
        Map.get(result, "applied_dashboard_packages") ||
        Map.get(result, :dashboard_packages) ||
        Map.get(result, "dashboard_packages") ||
        []

    assigns =
      assigns
      |> assign(:result, result)
      |> assign(:dashboard_results, dashboard_results)

    ~H"""
    <div id="wizard-step-4" class="space-y-4">
      <div class="flex items-start gap-3 rounded-lg border border-emerald-500/30 bg-emerald-500/10 p-4">
        <.icon
          name="hero-check-circle"
          class="size-6 shrink-0 text-emerald-600 dark:text-emerald-400"
        />
        <div>
          <h3 class="text-sm font-semibold text-sr-ink">
            Solution Pack {@pack["name"]} v{@pack["version"]} Applied
          </h3>
          <p class="mt-1 text-xs text-sr-muted">
            All checks, rules, dashboards, and Vantage ML pipelines were reconciled atomically in CNPG.
          </p>
        </div>
      </div>

      <div
        :if={@dashboard_results != []}
        id="wizard-step-4-dashboard-packages"
        class="rounded-lg border border-sr-line bg-sr-surface p-4 space-y-2.5"
      >
        <div class="flex items-center justify-between gap-2">
          <h4 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
            Bundled Dashboard Packages
          </h4>
          <.link
            id="wizard-step-4-review-dashboards-link"
            navigate={~p"/settings/dashboards/packages"}
            class="text-xs font-medium text-sr-brand hover:underline"
          >
            Review Dashboard Packages
          </.link>
        </div>
        <div
          :for={pkg <- @dashboard_results}
          class="flex flex-wrap items-center justify-between gap-2 rounded border border-sr-line bg-sr-subtle/40 px-3 py-2 text-xs"
        >
          <span class="font-mono font-medium text-sr-ink">
            {pkg[:dashboard_id] || pkg["dashboard_id"]} · v{pkg[:version] || pkg["version"]}
            <span :if={pkg[:route_slug] || pkg["route_slug"]} class="text-sr-muted">
              (/dashboards/{pkg[:route_slug] || pkg["route_slug"]})
            </span>
          </span>
          <.ui_badge
            variant={
              if((pkg[:status] || pkg["status"] || pkg[:action]) in [:enabled, "enabled"],
                do: "success",
                else: "warning"
              )
            }
            size="xs"
          >
            {pkg[:status] || pkg["status"] || pkg[:target_status] || :staged}
          </.ui_badge>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <.link
          navigate={~p"/settings/declarative-checks"}
          class="inline-flex items-center gap-1.5 rounded-sr-control border border-sr-line bg-sr-control px-3 py-1.5 text-xs font-medium text-sr-ink hover:bg-sr-subtle"
        >
          <.icon name="hero-squares-plus" class="size-4" /> Open Declarative Checks
        </.link>
        <.link
          navigate={~p"/settings/rules"}
          class="inline-flex items-center gap-1.5 rounded-sr-control border border-sr-line bg-sr-control px-3 py-1.5 text-xs font-medium text-sr-ink hover:bg-sr-subtle"
        >
          <.icon name="hero-bell-alert" class="size-4" /> Open Alert Rules
        </.link>
        <.link
          navigate={~p"/dashboards"}
          class="inline-flex items-center gap-1.5 rounded-sr-control border border-sr-line bg-sr-control px-3 py-1.5 text-xs font-medium text-sr-ink hover:bg-sr-subtle"
        >
          <.icon name="hero-squares-2x2" class="size-4" /> Open Dashboards
        </.link>
        <.link
          :if={@dashboard_results != []}
          navigate={~p"/settings/dashboards/packages"}
          class="inline-flex items-center gap-1.5 rounded-sr-control border border-sr-line bg-sr-control px-3 py-1.5 text-xs font-medium text-sr-ink hover:bg-sr-subtle"
        >
          <.icon name="hero-shield-check" class="size-4" /> Dashboard Packages
        </.link>
      </div>
    </div>
    """
  end

  defp build_preview_rows(plan) do
    checks =
      plan
      |> Map.get(:checks, Map.get(plan, "checks", []))
      |> Enum.map(&format_plan_row("check", &1))

    rules =
      plan
      |> Map.get(:rules, Map.get(plan, "rules", []))
      |> Enum.map(&format_plan_row("rule", &1))

    dashboards =
      plan
      |> Map.get(:dashboards, Map.get(plan, "dashboards", []))
      |> Enum.map(&format_plan_row("dashboard", &1))

    vantage_pipelines =
      plan
      |> Map.get(:vantage_pipelines, Map.get(plan, "vantage_pipelines", []))
      |> Enum.map(&format_vantage_pipeline_row/1)

    signal_schemas =
      plan
      |> Map.get(:signal_schemas, Map.get(plan, "signal_schemas", []))
      |> Enum.map(&format_signal_schema_row/1)

    dashboard_packages =
      plan
      |> Map.get(:dashboard_packages, Map.get(plan, "dashboard_packages", []))
      |> Enum.map(&format_dashboard_package_row/1)

    checks ++ rules ++ dashboards ++ vantage_pipelines ++ signal_schemas ++ dashboard_packages
  end

  defp format_vantage_pipeline_row(item) do
    base = format_plan_row("vantage_pipeline", item)
    pid = Map.get(item, :pipeline_id) || Map.get(item, "pipeline_id") || base.name
    ver = Map.get(item, :version) || Map.get(item, "version")
    %{base | name: if(ver, do: "#{pid}@#{ver}", else: to_string(pid))}
  end

  defp format_signal_schema_row(item) do
    schema_id = Map.get(item, :schema_id) || Map.get(item, "schema_id") || "signal_schema"
    ver = Map.get(item, :version) || Map.get(item, "version") || "1.0.0"

    %{
      key: "signal_schema:#{schema_id}:#{ver}",
      dom_id: String.replace("signal_schema-#{schema_id}-#{ver}", ~r/[^a-zA-Z0-9_-]/, "-"),
      kind: "signal_schema",
      name: "#{schema_id}@#{ver}",
      action: "register",
      diverged?: false,
      note: "Display contract: #{Map.get(item, :display_contract_id) || schema_id}",
      current_json: "{}",
      upstream_json: safe_pretty_json(Map.get(item, :signal_schema) || %{})
    }
  end

  defp format_dashboard_package_row(item) do
    dash_id = Map.get(item, :dashboard_id) || Map.get(item, "dashboard_id") || "dashboard_package"
    ver = Map.get(item, :version) || Map.get(item, "version") || "1.0.0"
    route_slug = Map.get(item, :route_slug) || Map.get(item, "route_slug") || ""
    target_status = Map.get(item, :target_status) || Map.get(item, "target_status") || :staged
    bind? = Map.get(item, :bind_instance?, false) == true

    note =
      if bind?,
        do: "Will enable module and bind /dashboards/#{route_slug}",
        else: "Will stage module (#{target_status}) for admin review at /settings/dashboards/packages"

    %{
      key: Map.get(item, :key) || "dashboard_package:#{dash_id}:#{ver}",
      dom_id: String.replace("dashboard_package-#{dash_id}-#{ver}", ~r/[^a-zA-Z0-9_-]/, "-"),
      kind: "dashboard_package",
      name: "#{dash_id}@#{ver}",
      action: to_string(target_status),
      diverged?: false,
      note: note,
      current_json: "{}",
      upstream_json: "{}"
    }
  end

  defp format_plan_row(kind, item) do
    key = Map.get(item, :key) || Map.get(item, "key") || "#{kind}:#{Map.get(item, :slug) || Map.get(item, :name)}"
    name = Map.get(item, :slug) || Map.get(item, "slug") || Map.get(item, :name) || Map.get(item, "name") || key
    action = Map.get(item, :action) || Map.get(item, "action") || :create
    diverged? = Map.get(item, :diverged?, Map.get(item, "diverged?", false)) == true
    dom_id = String.replace(to_string(key), ~r/[^a-zA-Z0-9_-]/, "-")

    current_json =
      case Map.get(item, :existing) || Map.get(item, "existing") do
        nil -> "{}"
        map when is_map(map) -> safe_pretty_json(map)
        _ -> "{}"
      end

    upstream_json =
      case Map.get(item, :active_doc) || Map.get(item, "active_doc") || Map.get(item, :baseline_doc) do
        nil -> "{}"
        map when is_map(map) -> safe_pretty_json(map)
        _ -> "{}"
      end

    %{
      key: to_string(key),
      dom_id: dom_id,
      kind: kind,
      name: to_string(name),
      action: to_string(action),
      diverged?: diverged?,
      note: Map.get(item, :note) || Map.get(item, "note"),
      current_json: current_json,
      upstream_json: upstream_json
    }
  end

  defp safe_pretty_json(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__, :aggregates, :calculations])
    |> Map.new(fn {k, v} -> {to_string(k), inspect_safe(v)} end)
    |> Jason.encode!(pretty: true)
  end

  defp safe_pretty_json(map) when is_map(map) do
    Jason.encode!(map, pretty: true)
  rescue
    _ -> inspect(map, pretty: true)
  end

  defp inspect_safe(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp inspect_safe(v) when is_list(v), do: Enum.map(v, &inspect_safe/1)
  defp inspect_safe(%{__struct__: _} = s), do: inspect(s)
  defp inspect_safe(v) when is_map(v), do: Map.new(v, fn {k, val} -> {to_string(k), inspect_safe(val)} end)
  defp inspect_safe(v), do: to_string(v)

  defp action_badge_variant("create"), do: "success"
  defp action_badge_variant("enabled"), do: "success"
  defp action_badge_variant("register"), do: "info"
  defp action_badge_variant("staged"), do: "warning"
  defp action_badge_variant("upgrade"), do: "info"
  defp action_badge_variant("keep_customized"), do: "warning"
  defp action_badge_variant("reset_to_upstream"), do: "warning"
  defp action_badge_variant(_), do: "ghost"
end
