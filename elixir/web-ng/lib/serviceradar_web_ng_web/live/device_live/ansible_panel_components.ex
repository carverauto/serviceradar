defmodule ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelComponents do
  @moduledoc """
  Device-detail Ansible panel: automation operation history plus an in-page
  launch modal (playbook picker + typed variable form).

  Rendered only for AWX-managed devices. Reads/launch dispatch live in
  `AnsiblePanelRuntime`; this module is presentation only.
  """

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.IntegrationLogos, only: [wordmark: 1]

  alias ServiceRadar.Automation.Ansible.VariableSchema.Var

  attr(:device_uid, :string, required: true)
  attr(:device_awx_managed, :boolean, default: false)
  attr(:can_view_ansible_operations, :boolean, default: false)
  attr(:can_run_ansible, :boolean, default: false)
  attr(:device_deleted, :boolean, default: false)
  attr(:ansible_controller_id, :string, default: nil)
  attr(:operation_history, :list, default: [])
  attr(:playbooks, :list, default: [])
  attr(:launch_open, :boolean, default: false)
  attr(:selected_playbook_id, :string, default: nil)
  attr(:vars, :list, default: [])
  attr(:var_values, :map, default: %{})
  attr(:launch_notice, :string, default: nil)
  attr(:launch_ready, :boolean, default: false)
  attr(:launch_resolution, :map, default: nil)
  attr(:launch_readiness, :string, default: nil)
  attr(:launch_form, :any, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def ansible_operations_section(assigns) do
    assigns =
      assigns
      |> assign(:launchable?, assigns.can_run_ansible and not assigns.device_deleted and assigns.playbooks != [])
      |> assign(:has_history, assigns.operation_history != [])

    ~H"""
    <section
      :if={@device_awx_managed and (@can_view_ansible_operations or @can_run_ansible)}
      class="rounded-xl border border-sr-line bg-sr-surface"
      data-testid="device-ansible-panel"
    >
      <div class="flex flex-wrap items-center justify-between gap-2 border-b border-sr-line px-4 py-3">
        <div class="flex items-center gap-2">
          <.wordmark name={:ansible} class="h-8 w-auto" />
          <p class="text-xs text-sr-muted">
            AWX inventory member · Ansible operations
          </p>
        </div>

        <div class="flex items-center gap-2">
          <.link
            :if={@can_view_ansible_operations}
            navigate={~p"/ansible/operations"}
            class="text-sr-brand hover:underline text-xs text-sr-muted"
          >
            All operations
          </.link>
          <.ui_button
            :if={@can_run_ansible and not @device_deleted}
            type="button"
            phx-click="ansible_launch_open"
            disabled={not @launchable?}
            title={launch_disabled_reason(@launchable?, @ansible_controller_id)}
            size="sm"
            variant="primary"
          >
            <.icon name="hero-play" class="size-4" /> Launch Playbook
          </.ui_button>
        </div>
      </div>

      <div
        :if={@can_view_ansible_operations and not @has_history}
        class="px-4 py-6 text-sm text-sr-muted"
      >
        No Ansible operations have targeted this device yet.
        <span :if={@can_run_ansible and @playbooks == []} class="block text-xs mt-1">
          No launchable playbooks are bound to this device's AWX controller.
        </span>
      </div>

      <div :if={@can_view_ansible_operations and @has_history}>
        <div class="flex flex-wrap items-center justify-between gap-2 px-4 py-3">
          <div>
            <h3 class="text-sm font-semibold">Recent operations</h3>
            <p class="text-xs text-sr-muted">
              Immutable controller, inventory, and AWX host identity.
            </p>
          </div>
        </div>

        <div class="sr-ui-table-shell">
          <table class={ui_table_class(size: "sm")} data-testid="device-ansible-operation-history">
            <thead>
              <tr>
                <th>Operation</th>
                <th>Execution</th>
                <th>Exact target</th>
                <th>Controller / inventory</th>
                <th>AWX job</th>
                <th>Started</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={record <- @operation_history}>
                <td>
                  <.ui_badge size="sm" variant={state_badge_variant(record.operation.state)}>
                    {record.operation.state}
                  </.ui_badge>
                  <code class="mt-1 block text-xs">{short_id(record.operation.id)}</code>
                </td>
                <td>
                  <.ui_badge size="sm" variant={state_badge_variant(record.execution.state)}>
                    {record.execution.state}
                  </.ui_badge>
                  <span
                    :if={record.execution.scope_verified_at}
                    class="mt-1 block text-xs text-success"
                  >
                    Scope verified
                  </span>
                  <span
                    :if={is_nil(record.execution.scope_verified_at)}
                    class="mt-1 block text-xs text-warning"
                  >
                    Scope proof pending
                  </span>
                </td>
                <td>
                  <div class="flex flex-wrap items-center gap-1">
                    <.ui_badge size="sm" variant={target_badge_variant(record.target.status)}>
                      {record.target.status}
                    </.ui_badge>
                    <.ui_badge :if={record.target.active_hold} size="sm" variant="error">
                      hold active
                    </.ui_badge>
                  </div>
                  <code class="mt-1 block text-xs">
                    host {record.target.awx_host_id} · gen {record.target.membership_generation}
                  </code>
                  <span class="block text-xs text-sr-muted">
                    {record.target.host_name} · {record.target.ansible_host || "no address"}
                  </span>
                </td>
                <td>
                  <span class="text-xs">{controller_name(record.execution.controller)}</span>
                  <code class="block max-w-56 break-all text-xs text-sr-muted">
                    {record.target.controller_id} / inventory {record.target.inventory_id}
                  </code>
                </td>
                <td>
                  <code class="text-xs">
                    {record.execution.awx_job_id || "not bound"}
                  </code>
                  <span class="block text-xs text-sr-muted">controller-local</span>
                </td>
                <td class="whitespace-nowrap text-xs">
                  <.user_time
                    id={"device-ansible-operation-#{record.operation.id}-started-at"}
                    value={record.execution.started_at || record.operation.started_at}
                    timezone={@timezone}
                    style={:compact}
                  />
                </td>
                <td>
                  <.ui_button
                    navigate={~p"/ansible/operations/#{record.operation.id}"}
                    size="xs"
                    variant="ghost"
                  >
                    Evidence
                  </.ui_button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <.launch_modal
        :if={@launch_open}
        playbooks={@playbooks}
        selected_playbook_id={@selected_playbook_id}
        vars={@vars}
        var_values={@var_values}
        notice={@launch_notice}
        ready={@launch_ready}
        resolution={@launch_resolution}
        readiness={@launch_readiness}
        form={@launch_form}
      />
    </section>
    """
  end

  ## Launch modal --------------------------------------------------------------

  attr(:playbooks, :list, required: true)
  attr(:selected_playbook_id, :string, default: nil)
  attr(:vars, :list, default: [])
  attr(:var_values, :map, default: %{})
  attr(:notice, :string, default: nil)
  attr(:ready, :boolean, default: false)
  attr(:resolution, :map, default: nil)
  attr(:readiness, :string, default: nil)
  attr(:form, :any, required: true)

  defp launch_modal(assigns) do
    ~H"""
    <dialog id="device-ansible-launch" class="sr-ui-modal sr-ui-modal-open" phx-hook="DialogTopLayer">
      <div class="sr-ui-modal-box sr-ui-modal-box-md">
        <form method="dialog">
          <.ui_icon_button
            phx-click="ansible_launch_close"
            size="sm"
            variant="ghost"
            class="absolute right-2 top-2"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.ui_icon_button>
        </form>

        <div class="flex items-start gap-3">
          <div class="rounded-lg bg-sr-brand/10 p-2">
            <.icon name="hero-play" class="size-5 text-sr-brand" />
          </div>
          <div class="min-w-0 flex-1">
            <h3 class="text-lg font-semibold text-sr-ink">Launch a reviewed playbook</h3>
            <p class="text-sm text-sr-muted">
              ServiceRadar resolves the exact AWX membership again on submit.
            </p>
          </div>
        </div>

        <div :if={@notice} role="alert" class={ui_alert_class(variant: "error", class: "mt-4")}>
          <.icon name="hero-exclamation-circle" class="size-5" />
          <span class="text-sm">{@notice}</span>
        </div>

        <.form
          for={@form}
          id="device-ansible-launch-form"
          phx-change="ansible_launch_change"
          phx-submit="ansible_launch"
          class="mt-5 space-y-4"
        >
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Playbook</span>
              <span class="text-xs text-sr-muted">
                {length(@playbooks)} catalog candidate{if length(@playbooks) == 1, do: "", else: "s"}
              </span>
            </label>
            <select name="playbook_id" class={ui_field_class(class: "w-full")}>
              <option value="" disabled selected={is_nil(@selected_playbook_id)}>
                — pick a playbook —
              </option>
              <option
                :for={playbook <- @playbooks}
                value={playbook.id}
                selected={playbook.id == @selected_playbook_id}
              >
                {playbook.name}
              </option>
            </select>
            <p :if={@playbooks == []} class="text-xs text-sr-muted mt-2">
              No launchable playbooks are bound to this device's AWX controller.
            </p>
          </div>

          <div
            :if={@selected_playbook_id}
            id="device-ansible-launch-readiness"
            role="status"
            class={[
              "alert",
              if(@ready, do: "alert-success", else: "alert-warning")
            ]}
          >
            <.icon
              name={if(@ready, do: "hero-check-circle", else: "hero-shield-exclamation")}
              class="size-5"
            />
            <div class="min-w-0">
              <p class="text-sm font-medium">{@readiness}</p>
              <div :if={@ready and @resolution} class="mt-1 flex flex-wrap gap-1.5">
                <.ui_badge size="sm" variant="success">Binding approved</.ui_badge>
                <.ui_badge size="sm" variant="success">Target ready</.ui_badge>
                <.ui_badge size="sm" variant="ghost">
                  Inventory {resolution_value(@resolution, :inventory_id)}
                </.ui_badge>
                <.ui_badge size="sm" variant="ghost">
                  Binding v{resolution_value(@resolution, :binding_version)}
                </.ui_badge>
              </div>
            </div>
          </div>

          <div :if={@vars != []} class="space-y-3">
            <h4 class="text-sm font-medium">Reviewed inputs</h4>
            <p class="text-xs text-sr-muted">
              Only non-secret fields declared by the approved binding are accepted.
            </p>
            <.var_input
              :for={var <- @vars}
              var={var}
              value={Map.get(@var_values, var.name)}
              name={"inputs[#{var.name}]"}
            />
          </div>

          <div :if={@vars == [] and @selected_playbook_id} class="text-xs text-sr-muted">
            This reviewed binding declares no operator inputs. Credentials remain pre-bound in AWX.
          </div>

          <div class="sr-ui-modal-action">
            <.ui_button type="button" phx-click="ansible_launch_close" size="sm" variant="ghost">
              Cancel
            </.ui_button>
            <.ui_button
              type="submit"
              disabled={is_nil(@selected_playbook_id) or @playbooks == [] or not @ready}
              size="sm"
              variant="primary"
            >
              <.icon name="hero-play" class="size-4" /> Launch
            </.ui_button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="sr-ui-modal-backdrop">
        <button phx-click="ansible_launch_close">close</button>
      </form>
    </dialog>
    """
  end

  ## Variable inputs -----------------------------------------------------------

  @doc """
  Typed input for a single `%Var{}` in the reviewed Ansible launch form.

  `name` overrides the HTML field name so a caller can namespace the inputs
  (e.g. `action[vars][hostname]`); it defaults to the bare variable name.
  """
  attr :var, :any, required: true
  attr :value, :any, default: nil
  attr :name, :string, default: nil

  def var_input(%{var: %Var{type: :textarea}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">{@var.label}</span>
        <span :if={@var.required} class="text-xs text-sr-muted text-error">required</span>
      </label>
      <textarea
        name={field_name(@var, @name)}
        rows="3"
        class={ui_field_class(class: "min-h-24 py-2.5 text-sm")}
      >{@value}</textarea>
    </div>
    """
  end

  def var_input(%{var: %Var{type: :password}} = assigns) do
    ~H"""
    <div role="alert" class={ui_alert_class("warning")}>
      <.icon name="hero-lock-closed" class="size-5" />
      <span class="text-sm">
        {@var.label} is a secret input and cannot be collected. Bind it to a reviewed AWX credential.
      </span>
    </div>
    """
  end

  def var_input(%{var: %Var{type: :integer}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">{@var.label}</span>
        <span :if={@var.required} class="text-xs text-sr-muted text-error">required</span>
      </label>
      <input
        type="number"
        name={field_name(@var, @name)}
        value={@value}
        min={@var.min}
        max={@var.max}
        step="1"
        class={ui_field_class(size: "sm")}
      />
    </div>
    """
  end

  def var_input(%{var: %Var{type: :float}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">{@var.label}</span>
      </label>
      <input
        type="number"
        name={field_name(@var, @name)}
        value={@value}
        step="any"
        class={ui_field_class(size: "sm")}
      />
    </div>
    """
  end

  def var_input(%{var: %Var{type: :select}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">{@var.label}</span>
      </label>
      <select name={field_name(@var, @name)} class={ui_field_class(size: "sm")}>
        <option value="" selected={is_nil(@value) or @value == ""}>—</option>
        <option :for={choice <- @var.choices} value={choice} selected={@value == choice}>
          {choice}
        </option>
      </select>
    </div>
    """
  end

  def var_input(%{var: %Var{type: :multiselect}} = assigns) do
    selected = if is_list(assigns.value), do: assigns.value, else: []
    assigns = assign(assigns, :selected_choices, selected)

    ~H"""
    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">{@var.label}</span>
        <span class="text-xs text-sr-muted">tick all that apply</span>
      </label>
      <div class="flex flex-wrap gap-3 px-1">
        <label :for={choice <- @var.choices} class="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            name={"#{field_name(@var, @name)}[]"}
            value={choice}
            checked={choice in @selected_choices}
            class={ui_checkbox_class()}
          />
          {choice}
        </label>
      </div>
    </div>
    """
  end

  def var_input(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">{@var.label}</span>
        <span :if={@var.required} class="text-xs text-sr-muted text-error">required</span>
      </label>
      <input
        type="text"
        name={field_name(@var, @name)}
        value={@value}
        class={ui_field_class(size: "sm")}
        placeholder={@var.default && to_string(@var.default)}
      />
    </div>
    """
  end

  ## Helpers -------------------------------------------------------------------

  defp field_name(%Var{name: name}, nil), do: name
  defp field_name(_var, name) when is_binary(name), do: name

  defp resolution_value(resolution, key) when is_map(resolution) do
    Map.get(resolution, key) || Map.get(resolution, to_string(key)) || "—"
  end

  defp launch_disabled_reason(true, _controller_id), do: nil
  defp launch_disabled_reason(false, nil), do: "This device isn't bound to an AWX controller."
  defp launch_disabled_reason(false, _controller_id), do: "No launchable playbooks for this device's AWX controller."

  defp controller_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp controller_name(_controller), do: "Controller"

  defp short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8) <> "…"

  defp short_id(id), do: to_string(id)

  defp state_badge_variant(:succeeded), do: "success"
  defp state_badge_variant(:partial), do: "warning"
  defp state_badge_variant(:failed), do: "error"
  defp state_badge_variant(:unreachable), do: "error"
  defp state_badge_variant(:canceled), do: "ghost"
  defp state_badge_variant(:running), do: "info"
  defp state_badge_variant(:launching), do: "info"
  defp state_badge_variant(:scope_verified), do: "info"
  defp state_badge_variant(:dispatching), do: "info"
  defp state_badge_variant(:dispatch_partial), do: "warning"
  defp state_badge_variant(:dispatch_ambiguous), do: "error"
  defp state_badge_variant(:cancel_failed), do: "error"
  defp state_badge_variant(:pending), do: "ghost"
  defp state_badge_variant(_), do: "ghost"

  defp target_badge_variant(:ok), do: "success"
  defp target_badge_variant(:failed), do: "error"
  defp target_badge_variant(:unreachable), do: "error"
  defp target_badge_variant(:scope_mismatch), do: "error"
  defp target_badge_variant(:canceled), do: "ghost"
  defp target_badge_variant(:skipped), do: "ghost"
  defp target_badge_variant(:pending), do: "ghost"
  defp target_badge_variant(_), do: "ghost"
end
