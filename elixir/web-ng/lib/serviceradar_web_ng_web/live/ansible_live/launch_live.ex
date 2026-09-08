defmodule ServiceRadarWebNGWeb.AnsibleLive.LaunchLive do
  @moduledoc """
  ServiceRadar-owned launch surface for reviewed AWX playbooks.

  The page accepts canonical device UIDs from the authenticated inventory UI.
  Selection readiness and submit both go through `SecureLaunchService`; submit
  resolves current approved memberships and the current approved binding again.
  The browser never supplies AWX membership IDs, host limits, credentials,
  callback policy, raw `extra_vars`, or secret inputs.
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Automation.Ansible.AutomationOperation

  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.Ansible.SecureLaunchService
  alias ServiceRadar.Automation.Ansible.VariableSchema.Var
  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelComponents
  alias ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelRuntime

  require Logger

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{
      "validate" => :create,
      "launch" => :create
    })
  end

  @impl true
  def skip_preload, do: [:new, :create]

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "ansible.runs.launch") do
      device_uids = parse_device_uids(params["devices"])

      socket =
        socket
        |> assign(:page_title, "Launch Ansible playbook")
        |> assign(:requested_uids, device_uids)
        |> assign(:devices, [])
        |> assign(:playbooks, [])
        |> assign(:selected_playbook_id, nil)
        |> assign(:vars, [])
        |> assign(:var_values, %{})
        |> assign(:launch_ready, false)
        |> assign(:launch_resolution, nil)
        |> assign(
          :launch_readiness,
          "Select a playbook to verify its reviewed binding and exact target memberships."
        )
        |> assign(:launch_in_progress, false)
        |> assign(:form, to_form(%{}))

      socket =
        if connected?(socket) do
          socket
          |> assign(:devices, load_devices(device_uids, scope))
          |> assign(:playbooks, launchable_awx_playbooks(scope))
        else
          socket
        end

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to launch Ansible operations.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("validate", params, socket) do
    playbook_id = params["playbook_id"] || socket.assigns.selected_playbook_id
    input_params = input_params(params)

    socket =
      assign(
        socket,
        :var_values,
        Map.merge(socket.assigns.var_values, values_from_params(socket.assigns.vars, input_params))
      )

    socket =
      if playbook_id == socket.assigns.selected_playbook_id do
        socket
      else
        prepare_launch(socket, playbook_id)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("launch", params, socket) do
    playbook_id = params["playbook_id"] || socket.assigns.selected_playbook_id

    if blank?(playbook_id) do
      {:noreply, put_flash(socket, :error, "Pick a playbook before launching.")}
    else
      do_launch(socket, playbook_id, input_params(params))
    end
  end

  defp do_launch(socket, playbook_id, inputs) do
    scope = socket.assigns.current_scope

    case SecureLaunchService.launch(
           scope.user,
           socket.assigns.requested_uids,
           playbook_id,
           inputs,
           mode: :run,
           request_source: :ansible_launch_live
         ) do
      {:ok, result} ->
        socket =
          socket
          |> reset_selection()
          |> assign(:launch_in_progress, false)
          |> put_flash(:info, secure_launch_success(result))

        {:noreply, navigate_to_operation(socket, result)}

      {:error, reason} ->
        Logger.info("Ansible launch failed", SafeFailureEvidence.log_metadata(reason))

        {:noreply,
         socket
         |> assign(:launch_in_progress, false)
         |> assign(:launch_ready, false)
         |> assign(:launch_readiness, launch_error_message(reason))
         |> put_flash(:error, launch_error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/ansible/launch"
      page_title={@page_title}
      shell={:operations}
    >
      <div class="mx-auto w-full max-w-5xl space-y-6 p-6">
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Launch Ansible playbook</h1>
          <p class="text-sm text-sr-muted">
            Targets and approval are resolved from durable ServiceRadar records, then checked again on submit.
          </p>
        </header>

        <section
          class="sr-ui-card card-border bg-sr-surface"
          aria-labelledby="ansible-launch-targets-title"
        >
          <div class="sr-ui-card-body gap-3">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h2 id="ansible-launch-targets-title" class="sr-ui-card-title text-base">
                Canonical targets
              </h2>
              <.ui_badge id="ansible-launch-target-count" size="sm" variant="ghost">
                {length(@requested_uids)} selected · {length(@devices)} visible
              </.ui_badge>
            </div>

            <div
              :if={@requested_uids == []}
              id="ansible-launch-no-targets"
              role="alert"
              class={ui_alert_class("warning")}
            >
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <span>Select at least one inventory device before launching.</span>
            </div>

            <div :if={@devices != []} class="overflow-x-auto">
              <table id="ansible-launch-targets" class={ui_table_class(size: "sm")}>
                <thead>
                  <tr>
                    <th>Device</th>
                    <th>Canonical UID</th>
                    <th>Inventory record</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={device <- @devices}>
                    <td>{device.hostname || "Unnamed device"}</td>
                    <td><code class="text-xs">{device.uid}</code></td>
                    <td>
                      <.ui_badge size="sm" variant="success">Resolved</.ui_badge>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>

        <section
          class="sr-ui-card card-border bg-sr-surface"
          aria-labelledby="ansible-launch-binding-title"
        >
          <div class="sr-ui-card-body gap-4">
            <div>
              <h2 id="ansible-launch-binding-title" class="sr-ui-card-title text-base">
                Reviewed launch contract
              </h2>
              <p class="text-sm text-sr-muted">
                Credentials and execution environment are pre-bound in AWX and are never collected here.
              </p>
            </div>

            <.form
              for={@form}
              id="secure-ansible-launch-form"
              phx-change="validate"
              phx-submit="launch"
              class="space-y-4"
            >
              <fieldset class="fieldset">
                <legend class="fieldset-legend">AWX playbook</legend>
                <select id="secure-ansible-playbook" name="playbook_id" class="select w-full">
                  <option value="" disabled selected={is_nil(@selected_playbook_id)}>
                    — select a catalog playbook —
                  </option>
                  <option
                    :for={playbook <- @playbooks}
                    value={playbook.id}
                    selected={playbook.id == @selected_playbook_id}
                  >
                    {playbook.name}
                  </option>
                </select>
                <p class="flex items-center justify-between gap-2">
                  Selection is not authority; the current binding and memberships are resolved server-side.
                </p>
              </fieldset>

              <div
                :if={@selected_playbook_id}
                id="secure-ansible-launch-readiness"
                role="status"
                class={[
                  "alert",
                  if(@launch_ready, do: "alert-success", else: "alert-warning")
                ]}
              >
                <.icon
                  name={if(@launch_ready, do: "hero-check-circle", else: "hero-shield-exclamation")}
                  class="size-5"
                />
                <div class="min-w-0">
                  <p class="text-sm font-medium">{@launch_readiness}</p>
                  <div :if={@launch_ready and @launch_resolution} class="mt-1 flex flex-wrap gap-1.5">
                    <.ui_badge size="sm" variant="success">Binding approved</.ui_badge>
                    <.ui_badge size="sm" variant="success">
                      {length(@launch_resolution.membership_ids)} exact target{if length(
                                                                                    @launch_resolution.membership_ids
                                                                                  ) == 1,
                                                                                  do: "",
                                                                                  else: "s"}
                    </.ui_badge>
                    <.ui_badge size="sm" variant="ghost">
                      Inventory {@launch_resolution.inventory_id}
                    </.ui_badge>
                    <.ui_badge size="sm" variant="ghost">
                      Binding v{@launch_resolution.binding_version}
                    </.ui_badge>
                  </div>
                </div>
              </div>

              <div :if={@vars != []} class="space-y-3">
                <div>
                  <h3 class="text-sm font-medium">Reviewed inputs</h3>
                  <p class="text-xs text-sr-muted">
                    Only typed, non-secret fields declared by the approved binding are accepted.
                  </p>
                </div>
                <AnsiblePanelComponents.var_input
                  :for={var <- @vars}
                  var={var}
                  value={Map.get(@var_values, var.name)}
                  name={"inputs[#{var.name}]"}
                />
              </div>

              <div
                :if={not is_nil(@selected_playbook_id) and @launch_ready and @vars == []}
                class={ui_alert_class("info")}
              >
                <.icon name="hero-information-circle" class="size-5" />
                <span>This binding declares no operator inputs.</span>
              </div>

              <div class="card-actions items-center justify-between pt-2">
                <.link
                  navigate={~p"/ansible/operations"}
                  class="text-sr-brand hover:underline text-sm"
                >
                  Operation history
                </.link>
                <.ui_button
                  id="secure-ansible-launch-submit"
                  type="submit"
                  disabled={not @launch_ready or @launch_in_progress}
                  size="sm"
                  variant="primary"
                >
                  <.icon name="hero-play" class="size-4" /> Launch
                </.ui_button>
              </div>
            </.form>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp prepare_launch(socket, playbook_id) do
    case SecureLaunchService.prepare(
           socket.assigns.current_scope.user,
           socket.assigns.requested_uids,
           playbook_id
         ) do
      {:ok, resolution} ->
        ready? = resolution.run_mode_supported == true

        socket
        |> assign(:selected_playbook_id, playbook_id)
        |> assign(:vars, resolution.variables)
        |> assign(:var_values, %{})
        |> assign(:launch_ready, ready?)
        |> assign(:launch_resolution, resolution)
        |> assign(
          :launch_readiness,
          if(ready?,
            do: "Reviewed binding and exact target memberships are ready.",
            else: "This binding is not approved for run mode."
          )
        )

      {:error, reason} ->
        socket
        |> assign(:selected_playbook_id, playbook_id)
        |> assign(:vars, [])
        |> assign(:var_values, %{})
        |> assign(:launch_ready, false)
        |> assign(:launch_resolution, nil)
        |> assign(:launch_readiness, launch_error_message(reason))
    end
  end

  defp reset_selection(socket) do
    socket
    |> assign(:selected_playbook_id, nil)
    |> assign(:vars, [])
    |> assign(:var_values, %{})
    |> assign(:launch_ready, false)
    |> assign(:launch_resolution, nil)
    |> assign(
      :launch_readiness,
      "Select a playbook to verify its reviewed binding and exact target memberships."
    )
  end

  defp input_params(%{"inputs" => inputs}) when is_map(inputs), do: inputs
  defp input_params(_params), do: %{}

  defp values_from_params(vars, params) when is_list(vars) and is_map(params) do
    Enum.reduce(vars, %{}, fn %Var{name: name}, acc ->
      case Map.fetch(params, name) do
        {:ok, value} -> Map.put(acc, name, value)
        :error -> acc
      end
    end)
  end

  defp parse_device_uids(nil), do: []
  defp parse_device_uids(""), do: []

  defp parse_device_uids(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_device_uids(_raw), do: []

  defp load_devices(device_uids, scope) do
    device_uids
    |> Enum.map(fn device_uid ->
      case Device.get_by_uid(device_uid, false, scope: scope) do
        {:ok, device} -> device
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp launchable_awx_playbooks(scope) do
    case Playbook.list_launchable(%{}, scope: scope) do
      {:ok, playbooks} ->
        Enum.filter(playbooks, fn playbook ->
          playbook.source_type == :awx and playbook.parse_status == :ok
        end)

      _ ->
        []
    end
  end

  defp launch_error_message(reason), do: AnsiblePanelRuntime.launch_error_message(reason)

  defp secure_launch_success(%{operation: %{id: id}}) when is_binary(id), do: "Launch dispatched as operation #{id}."

  defp secure_launch_success(_result), do: "Launch dispatched."

  defp navigate_to_operation(socket, %{operation: %{id: id}}) when is_binary(id),
    do: push_navigate(socket, to: ~p"/ansible/operations/#{id}")

  defp navigate_to_operation(socket, _result), do: push_navigate(socket, to: ~p"/ansible/operations")

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
