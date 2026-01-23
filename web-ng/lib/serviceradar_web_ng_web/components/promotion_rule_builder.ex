defmodule ServiceRadarWebNGWeb.Components.PromotionRuleBuilder do
  @moduledoc """
  LiveComponent for building log-based EventRule records from log entry details.

  This is a modal-based form that:
  - Pre-populates match conditions from the current log
  - Allows toggling which conditions to include in the rule
  - Provides rule preview/testing against recent logs
  - Creates EventRule records via Ash
  """

  use ServiceRadarWebNGWeb, :live_component

  alias ServiceRadar.Observability.EventRule

  @severity_options [
    {"Fatal", "fatal"},
    {"Critical", "critical"},
    {"Error", "error"},
    {"Warning", "warn"},
    {"Info", "info"},
    {"Debug", "debug"},
    {"Trace", "trace"}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:form, build_form(%{}))
     |> assign(:preview_state, :idle)
     |> assign(:preview_result, nil)
     |> assign(:preview_error, nil)
     |> assign(:saving, false)
     |> assign(:error, nil)
     |> assign(:editing_rule_id, nil)
     |> assign(:mode, :create)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Initialize form from log data or existing rule
    socket =
      if is_nil(socket.assigns[:initialized]) do
        cond do
          # Editing an existing rule
          Map.has_key?(assigns, :rule) and not is_nil(assigns.rule) ->
            rule = assigns.rule
            initial_values = rule_to_form_values(rule)

            socket
            |> assign(:form, build_form(initial_values))
            |> assign(:editing_rule_id, rule.id)
            |> assign(:mode, :edit)
            |> assign(:initialized, true)

          # Creating from a log entry
          Map.has_key?(assigns, :log) and not is_nil(assigns.log) ->
            log = assigns.log
            parsed_attributes = parse_log_attributes(log)

            initial_values = %{
              "name" => generate_rule_name(log),
              "body_contains" => Map.get(log, "body") || Map.get(log, "message") || "",
              "body_contains_enabled" => true,
              "severity_text" => Map.get(log, "severity_text") || "",
              "severity_enabled" => Map.get(log, "severity_text") != nil,
              "service_name" => Map.get(log, "service_name") || "",
              "service_name_enabled" => Map.get(log, "service_name") != nil,
              "attribute_key" => "",
              "attribute_value" => "",
              "attribute_enabled" => false,
              "auto_alert" => false,
              "parsed_attributes" => parsed_attributes
            }

            socket
            |> assign(:form, build_form(initial_values))
            |> assign(:mode, :create)
            |> assign(:initialized, true)

          # Creating a new rule from scratch
          true ->
            initial_values = %{
              "name" => "new-rule-#{:rand.uniform(999)}",
              "body_contains" => "",
              "body_contains_enabled" => false,
              "severity_text" => "",
              "severity_enabled" => false,
              "service_name" => "",
              "service_name_enabled" => false,
              "attribute_key" => "",
              "attribute_value" => "",
              "attribute_enabled" => false,
              "auto_alert" => false,
              "parsed_attributes" => %{}
            }

            socket
            |> assign(:form, build_form(initial_values))
            |> assign(:mode, :create)
            |> assign(:initialized, true)
        end
      else
        socket
      end

    {:ok, socket}
  end

  defp rule_to_form_values(rule) do
    match = rule.match || %{}
    event = rule.event || %{}

    # Extract first attribute if present
    {attr_key, attr_value} =
      case match["attribute_equals"] do
        %{} = attrs when map_size(attrs) > 0 ->
          [{k, v} | _] = Map.to_list(attrs)
          {k, stringify(v)}

        _ ->
          {"", ""}
      end

    %{
      "name" => rule.name,
      "body_contains" => match["body_contains"] || "",
      "body_contains_enabled" => match["body_contains"] != nil,
      "severity_text" => match["severity_text"] || "",
      "severity_enabled" => match["severity_text"] != nil,
      "service_name" => match["service_name"] || "",
      "service_name_enabled" => match["service_name"] != nil,
      "attribute_key" => attr_key,
      "attribute_value" => attr_value,
      "attribute_enabled" => attr_key != "",
      "auto_alert" => event["alert"] == true,
      "parsed_attributes" => %{}
    }
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :severity_options, @severity_options)

    ~H"""
    <dialog id="rule_builder_modal" class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close"
            phx-target={@myself}
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">
          {if @mode == :edit, do: "Edit Event Rule", else: "Create Event Rule"}
        </h3>
        <p class="py-2 text-sm text-base-content/70">
          Configure match conditions to create events from logs.
          For advanced configuration, visit <.link
            navigate="/settings/rules?tab=events"
            class="link link-primary"
          >Settings → Rules</.link>.
        </p>

        <.form
          for={@form}
          id="rule-builder-form"
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
          phx-debounce="500"
          class="space-y-4 mt-4"
        >
          <!-- Rule Name -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Rule Name</span>
            </label>
            <input
              type="text"
              name="rule[name]"
              value={@form[:name].value}
              class="input input-bordered"
              placeholder="e.g., db-writer-errors"
              required
            />
          </div>

          <div class="divider text-xs text-base-content/50">Match Conditions</div>
          
    <!-- Message Body Contains -->
          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-3">
              <input
                type="checkbox"
                name="rule[body_contains_enabled]"
                value="true"
                checked={@form[:body_contains_enabled].value}
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text font-medium">Message contains</span>
            </label>
            <input
              type="text"
              name="rule[body_contains]"
              value={@form[:body_contains].value}
              class={[
                "input input-bordered input-sm",
                not @form[:body_contains_enabled].value && "opacity-50"
              ]}
              placeholder="e.g., Fetch error"
              disabled={not @form[:body_contains_enabled].value}
            />
            <label class="label">
              <span class="label-text-alt text-base-content/50">
                Case-insensitive substring match
              </span>
            </label>
          </div>
          
    <!-- Severity -->
          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-3">
              <input
                type="checkbox"
                name="rule[severity_enabled]"
                value="true"
                checked={@form[:severity_enabled].value}
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text font-medium">Severity level</span>
            </label>
            <select
              name="rule[severity_text]"
              class={[
                "select select-bordered select-sm",
                not @form[:severity_enabled].value && "opacity-50"
              ]}
              disabled={not @form[:severity_enabled].value}
            >
              <option value="">Any severity</option>
              <%= for {label, value} <- @severity_options do %>
                <option value={value} selected={@form[:severity_text].value == value}>
                  {label}
                </option>
              <% end %>
            </select>
          </div>
          
    <!-- Service Name -->
          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-3">
              <input
                type="checkbox"
                name="rule[service_name_enabled]"
                value="true"
                checked={@form[:service_name_enabled].value}
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text font-medium">Service name</span>
            </label>
            <input
              type="text"
              name="rule[service_name]"
              value={@form[:service_name].value}
              class={[
                "input input-bordered input-sm",
                not @form[:service_name_enabled].value && "opacity-50"
              ]}
              placeholder="e.g., serviceradar-db-event-writer"
              disabled={not @form[:service_name_enabled].value}
            />
          </div>
          
    <!-- Attribute Match -->
          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-3">
              <input
                type="checkbox"
                name="rule[attribute_enabled]"
                value="true"
                checked={@form[:attribute_enabled].value}
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text font-medium">Attribute equals</span>
            </label>
            <div class={[
              "flex gap-2",
              not @form[:attribute_enabled].value && "opacity-50"
            ]}>
              <input
                type="text"
                name="rule[attribute_key]"
                value={@form[:attribute_key].value}
                class="input input-bordered input-sm flex-1"
                placeholder="Key (e.g., error)"
                disabled={not @form[:attribute_enabled].value}
              />
              <input
                type="text"
                name="rule[attribute_value]"
                value={@form[:attribute_value].value}
                class="input input-bordered input-sm flex-1"
                placeholder="Value (e.g., connection failed)"
                disabled={not @form[:attribute_enabled].value}
              />
            </div>
            <!-- Show parsed attributes as suggestions -->
            <div
              :if={@form[:parsed_attributes].value && map_size(@form[:parsed_attributes].value) > 0}
              class="mt-2"
            >
              <span class="text-xs text-base-content/50">Available attributes:</span>
              <div class="flex flex-wrap gap-1 mt-1">
                <%= for {key, value} <- flatten_for_suggestions(@form[:parsed_attributes].value) do %>
                  <button
                    type="button"
                    class="badge badge-ghost badge-sm cursor-pointer hover:badge-primary"
                    phx-click="select_attribute"
                    phx-value-key={key}
                    phx-value-value={value}
                    phx-target={@myself}
                  >
                    {key}={truncate(value, 20)}
                  </button>
                <% end %>
              </div>
            </div>
          </div>

          <div class="divider text-xs text-base-content/50">Event Options</div>
          
    <!-- Auto-create Alert -->
          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-3">
              <input
                type="checkbox"
                name="rule[auto_alert]"
                value="true"
                checked={@form[:auto_alert].value}
                class="checkbox checkbox-sm checkbox-primary"
              />
              <div>
                <span class="label-text font-medium">Auto-create alert for matching events</span>
                <p class="text-xs text-base-content/50">
                  If disabled, alerts are only created for high/critical severity events
                </p>
              </div>
            </label>
          </div>
          
    <!-- Rule Preview Section -->
          <div class="bg-base-200/50 rounded-lg p-4 mt-4">
            <div class="flex items-center justify-between mb-2">
              <span class="text-sm font-medium">Rule Preview</span>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="test_rule"
                phx-target={@myself}
                disabled={@preview_state == :loading}
              >
                <.icon :if={@preview_state != :loading} name="hero-play" class="w-4 h-4" />
                <span :if={@preview_state == :loading} class="loading loading-spinner loading-xs">
                </span>
                Test Rule
              </button>
            </div>

            <div :if={@preview_state == :idle} class="text-sm text-base-content/60">
              Click "Test Rule" to see how many logs from the last hour would match.
            </div>

            <div :if={@preview_state == :loading} class="text-sm text-base-content/60">
              Testing rule against recent logs...
            </div>

            <div :if={@preview_state == :done && @preview_result} class="space-y-2">
              <div class="flex items-center gap-2">
                <.icon name="hero-check-circle" class="w-5 h-5 text-success" />
                <span class="text-sm">
                  <strong>{@preview_result.match_count}</strong> logs from the last hour would match
                </span>
              </div>

              <div :if={@preview_result.sample_logs != []} class="mt-2">
                <span class="text-xs text-base-content/50">Sample matches:</span>
                <div class="mt-1 space-y-1 max-h-32 overflow-y-auto">
                  <%= for log <- @preview_result.sample_logs do %>
                    <div class="text-xs font-mono bg-base-300/50 px-2 py-1 rounded flex gap-2">
                      <span class="text-base-content/50">
                        {format_preview_time(log["timestamp"])}
                      </span>
                      <span class={severity_class(log["severity_text"])}>{log["severity_text"]}</span>
                      <span class="truncate">{truncate(log["body"] || log["message"], 60)}</span>
                    </div>
                  <% end %>
                </div>
              </div>

              <div :if={@preview_result.sample_logs == []} class="text-sm text-warning">
                No logs would match this rule. Consider adjusting your conditions.
              </div>
            </div>

            <div :if={@preview_state == :error} class="text-sm text-error">
              {@preview_error}
            </div>
          </div>
          
    <!-- Validation Error -->
          <div :if={@error} class="alert alert-error">
            <.icon name="hero-exclamation-circle" class="w-5 h-5" />
            <span>{@error}</span>
          </div>
          
    <!-- Actions -->
          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close" phx-target={@myself}>
              Cancel
            </button>
            <button type="submit" class="btn btn-primary" disabled={@saving}>
              <span :if={@saving} class="loading loading-spinner loading-xs"></span>
              <.icon :if={not @saving and @mode == :create} name="hero-plus" class="w-4 h-4" />
              <.icon :if={not @saving and @mode == :edit} name="hero-check" class="w-4 h-4" />
              {if @mode == :edit, do: "Save Changes", else: "Create Rule"}
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close" phx-target={@myself}>close</button>
      </form>
    </dialog>
    """
  end

  @impl true
  def handle_event("validate", %{"rule" => params}, socket) do
    params = normalize_checkbox_params(params, socket.assigns.form)
    form = build_form(params)
    socket = assign(socket, :form, form)

    # Auto-trigger preview if at least one condition is enabled
    # The form debounce handles the delay
    socket =
      if has_enabled_condition?(params) do
        run_preview_query(socket)
      else
        socket
        |> assign(:preview_state, :idle)
        |> assign(:preview_result, nil)
      end

    {:noreply, socket}
  end

  def handle_event("close", _params, socket) do
    send(self(), {:rule_builder_closed})
    {:noreply, socket}
  end

  def handle_event("select_attribute", %{"key" => key, "value" => value}, socket) do
    form_data = form_to_map(socket.assigns.form)

    updated =
      form_data
      |> Map.put("attribute_key", key)
      |> Map.put("attribute_value", value)
      |> Map.put("attribute_enabled", true)

    {:noreply, assign(socket, :form, build_form(updated))}
  end

  def handle_event("test_rule", _params, socket) do
    {:noreply, run_preview_query(socket)}
  end

  def handle_event("save", %{"rule" => params}, socket) do
    params = normalize_checkbox_params(params, socket.assigns.form)

    # Validate at least one condition is enabled
    cond do
      String.trim(params["name"] || "") == "" ->
        {:noreply, assign(socket, :error, "Rule name is required")}

      not has_enabled_condition?(params) ->
        {:noreply, assign(socket, :error, "At least one match condition must be enabled")}

      socket.assigns.mode == :edit ->
        socket = assign(socket, :saving, true)
        update_rule(params, socket)

      true ->
        socket = assign(socket, :saving, true)
        create_rule(params, socket)
    end
  end

  # Preview query timeout in milliseconds (5 seconds)
  @preview_timeout 5_000

  # Private functions

  defp run_preview_query(socket) do
    # Build SRQL query from form data
    query = build_preview_query(socket.assigns.form)

    # Execute query with timeout
    task = Task.async(fn -> srql_module().query(query) end)

    case Task.yield(task, @preview_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{"results" => results, "total_count" => total}}} ->
        socket
        |> assign(:preview_state, :done)
        |> assign(:preview_result, %{
          match_count: total || length(results),
          sample_logs: Enum.take(results, 5)
        })

      {:ok, {:ok, %{"results" => results}}} ->
        socket
        |> assign(:preview_state, :done)
        |> assign(:preview_result, %{
          match_count: length(results),
          sample_logs: Enum.take(results, 5)
        })

      {:ok, {:error, reason}} ->
        socket
        |> assign(:preview_state, :error)
        |> assign(:preview_error, format_error(reason))

      nil ->
        socket
        |> assign(:preview_state, :error)
        |> assign(
          :preview_error,
          "Query timed out after 5 seconds. Try narrowing your conditions."
        )

      {:exit, reason} ->
        socket
        |> assign(:preview_state, :error)
        |> assign(:preview_error, "Query failed: #{inspect(reason)}")
    end
  end

  defp build_form(params) do
    data = %{
      "name" => params["name"] || "",
      "body_contains" => params["body_contains"] || "",
      "body_contains_enabled" => to_boolean(params["body_contains_enabled"], false),
      "severity_text" => params["severity_text"] || "",
      "severity_enabled" => to_boolean(params["severity_enabled"], false),
      "service_name" => params["service_name"] || "",
      "service_name_enabled" => to_boolean(params["service_name_enabled"], false),
      "attribute_key" => params["attribute_key"] || "",
      "attribute_value" => params["attribute_value"] || "",
      "attribute_enabled" => to_boolean(params["attribute_enabled"], false),
      "auto_alert" => to_boolean(params["auto_alert"], false),
      "parsed_attributes" => params["parsed_attributes"] || %{}
    }

    to_form(data, as: :rule)
  end

  defp form_to_map(form) do
    %{
      "name" => form[:name].value,
      "body_contains" => form[:body_contains].value,
      "body_contains_enabled" => form[:body_contains_enabled].value,
      "severity_text" => form[:severity_text].value,
      "severity_enabled" => form[:severity_enabled].value,
      "service_name" => form[:service_name].value,
      "service_name_enabled" => form[:service_name_enabled].value,
      "attribute_key" => form[:attribute_key].value,
      "attribute_value" => form[:attribute_value].value,
      "attribute_enabled" => form[:attribute_enabled].value,
      "auto_alert" => form[:auto_alert].value,
      "parsed_attributes" => form[:parsed_attributes].value
    }
  end

  defp normalize_checkbox_params(params, existing_form) do
    # Checkboxes only send values when checked, so we need to handle unchecked state
    %{
      "name" => params["name"] || "",
      "body_contains" => params["body_contains"] || "",
      "body_contains_enabled" => params["body_contains_enabled"] == "true",
      "severity_text" => params["severity_text"] || "",
      "severity_enabled" => params["severity_enabled"] == "true",
      "service_name" => params["service_name"] || "",
      "service_name_enabled" => params["service_name_enabled"] == "true",
      "attribute_key" => params["attribute_key"] || "",
      "attribute_value" => params["attribute_value"] || "",
      "attribute_enabled" => params["attribute_enabled"] == "true",
      "auto_alert" => params["auto_alert"] == "true",
      "parsed_attributes" => existing_form[:parsed_attributes].value
    }
  end

  defp to_boolean(true, _default), do: true
  defp to_boolean(false, _default), do: false
  defp to_boolean("true", _default), do: true
  defp to_boolean("false", _default), do: false
  defp to_boolean(_, default), do: default

  defp has_enabled_condition?(params) do
    params["body_contains_enabled"] or
      params["severity_enabled"] or
      params["service_name_enabled"] or
      params["attribute_enabled"]
  end

  defp build_match_map(params) do
    %{}
    |> maybe_add_body_contains(params)
    |> maybe_add_severity(params)
    |> maybe_add_service_name(params)
    |> maybe_add_attribute_equals(params)
  end

  defp maybe_add_body_contains(match, params) do
    if params["body_contains_enabled"] and has_value?(params["body_contains"]) do
      Map.put(match, "body_contains", params["body_contains"])
    else
      match
    end
  end

  defp maybe_add_severity(match, params) do
    if params["severity_enabled"] and has_value?(params["severity_text"]) do
      Map.put(match, "severity_text", params["severity_text"])
    else
      match
    end
  end

  defp maybe_add_service_name(match, params) do
    if params["service_name_enabled"] and has_value?(params["service_name"]) do
      Map.put(match, "service_name", params["service_name"])
    else
      match
    end
  end

  defp maybe_add_attribute_equals(match, params) do
    if params["attribute_enabled"] and has_value?(params["attribute_key"]) and
         has_value?(params["attribute_value"]) do
      Map.put(match, "attribute_equals", %{params["attribute_key"] => params["attribute_value"]})
    else
      match
    end
  end

  defp has_value?(nil), do: false
  defp has_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp has_value?(_), do: false

  defp build_event_map(params) do
    if params["auto_alert"] do
      %{"alert" => true}
    else
      %{}
    end
  end

  defp create_rule(params, socket) do
    match = build_match_map(params)
    event = build_event_map(params)

    attrs = %{
      name: String.trim(params["name"]),
      enabled: true,
      priority: 100,
      source_type: :log,
      source: %{},
      match: match,
      event: event
    }

    scope = socket.assigns.current_scope

    case Ash.create(EventRule, attrs, scope: scope) do
      {:ok, rule} ->
        send(self(), {:rule_created, rule})
        {:noreply, assign(socket, :saving, false)}

      {:error, %Ash.Error.Invalid{} = error} ->
        error_message = format_ash_error(error)
        {:noreply, socket |> assign(:saving, false) |> assign(:error, error_message)}

      {:error, reason} ->
        {:noreply, socket |> assign(:saving, false) |> assign(:error, format_error(reason))}
    end
  end

  defp update_rule(params, socket) do
    match = build_match_map(params)
    event = build_event_map(params)

    attrs = %{
      name: String.trim(params["name"]),
      match: match,
      event: event
    }

    scope = socket.assigns.current_scope
    rule_id = socket.assigns.editing_rule_id

    # Fetch the existing rule first
    case Ash.get(EventRule, rule_id, scope: scope) do
      {:ok, rule} ->
        changeset = Ash.Changeset.for_update(rule, :update, attrs, scope: scope)

        case Ash.update(changeset) do
          {:ok, updated_rule} ->
            send(self(), {:rule_updated, updated_rule})
            {:noreply, assign(socket, :saving, false)}

          {:error, %Ash.Error.Invalid{} = error} ->
            error_message = format_ash_error(error)
            {:noreply, socket |> assign(:saving, false) |> assign(:error, error_message)}

          {:error, reason} ->
            {:noreply, socket |> assign(:saving, false) |> assign(:error, format_error(reason))}
        end

      {:error, _} ->
        {:noreply, socket |> assign(:saving, false) |> assign(:error, "Rule not found")}
    end
  end

  defp build_preview_query(form) do
    filters = []

    filters =
      if form[:body_contains_enabled].value and
           String.trim(form[:body_contains].value || "") != "" do
        escaped = escape_srql_value(form[:body_contains].value)
        ["body:\"*#{escaped}*\"" | filters]
      else
        filters
      end

    filters =
      if form[:severity_enabled].value and String.trim(form[:severity_text].value || "") != "" do
        ["severity_text:\"#{form[:severity_text].value}\"" | filters]
      else
        filters
      end

    filters =
      if form[:service_name_enabled].value and String.trim(form[:service_name].value || "") != "" do
        escaped = escape_srql_value(form[:service_name].value)
        ["service_name:\"#{escaped}\"" | filters]
      else
        filters
      end

    base = "in:logs"
    time_filter = "timestamp:>now-1h"

    [base, time_filter | filters]
    |> Enum.join(" ")
    |> Kernel.<>(" limit:10")
  end

  defp escape_srql_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_srql_value(other), do: to_string(other)

  defp generate_rule_name(log) do
    service = Map.get(log, "service_name") || "unknown"
    severity = Map.get(log, "severity_text") || "log"

    service_short =
      service
      |> String.replace("serviceradar-", "")
      |> String.split("-")
      |> Enum.take(2)
      |> Enum.join("-")

    "#{service_short}-#{String.downcase(severity)}-#{:rand.uniform(999)}"
  end

  defp parse_log_attributes(log) do
    case Map.get(log, "attributes") do
      nil -> %{}
      "" -> %{}
      value when is_map(value) -> value
      value when is_binary(value) -> parse_attribute_string(value)
      _ -> %{}
    end
  end

  defp parse_attribute_string(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "{") ->
        parse_json_attributes(value)

      String.contains?(value, "=") ->
        parse_key_value_attributes(value)

      true ->
        %{}
    end
  end

  defp parse_json_attributes(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp parse_key_value_attributes(value) do
    ~r/(\w+)=(\{[^}]*\}|[^,]+?)(?=,\w+=|$)/
    |> Regex.scan(value)
    |> Enum.reduce(%{}, &parse_key_value_pair/2)
  end

  defp parse_key_value_pair([_full, key, json_value], acc)
       when binary_part(json_value, 0, 1) == "{" do
    case Jason.decode(json_value) do
      {:ok, decoded} -> Map.put(acc, key, decoded)
      _ -> Map.put(acc, key, json_value)
    end
  end

  defp parse_key_value_pair([_full, key, plain_value], acc) do
    Map.put(acc, key, String.trim(plain_value))
  end

  defp flatten_for_suggestions(attributes) when is_map(attributes) do
    Enum.flat_map(attributes, fn
      {section, values} when is_map(values) ->
        Enum.map(values, fn {k, v} -> {"#{section}.#{k}", stringify(v)} end)

      {k, v} ->
        [{k, stringify(v)}]
    end)
    |> Enum.take(10)
  end

  defp flatten_for_suggestions(_), do: []

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_number(value), do: to_string(value)
  defp stringify(value) when is_boolean(value), do: to_string(value)
  defp stringify(value), do: inspect(value)

  defp truncate(nil, _max), do: ""
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "..."

  defp format_preview_time(nil), do: "--:--:--"

  defp format_preview_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> "--:--:--"
    end
  end

  defp format_preview_time(_), do: "--:--:--"

  defp severity_class(severity) when is_binary(severity) do
    case String.downcase(severity) do
      s when s in ["error", "critical", "fatal"] -> "text-error"
      s when s in ["warn", "warning"] -> "text-warning"
      _ -> "text-base-content/70"
    end
  end

  defp severity_class(_), do: "text-base-content/70"

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", fn
      %{field: field, message: message} when is_atom(field) ->
        "#{field}: #{message}"

      %{message: message} ->
        message

      other ->
        inspect(other)
    end)
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
