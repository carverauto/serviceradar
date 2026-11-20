defmodule ServiceRadarWebNGWeb.Settings.DeclarativeCheckLive.Index do
  @moduledoc """
  Settings LiveView (`/settings/declarative-checks`) listing declarative service
  and posture checks with status rollups, Solution Pack badges, state toggles,
  deterministic secret-free JSON export, and validated JSON import (`dry_run` preview).
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Observability.ServiceStatePubSub
  alias ServiceRadarWebNG.DeclarativeChecks
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @current_path "/settings/declarative-checks"
  @view_permission "declarative_checks.view"
  @manage_permission "declarative_checks.manage"
  @evaluate_permission "declarative_checks.evaluate"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_access?(scope) do
      if connected?(socket) do
        safe_subscribe_service_state()
      end

      socket =
        socket
        |> assign(:page_title, "Declarative Checks")
        |> assign(:current_path, @current_path)
        |> assign(:can_view, can_access?(scope))
        |> assign(:can_manage, RBAC.can?(scope, @manage_permission))
        |> assign(:can_evaluate, RBAC.can?(scope, @evaluate_permission))
        |> assign(:state_filter, "all")
        |> assign(:pack_filter, "")
        |> assign(:checks, [])
        |> assign(:loading?, not connected?(socket))
        |> assign(:load_error, nil)
        |> assign(:import_modal_open, false)
        |> assign(:import_form, default_import_form())
        |> assign(:import_preview, nil)
        |> assign(:import_errors, [])
        |> assign(:exported_json_preview, nil)

      socket =
        if connected?(socket) or socket.assigns[:force_connected_load?] == true do
          reload_checks(socket)
        else
          socket
        end

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to view Declarative Checks")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:service_state_updated, _payload}, socket) do
    {:noreply, reload_checks(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter_checks", params, socket) do
    scope = socket.assigns.current_scope

    if can_access?(scope) do
      state_filter = Map.get(params, "state", socket.assigns.state_filter)
      pack_filter = String.trim(to_string(Map.get(params, "pack_id", socket.assigns.pack_filter)))

      {:noreply,
       socket
       |> assign(:state_filter, state_filter)
       |> assign(:pack_filter, pack_filter)
       |> reload_checks()}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("toggle_state", %{"slug" => slug, "next_state" => next_state}, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @manage_permission) and next_state in ["enabled", "disabled", "draft"] do
      case backend(socket).update_check(slug, %{"state" => next_state}, scope: scope) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "Updated #{slug} state to #{next_state}")
           |> reload_checks()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, format_error_message(reason))}
      end
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("delete_check", %{"slug" => slug}, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @manage_permission) do
      case backend(socket).delete_check(slug, scope: scope) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "Deleted declarative check #{slug}")
           |> reload_checks()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, format_error_message(reason))}
      end
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("export_check", %{"slug" => slug}, socket) do
    scope = socket.assigns.current_scope

    if can_access?(scope) do
      case backend(socket).export_check_json(slug, scope: scope) do
        {:ok, canonical_json} ->
          {:noreply,
           socket
           |> assign(:exported_json_preview, %{slug: slug, json: canonical_json})
           |> push_event("download_canonical_json", %{
             filename: "#{slug}.declarative-check.json",
             content: canonical_json
           })}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, format_error_message(reason))}
      end
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("close_export_preview", _params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply, assign(socket, :exported_json_preview, nil)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("open_import_modal", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, @manage_permission) do
      {:noreply,
       socket
       |> assign(:import_modal_open, true)
       |> assign(:import_form, default_import_form())
       |> assign(:import_preview, nil)
       |> assign(:import_errors, [])}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("close_import_modal", _params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply,
       socket
       |> assign(:import_modal_open, false)
       |> assign(:import_preview, nil)
       |> assign(:import_errors, [])}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("change_import_form", %{"import" => import_params}, socket) do
    if RBAC.can?(socket.assigns.current_scope, @manage_permission) do
      {:noreply,
       socket
       |> assign(:import_form, to_form(normalize_import_params(import_params), as: :import))
       |> assign(:import_errors, [])}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("preview_import_current", _params, socket) do
    handle_event("preview_import", %{"import" => socket.assigns.import_form.params}, socket)
  end

  def handle_event("preview_import", %{"import" => import_params}, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @manage_permission) do
      normalized = normalize_import_params(import_params)
      json_payload = normalized["json"]

      opts = [
        scope: scope,
        dry_run: true,
        force_overwrite: normalized["force_overwrite"] == "true",
        allow_detach: normalized["allow_detach"] == "true"
      ]

      case backend(socket).import_check(json_payload, opts) do
        {:ok, preview} ->
          {:noreply,
           socket
           |> assign(:import_form, to_form(normalized, as: :import))
           |> assign(:import_preview, preview)
           |> assign(:import_errors, [])}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(:import_form, to_form(normalized, as: :import))
           |> assign(:import_preview, nil)
           |> assign(:import_errors, extract_diagnostics(error))}
      end
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("confirm_import", %{"import" => import_params}, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @manage_permission) do
      normalized = normalize_import_params(import_params)
      json_payload = normalized["json"]

      opts = [
        scope: scope,
        dry_run: false,
        force_overwrite: normalized["force_overwrite"] == "true",
        allow_detach: normalized["allow_detach"] == "true"
      ]

      case backend(socket).import_check(json_payload, opts) do
        {:ok, result} ->
          action_label = Map.get(result, "action", "imported")

          {:noreply,
           socket
           |> assign(:import_modal_open, false)
           |> assign(:import_preview, nil)
           |> assign(:import_errors, [])
           |> put_flash(:info, "Check import completed (#{action_label})")
           |> reload_checks()}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(:import_form, to_form(normalized, as: :import))
           |> assign(:import_errors, extract_diagnostics(error))}
      end
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
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
        <div id="declarative-checks-index" class="space-y-6">
          <header class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h1 class="text-xl font-semibold text-sr-ink">Declarative Checks</h1>
              <p class="mt-1 max-w-2xl text-sm text-sr-muted">
                Author portable, secret-free JSONB DAG pipelines combining HTTP synthetic journeys,
                TCP/TLS/DNS probes, read-only SRQL queries, and Solution Pack posture evaluators.
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <.ui_button
                id="view-live-results-link"
                size="sm"
                variant="outline"
                navigate={~p"/services/checks"}
              >
                <.icon name="hero-table-cells" class="w-4 h-4 mr-1" /> View Live Results
              </.ui_button>

              <.ui_button
                :if={@can_manage}
                id="open-import-declarative-check-btn"
                type="button"
                size="sm"
                variant="ghost"
                phx-click="open_import_modal"
              >
                <.icon name="hero-arrow-up-tray" class="w-4 h-4 mr-1" /> Import JSON
              </.ui_button>

              <.ui_button
                :if={@can_manage}
                id="new-declarative-check-btn"
                size="sm"
                variant="primary"
                navigate={~p"/settings/declarative-checks/new"}
              >
                <.icon name="hero-plus" class="w-4 h-4 mr-1" /> New Check
              </.ui_button>
            </div>
          </header>

          <.form
            for={to_form(%{"state" => @state_filter, "pack_id" => @pack_filter}, as: :filters)}
            id="declarative-checks-filter-form"
            phx-change="filter_checks"
            class="flex flex-wrap items-end gap-3 rounded-lg border border-sr-line bg-sr-surface p-3"
          >
            <div class="w-44">
              <label for="filter-check-state" class="block text-xs font-medium text-sr-muted mb-1">
                State
              </label>
              <select
                id="filter-check-state"
                name="state"
                value={@state_filter}
                class="w-full rounded-sr-control border border-sr-line bg-sr-control px-2.5 py-1.5 text-sm text-sr-ink"
              >
                <option value="all" selected={@state_filter == "all"}>All states</option>
                <option value="enabled" selected={@state_filter == "enabled"}>Enabled</option>
                <option value="draft" selected={@state_filter == "draft"}>Draft</option>
                <option value="disabled" selected={@state_filter == "disabled"}>Disabled</option>
              </select>
            </div>

            <div class="min-w-60 flex-1">
              <label for="filter-check-pack" class="block text-xs font-medium text-sr-muted mb-1">
                Solution Pack ID
              </label>
              <input
                id="filter-check-pack"
                type="text"
                name="pack_id"
                value={@pack_filter}
                placeholder="e.g. io.serviceradar.storage-and-nvr-health"
                class="w-full rounded-sr-control border border-sr-line bg-sr-control px-2.5 py-1.5 text-sm text-sr-ink"
              />
            </div>
          </.form>

          <.ui_alert :if={@load_error} id="declarative-checks-load-error" variant="error">
            {@load_error}
          </.ui_alert>

          <div
            :if={@exported_json_preview}
            id="declarative-check-export-preview"
            class="rounded-lg border border-sr-line bg-sr-surface p-4 space-y-2"
          >
            <div class="flex items-center justify-between">
              <span class="text-xs font-semibold text-sr-ink">
                Canonical Export ({@exported_json_preview.slug}.declarative-check.json)
              </span>
              <.ui_button
                type="button"
                size="xs"
                variant="ghost"
                phx-click="close_export_preview"
              >
                Close
              </.ui_button>
            </div>
            <pre
              phx-no-curly-interpolation
              class="max-h-60 overflow-auto rounded border border-sr-line bg-sr-subtle p-3 font-mono text-xs text-sr-ink"
            ><%= @exported_json_preview.json %></pre>
          </div>

          <div
            :if={@loading?}
            id="declarative-checks-loading"
            class="rounded-lg border border-sr-line bg-sr-surface p-8 text-center text-sm text-sr-muted"
          >
            Loading declarative checks...
          </div>

          <div
            :if={!@loading? and @checks == []}
            id="declarative-checks-empty"
            class="rounded-lg border border-sr-line bg-sr-surface p-8 text-center space-y-2"
          >
            <p class="text-sm font-medium text-sr-ink">No declarative checks found</p>
            <p class="mx-auto max-w-md text-xs text-sr-muted">
              Create a new check from a starter pipeline template or import a canonical
              <code>schema_version: 1</code>
              check JSON document.
            </p>
          </div>

          <ul :if={!@loading? and @checks != []} id="declarative-checks-list" class="space-y-3">
            <%= for check <- @checks do %>
              <li
                id={"declarative-check-row-#{check["slug"]}"}
                class="rounded-lg border border-sr-line bg-sr-surface p-4 space-y-3"
              >
                <div class="flex flex-wrap items-start justify-between gap-4">
                  <div class="min-w-0 flex-1 space-y-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <.link
                        id={"open-check-#{check["slug"]}"}
                        navigate={~p"/settings/declarative-checks/#{check["slug"]}"}
                        class="text-sm font-semibold text-sr-ink hover:underline"
                      >
                        {check["name"] || check["slug"]}
                      </.link>

                      <span class="font-mono text-xs text-sr-muted">{check["slug"]}</span>

                      <.check_state_badge state={check["state"]} />

                      <span
                        :if={check["managed"] == true}
                        data-role="managed-pack-badge"
                        class="inline-flex items-center rounded-full border border-sr-brand/30 bg-sr-brand/10 px-2 py-0.5 text-xs font-medium text-sr-ink"
                      >
                        Managed{if check["pack_id"], do: " -- #{check["pack_id"]}", else: ""}{if check[
                                                                                                   "pack_version"
                                                                                                 ],
                                                                                                 do:
                                                                                                   "@#{check["pack_version"]}",
                                                                                                 else:
                                                                                                   ""}
                      </span>

                      <span
                        :if={
                          check["managed"] != true and is_binary(check["pack_id"]) and
                            check["pack_id"] != ""
                        }
                        data-role="detached-pack-badge"
                        class="inline-flex items-center rounded-full border border-sr-line bg-sr-subtle px-2 py-0.5 text-xs text-sr-muted"
                      >
                        Detached -- {check["pack_id"]}
                      </span>
                    </div>

                    <p :if={check["description"] not in [nil, ""]} class="text-xs text-sr-muted">
                      {check["description"]}
                    </p>

                    <div class="flex flex-wrap items-center gap-3 text-xs text-sr-muted">
                      <span>Target: {get_in(check, ["target_binding", "mode"]) || "singleton"}</span>
                      <span>
                        Every {get_in(check, ["schedule", "interval_seconds"]) || 300}s
                      </span>
                      <span>{length(check["nodes"] || [])} nodes</span>
                    </div>
                  </div>

                  <div class="flex flex-wrap items-center gap-2">
                    <button
                      :if={@can_manage}
                      id={"toggle-check-#{check["slug"]}"}
                      type="button"
                      phx-click="toggle_state"
                      phx-value-slug={check["slug"]}
                      phx-value-next_state={
                        if(check["state"] == "enabled", do: "disabled", else: "enabled")
                      }
                      class="rounded-sr-control border border-sr-line px-2.5 py-1 text-xs font-medium text-sr-ink hover:bg-sr-subtle"
                    >
                      {if check["state"] == "enabled", do: "Disable", else: "Enable"}
                    </button>

                    <button
                      id={"export-check-#{check["slug"]}"}
                      type="button"
                      phx-click="export_check"
                      phx-value-slug={check["slug"]}
                      class="rounded-sr-control border border-sr-line px-2.5 py-1 text-xs font-medium text-sr-ink hover:bg-sr-subtle"
                    >
                      Export JSON
                    </button>

                    <a
                      id={"download-export-link-#{check["slug"]}"}
                      href={~p"/api/v2/declarative-checks/#{check["slug"]}/export"}
                      class="rounded-sr-control border border-sr-line px-2.5 py-1 text-xs text-sr-muted hover:text-sr-ink"
                    >
                      Download
                    </a>

                    <button
                      :if={@can_manage}
                      id={"delete-check-#{check["slug"]}"}
                      type="button"
                      phx-click="delete_check"
                      phx-value-slug={check["slug"]}
                      data-confirm={"Delete declarative check #{check["name"] || check["slug"]}?"}
                      class="rounded-sr-control border border-rose-500/40 px-2.5 py-1 text-xs text-rose-400 hover:bg-rose-500/10"
                    >
                      Delete
                    </button>
                  </div>
                </div>

                <.rollup_strip rollup={check["instance_rollup"]} />
              </li>
            <% end %>
          </ul>
        </div>

        <.ui_modal
          :if={@import_modal_open}
          id="declarative-check-import-modal"
          size="lg"
          on_cancel="close_import_modal"
        >
          <:title>Import Declarative Check JSON</:title>

          <p class="text-xs text-sr-muted">
            Paste a secret-free <code>schema_version: 1</code>
            declarative check JSON document. Run <strong>Dry-Run Preview</strong>
            to verify schema, cycle safety, and Solution Pack <code>template_fingerprint</code>
            reconciliation before saving.
          </p>

          <div
            :if={@import_errors != []}
            id="declarative-check-import-errors"
            class="rounded-sr-control border border-rose-500/40 bg-rose-500/10 p-3 text-xs text-rose-300 space-y-1"
          >
            <div class="font-semibold">Import Validation Failed</div>
            <ul class="list-disc pl-5 space-y-0.5">
              <li :for={diag <- @import_errors}>
                <code>{diag.path}</code> ({diag.code}): {diag.message}
              </li>
            </ul>
          </div>

          <div
            :if={@import_preview}
            id="declarative-check-import-preview"
            class="rounded-sr-control border border-emerald-500/40 bg-emerald-500/10 p-3 text-xs space-y-1"
          >
            <div class="font-semibold text-emerald-300">
              Dry-Run Validated ({@import_preview["action"]})
            </div>
            <div class="text-sr-ink">
              Slug: <code>{get_in(@import_preview, ["document", "slug"])}</code> | Fingerprint:{" "}
              <code>{String.slice(to_string(@import_preview["template_fingerprint"] || ""), 0, 16)}...</code>
            </div>
            <div :if={(@import_preview["warnings"] || []) != []} class="text-amber-300">
              Warnings: {Enum.join(@import_preview["warnings"], "; ")}
            </div>
          </div>

          <.form
            for={@import_form}
            id="declarative-check-import-form"
            phx-change="change_import_form"
            phx-submit="confirm_import"
            class="space-y-3"
          >
            <.input
              field={@import_form[:json]}
              type="textarea"
              rows="10"
              label="Canonical Check JSON"
              required
            />

            <div class="flex flex-wrap gap-4">
              <.input
                field={@import_form[:force_overwrite]}
                type="checkbox"
                label="Force overwrite diverged check"
              />
              <.input
                field={@import_form[:allow_detach]}
                type="checkbox"
                label="Allow detaching managed pack check"
              />
            </div>

            <div class="sr-ui-modal-action flex items-center justify-end gap-2">
              <.ui_button
                type="button"
                size="sm"
                variant="ghost"
                phx-click="close_import_modal"
              >
                Cancel
              </.ui_button>
              <.ui_button
                id="dry-run-import-btn"
                type="button"
                size="sm"
                variant="outline"
                phx-click="preview_import_current"
              >
                Dry-Run Preview
              </.ui_button>
              <.ui_button
                id="apply-import-btn"
                type="submit"
                size="sm"
                variant="primary"
              >
                Apply Import
              </.ui_button>
            </div>
          </.form>
        </.ui_modal>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr :state, :any, required: true

  defp check_state_badge(assigns) do
    state_str = to_string(assigns.state || "draft")
    assigns = assign(assigns, :state_str, state_str)

    ~H"""
    <span class={[
      "inline-flex items-center rounded-sr-control px-2 py-0.5 text-xs font-medium",
      @state_str == "enabled" && "bg-emerald-500/15 text-emerald-400",
      @state_str == "draft" && "bg-amber-500/15 text-amber-400",
      @state_str == "disabled" && "bg-sr-subtle text-sr-muted"
    ]}>
      {@state_str}
    </span>
    """
  end

  attr :rollup, :map, default: nil

  defp rollup_strip(assigns) do
    rollup = assigns.rollup || %{"total" => 0, "healthy" => 0, "degraded" => 0, "down" => 0, "unknown" => 0}
    total = Map.get(rollup, "total", 0)
    assigns = assigns |> assign(:r, rollup) |> assign(:total, total)

    ~H"""
    <div data-role="instance-rollup" class="flex flex-wrap items-center gap-4 text-xs">
      <span class="font-medium text-sr-ink">Targets: {@total}</span>
      <span class="text-emerald-400">Healthy: {Map.get(@r, "healthy", 0)}</span>
      <span class="text-amber-400">Degraded: {Map.get(@r, "degraded", 0)}</span>
      <span class="text-rose-400">Down: {Map.get(@r, "down", 0)}</span>
      <span class="text-sr-muted">Unknown: {Map.get(@r, "unknown", 0)}</span>
    </div>
    """
  end

  defp reload_checks(socket) do
    scope = socket.assigns.current_scope

    opts =
      [scope: scope]
      |> maybe_put_state(socket.assigns.state_filter)
      |> maybe_put_pack(socket.assigns.pack_filter)

    case backend(socket).list_checks(opts) do
      {:ok, checks} ->
        socket
        |> assign(:checks, checks)
        |> assign(:loading?, false)
        |> assign(:load_error, nil)

      {:error, reason} ->
        socket
        |> assign(:checks, [])
        |> assign(:loading?, false)
        |> assign(:load_error, format_error_message(reason))
    end
  end

  defp maybe_put_state(opts, state) when state in ["enabled", "draft", "disabled"],
    do: Keyword.put(opts, :state, String.to_existing_atom(state))

  defp maybe_put_state(opts, _), do: opts

  defp maybe_put_pack(opts, ""), do: opts
  defp maybe_put_pack(opts, nil), do: opts
  defp maybe_put_pack(opts, pack_id), do: Keyword.put(opts, :pack_id, pack_id)

  defp default_import_form do
    to_form(
      %{
        "json" => "",
        "force_overwrite" => "false",
        "allow_detach" => "false"
      },
      as: :import
    )
  end

  defp normalize_import_params(params) when is_map(params) do
    %{
      "json" => to_string(Map.get(params, "json", "")),
      "force_overwrite" => to_string(Map.get(params, "force_overwrite", "false") in [true, "true"]),
      "allow_detach" => to_string(Map.get(params, "allow_detach", "false") in [true, "true"])
    }
  end

  defp extract_diagnostics(%{errors: errors}) when is_list(errors) do
    Enum.map(errors, fn err ->
      %{
        path: Map.get(err, :path) || Map.get(err, "path") || "$",
        code: to_string(Map.get(err, :code) || Map.get(err, "code") || "invalid"),
        message: Map.get(err, :message) || Map.get(err, "message") || "Validation failed"
      }
    end)
  end

  defp extract_diagnostics(other) do
    [%{path: "$", code: "import_failed", message: format_error_message(other)}]
  end

  defp format_error_message(%{errors: [first | _]}) do
    Map.get(first, :message) || Map.get(first, "message") || "Validation failed"
  end

  defp format_error_message(:not_found), do: "Declarative check not found"
  defp format_error_message(err) when is_exception(err), do: Exception.message(err)
  defp format_error_message(other), do: inspect(other)

  defp can_access?(scope) do
    RBAC.can?(scope, @view_permission) or
      RBAC.can?(scope, @manage_permission) or
      RBAC.can?(scope, @evaluate_permission)
  end

  defp unauthorized_flash(socket) do
    put_flash(socket, :error, "You do not have permission to perform this action")
  end

  defp safe_subscribe_service_state do
    ServiceStatePubSub.subscribe()
  rescue
    _ -> :ok
  end

  defp backend(socket) do
    socket.assigns[:declarative_checks_backend] ||
      Application.get_env(:serviceradar_web_ng, :declarative_checks, DeclarativeChecks)
  end
end
