defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEvents.BulkState do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Helpers
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Selection

  require Ash.Query

  # "Out of service" is is_active == false -- the same flag the inactive display
  # uses (ServiceRadar.Notifications.Suppression.device_out_of_service?/1). There
  # is deliberately no separate out-of-service column.
  @service_actions %{"active" => :mark_active, "inactive" => :mark_inactive}
  @managed_actions %{"managed" => :mark_managed, "unmanaged" => :mark_unmanaged}

  def handle_event("apply_bulk_state", %{"bulk_state" => params}, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.bulk_edit") do
      apply_bulk_state(params, socket)
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to bulk edit devices")}
    end
  end

  # The modal's scope control is its own form and reports here on change. The
  # choice stays modal-local (`bulk_target_scope`) and governs both submits,
  # which resolve targets through Selection.selected_uids_for_scope/2. It must
  # not write the shared `select_all_matching`, or cancelling the modal would
  # leave the whole-result-set scope armed for the toolbar buttons.
  def handle_event("bulk_state_scope_change", %{"bulk_scope" => params}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_scope_form, to_form(params, as: :bulk_scope))
     |> assign(:bulk_target_scope, Map.get(params, "scope", "selected"))}
  end

  def handle_event("bulk_state_scope_change", _params, socket), do: {:noreply, socket}

  defp apply_bulk_state(params, socket) do
    service_state = Map.get(params, "service_state", "no_change")
    managed_state = Map.get(params, "managed_state", "no_change")

    if service_state == "no_change" and managed_state == "no_change" do
      {:noreply,
       socket
       |> assign(:bulk_state_form, to_form(params, as: :bulk_state))
       |> put_flash(:error, "Choose at least one change to apply")}
    else
      run_changes(socket, params, service_state, managed_state)
    end
  end

  defp run_changes(socket, params, service_state, managed_state) do
    target_scope = socket.assigns.bulk_target_scope

    case Selection.validate_device_selection_for_scope(socket, target_scope) do
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:bulk_state_form, to_form(params, as: :bulk_state))
         |> put_flash(:error, reason)}

      :ok ->
        case Selection.selected_uids_for_scope(socket, target_scope) do
          [] ->
            {:noreply,
             socket
             |> assign(:bulk_state_form, to_form(params, as: :bulk_state))
             |> put_flash(:error, "No devices selected")}

          uids ->
            apply_changes(socket, params, uids, service_state, managed_state)
        end
    end
  end

  defp apply_changes(socket, params, uids, service_state, managed_state) do
    scope = socket.assigns.current_scope

    case apply_state_changes(scope, uids, service_state, managed_state) do
      {:ok, service_result, managed_result} ->
        count = max(service_result.count, managed_result.count)
        labels = service_result.labels ++ managed_result.labels
        query = Map.get(socket.assigns.srql || %{}, :query, "")

        {:noreply,
         socket
         |> assign(:show_bulk_edit_modal, false)
         |> assign(:bulk_state_form, Helpers.bulk_state_form())
         |> assign(:bulk_scope_form, Helpers.bulk_scope_form())
         |> assign(:bulk_edit_form, to_form(%{"tags" => ""}, as: :bulk))
         |> assign(:bulk_target_scope, "selected")
         |> assign(:bulk_target_matching_count, nil)
         |> assign(:selected_devices, MapSet.new())
         |> assign(:select_all_matching, false)
         |> assign(:total_matching_count, nil)
         |> put_flash(:info, success_message(count, labels, managed_result.skipped))
         |> push_patch(to: Helpers.device_list_path(query, socket.assigns.limit))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:bulk_state_form, to_form(params, as: :bulk_state))
         |> put_flash(:error, "Failed to update devices: #{reason}")}
    end
  end

  defp apply_state_changes(scope, uids, service_state, managed_state) do
    resources = [Device]

    resources
    |> Ash.transaction(fn ->
      with {:ok, service_result} <- maybe_apply_service(scope, uids, service_state),
           {:ok, managed_result} <- maybe_apply_managed(scope, uids, managed_state) do
        {service_result, managed_result}
      else
        {:error, reason} -> Ash.DataLayer.rollback(resources, reason)
      end
    end)
    |> case do
      {:ok, {service_result, managed_result}} -> {:ok, service_result, managed_result}
      {:error, reason} -> {:error, Helpers.format_transaction_error(reason)}
    end
  end

  defp maybe_apply_service(_scope, _uids, "no_change"), do: {:ok, change_result(0, [], 0)}

  defp maybe_apply_service(scope, uids, service_state) do
    case Map.fetch(@service_actions, service_state) do
      {:ok, action} -> update_service_state(scope, uids, action, service_state)
      :error -> {:error, "Unknown service state"}
    end
  end

  defp update_service_state(scope, uids, action, service_state) do
    query = device_query(scope, uids)

    case count_devices(query, scope) do
      {:ok, existing_count} ->
        result =
          Ash.bulk_update(query, action, %{},
            scope: scope,
            return_records?: false,
            return_errors?: true
          )

        case Helpers.handle_bulk_update_result(result, existing_count, length(uids)) do
          {:ok, count} -> {:ok, change_result(count, [service_label(service_state)], 0)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_apply_managed(_scope, _uids, "no_change"), do: {:ok, change_result(0, [], 0)}

  defp maybe_apply_managed(scope, uids, "unmanaged") do
    update_unmanaged_state(scope, uids)
  end

  defp maybe_apply_managed(scope, uids, managed_state) do
    case Map.fetch(@managed_actions, managed_state) do
      {:ok, action} -> update_managed_state(scope, uids, action, managed_state)
      :error -> {:error, "Unknown managed state"}
    end
  end

  defp update_managed_state(scope, uids, action, managed_state) do
    query = device_query(scope, uids)

    case count_devices(query, scope) do
      {:ok, existing_count} ->
        result =
          Ash.bulk_update(query, action, %{},
            scope: scope,
            return_records?: false,
            return_errors?: true
          )

        case Helpers.handle_bulk_update_result(result, existing_count, length(uids)) do
          {:ok, count} -> {:ok, change_result(count, [managed_label(managed_state)], 0)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_unmanaged_state(scope, uids) do
    base_query = device_query(scope, uids)

    with {:ok, existing_count} <- count_devices(base_query, scope),
         {:ok, eligible_count} <-
           count_devices(Ash.Query.filter(base_query, is_nil(agent_id)), scope) do
      if existing_count < length(uids) do
        {:error, "One or more devices were not found"}
      else
        run_unmanaged_update(scope, base_query, existing_count, eligible_count)
      end
    end
  end

  defp run_unmanaged_update(scope, base_query, existing_count, eligible_count) do
    # ServiceRadar.Inventory.Validations.AgentManaged forbids an agent-backed
    # device (agent_id present) from becoming unmanaged, but its atomic/3
    # returns a bare `:ok`, which Ash reads as "nothing to check atomically".
    # On a bulk/atomic update the validator is therefore skipped and the rule
    # appears to work while never running, so the guard has to be an explicit
    # query filter here. Do not "simplify" this filter away: removing it
    # silently flips agent-backed devices to unmanaged.
    eligible_query = Ash.Query.filter(base_query, is_nil(agent_id))

    result =
      Ash.bulk_update(eligible_query, :mark_unmanaged, %{},
        scope: scope,
        return_records?: false,
        return_errors?: true
      )

    case Helpers.handle_bulk_update_result(result, eligible_count, eligible_count) do
      {:ok, count} ->
        skipped = max(existing_count - eligible_count, 0)
        {:ok, change_result(count, [managed_label("unmanaged")], skipped)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp device_query(scope, uids) do
    Device
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(uid in ^uids)
  end

  defp count_devices(query, scope) do
    case Ash.count(query, scope: scope) do
      {:ok, count} -> {:ok, count}
      {:error, error} -> {:error, Helpers.format_changeset_errors(error)}
    end
  end

  defp change_result(count, labels, skipped), do: %{count: count, labels: labels, skipped: skipped}

  defp service_label("active"), do: "in service"
  defp service_label("inactive"), do: "out of service"

  defp managed_label("managed"), do: "managed"
  defp managed_label("unmanaged"), do: "unmanaged"

  defp success_message(count, labels, skipped) do
    message =
      case labels do
        [single] -> "Marked #{count} device(s) #{single}"
        many -> "Updated #{count} device(s): #{Enum.join(many, ", ")}"
      end

    if skipped > 0 do
      message <> "; skipped #{skipped} agent-backed device(s) that must remain managed"
    else
      message
    end
  end
end
