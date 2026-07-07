defmodule ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelRuntime do
  @moduledoc """
  Device-detail Ansible panel: AWX-managed detection, run-history loading,
  and the in-page launch modal.

  A device is "AWX-managed" when the AWX inventory sync has stamped
  `metadata.awx.*` onto it (the same signal `RunLauncher` uses to derive the
  ansible inventory ref). `metadata.awx.controller_id` is the AWX controller
  the device belongs to; only playbooks bound to that controller's job
  templates are launchable against it.

  Reads and launches go through Ash with a `SystemActor` — mirroring the
  existing `AnsibleLive.LaunchLive` / `RunsIndex` pages — while the human
  operator is gated up-front with `RBAC.can?/2` and recorded on the run via
  `requested_by_actor_id`. `RunLauncher` internally reads the AWX `Controller`
  (which requires a manage permission most launchers lack), so a `SystemActor`
  is the correct actor for the dispatch path.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.PlaybookRunTarget
  alias ServiceRadar.Automation.Ansible.RunLauncher
  alias ServiceRadar.Automation.Ansible.VariableSchema
  alias ServiceRadar.Automation.Ansible.VariableSchema.Var
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceStateData

  require Ash.Query
  require Logger

  @actor_name :device_ansible_panel
  @runs_limit 50
  @playbooks_limit 200

  ## Defaults ------------------------------------------------------------------

  @doc "Seed the panel + launch-modal assigns with safe defaults."
  def assign_defaults(socket) do
    socket
    |> assign(:device_awx_managed, false)
    |> assign(:can_view_ansible_runs, false)
    |> assign(:ansible_controller_id, nil)
    |> assign(:ansible_runs, [])
    |> assign(:ansible_playbooks, [])
    |> reset_launch_modal()
  end

  defp reset_launch_modal(socket) do
    socket
    |> assign(:ansible_launch_open, false)
    |> assign(:ansible_selected_playbook_id, nil)
    |> assign(:ansible_vars, [])
    |> assign(:ansible_var_values, %{})
    |> assign(:ansible_launch_notice, nil)
  end

  ## Detection -----------------------------------------------------------------

  @doc """
  Whether the device is a member of an AWX inventory (and therefore has an
  Ansible panel). Prefers the authoritative `metadata.awx.host_id` the backend
  uses, and falls back to the legacy `ansible_managed` flag / `awx` discovery
  source so the panel still surfaces on older rows.
  """
  def awx_managed?(device_row) when is_map(device_row) do
    not is_nil(awx_host_id(device_row)) or
      DeviceStateData.ansible_managed?(device_row) or
      awx_discovery_source?(device_row)
  end

  def awx_managed?(_), do: false

  @doc "AWX controller id the device is bound to, or nil."
  def awx_controller_id(device_row) do
    ref = awx_ref(device_row)
    value = Map.get(ref, "controller_id") || Map.get(ref, :controller_id)
    if is_binary(value) and value != "", do: value
  end

  defp awx_host_id(device_row) do
    ref = awx_ref(device_row)
    Map.get(ref, "host_id") || Map.get(ref, :host_id)
  end

  defp awx_ref(device_row) when is_map(device_row) do
    metadata =
      case Map.get(device_row, "metadata") || Map.get(device_row, :metadata) do
        map when is_map(map) -> map
        _ -> %{}
      end

    case Map.get(metadata, "awx") || Map.get(metadata, :awx) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp awx_ref(_), do: %{}

  defp awx_discovery_source?(device_row) do
    device_row
    |> discovery_sources()
    |> Enum.any?(&(&1 in ["awx", "ansible"]))
  end

  defp discovery_sources(device_row) do
    case Map.get(device_row, "discovery_sources") || Map.get(device_row, :discovery_sources) do
      list when is_list(list) ->
        Enum.map(list, &normalize_source/1)

      raw when is_binary(raw) ->
        raw
        |> String.trim_leading("{")
        |> String.trim_trailing("}")
        |> String.split(",")
        |> Enum.map(&normalize_source/1)

      _ ->
        []
    end
  end

  defp normalize_source(value) do
    value |> to_string() |> String.trim() |> String.trim("\"") |> String.downcase()
  end

  ## Loading -------------------------------------------------------------------

  @doc """
  Populate the panel assigns for a freshly loaded device. On a background
  refresh the in-flight launch modal is preserved; on a full (device-switch)
  load it is reset.
  """
  def assign_device_ansible(socket, device_row, uid, scope, refresh?) do
    can_view? = RBAC.can?(scope, "ansible.runs.view")
    managed? = awx_managed?(device_row)
    controller_id = awx_controller_id(device_row)

    runs = if managed? and can_view?, do: load_runs(uid), else: []
    playbooks = if managed? and RBAC.can?(scope, "ansible.runs.launch"), do: load_playbooks(controller_id), else: []

    socket =
      socket
      |> assign(:device_awx_managed, managed?)
      |> assign(:can_view_ansible_runs, can_view?)
      |> assign(:ansible_controller_id, controller_id)
      |> assign(:ansible_runs, runs)
      |> assign(:ansible_playbooks, playbooks)

    if refresh?, do: socket, else: reset_launch_modal(socket)
  end

  @doc "Reload just the run history (used on Ansible PubSub updates)."
  def refresh_runs(socket) do
    if socket.assigns[:device_awx_managed] and socket.assigns[:can_view_ansible_runs] do
      assign(socket, :ansible_runs, load_runs(socket.assigns.device_uid))
    else
      socket
    end
  end

  defp load_runs(uid) when is_binary(uid) do
    case PlaybookRunTarget.list_for_device(uid, actor: actor()) do
      {:ok, targets} -> Enum.take(targets, @runs_limit)
      _ -> []
    end
  end

  defp load_runs(_), do: []

  defp load_playbooks(controller_id) when is_binary(controller_id) do
    query =
      Playbook
      |> Ash.Query.filter(controller_id == ^controller_id and not is_nil(awx_job_template_id))
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(@playbooks_limit)

    case Ash.read(query, actor: actor()) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp load_playbooks(_), do: []

  ## Launch modal --------------------------------------------------------------

  def open_launch(socket) do
    if RBAC.can?(socket.assigns.current_scope, "ansible.runs.launch") do
      socket
      |> assign(:ansible_launch_open, true)
      |> assign(:ansible_launch_notice, nil)
    else
      socket
    end
  end

  def close_launch(socket), do: reset_launch_modal(socket)

  @doc "phx-change on the launch form: track selection + typed values."
  def change_launch(socket, params) do
    playbook_id = params["playbook_id"] || socket.assigns.ansible_selected_playbook_id

    socket =
      assign(
        socket,
        :ansible_var_values,
        Map.merge(socket.assigns.ansible_var_values, var_values_from_params(socket.assigns.ansible_vars, params))
      )

    if playbook_id == socket.assigns.ansible_selected_playbook_id do
      socket
    else
      playbook = Enum.find(socket.assigns.ansible_playbooks, &(&1.id == playbook_id))
      vars = if playbook, do: VariableSchema.from_playbook(playbook), else: []

      socket
      |> assign(:ansible_selected_playbook_id, playbook_id)
      |> assign(:ansible_vars, vars)
      |> assign(:ansible_var_values, defaults_for(vars))
    end
  end

  def launch(socket, params) do
    scope = socket.assigns.current_scope

    cond do
      not RBAC.can?(scope, "ansible.runs.launch") ->
        put_flash(socket, :error, "You don't have permission to launch Ansible runs.")

      blank?(params["playbook_id"]) ->
        assign(socket, :ansible_launch_notice, "Pick a playbook before launching.")

      true ->
        do_launch(socket, params["playbook_id"], params)
    end
  end

  defp do_launch(socket, playbook_id, params) do
    scope = socket.assigns.current_scope
    extra_vars = VariableSchema.extra_vars_from_form(socket.assigns.ansible_vars, params)

    intent = %{
      playbook_id: playbook_id,
      device_uids: [socket.assigns.device_uid],
      extra_vars: extra_vars,
      requested_by_actor_id: actor_id(scope)
    }

    case RunLauncher.launch(intent, actor: actor()) do
      {:ok, _run} ->
        socket
        |> reset_launch_modal()
        |> put_flash(:info, "Launch dispatched — the run will appear in the history below.")
        |> refresh_runs()

      {:error, reason} ->
        Logger.info("Device Ansible launch failed", reason: inspect(reason))
        assign(socket, :ansible_launch_notice, launch_error_message(reason))
    end
  end

  ## Helpers -------------------------------------------------------------------

  defp actor, do: SystemActor.system(@actor_name)

  defp actor_id(%{user: %{id: id}}), do: id
  defp actor_id(_), do: nil

  defp var_values_from_params(vars, params) when is_list(vars) and is_map(params) do
    Enum.reduce(vars, %{}, fn %Var{name: name}, acc ->
      case Map.get(params, name) do
        nil -> acc
        value -> Map.put(acc, name, value)
      end
    end)
  end

  defp var_values_from_params(_vars, _params), do: %{}

  defp defaults_for(vars) do
    Enum.reduce(vars, %{}, fn %Var{} = var, acc ->
      case var.default do
        nil -> acc
        default -> Map.put(acc, var.name, to_string_default(default))
      end
    end)
  end

  defp to_string_default(value) when is_binary(value), do: value
  defp to_string_default(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp to_string_default(true), do: "true"
  defp to_string_default(false), do: "false"
  defp to_string_default(value), do: inspect(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  @doc false
  def launch_error_message(:devices_required), do: "This device isn't in an AWX inventory."
  def launch_error_message(:unmanaged_devices), do: "This device isn't ansible-managed."

  def launch_error_message(:mixed_controllers), do: "This device spans multiple AWX controllers."

  def launch_error_message(:unknown_playbook), do: "Playbook not found."
  def launch_error_message(:unknown_controller), do: "AWX controller not found."
  def launch_error_message(:playbook_unbound), do: "Playbook isn't bound to an AWX job template."

  def launch_error_message(:git_sourced_not_supported_v1),
    do: "Git-sourced playbooks need an AWX template binding before they're launchable."

  def launch_error_message(other), do: String.slice("Launch failed: #{inspect(other)}", 0, 240)
end
