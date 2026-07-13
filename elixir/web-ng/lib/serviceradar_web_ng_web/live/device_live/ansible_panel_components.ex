defmodule ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelComponents do
  @moduledoc """
  Device-detail Ansible panel: run history for the device plus an in-page
  launch modal (playbook picker + typed variable form).

  Rendered only for AWX-managed devices. Reads/launch dispatch live in
  `AnsiblePanelRuntime`; this module is presentation only.
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Automation.Ansible.VariableSchema.Var

  attr(:device_uid, :string, required: true)
  attr(:device_awx_managed, :boolean, default: false)
  attr(:can_view_ansible_runs, :boolean, default: false)
  attr(:can_run_ansible, :boolean, default: false)
  attr(:device_deleted, :boolean, default: false)
  attr(:ansible_controller_id, :string, default: nil)
  attr(:secure_history, :list, default: [])
  attr(:runs, :list, default: [])
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

  def ansible_runs_section(assigns) do
    assigns =
      assigns
      |> assign(:launchable?, assigns.can_run_ansible and not assigns.device_deleted and assigns.playbooks != [])
      |> assign(:has_secure_history, assigns.secure_history != [])
      |> assign(:has_legacy_runs, assigns.runs != [])
      |> assign(:has_history, assigns.secure_history != [] or assigns.runs != [])

    ~H"""
    <section
      :if={@device_awx_managed and @can_view_ansible_runs}
      class="rounded-xl border border-base-200 bg-base-100"
      data-testid="device-ansible-panel"
    >
      <div class="flex flex-wrap items-center justify-between gap-2 border-b border-base-200 px-4 py-3">
        <div class="flex items-center gap-2">
          <span class="rounded-lg bg-primary/10 p-1.5">
            <.icon name="hero-command-line" class="size-4 text-primary" />
          </span>
          <div>
            <h2 class="text-sm font-semibold text-base-content">Ansible</h2>
            <p class="text-xs text-base-content/60">
              AWX inventory member · secure operations and legacy run history
            </p>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/ansible/operations"}
            class="link link-hover text-xs text-base-content/60"
          >
            Secure operations
          </.link>
          <.link navigate={~p"/ansible/runs"} class="link link-hover text-xs text-base-content/60">
            Legacy runs
          </.link>
          <button
            :if={@can_run_ansible and not @device_deleted}
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="ansible_launch_open"
            disabled={not @launchable?}
            title={launch_disabled_reason(@launchable?, @ansible_controller_id)}
          >
            <.icon name="hero-play" class="size-4" /> Run Task
          </button>
        </div>
      </div>

      <div :if={not @has_history} class="px-4 py-6 text-sm text-base-content/60">
        No playbook runs have targeted this device yet.
        <span :if={@can_run_ansible and @playbooks == []} class="block text-xs mt-1">
          No launchable playbooks are bound to this device's AWX controller.
        </span>
      </div>

      <div :if={@has_secure_history} class="border-b border-base-200">
        <div class="flex flex-wrap items-center justify-between gap-2 px-4 py-3">
          <div>
            <h3 class="text-sm font-semibold">Secure operation history</h3>
            <p class="text-xs text-base-content/60">
              Immutable controller, inventory, and AWX host identity.
            </p>
          </div>
          <span class="badge badge-success badge-sm">ServiceRadar secured</span>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm" data-testid="device-secure-ansible-history">
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
              <tr :for={record <- @secure_history}>
                <td>
                  <span class={["badge badge-sm", state_badge_class(record.operation.state)]}>
                    {record.operation.state}
                  </span>
                  <code class="mt-1 block text-xs">{short_id(record.operation.id)}</code>
                </td>
                <td>
                  <span class={["badge badge-sm", state_badge_class(record.execution.state)]}>
                    {record.execution.state}
                  </span>
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
                    <span class={["badge badge-sm", target_badge_class(record.target.status)]}>
                      {record.target.status}
                    </span>
                    <span :if={record.target.active_hold} class="badge badge-error badge-sm">
                      hold active
                    </span>
                  </div>
                  <code class="mt-1 block text-xs">
                    host {record.target.awx_host_id} · gen {record.target.membership_generation}
                  </code>
                  <span class="block text-xs text-base-content/60">
                    {record.target.host_name} · {record.target.ansible_host || "no address"}
                  </span>
                </td>
                <td>
                  <span class="text-xs">{controller_name(record.execution.controller)}</span>
                  <code class="block max-w-56 break-all text-xs text-base-content/60">
                    {record.target.controller_id} / inventory {record.target.inventory_id}
                  </code>
                </td>
                <td>
                  <code class="text-xs">
                    {record.execution.awx_job_id || "not bound"}
                  </code>
                  <span class="block text-xs text-base-content/60">controller-local</span>
                </td>
                <td class="whitespace-nowrap text-xs">
                  {fmt_ts(record.execution.started_at || record.operation.started_at)}
                </td>
                <td>
                  <.link
                    navigate={~p"/ansible/operations/#{record.operation.id}"}
                    class="btn btn-ghost btn-xs"
                  >
                    Evidence
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div :if={@has_legacy_runs}>
        <div class="flex flex-wrap items-center justify-between gap-2 px-4 py-3">
          <div>
            <h3 class="text-sm font-semibold">Legacy PlaybookRun history</h3>
            <p class="text-xs text-base-content/60">
              Pre-hardening task/event records; not secure operation evidence.
            </p>
          </div>
          <span class="badge badge-outline badge-sm">Legacy</span>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Playbook</th>
                <th>Run</th>
                <th>Host result</th>
                <th>Tasks</th>
                <th>Started</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={target <- @runs}>
                <td class="max-w-[16rem] truncate" title={playbook_name(target)}>
                  {playbook_name(target)}
                </td>
                <td>
                  <span class={["badge badge-sm", state_badge_class(run_state(target))]}>
                    {run_state(target)}
                  </span>
                </td>
                <td>
                  <span class={["badge badge-sm", target_badge_class(target.status)]}>
                    {target.status}
                  </span>
                </td>
                <td class="whitespace-nowrap text-xs text-base-content/70">
                  <span class="text-success">{target.ok_count} ok</span>
                  <span :if={target.changed_count > 0} class="text-warning">
                    · {target.changed_count} chg
                  </span>
                  <span :if={target.failed_count > 0} class="text-error">
                    · {target.failed_count} fail
                  </span>
                  <span :if={target.unreachable_count > 0} class="text-error">
                    · {target.unreachable_count} unreachable
                  </span>
                </td>
                <td class="whitespace-nowrap text-xs">
                  {fmt_ts(target.started_at || target.inserted_at)}
                </td>
                <td>
                  <.link
                    :if={run_id(target)}
                    navigate={~p"/ansible/runs/#{run_id(target)}"}
                    class="btn btn-ghost btn-xs"
                  >
                    View
                  </.link>
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
    <dialog id="device-ansible-launch" class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="ansible_launch_close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </form>

        <div class="flex items-start gap-3">
          <div class="rounded-lg bg-primary/10 p-2">
            <.icon name="hero-play" class="size-5 text-primary" />
          </div>
          <div class="min-w-0 flex-1">
            <h3 class="text-lg font-semibold text-base-content">Launch a reviewed playbook</h3>
            <p class="text-sm text-base-content/60">
              ServiceRadar resolves the exact AWX membership again on submit.
            </p>
          </div>
        </div>

        <div :if={@notice} role="alert" class="alert alert-error mt-4">
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
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Playbook</span>
              <span class="label-text-alt text-xs text-base-content/60">
                {length(@playbooks)} catalog candidate{if length(@playbooks) == 1, do: "", else: "s"}
              </span>
            </label>
            <select name="playbook_id" class="select select-bordered w-full">
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
            <p :if={@playbooks == []} class="text-xs text-base-content/60 mt-2">
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
                <span class="badge badge-success badge-sm">Binding approved</span>
                <span class="badge badge-success badge-sm">Target ready</span>
                <span class="badge badge-ghost badge-sm">
                  Inventory {resolution_value(@resolution, :inventory_id)}
                </span>
                <span class="badge badge-ghost badge-sm">
                  Binding v{resolution_value(@resolution, :binding_version)}
                </span>
              </div>
            </div>
          </div>

          <div :if={@vars != []} class="space-y-3">
            <h4 class="text-sm font-medium">Reviewed inputs</h4>
            <p class="text-xs text-base-content/60">
              Only non-secret fields declared by the approved binding are accepted.
            </p>
            <.var_input
              :for={var <- @vars}
              var={var}
              value={Map.get(@var_values, var.name)}
              name={"inputs[#{var.name}]"}
            />
          </div>

          <div :if={@vars == [] and @selected_playbook_id} class="text-xs text-base-content/60">
            This reviewed binding declares no operator inputs. Credentials remain pre-bound in AWX.
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="ansible_launch_close">
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary"
              disabled={is_nil(@selected_playbook_id) or @playbooks == [] or not @ready}
            >
              <.icon name="hero-play" class="size-4" /> Launch
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="ansible_launch_close">close</button>
      </form>
    </dialog>
    """
  end

  ## Variable inputs -----------------------------------------------------------

  @doc """
  Typed input for a single `%Var{}`. Shared with the bulk Devices "Run Task"
  modal so both ansible surfaces render identical variable forms.

  `name` overrides the HTML field name so a caller can namespace the inputs
  (e.g. `action[vars][hostname]`); it defaults to the bare variable name.
  """
  attr :var, :any, required: true
  attr :value, :any, default: nil
  attr :name, :string, default: nil

  def var_input(%{var: %Var{type: :textarea}} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text">{@var.label}</span>
        <span :if={@var.required} class="label-text-alt text-xs text-error">required</span>
      </label>
      <textarea name={field_name(@var, @name)} rows="3" class="textarea textarea-bordered text-sm">{@value}</textarea>
    </div>
    """
  end

  def var_input(%{var: %Var{type: :password}} = assigns) do
    ~H"""
    <div role="alert" class="alert alert-warning">
      <.icon name="hero-lock-closed" class="size-5" />
      <span class="text-sm">
        {@var.label} is a secret input and cannot be collected. Bind it to a reviewed AWX credential.
      </span>
    </div>
    """
  end

  def var_input(%{var: %Var{type: :integer}} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text">{@var.label}</span>
        <span :if={@var.required} class="label-text-alt text-xs text-error">required</span>
      </label>
      <input
        type="number"
        name={field_name(@var, @name)}
        value={@value}
        min={@var.min}
        max={@var.max}
        step="1"
        class="input input-bordered input-sm"
      />
    </div>
    """
  end

  def var_input(%{var: %Var{type: :float}} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label"><span class="label-text">{@var.label}</span></label>
      <input
        type="number"
        name={field_name(@var, @name)}
        value={@value}
        step="any"
        class="input input-bordered input-sm"
      />
    </div>
    """
  end

  def var_input(%{var: %Var{type: :select}} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label"><span class="label-text">{@var.label}</span></label>
      <select name={field_name(@var, @name)} class="select select-bordered select-sm">
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
    <div class="form-control">
      <label class="label">
        <span class="label-text">{@var.label}</span>
        <span class="label-text-alt text-xs text-base-content/60">tick all that apply</span>
      </label>
      <div class="flex flex-wrap gap-3 px-1">
        <label :for={choice <- @var.choices} class="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            name={"#{field_name(@var, @name)}[]"}
            value={choice}
            checked={choice in @selected_choices}
            class="checkbox checkbox-sm"
          />
          {choice}
        </label>
      </div>
    </div>
    """
  end

  def var_input(assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text">{@var.label}</span>
        <span :if={@var.required} class="label-text-alt text-xs text-error">required</span>
      </label>
      <input
        type="text"
        name={field_name(@var, @name)}
        value={@value}
        class="input input-bordered input-sm"
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

  defp playbook_name(%{run: %{playbook: %{name: name}}}) when is_binary(name), do: name
  defp playbook_name(_), do: "—"

  defp run_state(%{run: %{state: state}}), do: state
  defp run_state(_), do: :pending

  defp run_id(%{run: %{id: id}}) when is_binary(id), do: id
  defp run_id(_), do: nil

  defp controller_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp controller_name(_controller), do: "Controller"

  defp short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8) <> "…"

  defp short_id(id), do: to_string(id)

  defp fmt_ts(nil), do: "—"
  defp fmt_ts(%DateTime{} = ts), do: Calendar.strftime(ts, "%Y-%m-%d %H:%M")
  defp fmt_ts(_), do: "—"

  defp state_badge_class(:succeeded), do: "badge-success"
  defp state_badge_class(:partial), do: "badge-warning"
  defp state_badge_class(:failed), do: "badge-error"
  defp state_badge_class(:unreachable), do: "badge-error"
  defp state_badge_class(:canceled), do: "badge-neutral"
  defp state_badge_class(:running), do: "badge-info"
  defp state_badge_class(:launching), do: "badge-info"
  defp state_badge_class(:scope_verified), do: "badge-info"
  defp state_badge_class(:dispatching), do: "badge-info"
  defp state_badge_class(:dispatch_partial), do: "badge-warning"
  defp state_badge_class(:dispatch_ambiguous), do: "badge-error"
  defp state_badge_class(:cancel_failed), do: "badge-error"
  defp state_badge_class(:pending), do: "badge-ghost"
  defp state_badge_class(_), do: "badge-ghost"

  defp target_badge_class(:ok), do: "badge-success"
  defp target_badge_class(:failed), do: "badge-error"
  defp target_badge_class(:unreachable), do: "badge-error"
  defp target_badge_class(:scope_mismatch), do: "badge-error"
  defp target_badge_class(:canceled), do: "badge-neutral"
  defp target_badge_class(:skipped), do: "badge-neutral"
  defp target_badge_class(:pending), do: "badge-ghost"
  defp target_badge_class(_), do: "badge-ghost"
end
