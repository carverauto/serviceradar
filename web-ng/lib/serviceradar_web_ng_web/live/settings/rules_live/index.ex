defmodule ServiceRadarWebNGWeb.Settings.RulesLive.Index do
  @moduledoc """
  LiveView for managing log normalization, event promotion, and alert rules.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Observability.{
    LogPromotionRule,
    LogPromotionRuleTemplate,
    StatefulAlertRule,
    StatefulAlertRuleTemplate,
    ZenRule,
    ZenRuleTemplate
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    zen_form = build_zen_form(scope)
    promotion_form = build_promotion_form(scope)
    stateful_form = build_stateful_form(scope)
    zen_template_form = build_zen_template_form(scope)
    promotion_template_form = build_promotion_template_form(scope)
    stateful_template_form = build_stateful_template_form(scope)

    socket =
      socket
      |> assign(:page_title, "Events")
      |> assign(:active_tab, "logs")
      |> assign(:zen_rules, list_zen_rules(scope))
      |> assign(:promotion_rules, list_promotion_rules(scope))
      |> assign(:stateful_rules, list_stateful_rules(scope))
      |> assign(:zen_templates, list_zen_templates(scope))
      |> assign(:promotion_templates, list_promotion_templates(scope))
      |> assign(:stateful_templates, list_stateful_templates(scope))
      |> assign(:zen_ash_form, zen_form)
      |> assign(:zen_form, to_form(zen_form))
      |> assign(:promotion_ash_form, promotion_form)
      |> assign(:promotion_form, to_form(promotion_form))
      |> assign(:stateful_ash_form, stateful_form)
      |> assign(:stateful_form, to_form(stateful_form))
      |> assign(:zen_template_ash_form, zen_template_form)
      |> assign(:zen_template_form, to_form(zen_template_form))
      |> assign(:promotion_template_ash_form, promotion_template_form)
      |> assign(:promotion_template_form, to_form(promotion_template_form))
      |> assign(:stateful_template_ash_form, stateful_template_form)
      |> assign(:stateful_template_form, to_form(stateful_template_form))
      |> assign(:editing_zen_id, nil)
      |> assign(:editing_promotion_id, nil)
      |> assign(:editing_stateful_id, nil)
      |> assign(:editing_zen_template_id, nil)
      |> assign(:editing_promotion_template_id, nil)
      |> assign(:editing_stateful_template_id, nil)
      |> assign(:selected_zen_template_id, nil)
      |> assign(:selected_promotion_template_id, nil)
      |> assign(:selected_stateful_template_id, nil)
      |> assign(:show_zen_presets_modal, false)
      |> assign(:show_promotion_presets_modal, false)
      |> assign(:show_stateful_presets_modal, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab =
      params
      |> Map.get("tab", "logs")
      |> normalize_tab()

    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("open_zen_presets", _params, socket) do
    {:noreply, assign(socket, :show_zen_presets_modal, true)}
  end

  def handle_event("close_zen_presets", _params, socket) do
    {:noreply, assign(socket, :show_zen_presets_modal, false)}
  end

  def handle_event("open_promotion_presets", _params, socket) do
    {:noreply, assign(socket, :show_promotion_presets_modal, true)}
  end

  def handle_event("close_promotion_presets", _params, socket) do
    {:noreply, assign(socket, :show_promotion_presets_modal, false)}
  end

  def handle_event("open_stateful_presets", _params, socket) do
    {:noreply, assign(socket, :show_stateful_presets_modal, true)}
  end

  def handle_event("close_stateful_presets", _params, socket) do
    {:noreply, assign(socket, :show_stateful_presets_modal, false)}
  end

  @impl true
  def handle_event("validate_zen", %{"zen_rule" => params}, socket) do
    ash_form =
      socket.assigns.zen_ash_form
      |> AshPhoenix.Form.validate(params)

    {:noreply, assign(socket, :zen_ash_form, ash_form) |> assign(:zen_form, to_form(ash_form))}
  end

  def handle_event("save_zen", %{"zen_rule" => params}, socket) do
    scope = socket.assigns.current_scope

    case AshPhoenix.Form.submit(socket.assigns.zen_ash_form, params: params) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> assign(:zen_rules, list_zen_rules(scope))
         |> reset_zen_form(scope)}

      {:error, ash_form} ->
        {:noreply,
         assign(socket, :zen_ash_form, ash_form) |> assign(:zen_form, to_form(ash_form))}
    end
  end

  def handle_event("edit_zen", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.zen_rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        ash_form = build_zen_form(scope, rule)

        {:noreply,
         socket
         |> assign(:editing_zen_id, rule.id)
         |> assign(:zen_ash_form, ash_form)
         |> assign(:zen_form, to_form(ash_form))}
    end
  end

  def handle_event("cancel_zen_edit", _params, socket) do
    {:noreply, reset_zen_form(socket, socket.assigns.current_scope)}
  end

  def handle_event("delete_zen", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.zen_rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        case Ash.destroy(rule, scope: scope) do
          :ok ->
            {:noreply, assign(socket, :zen_rules, list_zen_rules(scope))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete rule")}
        end
    end
  end

  def handle_event("validate_promotion", %{"promotion_rule" => params}, socket) do
    ash_form =
      socket.assigns.promotion_ash_form
      |> AshPhoenix.Form.validate(params)

    {:noreply,
     assign(socket, :promotion_ash_form, ash_form) |> assign(:promotion_form, to_form(ash_form))}
  end

  def handle_event("save_promotion", %{"promotion_rule" => params}, socket) do
    scope = socket.assigns.current_scope

    case AshPhoenix.Form.submit(socket.assigns.promotion_ash_form, params: params) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> assign(:promotion_rules, list_promotion_rules(scope))
         |> reset_promotion_form(scope)}

      {:error, ash_form} ->
        {:noreply,
         assign(socket, :promotion_ash_form, ash_form)
         |> assign(:promotion_form, to_form(ash_form))}
    end
  end

  def handle_event("edit_promotion", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.promotion_rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        ash_form = build_promotion_form(scope, rule)

        {:noreply,
         socket
         |> assign(:editing_promotion_id, rule.id)
         |> assign(:promotion_ash_form, ash_form)
         |> assign(:promotion_form, to_form(ash_form))}
    end
  end

  def handle_event("cancel_promotion_edit", _params, socket) do
    {:noreply, reset_promotion_form(socket, socket.assigns.current_scope)}
  end

  def handle_event("delete_promotion", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.promotion_rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        case Ash.destroy(rule, scope: scope) do
          :ok ->
            {:noreply, assign(socket, :promotion_rules, list_promotion_rules(scope))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete rule")}
        end
    end
  end

  def handle_event("validate_stateful", %{"stateful_rule" => params}, socket) do
    ash_form =
      socket.assigns.stateful_ash_form
      |> AshPhoenix.Form.validate(params)

    {:noreply,
     assign(socket, :stateful_ash_form, ash_form) |> assign(:stateful_form, to_form(ash_form))}
  end

  def handle_event("save_stateful", %{"stateful_rule" => params}, socket) do
    scope = socket.assigns.current_scope

    case AshPhoenix.Form.submit(socket.assigns.stateful_ash_form, params: params) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> assign(:stateful_rules, list_stateful_rules(scope))
         |> reset_stateful_form(scope)}

      {:error, ash_form} ->
        {:noreply,
         assign(socket, :stateful_ash_form, ash_form)
         |> assign(:stateful_form, to_form(ash_form))}
    end
  end

  def handle_event("edit_stateful", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.stateful_rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        ash_form = build_stateful_form(scope, rule)

        {:noreply,
         socket
         |> assign(:editing_stateful_id, rule.id)
         |> assign(:stateful_ash_form, ash_form)
         |> assign(:stateful_form, to_form(ash_form))}
    end
  end

  def handle_event("cancel_stateful_edit", _params, socket) do
    {:noreply, reset_stateful_form(socket, socket.assigns.current_scope)}
  end

  def handle_event("delete_stateful", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.stateful_rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        case Ash.destroy(rule, scope: scope) do
          :ok ->
            {:noreply, assign(socket, :stateful_rules, list_stateful_rules(scope))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete rule")}
        end
    end
  end

  def handle_event("apply_zen_template", %{"zen_template_id" => template_id}, socket) do
    scope = socket.assigns.current_scope

    socket =
      if template_id in [nil, ""] do
        reset_zen_form(socket, scope)
      else
        template_id = to_string(template_id)

        case Enum.find(socket.assigns.zen_templates, &(to_string(&1.id) == template_id)) do
          nil ->
            socket

          template ->
            ash_form =
              socket.assigns.zen_ash_form
              |> AshPhoenix.Form.validate(zen_template_params(template))

            socket
            |> assign(:editing_zen_id, nil)
            |> assign(:zen_ash_form, ash_form)
            |> assign(:zen_form, to_form(ash_form))
        end
      end

    {:noreply, assign(socket, :selected_zen_template_id, blank_to_nil(template_id))}
  end

  def handle_event("apply_promotion_template", %{"promotion_template_id" => template_id}, socket) do
    scope = socket.assigns.current_scope

    socket =
      if template_id in [nil, ""] do
        reset_promotion_form(socket, scope)
      else
        template_id = to_string(template_id)

        case Enum.find(socket.assigns.promotion_templates, &(to_string(&1.id) == template_id)) do
          nil ->
            socket

          template ->
            ash_form =
              socket.assigns.promotion_ash_form
              |> AshPhoenix.Form.validate(promotion_template_params(template))

            socket
            |> assign(:editing_promotion_id, nil)
            |> assign(:promotion_ash_form, ash_form)
            |> assign(:promotion_form, to_form(ash_form))
        end
      end

    {:noreply, assign(socket, :selected_promotion_template_id, blank_to_nil(template_id))}
  end

  def handle_event("apply_stateful_template", %{"stateful_template_id" => template_id}, socket) do
    scope = socket.assigns.current_scope

    socket =
      if template_id in [nil, ""] do
        reset_stateful_form(socket, scope)
      else
        template_id = to_string(template_id)

        case Enum.find(socket.assigns.stateful_templates, &(to_string(&1.id) == template_id)) do
          nil ->
            socket

          template ->
            ash_form =
              socket.assigns.stateful_ash_form
              |> AshPhoenix.Form.validate(stateful_template_params(template))

            socket
            |> assign(:editing_stateful_id, nil)
            |> assign(:stateful_ash_form, ash_form)
            |> assign(:stateful_form, to_form(ash_form))
        end
      end

    {:noreply, assign(socket, :selected_stateful_template_id, blank_to_nil(template_id))}
  end

  def handle_event("validate_zen_template", %{"zen_template" => params}, socket) do
    ash_form =
      socket.assigns.zen_template_ash_form
      |> AshPhoenix.Form.validate(params)

    {:noreply,
     assign(socket, :zen_template_ash_form, ash_form)
     |> assign(:zen_template_form, to_form(ash_form))}
  end

  def handle_event("save_zen_template", %{"zen_template" => params}, socket) do
    scope = socket.assigns.current_scope

    case AshPhoenix.Form.submit(socket.assigns.zen_template_ash_form, params: params) do
      {:ok, _template} ->
        {:noreply,
         socket
         |> assign(:zen_templates, list_zen_templates(scope))
         |> reset_zen_template_form(scope)}

      {:error, ash_form} ->
        {:noreply,
         assign(socket, :zen_template_ash_form, ash_form)
         |> assign(:zen_template_form, to_form(ash_form))}
    end
  end

  def handle_event("edit_zen_template", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.zen_templates, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      template ->
        ash_form = build_zen_template_form(scope, template)

        {:noreply,
         socket
         |> assign(:editing_zen_template_id, template.id)
         |> assign(:zen_template_ash_form, ash_form)
         |> assign(:zen_template_form, to_form(ash_form))}
    end
  end

  def handle_event("cancel_zen_template_edit", _params, socket) do
    {:noreply, reset_zen_template_form(socket, socket.assigns.current_scope)}
  end

  def handle_event("delete_zen_template", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.zen_templates, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      template ->
        case Ash.destroy(template, scope: scope) do
          :ok ->
            {:noreply, assign(socket, :zen_templates, list_zen_templates(scope))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete template")}
        end
    end
  end

  def handle_event("validate_promotion_template", %{"promotion_template" => params}, socket) do
    ash_form =
      socket.assigns.promotion_template_ash_form
      |> AshPhoenix.Form.validate(params)

    {:noreply,
     assign(socket, :promotion_template_ash_form, ash_form)
     |> assign(:promotion_template_form, to_form(ash_form))}
  end

  def handle_event("save_promotion_template", %{"promotion_template" => params}, socket) do
    scope = socket.assigns.current_scope

    case AshPhoenix.Form.submit(socket.assigns.promotion_template_ash_form, params: params) do
      {:ok, _template} ->
        {:noreply,
         socket
         |> assign(:promotion_templates, list_promotion_templates(scope))
         |> reset_promotion_template_form(scope)}

      {:error, ash_form} ->
        {:noreply,
         assign(socket, :promotion_template_ash_form, ash_form)
         |> assign(:promotion_template_form, to_form(ash_form))}
    end
  end

  def handle_event("edit_promotion_template", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.promotion_templates, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      template ->
        ash_form = build_promotion_template_form(scope, template)

        {:noreply,
         socket
         |> assign(:editing_promotion_template_id, template.id)
         |> assign(:promotion_template_ash_form, ash_form)
         |> assign(:promotion_template_form, to_form(ash_form))}
    end
  end

  def handle_event("cancel_promotion_template_edit", _params, socket) do
    {:noreply, reset_promotion_template_form(socket, socket.assigns.current_scope)}
  end

  def handle_event("delete_promotion_template", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.promotion_templates, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      template ->
        case Ash.destroy(template, scope: scope) do
          :ok ->
            {:noreply, assign(socket, :promotion_templates, list_promotion_templates(scope))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete template")}
        end
    end
  end

  def handle_event("validate_stateful_template", %{"stateful_template" => params}, socket) do
    ash_form =
      socket.assigns.stateful_template_ash_form
      |> AshPhoenix.Form.validate(params)

    {:noreply,
     assign(socket, :stateful_template_ash_form, ash_form)
     |> assign(:stateful_template_form, to_form(ash_form))}
  end

  def handle_event("save_stateful_template", %{"stateful_template" => params}, socket) do
    scope = socket.assigns.current_scope

    case AshPhoenix.Form.submit(socket.assigns.stateful_template_ash_form, params: params) do
      {:ok, _template} ->
        {:noreply,
         socket
         |> assign(:stateful_templates, list_stateful_templates(scope))
         |> reset_stateful_template_form(scope)}

      {:error, ash_form} ->
        {:noreply,
         assign(socket, :stateful_template_ash_form, ash_form)
         |> assign(:stateful_template_form, to_form(ash_form))}
    end
  end

  def handle_event("edit_stateful_template", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.stateful_templates, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      template ->
        ash_form = build_stateful_template_form(scope, template)

        {:noreply,
         socket
         |> assign(:editing_stateful_template_id, template.id)
         |> assign(:stateful_template_ash_form, ash_form)
         |> assign(:stateful_template_form, to_form(ash_form))}
    end
  end

  def handle_event("cancel_stateful_template_edit", _params, socket) do
    {:noreply, reset_stateful_template_form(socket, socket.assigns.current_scope)}
  end

  def handle_event("delete_stateful_template", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    id = to_string(id)

    case Enum.find(socket.assigns.stateful_templates, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      template ->
        case Ash.destroy(template, scope: scope) do
          :ok ->
            {:noreply, assign(socket, :stateful_templates, list_stateful_templates(scope))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete template")}
        end
    end
  end

  defp normalize_tab(tab) do
    case tab do
      "log" -> "logs"
      "logs" -> "logs"
      "response" -> "events"
      "events" -> "events"
      "alerts" -> "alerts"
      "templates" -> "logs"
      _ -> "logs"
    end
  end

  @impl true
  def render(assigns) do
    tabs = [
      %{
        label: "Logs",
        patch: ~p"/settings/rules?tab=logs",
        active: assigns.active_tab == "logs"
      },
      %{
        label: "Events",
        patch: ~p"/settings/rules?tab=events",
        active: assigns.active_tab == "events"
      },
      %{
        label: "Alerts",
        patch: ~p"/settings/rules?tab=alerts",
        active: assigns.active_tab == "alerts"
      }
    ]

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/rules">
        <.settings_nav current_path="/settings/rules" />

        <div>
          <h1 class="text-2xl font-semibold text-base-content">Events</h1>
          <p class="text-sm text-base-content/60">
            Build a pipeline from logs to events to alerts.
          </p>
        </div>

        <div class="rounded-xl border border-base-200 bg-base-100 p-4">
          <div class="flex flex-wrap items-center gap-4">
            <div class="flex items-center gap-3">
              <.ui_badge variant="info" size="xs">1</.ui_badge>
              <div>
                <div class="text-sm font-semibold">Logs</div>
                <div class="text-xs text-base-content/60">Normalize and enrich raw inputs.</div>
              </div>
            </div>
            <.icon name="hero-arrow-right-mini" class="w-4 h-4 text-base-content/40" />
            <div class="flex items-center gap-3">
              <.ui_badge variant="warning" size="xs">2</.ui_badge>
              <div>
                <div class="text-sm font-semibold">Events</div>
                <div class="text-xs text-base-content/60">Promote log patterns into events.</div>
              </div>
            </div>
            <.icon name="hero-arrow-right-mini" class="w-4 h-4 text-base-content/40" />
            <div class="flex items-center gap-3">
              <.ui_badge variant="success" size="xs">3</.ui_badge>
              <div>
                <div class="text-sm font-semibold">Alerts</div>
                <div class="text-xs text-base-content/60">Escalate events with thresholds.</div>
              </div>
            </div>
          </div>
        </div>

        <.ui_tabs tabs={@tabs} />

        <div :if={@active_tab == "logs"} class="space-y-6">
          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">Log Rules (Zen)</div>
                <p class="text-xs text-base-content/60">
                  Normalize and enrich logs before promoting them into events.
                </p>
              </div>
              <.ui_button
                id="open_zen_presets"
                variant="ghost"
                size="xs"
                phx-click="open_zen_presets"
              >
                Manage presets
              </.ui_button>
            </:header>

            <div class="grid grid-cols-1 lg:grid-cols-[minmax(0,360px)_1fr] gap-6">
              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="flex items-center justify-between">
                  <div class="text-sm font-semibold">
                    {if @editing_zen_id, do: "Edit rule", else: "Create rule"}
                  </div>
                  <.ui_button
                    :if={@editing_zen_id}
                    variant="ghost"
                    size="xs"
                    phx-click="cancel_zen_edit"
                  >
                    Cancel
                  </.ui_button>
                </div>

                <.form
                  for={@zen_form}
                  id="zen_rule_form"
                  class="mt-4 space-y-3"
                  phx-change="validate_zen"
                  phx-submit="save_zen"
                >
                  <.input field={@zen_form[:name]} label="Rule ID" />
                  <.input field={@zen_form[:description]} label="Description" />
                  <.input
                    field={@zen_form[:subject]}
                    label="Subject"
                    type="text"
                    placeholder="logs.syslog"
                    list="zen-subjects"
                  />
                  <datalist id="zen-subjects">
                    <option value="logs.syslog" />
                    <option value="logs.snmp" />
                    <option value="logs.otel" />
                    <option value="otel.metrics.raw" />
                    <option value="logs.internal.health" />
                    <option value="logs.internal.jobs" />
                    <option value="logs.internal.onboarding" />
                    <option value="logs.internal.audit" />
                  </datalist>
                  <.input
                    field={@zen_form[:template]}
                    label="Rule type"
                    type="select"
                    options={[
                      {"Passthrough", :passthrough},
                      {"Strip full_message", :strip_full_message},
                      {"CEF severity mapping", :cef_severity},
                      {"SNMP severity mapping", :snmp_severity}
                    ]}
                  />
                  <.input field={@zen_form[:order]} label="Order" type="number" />
                  <.input field={@zen_form[:enabled]} label="Enabled" type="checkbox" />
                  <.input field={@zen_form[:stream_name]} type="hidden" />
                  <.input field={@zen_form[:agent_id]} type="hidden" />
                  <.button variant="primary" phx-disable-with="Saving...">
                    {if @editing_zen_id, do: "Save changes", else: "Create rule"}
                  </.button>
                </.form>
              </div>

              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr class="text-xs uppercase tracking-wide text-base-content/60">
                      <th>Rule</th>
                      <th>Subject</th>
                      <th>Type</th>
                      <th>Order</th>
                      <th>Status</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for rule <- @zen_rules do %>
                      <tr>
                        <td class="font-mono text-xs">{rule.name}</td>
                        <td class="text-xs">{rule.subject}</td>
                        <td class="text-xs">{to_string(rule.template)}</td>
                        <td class="text-xs">{rule.order}</td>
                        <td>
                          <.ui_badge variant={if rule.enabled, do: "success", else: "ghost"} size="xs">
                            {if rule.enabled, do: "Enabled", else: "Disabled"}
                          </.ui_badge>
                        </td>
                        <td class="text-right">
                          <div class="flex justify-end gap-2">
                            <.ui_button
                              size="xs"
                              variant="ghost"
                              phx-click="edit_zen"
                              phx-value-id={rule.id}
                            >
                              Edit
                            </.ui_button>
                            <.ui_button
                              size="xs"
                              variant="ghost"
                              phx-click="delete_zen"
                              phx-value-id={rule.id}
                            >
                              Delete
                            </.ui_button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                    <tr :if={@zen_rules == []}>
                      <td colspan="6" class="text-center text-base-content/60 py-6">
                        No Zen rules configured.
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </.ui_panel>
        </div>

        <div :if={@active_tab == "events"} class="space-y-6">
          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">Event Rules (Promotion)</div>
                <p class="text-xs text-base-content/60">
                  Promote log patterns into events for downstream alerting.
                </p>
              </div>
              <.ui_button
                id="open_promotion_presets"
                variant="ghost"
                size="xs"
                phx-click="open_promotion_presets"
              >
                Manage presets
              </.ui_button>
            </:header>

            <div class="grid grid-cols-1 lg:grid-cols-[minmax(0,360px)_1fr] gap-6">
              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="flex items-center justify-between">
                  <div class="text-sm font-semibold">
                    {if @editing_promotion_id, do: "Edit rule", else: "Create rule"}
                  </div>
                  <.ui_button
                    :if={@editing_promotion_id}
                    variant="ghost"
                    size="xs"
                    phx-click="cancel_promotion_edit"
                  >
                    Cancel
                  </.ui_button>
                </div>

                <.form
                  for={@promotion_form}
                  id="promotion_rule_form"
                  class="mt-4 space-y-3"
                  phx-change="validate_promotion"
                  phx-submit="save_promotion"
                >
                  <.input field={@promotion_form[:name]} label="Rule name" />
                  <.input field={@promotion_form[:priority]} label="Priority" type="number" />
                  <.input field={@promotion_form[:enabled]} label="Enabled" type="checkbox" />

                  <div class="space-y-2">
                    <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Match criteria
                    </div>
                    <.input
                      id="promotion_rule_match_always"
                      name="promotion_rule[match][always]"
                      label="Match all logs"
                      type="checkbox"
                      value={map_form_value(@promotion_form, :match, :always, false)}
                    />
                    <.input
                      id="promotion_rule_match_subject_prefix"
                      name="promotion_rule[match][subject_prefix]"
                      label="Subject prefix"
                      value={map_form_value(@promotion_form, :match, :subject_prefix)}
                    />
                    <.input
                      id="promotion_rule_match_service_name"
                      name="promotion_rule[match][service_name]"
                      label="Service name"
                      value={map_form_value(@promotion_form, :match, :service_name)}
                    />
                    <.input
                      id="promotion_rule_match_severity_number_min"
                      name="promotion_rule[match][severity_number_min]"
                      label="Min severity"
                      type="number"
                      value={map_form_value(@promotion_form, :match, :severity_number_min)}
                    />
                    <.input
                      id="promotion_rule_match_severity_number_max"
                      name="promotion_rule[match][severity_number_max]"
                      label="Max severity"
                      type="number"
                      value={map_form_value(@promotion_form, :match, :severity_number_max)}
                    />
                    <.input
                      id="promotion_rule_match_severity_text"
                      name="promotion_rule[match][severity_text]"
                      label="Severity text"
                      value={map_form_value(@promotion_form, :match, :severity_text)}
                    />
                    <.input
                      id="promotion_rule_match_body_contains"
                      name="promotion_rule[match][body_contains]"
                      label="Message contains"
                      value={map_form_value(@promotion_form, :match, :body_contains)}
                    />
                  </div>

                  <div class="space-y-2">
                    <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Event overrides
                    </div>
                    <.input
                      id="promotion_rule_event_message"
                      name="promotion_rule[event][message]"
                      label="Event message override"
                      value={map_form_value(@promotion_form, :event, :message)}
                    />
                  </div>

                  <.button variant="primary" phx-disable-with="Saving...">
                    {if @editing_promotion_id, do: "Save changes", else: "Create rule"}
                  </.button>
                </.form>
              </div>

              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr class="text-xs uppercase tracking-wide text-base-content/60">
                      <th>Rule</th>
                      <th>Subject</th>
                      <th>Priority</th>
                      <th>Status</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for rule <- @promotion_rules do %>
                      <tr>
                        <td class="font-mono text-xs">{rule.name}</td>
                        <td class="text-xs">
                          {Map.get(rule.match || %{}, "subject_prefix") || "Any"}
                        </td>
                        <td class="text-xs">{rule.priority}</td>
                        <td>
                          <.ui_badge variant={if rule.enabled, do: "success", else: "ghost"} size="xs">
                            {if rule.enabled, do: "Enabled", else: "Disabled"}
                          </.ui_badge>
                        </td>
                        <td class="text-right">
                          <div class="flex justify-end gap-2">
                            <.ui_button
                              size="xs"
                              variant="ghost"
                              phx-click="edit_promotion"
                              phx-value-id={rule.id}
                            >
                              Edit
                            </.ui_button>
                            <.ui_button
                              size="xs"
                              variant="ghost"
                              phx-click="delete_promotion"
                              phx-value-id={rule.id}
                            >
                              Delete
                            </.ui_button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                    <tr :if={@promotion_rules == []}>
                      <td colspan="5" class="text-center text-base-content/60 py-6">
                        No event rules configured.
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </.ui_panel>
        </div>

        <div :if={@active_tab == "alerts"} class="space-y-6">
          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">Alert Rules (Stateful)</div>
                <p class="text-xs text-base-content/60">
                  Escalate event patterns into alerts with thresholds and cooldowns.
                </p>
              </div>
              <.ui_button
                id="open_stateful_presets"
                variant="ghost"
                size="xs"
                phx-click="open_stateful_presets"
              >
                Manage presets
              </.ui_button>
            </:header>

            <div class="grid grid-cols-1 lg:grid-cols-[minmax(0,360px)_1fr] gap-6">
              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="flex items-center justify-between">
                  <div class="text-sm font-semibold">
                    {if @editing_stateful_id, do: "Edit rule", else: "Create rule"}
                  </div>
                  <.ui_button
                    :if={@editing_stateful_id}
                    variant="ghost"
                    size="xs"
                    phx-click="cancel_stateful_edit"
                  >
                    Cancel
                  </.ui_button>
                </div>

                <.form
                  for={@stateful_form}
                  id="stateful_rule_form"
                  class="mt-4 space-y-3"
                  phx-change="validate_stateful"
                  phx-submit="save_stateful"
                >
                  <.input field={@stateful_form[:name]} label="Rule name" />
                  <.input field={@stateful_form[:description]} label="Description" />
                  <.input field={@stateful_form[:enabled]} label="Enabled" type="checkbox" />
                  <.input field={@stateful_form[:priority]} label="Priority" type="number" />
                  <.input
                    field={@stateful_form[:signal]}
                    label="Signal"
                    type="select"
                    options={[{"Log", :log}, {"Event", :event}]}
                  />
                  <div class="grid grid-cols-2 gap-3">
                    <.input field={@stateful_form[:threshold]} label="Threshold" type="number" />
                    <.input
                      field={@stateful_form[:window_seconds]}
                      label="Window (sec)"
                      type="number"
                    />
                    <.input
                      field={@stateful_form[:bucket_seconds]}
                      label="Bucket (sec)"
                      type="number"
                    />
                    <.input
                      field={@stateful_form[:cooldown_seconds]}
                      label="Cooldown (sec)"
                      type="number"
                    />
                    <.input
                      field={@stateful_form[:renotify_seconds]}
                      label="Renotify (sec)"
                      type="number"
                    />
                  </div>

                  <div class="space-y-2">
                    <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Match criteria
                    </div>
                    <.input
                      id="stateful_rule_match_always"
                      name="stateful_rule[match][always]"
                      label="Match all logs/events"
                      type="checkbox"
                      value={map_form_value(@stateful_form, :match, :always, false)}
                    />
                    <.input
                      id="stateful_rule_match_subject_prefix"
                      name="stateful_rule[match][subject_prefix]"
                      label="Subject prefix"
                      value={map_form_value(@stateful_form, :match, :subject_prefix)}
                    />
                    <.input
                      id="stateful_rule_match_service_name"
                      name="stateful_rule[match][service_name]"
                      label="Service name"
                      value={map_form_value(@stateful_form, :match, :service_name)}
                    />
                    <.input
                      id="stateful_rule_match_severity_number_min"
                      name="stateful_rule[match][severity_number_min]"
                      label="Min severity"
                      type="number"
                      value={map_form_value(@stateful_form, :match, :severity_number_min)}
                    />
                    <.input
                      id="stateful_rule_match_severity_number_max"
                      name="stateful_rule[match][severity_number_max]"
                      label="Max severity"
                      type="number"
                      value={map_form_value(@stateful_form, :match, :severity_number_max)}
                    />
                    <.input
                      id="stateful_rule_match_severity_text"
                      name="stateful_rule[match][severity_text]"
                      label="Severity text"
                      value={map_form_value(@stateful_form, :match, :severity_text)}
                    />
                    <.input
                      id="stateful_rule_match_body_contains"
                      name="stateful_rule[match][body_contains]"
                      label="Message contains"
                      value={map_form_value(@stateful_form, :match, :body_contains)}
                    />
                  </div>

                  <.button variant="primary" phx-disable-with="Saving...">
                    {if @editing_stateful_id, do: "Save changes", else: "Create rule"}
                  </.button>
                </.form>
              </div>

              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr class="text-xs uppercase tracking-wide text-base-content/60">
                      <th>Rule</th>
                      <th>Signal</th>
                      <th>Threshold</th>
                      <th>Status</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for rule <- @stateful_rules do %>
                      <tr>
                        <td class="font-mono text-xs">{rule.name}</td>
                        <td class="text-xs">{to_string(rule.signal)}</td>
                        <td class="text-xs">
                          {rule.threshold} / {rule.window_seconds}s
                        </td>
                        <td>
                          <.ui_badge variant={if rule.enabled, do: "success", else: "ghost"} size="xs">
                            {if rule.enabled, do: "Enabled", else: "Disabled"}
                          </.ui_badge>
                        </td>
                        <td class="text-right">
                          <div class="flex justify-end gap-2">
                            <.ui_button
                              size="xs"
                              variant="ghost"
                              phx-click="edit_stateful"
                              phx-value-id={rule.id}
                            >
                              Edit
                            </.ui_button>
                            <.ui_button
                              size="xs"
                              variant="ghost"
                              phx-click="delete_stateful"
                              phx-value-id={rule.id}
                            >
                              Delete
                            </.ui_button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                    <tr :if={@stateful_rules == []}>
                      <td colspan="5" class="text-center text-base-content/60 py-6">
                        No alert rules configured.
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </.ui_panel>
        </div>

        <.zen_presets_modal
          :if={@show_zen_presets_modal}
          zen_templates={@zen_templates}
          zen_template_form={@zen_template_form}
          editing_zen_template_id={@editing_zen_template_id}
        />
        <.promotion_presets_modal
          :if={@show_promotion_presets_modal}
          promotion_templates={@promotion_templates}
          promotion_template_form={@promotion_template_form}
          editing_promotion_template_id={@editing_promotion_template_id}
        />
        <.stateful_presets_modal
          :if={@show_stateful_presets_modal}
          stateful_templates={@stateful_templates}
          stateful_template_form={@stateful_template_form}
          editing_stateful_template_id={@editing_stateful_template_id}
        />
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp zen_presets_modal(assigns) do
    ~H"""
    <dialog id="zen_presets_modal" class="modal modal-open">
      <div class="modal-box max-w-4xl">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h3 class="text-lg font-semibold text-base-content">Log Presets (Zen)</h3>
            <p class="text-sm text-base-content/60">
              Save reusable presets for log normalization.
            </p>
          </div>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close_zen_presets">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div class="mt-6 grid grid-cols-1 lg:grid-cols-[minmax(0,360px)_1fr] gap-6">
          <div class="rounded-xl border border-base-200 bg-base-100 p-4">
            <div class="flex items-center justify-between">
              <div class="text-sm font-semibold">
                {if @editing_zen_template_id, do: "Edit preset", else: "Create preset"}
              </div>
              <.ui_button
                :if={@editing_zen_template_id}
                variant="ghost"
                size="xs"
                phx-click="cancel_zen_template_edit"
              >
                Cancel
              </.ui_button>
            </div>

            <.form
              for={@zen_template_form}
              id="zen_template_form"
              class="mt-4 space-y-3"
              phx-change="validate_zen_template"
              phx-submit="save_zen_template"
            >
              <.input field={@zen_template_form[:name]} label="Preset name" />
              <.input field={@zen_template_form[:description]} label="Description" />
              <.input
                field={@zen_template_form[:subject]}
                label="Subject"
                type="text"
                placeholder="logs.syslog"
                list="zen-template-subjects"
              />
              <datalist id="zen-template-subjects">
                <option value="logs.syslog" />
                <option value="logs.snmp" />
                <option value="logs.otel" />
                <option value="otel.metrics.raw" />
                <option value="logs.internal.health" />
                <option value="logs.internal.jobs" />
                <option value="logs.internal.onboarding" />
                <option value="logs.internal.audit" />
              </datalist>
              <.input
                field={@zen_template_form[:template]}
                label="Rule type"
                type="select"
                options={[
                  {"Passthrough", :passthrough},
                  {"Strip full_message", :strip_full_message},
                  {"CEF severity mapping", :cef_severity},
                  {"SNMP severity mapping", :snmp_severity}
                ]}
              />
              <.input field={@zen_template_form[:order]} label="Order" type="number" />
              <.input field={@zen_template_form[:enabled]} label="Enabled" type="checkbox" />
              <.input field={@zen_template_form[:stream_name]} type="hidden" />
              <.input field={@zen_template_form[:agent_id]} type="hidden" />
              <.button variant="primary" phx-disable-with="Saving...">
                {if @editing_zen_template_id, do: "Save preset", else: "Create preset"}
              </.button>
            </.form>
          </div>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="text-xs uppercase tracking-wide text-base-content/60">
                  <th>Preset</th>
                  <th>Subject</th>
                  <th>Rule type</th>
                  <th>Status</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for template <- @zen_templates do %>
                  <tr>
                    <td class="font-mono text-xs">{template.name}</td>
                    <td class="text-xs">{template.subject}</td>
                    <td class="text-xs">{to_string(template.template)}</td>
                    <td>
                      <.ui_badge variant={if template.enabled, do: "success", else: "ghost"} size="xs">
                        {if template.enabled, do: "Enabled", else: "Disabled"}
                      </.ui_badge>
                    </td>
                    <td class="text-right">
                      <div class="flex justify-end gap-2">
                        <.ui_button
                          size="xs"
                          variant="ghost"
                          phx-click="edit_zen_template"
                          phx-value-id={template.id}
                        >
                          Edit
                        </.ui_button>
                        <.ui_button
                          size="xs"
                          variant="ghost"
                          phx-click="delete_zen_template"
                          phx-value-id={template.id}
                        >
                          Delete
                        </.ui_button>
                      </div>
                    </td>
                  </tr>
                <% end %>
                <tr :if={@zen_templates == []}>
                  <td colspan="5" class="text-center text-base-content/60 py-6">
                    No log presets configured.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_zen_presets">close</button>
      </form>
    </dialog>
    """
  end

  defp promotion_presets_modal(assigns) do
    ~H"""
    <dialog id="promotion_presets_modal" class="modal modal-open">
      <div class="modal-box max-w-4xl">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h3 class="text-lg font-semibold text-base-content">Event Presets</h3>
            <p class="text-sm text-base-content/60">
              Save reusable presets for promoting logs into events.
            </p>
          </div>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close_promotion_presets">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div class="mt-6 grid grid-cols-1 lg:grid-cols-[minmax(0,360px)_1fr] gap-6">
          <div class="rounded-xl border border-base-200 bg-base-100 p-4">
            <div class="flex items-center justify-between">
              <div class="text-sm font-semibold">
                {if @editing_promotion_template_id, do: "Edit preset", else: "Create preset"}
              </div>
              <.ui_button
                :if={@editing_promotion_template_id}
                variant="ghost"
                size="xs"
                phx-click="cancel_promotion_template_edit"
              >
                Cancel
              </.ui_button>
            </div>

            <.form
              for={@promotion_template_form}
              id="promotion_template_form"
              class="mt-4 space-y-3"
              phx-change="validate_promotion_template"
              phx-submit="save_promotion_template"
            >
              <.input field={@promotion_template_form[:name]} label="Preset name" />
              <.input field={@promotion_template_form[:description]} label="Description" />
              <.input field={@promotion_template_form[:priority]} label="Priority" type="number" />
              <.input field={@promotion_template_form[:enabled]} label="Enabled" type="checkbox" />

              <div class="space-y-2">
                <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Match criteria
                </div>
                <.input
                  id="promotion_template_match_always"
                  name="promotion_template[match][always]"
                  label="Match all logs"
                  type="checkbox"
                  value={map_form_value(@promotion_template_form, :match, :always, false)}
                />
                <.input
                  id="promotion_template_match_subject_prefix"
                  name="promotion_template[match][subject_prefix]"
                  label="Subject prefix"
                  value={map_form_value(@promotion_template_form, :match, :subject_prefix)}
                />
                <.input
                  id="promotion_template_match_service_name"
                  name="promotion_template[match][service_name]"
                  label="Service name"
                  value={map_form_value(@promotion_template_form, :match, :service_name)}
                />
                <.input
                  id="promotion_template_match_severity_number_min"
                  name="promotion_template[match][severity_number_min]"
                  label="Min severity"
                  type="number"
                  value={map_form_value(@promotion_template_form, :match, :severity_number_min)}
                />
                <.input
                  id="promotion_template_match_severity_number_max"
                  name="promotion_template[match][severity_number_max]"
                  label="Max severity"
                  type="number"
                  value={map_form_value(@promotion_template_form, :match, :severity_number_max)}
                />
                <.input
                  id="promotion_template_match_severity_text"
                  name="promotion_template[match][severity_text]"
                  label="Severity text"
                  value={map_form_value(@promotion_template_form, :match, :severity_text)}
                />
                <.input
                  id="promotion_template_match_body_contains"
                  name="promotion_template[match][body_contains]"
                  label="Message contains"
                  value={map_form_value(@promotion_template_form, :match, :body_contains)}
                />
              </div>

              <div class="space-y-2">
                <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Event overrides
                </div>
                <.input
                  id="promotion_template_event_message"
                  name="promotion_template[event][message]"
                  label="Event message override"
                  value={map_form_value(@promotion_template_form, :event, :message)}
                />
              </div>

              <.button variant="primary" phx-disable-with="Saving...">
                {if @editing_promotion_template_id, do: "Save preset", else: "Create preset"}
              </.button>
            </.form>
          </div>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="text-xs uppercase tracking-wide text-base-content/60">
                  <th>Preset</th>
                  <th>Subject</th>
                  <th>Priority</th>
                  <th>Status</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for template <- @promotion_templates do %>
                  <tr>
                    <td class="font-mono text-xs">{template.name}</td>
                    <td class="text-xs">
                      {Map.get(template.match || %{}, "subject_prefix") || "Any"}
                    </td>
                    <td class="text-xs">{template.priority}</td>
                    <td>
                      <.ui_badge variant={if template.enabled, do: "success", else: "ghost"} size="xs">
                        {if template.enabled, do: "Enabled", else: "Disabled"}
                      </.ui_badge>
                    </td>
                    <td class="text-right">
                      <div class="flex justify-end gap-2">
                        <.ui_button
                          size="xs"
                          variant="ghost"
                          phx-click="edit_promotion_template"
                          phx-value-id={template.id}
                        >
                          Edit
                        </.ui_button>
                        <.ui_button
                          size="xs"
                          variant="ghost"
                          phx-click="delete_promotion_template"
                          phx-value-id={template.id}
                        >
                          Delete
                        </.ui_button>
                      </div>
                    </td>
                  </tr>
                <% end %>
                <tr :if={@promotion_templates == []}>
                  <td colspan="5" class="text-center text-base-content/60 py-6">
                    No event presets configured.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_promotion_presets">close</button>
      </form>
    </dialog>
    """
  end

  defp stateful_presets_modal(assigns) do
    ~H"""
    <dialog id="stateful_presets_modal" class="modal modal-open">
      <div class="modal-box max-w-4xl">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h3 class="text-lg font-semibold text-base-content">Alert Presets</h3>
            <p class="text-sm text-base-content/60">
              Save reusable presets for alert thresholds and cooldowns.
            </p>
          </div>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close_stateful_presets">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div class="mt-6 grid grid-cols-1 lg:grid-cols-[minmax(0,360px)_1fr] gap-6">
          <div class="rounded-xl border border-base-200 bg-base-100 p-4">
            <div class="flex items-center justify-between">
              <div class="text-sm font-semibold">
                {if @editing_stateful_template_id, do: "Edit preset", else: "Create preset"}
              </div>
              <.ui_button
                :if={@editing_stateful_template_id}
                variant="ghost"
                size="xs"
                phx-click="cancel_stateful_template_edit"
              >
                Cancel
              </.ui_button>
            </div>

            <.form
              for={@stateful_template_form}
              id="stateful_template_form"
              class="mt-4 space-y-3"
              phx-change="validate_stateful_template"
              phx-submit="save_stateful_template"
            >
              <.input field={@stateful_template_form[:name]} label="Preset name" />
              <.input field={@stateful_template_form[:description]} label="Description" />
              <.input field={@stateful_template_form[:enabled]} label="Enabled" type="checkbox" />
              <.input field={@stateful_template_form[:priority]} label="Priority" type="number" />
              <.input
                field={@stateful_template_form[:signal]}
                label="Signal"
                type="select"
                options={[{"Log", :log}, {"Event", :event}]}
              />
              <div class="grid grid-cols-2 gap-3">
                <.input
                  field={@stateful_template_form[:threshold]}
                  label="Threshold"
                  type="number"
                />
                <.input
                  field={@stateful_template_form[:window_seconds]}
                  label="Window (sec)"
                  type="number"
                />
                <.input
                  field={@stateful_template_form[:bucket_seconds]}
                  label="Bucket (sec)"
                  type="number"
                />
                <.input
                  field={@stateful_template_form[:cooldown_seconds]}
                  label="Cooldown (sec)"
                  type="number"
                />
                <.input
                  field={@stateful_template_form[:renotify_seconds]}
                  label="Renotify (sec)"
                  type="number"
                />
              </div>

              <div class="space-y-2">
                <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Match criteria
                </div>
                <.input
                  id="stateful_template_match_always"
                  name="stateful_template[match][always]"
                  label="Match all logs/events"
                  type="checkbox"
                  value={map_form_value(@stateful_template_form, :match, :always, false)}
                />
                <.input
                  id="stateful_template_match_subject_prefix"
                  name="stateful_template[match][subject_prefix]"
                  label="Subject prefix"
                  value={map_form_value(@stateful_template_form, :match, :subject_prefix)}
                />
                <.input
                  id="stateful_template_match_service_name"
                  name="stateful_template[match][service_name]"
                  label="Service name"
                  value={map_form_value(@stateful_template_form, :match, :service_name)}
                />
                <.input
                  id="stateful_template_match_severity_number_min"
                  name="stateful_template[match][severity_number_min]"
                  label="Min severity"
                  type="number"
                  value={map_form_value(@stateful_template_form, :match, :severity_number_min)}
                />
                <.input
                  id="stateful_template_match_severity_number_max"
                  name="stateful_template[match][severity_number_max]"
                  label="Max severity"
                  type="number"
                  value={map_form_value(@stateful_template_form, :match, :severity_number_max)}
                />
                <.input
                  id="stateful_template_match_severity_text"
                  name="stateful_template[match][severity_text]"
                  label="Severity text"
                  value={map_form_value(@stateful_template_form, :match, :severity_text)}
                />
                <.input
                  id="stateful_template_match_body_contains"
                  name="stateful_template[match][body_contains]"
                  label="Message contains"
                  value={map_form_value(@stateful_template_form, :match, :body_contains)}
                />
              </div>

              <.button variant="primary" phx-disable-with="Saving...">
                {if @editing_stateful_template_id, do: "Save preset", else: "Create preset"}
              </.button>
            </.form>
          </div>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="text-xs uppercase tracking-wide text-base-content/60">
                  <th>Preset</th>
                  <th>Signal</th>
                  <th>Threshold</th>
                  <th>Status</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for template <- @stateful_templates do %>
                  <tr>
                    <td class="font-mono text-xs">{template.name}</td>
                    <td class="text-xs">{to_string(template.signal)}</td>
                    <td class="text-xs">
                      {template.threshold} / {template.window_seconds}s
                    </td>
                    <td>
                      <.ui_badge variant={if template.enabled, do: "success", else: "ghost"} size="xs">
                        {if template.enabled, do: "Enabled", else: "Disabled"}
                      </.ui_badge>
                    </td>
                    <td class="text-right">
                      <div class="flex justify-end gap-2">
                        <.ui_button
                          size="xs"
                          variant="ghost"
                          phx-click="edit_stateful_template"
                          phx-value-id={template.id}
                        >
                          Edit
                        </.ui_button>
                        <.ui_button
                          size="xs"
                          variant="ghost"
                          phx-click="delete_stateful_template"
                          phx-value-id={template.id}
                        >
                          Delete
                        </.ui_button>
                      </div>
                    </td>
                  </tr>
                <% end %>
                <tr :if={@stateful_templates == []}>
                  <td colspan="5" class="text-center text-base-content/60 py-6">
                    No alert presets configured.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_stateful_presets">close</button>
      </form>
    </dialog>
    """
  end

  defp build_zen_form(scope, rule \\ nil) do
    if rule do
      AshPhoenix.Form.for_update(rule, :update,
        domain: ServiceRadar.Observability,
        scope: scope,
        as: "zen_rule",
        transform_params: &normalize_zen_params/3
      )
    else
      AshPhoenix.Form.for_create(ZenRule, :create,
        domain: ServiceRadar.Observability,
        scope: scope,
        as: "zen_rule",
        transform_params: &normalize_zen_params/3
      )
    end
  end

  defp build_promotion_form(scope, rule \\ nil) do
    opts = [
      domain: ServiceRadar.Observability,
      scope: scope,
      as: "promotion_rule",
      transform_params: &normalize_rule_params/3
    ]

    if rule do
      AshPhoenix.Form.for_update(rule, :update, opts)
    else
      AshPhoenix.Form.for_create(LogPromotionRule, :create, opts)
    end
  end

  defp build_stateful_form(scope, rule \\ nil) do
    opts = [
      domain: ServiceRadar.Observability,
      scope: scope,
      as: "stateful_rule",
      transform_params: &normalize_rule_params/3
    ]

    if rule do
      AshPhoenix.Form.for_update(rule, :update, opts)
    else
      AshPhoenix.Form.for_create(StatefulAlertRule, :create, opts)
    end
  end

  defp build_zen_template_form(scope, template \\ nil) do
    opts = [
      domain: ServiceRadar.Observability,
      scope: scope,
      as: "zen_template",
      transform_params: &normalize_zen_params/3
    ]

    if template do
      AshPhoenix.Form.for_update(template, :update, opts)
    else
      AshPhoenix.Form.for_create(ZenRuleTemplate, :create, opts)
    end
  end

  defp build_promotion_template_form(scope, template \\ nil) do
    opts = [
      domain: ServiceRadar.Observability,
      scope: scope,
      as: "promotion_template",
      transform_params: &normalize_rule_params/3
    ]

    if template do
      AshPhoenix.Form.for_update(template, :update, opts)
    else
      AshPhoenix.Form.for_create(LogPromotionRuleTemplate, :create, opts)
    end
  end

  defp build_stateful_template_form(scope, template \\ nil) do
    opts = [
      domain: ServiceRadar.Observability,
      scope: scope,
      as: "stateful_template",
      transform_params: &normalize_rule_params/3
    ]

    if template do
      AshPhoenix.Form.for_update(template, :update, opts)
    else
      AshPhoenix.Form.for_create(StatefulAlertRuleTemplate, :create, opts)
    end
  end

  defp normalize_zen_params(_form, params, _action) do
    params
    |> normalize_integer("order")
  end

  defp normalize_rule_params(_form, params, _action) do
    params
    |> normalize_integer("priority")
    |> normalize_integer("threshold")
    |> normalize_integer("window_seconds")
    |> normalize_integer("bucket_seconds")
    |> normalize_integer("cooldown_seconds")
    |> normalize_integer("renotify_seconds")
    |> normalize_match()
  end

  defp normalize_match(params) do
    match =
      params
      |> Map.get("match", %{})
      |> normalize_integer_in_map("severity_number_min")
      |> normalize_integer_in_map("severity_number_max")
      |> normalize_blank_in_map("subject_prefix")
      |> normalize_blank_in_map("service_name")
      |> normalize_blank_in_map("severity_text")
      |> normalize_blank_in_map("body_contains")
      |> normalize_boolean_in_map("always")

    event =
      params
      |> Map.get("event", %{})
      |> normalize_blank_in_map("message")

    params
    |> Map.put("match", match)
    |> Map.put("event", event)
  end

  defp map_form_value(form, map_key, key, default \\ nil) do
    params = form.params || %{}
    param_value = get_in(params, [Atom.to_string(map_key), Atom.to_string(key)])

    if param_value != nil do
      param_value
    else
      map_data_value(form, map_key, key, default)
    end
  end

  defp map_data_value(form, map_key, key, default) do
    map_value =
      case form.data do
        %{^map_key => value} when is_map(value) -> value
        _ -> %{}
      end

    Map.get(map_value, key) || Map.get(map_value, Atom.to_string(key)) || default
  end

  defp normalize_integer(params, key) do
    case Map.get(params, key) do
      "" ->
        Map.delete(params, key)

      nil ->
        params

      value when is_integer(value) ->
        params

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _} -> Map.put(params, key, int)
          :error -> params
        end

      _ ->
        params
    end
  end

  defp normalize_integer_in_map(map, key) do
    case Map.get(map, key) do
      "" ->
        Map.delete(map, key)

      nil ->
        map

      value when is_integer(value) ->
        map

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _} -> Map.put(map, key, int)
          :error -> map
        end

      _ ->
        map
    end
  end

  defp normalize_blank_in_map(map, key) do
    case Map.get(map, key) do
      "" -> Map.delete(map, key)
      nil -> map
      _ -> map
    end
  end

  defp normalize_boolean_in_map(map, key) do
    case Map.get(map, key) do
      "true" -> Map.put(map, key, true)
      "false" -> Map.put(map, key, false)
      value when is_boolean(value) -> map
      _ -> map
    end
  end

  defp list_zen_rules(scope) do
    ZenRule
    |> Ash.Query.for_read(:read, %{})
    |> Ash.read(scope: scope)
    |> unwrap_page()
  end

  defp list_promotion_rules(scope) do
    LogPromotionRule
    |> Ash.Query.for_read(:read, %{})
    |> Ash.read(scope: scope)
    |> unwrap_page()
  end

  defp list_stateful_rules(scope) do
    StatefulAlertRule
    |> Ash.Query.for_read(:read, %{})
    |> Ash.read(scope: scope)
    |> unwrap_page()
  end

  defp list_zen_templates(scope) do
    ZenRuleTemplate
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.sort(:name)
    |> Ash.read(scope: scope)
    |> unwrap_page()
  end

  defp list_promotion_templates(scope) do
    LogPromotionRuleTemplate
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.sort(:name)
    |> Ash.read(scope: scope)
    |> unwrap_page()
  end

  defp list_stateful_templates(scope) do
    StatefulAlertRuleTemplate
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.sort(:name)
    |> Ash.read(scope: scope)
    |> unwrap_page()
  end

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_page({:ok, %Ash.Page.Offset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []

  defp reset_zen_form(socket, scope) do
    ash_form = build_zen_form(scope)

    socket
    |> assign(:editing_zen_id, nil)
    |> assign(:selected_zen_template_id, nil)
    |> assign(:zen_ash_form, ash_form)
    |> assign(:zen_form, to_form(ash_form))
  end

  defp reset_promotion_form(socket, scope) do
    ash_form = build_promotion_form(scope)

    socket
    |> assign(:editing_promotion_id, nil)
    |> assign(:selected_promotion_template_id, nil)
    |> assign(:promotion_ash_form, ash_form)
    |> assign(:promotion_form, to_form(ash_form))
  end

  defp reset_stateful_form(socket, scope) do
    ash_form = build_stateful_form(scope)

    socket
    |> assign(:editing_stateful_id, nil)
    |> assign(:selected_stateful_template_id, nil)
    |> assign(:stateful_ash_form, ash_form)
    |> assign(:stateful_form, to_form(ash_form))
  end

  defp reset_zen_template_form(socket, scope) do
    ash_form = build_zen_template_form(scope)

    socket
    |> assign(:editing_zen_template_id, nil)
    |> assign(:zen_template_ash_form, ash_form)
    |> assign(:zen_template_form, to_form(ash_form))
  end

  defp reset_promotion_template_form(socket, scope) do
    ash_form = build_promotion_template_form(scope)

    socket
    |> assign(:editing_promotion_template_id, nil)
    |> assign(:promotion_template_ash_form, ash_form)
    |> assign(:promotion_template_form, to_form(ash_form))
  end

  defp reset_stateful_template_form(socket, scope) do
    ash_form = build_stateful_template_form(scope)

    socket
    |> assign(:editing_stateful_template_id, nil)
    |> assign(:stateful_template_ash_form, ash_form)
    |> assign(:stateful_template_form, to_form(ash_form))
  end

  defp zen_template_params(template) do
    %{
      "name" => template.name,
      "description" => template.description,
      "subject" => template.subject,
      "template" => template.template && to_string(template.template),
      "order" => template.order,
      "stream_name" => template.stream_name,
      "enabled" => template.enabled,
      "agent_id" => template.agent_id
    }
    |> drop_nil_params()
  end

  defp promotion_template_params(template) do
    %{
      "name" => template.name,
      "description" => template.description,
      "priority" => template.priority,
      "enabled" => template.enabled,
      "match" => template.match || %{},
      "event" => template.event || %{}
    }
    |> drop_nil_params()
  end

  defp stateful_template_params(template) do
    %{
      "name" => template.name,
      "description" => template.description,
      "enabled" => template.enabled,
      "priority" => template.priority,
      "signal" => template.signal && to_string(template.signal),
      "threshold" => template.threshold,
      "window_seconds" => template.window_seconds,
      "bucket_seconds" => template.bucket_seconds,
      "cooldown_seconds" => template.cooldown_seconds,
      "renotify_seconds" => template.renotify_seconds,
      "match" => template.match || %{},
      "event" => template.event || %{},
      "alert" => template.alert || %{}
    }
    |> drop_nil_params()
  end

  defp drop_nil_params(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
