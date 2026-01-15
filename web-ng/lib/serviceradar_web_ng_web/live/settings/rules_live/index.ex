defmodule ServiceRadarWebNGWeb.Settings.RulesLive.Index do
  @moduledoc """
  LiveView for managing log normalization, event promotion, and alert rules.

  Zen rules are synced to NATS KV and picked up by serviceradar-zen.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Observability.{
    LogPromotionRule,
    StatefulAlertRule,
    ZenRule
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Events")
      |> assign(:active_tab, "logs")
      |> assign(:zen_rules, list_zen_rules(scope))
      |> assign(:promotion_rules, list_promotion_rules(scope))
      |> assign(:stateful_rules, list_stateful_rules(scope))

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

  @impl true
  def handle_event("delete_zen", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    id = to_string(id)

    case Enum.find(socket.assigns.zen_rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        case Ash.destroy(rule, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> assign(:zen_rules, list_zen_rules(scope))
             |> put_flash(:info, "Rule deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete rule")}
        end
    end
  end

  def handle_event("toggle_zen", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    id = to_string(id)

    case Enum.find(socket.assigns.zen_rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        changeset =
          Ash.Changeset.for_update(rule, :update, %{enabled: !rule.enabled},
            tenant: scope.tenant_schema,
            actor: %{tenant_id: scope.tenant_id, role: :admin}
          )

        case Ash.update(changeset) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:zen_rules, list_zen_rules(scope))
             |> put_flash(:info, "Rule #{if rule.enabled, do: "disabled", else: "enabled"}")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle rule")}
        end
    end
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
            {:noreply,
             socket
             |> assign(:promotion_rules, list_promotion_rules(scope))
             |> put_flash(:info, "Rule deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete rule")}
        end
    end
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
            {:noreply,
             socket
             |> assign(:stateful_rules, list_stateful_rules(scope))
             |> put_flash(:info, "Rule deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete rule")}
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
                <div class="text-sm font-semibold">Log Normalization Rules</div>
                <p class="text-xs text-base-content/60">
                  Rules processed by the Zen engine to normalize and enrich logs.
                </p>
              </div>
              <.link navigate={~p"/settings/rules/zen/new"} class="btn btn-primary btn-sm">
                <.icon name="hero-plus" class="w-4 h-4" /> New Rule
              </.link>
            </:header>

            <div class="overflow-x-auto">
              <table class="table">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Rule</th>
                    <th>Subject</th>
                    <th>Description</th>
                    <th>Order</th>
                    <th>Status</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for rule <- @zen_rules do %>
                    <tr class="hover">
                      <td>
                        <.link
                          navigate={~p"/settings/rules/zen/#{rule.id}"}
                          class="font-mono text-sm link link-primary"
                        >
                          {rule.name}
                        </.link>
                      </td>
                      <td>
                        <span class="badge badge-ghost badge-sm font-mono">{rule.subject}</span>
                      </td>
                      <td class="text-sm text-base-content/70 max-w-xs truncate">
                        {rule.description}
                      </td>
                      <td class="text-sm">{rule.order}</td>
                      <td>
                        <label class="swap">
                          <input
                            type="checkbox"
                            checked={rule.enabled}
                            phx-click="toggle_zen"
                            phx-value-id={rule.id}
                          />
                          <span class="swap-on badge badge-success badge-sm">Enabled</span>
                          <span class="swap-off badge badge-ghost badge-sm">Disabled</span>
                        </label>
                      </td>
                      <td class="text-right">
                        <div class="flex justify-end gap-1">
                          <.link
                            navigate={~p"/settings/rules/zen/#{rule.id}"}
                            class="btn btn-ghost btn-xs"
                          >
                            <.icon name="hero-pencil-square" class="w-4 h-4" />
                          </.link>
                          <.link
                            navigate={~p"/settings/rules/zen/clone/#{rule.id}"}
                            class="btn btn-ghost btn-xs"
                          >
                            <.icon name="hero-document-duplicate" class="w-4 h-4" />
                          </.link>
                          <button
                            type="button"
                            class="btn btn-ghost btn-xs text-error"
                            phx-click="delete_zen"
                            phx-value-id={rule.id}
                            data-confirm="Are you sure you want to delete this rule?"
                          >
                            <.icon name="hero-trash" class="w-4 h-4" />
                          </button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                  <tr :if={@zen_rules == []}>
                    <td colspan="6" class="text-center text-base-content/60 py-8">
                      <div class="flex flex-col items-center gap-2">
                        <.icon name="hero-inbox" class="w-8 h-8 opacity-40" />
                        <p>No rules configured yet.</p>
                        <.link navigate={~p"/settings/rules/zen/new"} class="btn btn-primary btn-sm">
                          Create your first rule
                        </.link>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.ui_panel>
        </div>

        <div :if={@active_tab == "events"} class="space-y-6">
          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">Event Promotion Rules</div>
                <p class="text-xs text-base-content/60">
                  Promote log patterns into events for downstream alerting.
                </p>
              </div>
              <button type="button" class="btn btn-primary btn-sm" disabled>
                <.icon name="hero-plus" class="w-4 h-4" /> New Rule
              </button>
            </:header>

            <div class="overflow-x-auto">
              <table class="table">
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
                    <tr class="hover">
                      <td class="font-mono text-sm">{rule.name}</td>
                      <td class="text-sm">
                        {Map.get(rule.match || %{}, "subject_prefix") || "Any"}
                      </td>
                      <td class="text-sm">{rule.priority}</td>
                      <td>
                        <.ui_badge variant={if rule.enabled, do: "success", else: "ghost"} size="xs">
                          {if rule.enabled, do: "Enabled", else: "Disabled"}
                        </.ui_badge>
                      </td>
                      <td class="text-right">
                        <button
                          type="button"
                          class="btn btn-ghost btn-xs text-error"
                          phx-click="delete_promotion"
                          phx-value-id={rule.id}
                          data-confirm="Are you sure?"
                        >
                          <.icon name="hero-trash" class="w-4 h-4" />
                        </button>
                      </td>
                    </tr>
                  <% end %>
                  <tr :if={@promotion_rules == []}>
                    <td colspan="5" class="text-center text-base-content/60 py-8">
                      <div class="flex flex-col items-center gap-2">
                        <.icon name="hero-inbox" class="w-8 h-8 opacity-40" />
                        <p>No event promotion rules configured.</p>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
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
              <button type="button" class="btn btn-primary btn-sm" disabled>
                <.icon name="hero-plus" class="w-4 h-4" /> New Rule
              </button>
            </:header>

            <div class="overflow-x-auto">
              <table class="table">
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
                    <tr class="hover">
                      <td class="font-mono text-sm">{rule.name}</td>
                      <td class="text-sm">{to_string(rule.signal)}</td>
                      <td class="text-sm">
                        {rule.threshold} / {rule.window_seconds}s
                      </td>
                      <td>
                        <.ui_badge variant={if rule.enabled, do: "success", else: "ghost"} size="xs">
                          {if rule.enabled, do: "Enabled", else: "Disabled"}
                        </.ui_badge>
                      </td>
                      <td class="text-right">
                        <button
                          type="button"
                          class="btn btn-ghost btn-xs text-error"
                          phx-click="delete_stateful"
                          phx-value-id={rule.id}
                          data-confirm="Are you sure?"
                        >
                          <.icon name="hero-trash" class="w-4 h-4" />
                        </button>
                      </td>
                    </tr>
                  <% end %>
                  <tr :if={@stateful_rules == []}>
                    <td colspan="5" class="text-center text-base-content/60 py-8">
                      <div class="flex flex-col items-center gap-2">
                        <.icon name="hero-inbox" class="w-8 h-8 opacity-40" />
                        <p>No alert rules configured.</p>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.ui_panel>
        </div>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp list_zen_rules(scope) do
    ZenRule
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.sort([:subject, :order, :name])
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

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_page({:ok, %Ash.Page.Offset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []
end
