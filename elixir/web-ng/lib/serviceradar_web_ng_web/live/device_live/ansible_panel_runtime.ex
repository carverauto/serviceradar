defmodule ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelRuntime do
  @moduledoc """
  Device-detail Ansible panel: AWX-managed detection, operation-history loading,
  and the in-page launch modal.

  The AWX inventory metadata on a device controls panel visibility and catalog
  filtering only. The secure launch path does not derive target identity from
  that metadata; it resolves the canonical device UID to durable approved AWX
  memberships instead.

  Catalog and history reads use the authenticated human scope. Launches go
  through `SecureLaunchService`, which resolves reviewed bindings and durable
  AWX memberships again on submit before dispatch. Device metadata is display
  context only and never becomes execution identity.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 1]
  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.Ansible.SecureLaunchService
  alias ServiceRadar.Automation.Ansible.VariableSchema.Var
  alias ServiceRadarWebNG.AnsibleAutomation.History, as: AutomationHistory
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceStateData

  require Logger

  @history_limit 50

  ## Defaults ------------------------------------------------------------------

  @doc "Seed the panel + launch-modal assigns with safe defaults."
  def assign_defaults(socket) do
    socket
    |> assign(:device_awx_managed, false)
    |> assign(:can_view_ansible_operations, false)
    |> assign(:ansible_controller_id, nil)
    |> assign(:ansible_operation_history, [])
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
    |> assign(:ansible_launch_ready, false)
    |> assign(:ansible_launch_resolution, nil)
    |> assign(
      :ansible_launch_readiness,
      "Select a playbook to verify its reviewed binding and target membership."
    )
    |> assign(:ansible_launch_form, to_form(%{}))
  end

  ## Detection -----------------------------------------------------------------

  @doc """
  Whether the device is a member of an AWX inventory (and therefore has an
  Ansible panel). Prefers the authoritative `metadata.awx.host_id` the backend
  uses, and falls back to the existing `ansible_managed` flag / `awx` discovery
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

    operation_history = if managed? and can_view?, do: load_operation_history(uid, scope), else: []

    playbooks =
      if managed? and RBAC.can?(scope, "ansible.runs.launch"),
        do: load_playbooks(controller_id, scope),
        else: []

    socket =
      socket
      |> assign(:device_awx_managed, managed?)
      |> assign(:can_view_ansible_operations, can_view?)
      |> assign(:ansible_controller_id, controller_id)
      |> assign(:ansible_operation_history, operation_history)
      |> assign(:ansible_playbooks, playbooks)

    if refresh?, do: socket, else: reset_launch_modal(socket)
  end

  defp load_operation_history(uid, scope) when is_binary(uid) do
    case AutomationHistory.list_device_history(uid, scope, @history_limit) do
      {:ok, records} -> records
      _ -> []
    end
  end

  defp load_operation_history(_uid, _scope), do: []

  # Launchable playbooks bound to this device's AWX controller. Reuses the
  # canonical `Playbook.list_launchable/2` read (single source of truth shared
  # with the ad-hoc launch page) scoped to the controller,
  # rather than a hand-rolled query that silently returned [] when the resource
  # had no primary read action.
  defp load_playbooks(controller_id, scope) when is_binary(controller_id) do
    case Playbook.list_launchable(%{controller_id: controller_id}, scope: scope) do
      {:ok, rows} ->
        Enum.filter(rows, fn playbook ->
          playbook.source_type == :awx and playbook.parse_status == :ok
        end)

      _ ->
        []
    end
  end

  defp load_playbooks(_controller_id, _scope), do: []

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
    input_params = input_params(params)

    socket =
      assign(
        socket,
        :ansible_var_values,
        Map.merge(
          socket.assigns.ansible_var_values,
          var_values_from_params(socket.assigns.ansible_vars, input_params)
        )
      )

    if playbook_id == socket.assigns.ansible_selected_playbook_id do
      socket
    else
      prepare_launch(socket, playbook_id)
    end
  end

  def launch(socket, params) do
    scope = socket.assigns.current_scope

    cond do
      not RBAC.can?(scope, "ansible.runs.launch") ->
        put_flash(socket, :error, "You don't have permission to launch Ansible playbooks.")

      blank?(params["playbook_id"]) ->
        assign(socket, :ansible_launch_notice, "Pick a playbook before launching.")

      true ->
        do_launch(socket, params["playbook_id"], params)
    end
  end

  defp do_launch(socket, playbook_id, params) do
    scope = socket.assigns.current_scope
    inputs = input_params(params)

    case SecureLaunchService.launch(
           scope.user,
           [socket.assigns.device_uid],
           playbook_id,
           inputs,
           mode: :run,
           request_source: :device_details
         ) do
      {:ok, result} ->
        socket =
          socket
          |> reset_launch_modal()
          |> put_flash(:info, secure_launch_success(result))

        navigate_to_operation(socket, result)

      {:error, reason} ->
        Logger.info("Device Ansible launch failed", SafeFailureEvidence.log_metadata(reason))
        assign(socket, :ansible_launch_notice, launch_error_message(reason))
    end
  end

  ## Helpers -------------------------------------------------------------------

  defp prepare_launch(socket, playbook_id) do
    scope = socket.assigns.current_scope

    case SecureLaunchService.prepare(
           scope.user,
           [socket.assigns.device_uid],
           playbook_id
         ) do
      {:ok, resolution} ->
        ready? = resolution.run_mode_supported == true

        socket
        |> assign(:ansible_selected_playbook_id, playbook_id)
        |> assign(:ansible_vars, resolution.variables)
        |> assign(:ansible_var_values, %{})
        |> assign(:ansible_launch_ready, ready?)
        |> assign(:ansible_launch_resolution, resolution)
        |> assign(
          :ansible_launch_readiness,
          if(ready?,
            do: "Reviewed binding and exact target membership are ready.",
            else: "This binding is not approved for run mode."
          )
        )
        |> assign(:ansible_launch_notice, nil)

      {:error, reason} ->
        socket
        |> assign(:ansible_selected_playbook_id, playbook_id)
        |> assign(:ansible_vars, [])
        |> assign(:ansible_var_values, %{})
        |> assign(:ansible_launch_ready, false)
        |> assign(:ansible_launch_resolution, nil)
        |> assign(:ansible_launch_readiness, launch_error_message(reason))
        |> assign(:ansible_launch_notice, nil)
    end
  end

  defp input_params(%{"inputs" => inputs}) when is_map(inputs), do: inputs
  defp input_params(_params), do: %{}

  defp var_values_from_params(vars, params) when is_list(vars) and is_map(params) do
    Enum.reduce(vars, %{}, fn %Var{name: name}, acc ->
      case Map.get(params, name) do
        nil -> acc
        value -> Map.put(acc, name, value)
      end
    end)
  end

  defp var_values_from_params(_vars, _params), do: %{}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  @doc false
  def launch_error_message(:devices_required), do: "This device is not an eligible canonical target."

  def launch_error_message({:target_not_ready, _device_uid}),
    do: "This target has no human-approved, current, enabled AWX membership for this binding."

  def launch_error_message(:no_common_approved_inventory),
    do: "The selected targets do not share an approved AWX inventory for this binding."

  def launch_error_message(:ambiguous_common_approved_inventory),
    do: "More than one approved AWX inventory matches; an operator must resolve the ambiguity."

  def launch_error_message({:ambiguous_target_membership, _device_uid}),
    do: "A target has multiple approved memberships in the selected inventory."

  def launch_error_message(:binding_not_approved), do: "The AWX template has no current approval."

  def launch_error_message(:binding_approval_expired), do: "The AWX template approval has expired."

  def launch_error_message(:binding_mode_not_approved), do: "The reviewed binding does not allow run mode."

  def launch_error_message({:required_launch_input, name}), do: "#{name} is required by the reviewed binding."

  def launch_error_message({:invalid_launch_input, name}), do: "#{name} is not a valid value for the reviewed binding."

  def launch_error_message({:invalid_launch_choice, name}), do: "#{name} is not one of the reviewed choices."

  def launch_error_message({:launch_input_out_of_bounds, name}), do: "#{name} is outside the reviewed bounds."

  def launch_error_message({:undeclared_launch_inputs, _names}),
    do: "The request contained an input that is not declared by the reviewed binding."

  def launch_error_message(:ambiguous_launch_inputs), do: "The request contained ambiguous reviewed-input fields."

  def launch_error_message(:playbook_not_found), do: "Playbook not found."

  def launch_error_message(:awx_playbook_required), do: "Only reviewed AWX playbooks can run here."

  def launch_error_message({:target_held, _device_uid}),
    do: "This target is under an active automation hold and cannot launch until cleared."

  def launch_error_message({:target_hold_lookup_failed, _reason}),
    do: "Could not verify target-hold state for this device."

  def launch_error_message(:authenticated_edge_principal_unavailable),
    do: "The controller edge principal is not currently available for launch."

  def launch_error_message(:awx_preflight_unavailable),
    do: "Live AWX launch preflight is not available on this deployment."

  def launch_error_message(:awx_preflight_controller_drift),
    do: "The live AWX controller no longer matches the reviewed binding. An authorized reviewer must approve it again."

  def launch_error_message(:awx_preflight_template_project_drift),
    do: "The live AWX template or project changed after review. An authorized reviewer must approve the binding again."

  def launch_error_message(:awx_preflight_inventory_drift),
    do: "The live AWX inventory changed after review. An authorized reviewer must approve the binding again."

  def launch_error_message(:awx_preflight_credential_set_drift),
    do: "The reviewed AWX credential set changed. An authorized reviewer must approve the binding again."

  def launch_error_message(:awx_preflight_execution_environment_drift),
    do: "The reviewed AWX execution environment changed. An authorized reviewer must approve the binding again."

  def launch_error_message(:awx_preflight_survey_contract_drift),
    do: "The reviewed AWX survey contract changed. An authorized reviewer must approve the binding again."

  def launch_error_message(:awx_preflight_prompt_policy_drift),
    do: "The reviewed AWX launch-prompt policy changed. An authorized reviewer must approve the binding again."

  def launch_error_message(:awx_preflight_target_drift),
    do:
      "The selected target no longer matches the reviewed AWX membership. Refresh the target and request binding review."

  def launch_error_message(:awx_preflight_static_drift),
    do: "The live AWX configuration changed after review. An authorized reviewer must approve the binding again."

  def launch_error_message(_other), do: "Launch failed because current approval or authorization could not be verified."

  defp secure_launch_success(%{operation: %{id: id}}) when is_binary(id) do
    "Launch dispatched as operation #{id}."
  end

  defp secure_launch_success(_result), do: "Launch dispatched."

  defp navigate_to_operation(socket, %{operation: %{id: id}}) when is_binary(id),
    do: push_navigate(socket, to: "/ansible/operations/#{id}")

  defp navigate_to_operation(socket, _result), do: push_navigate(socket, to: "/ansible/operations")
end
