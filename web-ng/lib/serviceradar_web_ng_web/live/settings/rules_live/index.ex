defmodule ServiceRadarWebNGWeb.Settings.RulesLive.Index do
  @moduledoc """
  LiveView for managing log normalization, event promotion, and alert rules.

  Zen rules are synced to NATS KV and picked up by serviceradar-zen.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Observability.{
    EventRule,
    StatefulAlertRule,
    ZenRule
  }

  alias ServiceRadarWebNGWeb.Components.PromotionRuleBuilder
  alias ServiceRadarWebNG.RBAC

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "observability.rules.update") or RBAC.can?(scope, "observability.rules.create") do
      socket =
        socket
        |> assign(:page_title, "Events")
        |> assign(:active_tab, "logs")
        |> assign(:zen_rules, list_zen_rules(scope))
        |> assign(:event_rules, list_event_rules(scope))
        |> assign(:stateful_rules, list_stateful_rules(scope))
        |> assign(:show_rule_builder, false)
        |> assign(:editing_rule, nil)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to Events rules")
       |> push_navigate(to: ~p"/settings/profile")}
    end
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
          Ash.Changeset.for_update(rule, :update, %{enabled: !rule.enabled}, scope: scope)

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

    case Enum.find(socket.assigns.event_rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        case Ash.destroy(rule, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> assign(:event_rules, list_event_rules(scope))
             |> put_flash(:info, "Rule deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete rule")}
        end
    end
  end

  def handle_event("toggle_promotion", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    id = to_string(id)

    case Enum.find(socket.assigns.event_rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        changeset =
          Ash.Changeset.for_update(rule, :update, %{enabled: !rule.enabled}, scope: scope)

        case Ash.update(changeset) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:event_rules, list_event_rules(scope))
             |> put_flash(:info, "Rule #{if rule.enabled, do: "disabled", else: "enabled"}")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle rule")}
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

  def handle_event("new_promotion_rule", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_rule_builder, true)
     |> assign(:editing_rule, nil)}
  end

  def handle_event("edit_promotion_rule", %{"id" => id}, socket) do
    id = to_string(id)

    case Enum.find(socket.assigns.event_rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Rule not found")}

      rule ->
        {:noreply,
         socket
         |> assign(:show_rule_builder, true)
         |> assign(:editing_rule, rule)}
    end
  end

  @impl true
  def handle_info({:rule_builder_closed}, socket) do
    {:noreply,
     socket
     |> assign(:show_rule_builder, false)
     |> assign(:editing_rule, nil)}
  end

  def handle_info({:rule_created, rule}, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:show_rule_builder, false)
     |> assign(:editing_rule, nil)
     |> assign(:event_rules, list_event_rules(scope))
     |> put_flash(:info, "Rule \"#{rule.name}\" created successfully")}
  end

  def handle_info({:rule_updated, rule}, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:show_rule_builder, false)
     |> assign(:editing_rule, nil)
     |> assign(:event_rules, list_event_rules(scope))
     |> put_flash(:info, "Rule \"#{rule.name}\" updated successfully")}
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
        <.settings_nav current_path="/settings/rules" current_scope={@current_scope} />

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
                <div class="text-xs text-base-content/60">
                  Create events from logs or metric thresholds.
                </div>
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
                <div class="text-sm font-semibold">Event Rules</div>
                <p class="text-xs text-base-content/60">
                  Create events from logs or metrics for downstream alerting.
                </p>
              </div>
              <button type="button" class="btn btn-primary btn-sm" phx-click="new_promotion_rule">
                <.icon name="hero-plus" class="w-4 h-4" /> New Log Rule
              </button>
            </:header>

            <div class="overflow-x-auto">
              <table class="table">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Rule</th>
                    <th>Source</th>
                    <th>Match Conditions</th>
                    <th>Priority</th>
                    <th>Status</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for rule <- @event_rules do %>
                    <% source_type = normalize_source_type(rule.source_type) %>
                    <% editable? = source_type == "log" %>
                    <tr class="hover">
                      <td class="font-mono text-sm">{rule.name}</td>
                      <td class="text-sm max-w-xs">
                        <.event_rule_source rule={rule} />
                      </td>
                      <td class="text-sm max-w-xs">
                        <%= if source_type == "log" do %>
                          <.match_conditions_summary match={rule.match} />
                        <% else %>
                          <.metric_rule_summary source={rule.source} />
                        <% end %>
                      </td>
                      <td class="text-sm">{rule.priority}</td>
                      <td>
                        <%= if editable? do %>
                          <label class="swap">
                            <input
                              type="checkbox"
                              checked={rule.enabled}
                              phx-click="toggle_promotion"
                              phx-value-id={rule.id}
                            />
                            <span class="swap-on badge badge-success badge-sm">Enabled</span>
                            <span class="swap-off badge badge-ghost badge-sm">Disabled</span>
                          </label>
                        <% else %>
                          <.ui_badge variant={if rule.enabled, do: "success", else: "ghost"} size="xs">
                            {if rule.enabled, do: "Enabled", else: "Disabled"}
                          </.ui_badge>
                        <% end %>
                      </td>
                      <td class="text-right">
                        <div class="flex justify-end gap-1">
                          <%= if editable? do %>
                            <button
                              type="button"
                              class="btn btn-ghost btn-xs"
                              phx-click="edit_promotion_rule"
                              phx-value-id={rule.id}
                            >
                              <.icon name="hero-pencil-square" class="w-4 h-4" />
                            </button>
                            <button
                              type="button"
                              class="btn btn-ghost btn-xs text-error"
                              phx-click="delete_promotion"
                              phx-value-id={rule.id}
                              data-confirm="Are you sure you want to delete this rule?"
                            >
                              <.icon name="hero-trash" class="w-4 h-4" />
                            </button>
                          <% else %>
                            <.link
                              :if={metric_rule_path(rule)}
                              navigate={metric_rule_path(rule)}
                              class="btn btn-ghost btn-xs"
                            >
                              <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
                            </.link>
                          <% end %>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                  <tr :if={@event_rules == []}>
                    <td colspan="6" class="text-center text-base-content/60 py-8">
                      <div class="flex flex-col items-center gap-2">
                        <.icon name="hero-inbox" class="w-8 h-8 opacity-40" />
                        <p>No event rules configured.</p>
                        <button
                          type="button"
                          class="btn btn-primary btn-sm"
                          phx-click="new_promotion_rule"
                        >
                          Create your first log rule
                        </button>
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
      
    <!-- Rule Builder Modal -->
      <.live_component
        :if={@show_rule_builder}
        module={PromotionRuleBuilder}
        id="rule-builder"
        rule={@editing_rule}
        current_scope={@current_scope}
      />
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

  defp list_event_rules(scope) do
    EventRule
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.sort([:source_type, :priority, :name])
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

  # Component to display match conditions summary
  attr :match, :map, default: nil
  attr :rule, :map, required: true

  defp event_rule_source(assigns) do
    %{rule: rule} = assigns
    label = if normalize_source_type(rule.source_type) == "metric", do: "Metric", else: "Log"
    details = event_rule_source_details(rule)
    assigns = assign(assigns, %{label: label, details: details})

    ~H"""
    <div class="flex flex-col gap-1">
      <span class={["badge badge-xs", (@label == "Metric" && "badge-info") || "badge-ghost"]}>
        {@label}
      </span>
      <span class="text-xs text-base-content/60">{@details}</span>
    </div>
    """
  end

  attr :source, :map, default: %{}

  defp metric_rule_summary(assigns) do
    metric = source_value(assigns.source, "metric") || "metric"
    assigns = assign(assigns, :metric, metric)

    ~H"""
    <span class="badge badge-ghost badge-xs">threshold: {@metric}</span>
    """
  end

  defp match_conditions_summary(assigns) do
    conditions = build_conditions_list(assigns.match)
    assigns = assign(assigns, :conditions, conditions)

    ~H"""
    <div class="flex flex-wrap gap-1">
      <%= if @conditions == [] do %>
        <span class="text-base-content/50">No conditions</span>
      <% else %>
        <%= for {icon, label} <- @conditions do %>
          <span class="badge badge-ghost badge-xs gap-1">
            <.icon name={icon} class="w-3 h-3" />
            {label}
          </span>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp build_conditions_list(nil), do: []
  defp build_conditions_list(match) when map_size(match) == 0, do: []

  defp build_conditions_list(match) when is_map(match) do
    conditions = []

    conditions =
      if match["body_contains"] do
        [
          {"hero-chat-bubble-bottom-center", "body: #{truncate(match["body_contains"], 15)}"}
          | conditions
        ]
      else
        conditions
      end

    conditions =
      if match["severity_text"] do
        [{"hero-exclamation-triangle", "severity: #{match["severity_text"]}"} | conditions]
      else
        conditions
      end

    conditions =
      if match["service_name"] do
        [{"hero-server", "service: #{truncate(match["service_name"], 15)}"} | conditions]
      else
        conditions
      end

    conditions =
      if match["subject_prefix"] do
        [{"hero-envelope", "subject: #{truncate(match["subject_prefix"], 15)}"} | conditions]
      else
        conditions
      end

    conditions =
      if is_map(match["attribute_equals"]) and map_size(match["attribute_equals"]) > 0 do
        count = map_size(match["attribute_equals"])
        [{"hero-tag", "#{count} attr#{if count > 1, do: "s", else: ""}"} | conditions]
      else
        conditions
      end

    Enum.reverse(conditions)
  end

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max do
    String.slice(str, 0, max) <> "..."
  end

  defp truncate(str, _max), do: str

  defp event_rule_source_details(rule) do
    source = rule.source || %{}

    case normalize_source_type(rule.source_type) do
      "metric" ->
        device_id = source_value(source, "device_id") || "unknown device"
        interface_uid = source_value(source, "interface_uid") || "unknown interface"
        metric = source_value(source, "metric")

        details =
          [device_id, interface_uid, metric]
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join(" • ", &to_string/1)

        if details == "", do: "metric rule", else: details

      _ ->
        "log pattern"
    end
  end

  defp normalize_source_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_source_type(type) when is_binary(type), do: type
  defp normalize_source_type(_), do: "log"

  defp metric_rule_path(rule) do
    source = rule.source || %{}
    device_id = source_value(source, "device_id")
    interface_uid = source_value(source, "interface_uid")

    if device_id && interface_uid do
      ~p"/devices/#{device_id}/interfaces/#{interface_uid}"
    else
      nil
    end
  end

  defp source_value(source, "device_id") when is_map(source) do
    Map.get(source, "device_id") || Map.get(source, :device_id)
  end

  defp source_value(source, "interface_uid") when is_map(source) do
    Map.get(source, "interface_uid") || Map.get(source, :interface_uid)
  end

  defp source_value(source, "metric") when is_map(source) do
    Map.get(source, "metric") || Map.get(source, :metric)
  end

  defp source_value(source, key) when is_map(source), do: Map.get(source, key)
end
