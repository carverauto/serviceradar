defmodule ServiceRadarWebNGWeb.NorthboundActionComponents do
  @moduledoc false
  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents
  import ServiceRadarWebNGWeb.UIComponents
  # Reuse the device-detail Ansible panel's typed variable input so the bulk
  # "Run Task" modal renders an identical variable form.
  import ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelComponents, only: [var_input: 1]

  alias ServiceRadarWebNG.Northbound.ActionForm

  # How many non-applicable device names to name before collapsing to "+N more".
  @non_applicable_display_limit 10

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:subtitle, :string, required: true)
  attr(:form, :any, required: true)
  attr(:actions, :list, required: true)
  attr(:action, :map, default: nil)
  attr(:error, :string, default: nil)
  attr(:close_event, :string, required: true)
  attr(:change_event, :string, required: true)
  attr(:submit_event, :string, required: true)
  # Bulk-selection AWX applicability summary: %{applicable_count, total_count,
  # non_applicable: [%{uid, label}]}. nil when the modal is not device-bulk
  # (e.g. the device-detail interface actions), which renders no gating block.
  attr(:applicability, :map, default: nil)
  # Ansible typed-variable form. `ansible_vars` is a list (possibly empty) for
  # an Ansible task and nil for non-ansible actions (which fall back to the
  # descriptor's JSON-schema fields).
  attr(:ansible_vars, :list, default: nil)
  attr(:ansible_var_values, :map, default: %{})
  attr(:raw_extra_vars_open, :boolean, default: false)
  attr(:raw_extra_vars, :string, default: "")
  attr(:toggle_raw_event, :string, default: nil)

  def northbound_action_modal(assigns) do
    action = assigns.action || List.first(assigns.actions)
    properties = if action, do: ActionForm.schema_properties(action), else: []
    required = if action, do: ActionForm.schema_required(action), else: MapSet.new()

    assigns =
      assigns
      |> assign(:action, action)
      |> assign(:properties, properties)
      |> assign(:required, required)

    ~H"""
    <.ui_modal id={@id} size="md" on_cancel={@close_event} show_close={true}>
      <div class="flex items-start gap-3">
        <div class="rounded-lg bg-sr-brand/12 p-2">
          <.icon name="hero-play" class="size-5 text-sr-brand" />
        </div>
        <div class="min-w-0 flex-1">
          <h3 class="text-lg font-semibold text-sr-ink">{@title}</h3>
          <p class="text-sm text-sr-muted">{@subtitle}</p>
        </div>
      </div>

        <div :if={applicability_present?(@applicability)} class="mt-4 space-y-3">
          <div
            role="status"
            class={[
              "flex items-start gap-3 rounded-lg border px-4 py-3 text-sm",
              if(applicability_blocked?(@applicability),
                do: "border-warning/30 bg-warning/10",
                else: "border-info/20 bg-info/10"
              )
            ]}
          >
            <.icon
              name={
                if applicability_blocked?(@applicability),
                  do: "hero-exclamation-triangle",
                  else: "hero-check-circle"
              }
              class={[
                "mt-0.5 size-5 shrink-0",
                if(applicability_blocked?(@applicability), do: "text-warning", else: "text-info")
              ]}
            />
            <div class="min-w-0">
              <p class="font-medium text-sr-ink">{applicable_summary_text(@applicability)}</p>
              <p
                :if={applicability_blocked?(@applicability)}
                class="mt-1 text-xs text-sr-muted"
              >
                Only AWX-managed devices can run Ansible tasks. Select at least one device that is in an AWX inventory.
              </p>
            </div>
          </div>

          <div
            :if={non_applicable_any?(@applicability)}
            role="alert"
            class="rounded-lg border border-warning/30 bg-warning/10 px-4 py-3 text-sm"
          >
            <div class="flex items-start gap-3">
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
              <div class="min-w-0">
                <p class="font-medium text-sr-ink">
                  Not in an AWX inventory (will be skipped):
                </p>
                <div class="mt-2 flex flex-wrap gap-1.5">
                  <.ui_badge
                    :for={entry <- non_applicable_visible(@applicability)}
                    size="sm"
                    variant="warning"
                    class="max-w-full truncate"
                    title={entry.uid}
                  >
                    {entry.label}
                  </.ui_badge>
                  <.ui_badge
                    :if={non_applicable_more(@applicability) > 0}
                    size="sm"
                    variant="ghost"
                  >
                    +{non_applicable_more(@applicability)} more
                  </.ui_badge>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div :if={@error} role="alert" class={ui_alert_class(variant: "error", class: "mt-4")}>
          <.icon name="hero-exclamation-circle" class="size-5" />
          <span class="text-sm">{@error}</span>
        </div>

        <.form
          for={@form}
          id={"#{@id}-form"}
          phx-change={@change_event}
          phx-submit={@submit_event}
          class="mt-5 space-y-4"
        >
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Task</span>
            </label>
            <select name="action[action_id]" class={ui_field_class(class: "w-full")}>
              <%= for option <- @actions do %>
                <option value={option.id} selected={@action && option.id == @action.id}>
                  {option.label}
                </option>
              <% end %>
            </select>
          </div>

          <div :if={@action} class="rounded-lg border border-sr-line bg-sr-subtle/60 p-3">
            <div class="flex flex-wrap items-center gap-2 text-xs">
              <.ui_badge size="sm" variant="ghost">{@action.provider_name}</.ui_badge>
              <.ui_badge
                size="sm"
                variant={ActionForm.safety_badge_variant(@action.safety_classification)}
              >
                {ActionForm.humanize(@action.safety_classification)}
              </.ui_badge>
              <.ui_badge :if={@action.requires_confirmation} size="sm" variant="warning">
                Confirmation required
              </.ui_badge>
              <.ui_badge size="sm" variant="ghost">
                {@action.timeout_seconds}s timeout
              </.ui_badge>
            </div>
            <p
              :if={ActionForm.present_text?(@action.description)}
              class="mt-2 text-sm text-sr-muted"
            >
              {@action.description}
            </p>
          </div>

          <%= if ansible_action?(@ansible_vars) do %>
            <div :if={@ansible_vars != []} class="space-y-3">
              <h4 class="text-sm font-medium text-sr-ink">Variables</h4>
              <.var_input
                :for={var <- @ansible_vars}
                var={var}
                value={Map.get(@ansible_var_values, var.name)}
                name={"action[vars][#{var.name}]"}
              />
            </div>

            <div
              :if={@ansible_vars == []}
              class="rounded-lg border border-sr-line p-4 text-sm text-sr-muted"
            >
              This task requires no variables.
            </div>

            <div class="rounded-lg border border-sr-line">
              <button
                type="button"
                phx-click={@toggle_raw_event}
                class="flex w-full items-center justify-between px-3 py-2 text-sm text-sr-muted hover:text-sr-ink"
              >
                <span class="flex items-center gap-2 font-medium">
                  <.icon name="hero-code-bracket" class="size-4" /> Advanced: raw extra_vars JSON
                </span>
                <.icon
                  name={if @raw_extra_vars_open, do: "hero-chevron-up", else: "hero-chevron-down"}
                  class="size-4"
                />
              </button>
              <div :if={@raw_extra_vars_open} class="border-t border-sr-line p-3">
                <p class="mb-2 text-xs text-sr-muted">
                  Optional. Merged over the fields above (raw keys win). Leave blank to use the form values.
                </p>
                <textarea
                  name="action[raw_extra_vars]"
                  class={ui_field_class(mono: true, class: "min-h-24 w-full py-2.5 text-xs")}
                  placeholder="{}"
                >{@raw_extra_vars}</textarea>
              </div>
            </div>
          <% else %>
            <div :if={@properties != []} class="grid gap-4">
              <%= for {name, schema} <- @properties do %>
                <.northbound_action_field
                  form={@form}
                  name={name}
                  schema={schema}
                  required={MapSet.member?(@required, name)}
                />
              <% end %>
            </div>

            <div
              :if={@properties == []}
              class="rounded-lg border border-sr-line p-4 text-sm text-sr-muted"
            >
              This task does not require additional input.
            </div>
          <% end %>

          <div class="flex justify-end gap-2 pt-2">
            <.ui_button type="button" phx-click={@close_event} size="sm" variant="ghost">
              Cancel
            </.ui_button>
            <.ui_button
              type="submit"
              disabled={launch_disabled?(@action, @applicability)}
              size="sm"
              variant="primary"
            >
              <.icon name="hero-play" class="size-4" /> Create Invocation
            </.ui_button>
          </div>
        </.form>
    </.ui_modal>
    """
  end

  attr(:entries, :list, required: true)
  attr(:title, :string, default: "Task History")
  attr(:subtitle, :string, default: nil)
  attr(:empty_message, :string, default: "No task invocations have been recorded yet.")
  attr(:error, :string, default: nil)
  attr(:notice, :map, default: nil)

  def northbound_action_history(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="flex items-start justify-between gap-3 border-b border-sr-line px-4 py-3">
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <.icon name="hero-clock" class="size-4 text-sr-brand" />
            <span class="text-sm font-semibold">{@title}</span>
          </div>
          <p :if={ActionForm.present_text?(@subtitle)} class="mt-1 text-xs text-sr-muted">
            {@subtitle}
          </p>
        </div>
        <.ui_badge :if={@entries != []} size="sm" variant="ghost">{length(@entries)}</.ui_badge>
      </div>

      <div
        :if={is_map(@notice)}
        class="mx-4 mt-4 rounded-lg border border-info/20 bg-info/10 px-4 py-3 text-sm text-sr-ink"
      >
        <div class="flex gap-3">
          <.icon name="hero-play-circle" class="mt-0.5 size-5 shrink-0 text-info" />
          <div class="min-w-0 space-y-1">
            <p class="font-semibold">{Map.get(@notice, :title, "Task dispatched")}</p>
            <p class="text-xs text-sr-muted">
              Results update in Task History as the integration reports progress.
              <span
                :if={ActionForm.present_text?(Map.get(@notice, :invocation_id))}
                class="font-mono"
              >
                {ActionForm.short_id(Map.get(@notice, :invocation_id))}
              </span>
            </p>
          </div>
        </div>
      </div>

      <div :if={ActionForm.present_text?(@error)} class="px-4 py-3 text-sm text-error">
        {@error}
      </div>

      <div
        :if={@entries == [] and not ActionForm.present_text?(@error)}
        class="px-4 py-6 text-sm text-sr-muted"
      >
        <p>{@empty_message}</p>
        <p class="mt-2 text-xs text-sr-muted">
          Newly launched tasks appear here with queued, running, succeeded, or failed status.
        </p>
      </div>

      <div :if={@entries != []} class="divide-y divide-sr-line">
        <div :for={entry <- @entries} class="px-4 py-3">
          <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0 space-y-1">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-medium">{Map.get(entry, :action_label) || "Action"}</span>
                <.ui_badge
                  :if={ActionForm.present_text?(Map.get(entry, :provider_name))}
                  size="sm"
                  variant="ghost"
                >
                  {Map.get(entry, :provider_name)}
                </.ui_badge>
                <.ui_badge size="sm" variant={action_state_badge_variant(Map.get(entry, :state))}>
                  {action_state_label(Map.get(entry, :state))}
                </.ui_badge>
                <.ui_badge
                  size="sm"
                  variant={target_status_badge_variant(Map.get(entry, :target_status))}
                >
                  {target_status_label(Map.get(entry, :target_status))}
                </.ui_badge>
              </div>

              <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-sr-muted">
                <span class="font-mono">{ActionForm.short_id(Map.get(entry, :invocation_id))}</span>
                <span>{format_history_timestamp(Map.get(entry, :inserted_at))}</span>
                <span>{history_target_label(entry)}</span>
              </div>

              <p
                :if={ActionForm.present_text?(history_summary(entry))}
                class="text-sm text-sr-muted"
              >
                {history_summary(entry)}
              </p>
            </div>

            <div class="flex max-w-full flex-wrap justify-start gap-1 lg:max-w-sm lg:justify-end">
              <.ui_badge
                :for={chip <- history_input_chips(entry)}
                size="sm"
                variant="outline"
                class="max-w-full truncate"
              >
                {chip}
              </.ui_badge>
              <.ui_badge
                :if={history_input_more_count(entry) > 0}
                size="sm"
                variant="ghost"
              >
                +{history_input_more_count(entry)}
              </.ui_badge>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:name, :string, required: true)
  attr(:schema, :map, required: true)
  attr(:required, :boolean, default: false)

  defp northbound_action_field(assigns) do
    type = ActionForm.schema_type(assigns.schema)
    enum_values = ActionForm.schema_enum(assigns.schema)

    assigns =
      assigns
      |> assign(:type, type)
      |> assign(:enum_values, enum_values)
      |> assign(:value, ActionForm.form_value(assigns.form, assigns.name))
      |> assign(:label, ActionForm.schema_title(assigns.name, assigns.schema))
      |> assign(:description, ActionForm.schema_description(assigns.schema))
      |> assign(:input_name, "action[input][#{assigns.name}]")

    ~H"""
    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">
          {@label}
          <span :if={@required} class="text-error">*</span>
        </span>
        <span :if={ActionForm.present_text?(@description)} class="text-xs text-sr-muted">
          {@description}
        </span>
      </label>

      <select
        :if={@enum_values != []}
        name={@input_name}
        class={ui_field_class(class: "w-full")}
        required={@required}
      >
        <option value="">Select...</option>
        <%= for option <- @enum_values do %>
          <option value={option} selected={to_string(@value || "") == option}>{option}</option>
        <% end %>
      </select>

      <div :if={@enum_values == [] and @type == "boolean"} class="flex items-center gap-2">
        <input type="hidden" name={@input_name} value="false" />
        <input
          type="checkbox"
          name={@input_name}
          value="true"
          checked={@value in [true, "true", "on", "1", 1]}
          class="toggle toggle-primary"
        />
      </div>

      <textarea
        :if={@enum_values == [] and @type in ["object", "array"]}
        name={@input_name}
        class={ui_field_class(mono: true, class: "min-h-28 w-full py-2.5 text-xs")}
        required={@required}
        placeholder={if @type == "array", do: "[]", else: "{}"}
      >{ActionForm.json_textarea_value(@value, @type)}</textarea>

      <input
        :if={@enum_values == [] and @type not in ["boolean", "object", "array"]}
        type={ActionForm.html_input_type(@type)}
        name={@input_name}
        value={@value}
        class={ui_field_class(class: "w-full")}
        required={@required}
      />
    </div>
    """
  end

  ## Applicability + ansible-form helpers --------------------------------------

  defp ansible_action?(ansible_vars), do: is_list(ansible_vars)

  defp launch_disabled?(action, applicability) do
    is_nil(action) or applicability_blocked?(applicability)
  end

  defp applicability_present?(applicability), do: is_map(applicability)

  defp applicability_blocked?(applicability) do
    is_map(applicability) and Map.get(applicability, :applicable_count, 0) == 0
  end

  defp applicable_summary_text(applicability) do
    applicable = Map.get(applicability, :applicable_count, 0)
    total = Map.get(applicability, :total_count, 0)

    "#{applicable} of #{total} selected device(s) are AWX-managed and will run this task."
  end

  defp non_applicable_list(applicability), do: Map.get(applicability, :non_applicable, [])

  defp non_applicable_any?(applicability), do: non_applicable_list(applicability) != []

  defp non_applicable_visible(applicability) do
    applicability |> non_applicable_list() |> Enum.take(@non_applicable_display_limit)
  end

  defp non_applicable_more(applicability) do
    max(length(non_applicable_list(applicability)) - @non_applicable_display_limit, 0)
  end

  defp action_state_badge_variant(:succeeded), do: "success"
  defp action_state_badge_variant(:failed), do: "error"
  defp action_state_badge_variant(:canceled), do: "warning"
  defp action_state_badge_variant(:suppressed), do: "warning"
  defp action_state_badge_variant(:running), do: "info"
  defp action_state_badge_variant(:dispatching), do: "info"
  defp action_state_badge_variant(:polling), do: "info"
  defp action_state_badge_variant(:result_fetching), do: "info"
  defp action_state_badge_variant(:expired), do: "error"
  defp action_state_badge_variant(_state), do: "ghost"

  defp target_status_badge_variant(:succeeded), do: "success"
  defp target_status_badge_variant(:failed), do: "error"
  defp target_status_badge_variant(:skipped), do: "warning"
  defp target_status_badge_variant(:suppressed), do: "warning"
  defp target_status_badge_variant(:canceled), do: "warning"
  defp target_status_badge_variant(:running), do: "info"
  defp target_status_badge_variant(:polling), do: "info"
  defp target_status_badge_variant(:result_fetching), do: "info"
  defp target_status_badge_variant(:expired), do: "error"
  defp target_status_badge_variant(_status), do: "ghost"

  defp action_state_label(nil), do: "Pending"
  defp action_state_label(state), do: ActionForm.humanize(state)

  defp target_status_label(nil), do: "Target Pending"
  defp target_status_label(:result_fetching), do: "Target Result fetching"
  defp target_status_label(status), do: "Target #{ActionForm.humanize(status)}"

  defp history_target_label(entry) do
    case {Map.get(entry, :target_kind), Map.get(entry, :interface_uid), Map.get(entry, :device_uid)} do
      {:interface, interface_uid, _device_uid} when is_binary(interface_uid) ->
        "Interface #{ActionForm.short_id(interface_uid)}"

      {"interface", interface_uid, _device_uid} when is_binary(interface_uid) ->
        "Interface #{ActionForm.short_id(interface_uid)}"

      {_kind, _interface_uid, device_uid} when is_binary(device_uid) ->
        "Device #{ActionForm.short_id(device_uid)}"

      _ ->
        "Target"
    end
  end

  defp history_summary(entry) do
    Enum.find_value(
      [
        Map.get(entry, :error_message),
        history_progress_summary(entry),
        summary_value(Map.get(entry, :target_result)),
        summary_value(Map.get(entry, :result_summary)),
        Map.get(entry, :external_correlation_id)
      ],
      &summary_candidate/1
    )
  end

  defp summary_candidate(value) when is_binary(value), do: present_summary_text(value)
  defp summary_candidate(value) when is_atom(value), do: value |> Atom.to_string() |> present_summary_text()
  defp summary_candidate(value) when is_number(value), do: to_string(value)
  defp summary_candidate(_value), do: nil

  defp summary_value(%{} = map) do
    Enum.find_value(
      [
        {"message", :message},
        {"summary", :summary},
        {"status", :status},
        {"detail", :detail},
        {"result", :result}
      ],
      fn {string_key, atom_key} ->
        case Map.get(map, string_key) || Map.get(map, atom_key) do
          value when is_binary(value) -> present_summary_text(value)
          value when is_atom(value) -> Atom.to_string(value)
          value when is_number(value) -> to_string(value)
          _ -> nil
        end
      end
    )
  end

  defp summary_value(_value), do: nil

  defp history_progress_summary(entry) do
    case Map.get(entry, :target_status) || Map.get(entry, :state) do
      status when status in [:polling, :result_fetching] ->
        progress_summary(status, entry)

      :expired ->
        "External task expired"

      _ ->
        nil
    end
  end

  defp progress_summary(:result_fetching, entry), do: poll_summary("Fetching external task results", entry)

  defp progress_summary(_status, entry), do: poll_summary("Waiting for external task", entry)

  defp poll_summary(prefix, entry) do
    [
      prefix,
      next_poll_text(Map.get(entry, :next_poll_at)),
      poll_attempt_text(Map.get(entry, :poll_attempt_count))
    ]
    |> Enum.filter(&ActionForm.present_text?/1)
    |> Enum.join(" · ")
  end

  defp next_poll_text(nil), do: nil
  defp next_poll_text(value), do: "next poll #{format_history_timestamp(value)}"

  defp poll_attempt_text(count) when is_integer(count) and count > 0, do: "poll #{count}"
  defp poll_attempt_text(_count), do: nil

  defp present_summary_text(value) when is_binary(value) do
    value = String.trim(value)

    if value in ["", "nil", "null"] do
      nil
    else
      value
    end
  end

  defp history_input_chips(entry) do
    entry
    |> Map.get(:redacted_input_values, %{})
    |> input_chips()
    |> Enum.take(3)
  end

  defp history_input_more_count(entry) do
    entry
    |> Map.get(:redacted_input_values, %{})
    |> input_chips()
    |> length()
    |> Kernel.-(3)
    |> max(0)
  end

  defp input_chips(%{} = values) do
    values
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> "#{ActionForm.humanize(key)}: #{compact_value(value)}" end)
  end

  defp input_chips(_values), do: []

  defp compact_value(nil), do: "—"
  defp compact_value(value) when is_binary(value), do: String.slice(value, 0, 48)
  defp compact_value(value) when is_boolean(value), do: if(value, do: "Yes", else: "No")
  defp compact_value(value) when is_atom(value), do: Atom.to_string(value)
  defp compact_value(value) when is_number(value), do: to_string(value)
  defp compact_value(%{} = value), do: "#{map_size(value)} fields"
  defp compact_value(value) when is_list(value), do: "#{length(value)} values"
  defp compact_value(value), do: value |> to_string() |> String.slice(0, 48)

  defp format_history_timestamp(nil), do: "—"

  defp format_history_timestamp(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  defp format_history_timestamp(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> format_history_timestamp()
  end

  defp format_history_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> format_history_timestamp(datetime)
      _ -> value
    end
  end

  defp format_history_timestamp(_value), do: "—"
end
