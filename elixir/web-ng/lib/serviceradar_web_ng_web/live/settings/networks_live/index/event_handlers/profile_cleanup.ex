defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.EventHandlers.ProfileCleanup do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Builder
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Executions
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Messages
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.ProfileParams

  alias AshPhoenix.Form
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.TargetBuilder

  def handle_event("delete_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_sweep_profile(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Scanner profile not found")}

      profile ->
        case Ash.destroy(profile, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> assign(:sweep_profiles, load_sweep_profiles(scope))
             |> put_flash(:info, "Scanner profile deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete scanner profile")}
        end
    end
  end

  def handle_event("save_group", %{"form" => params}, socket) do
    require Logger

    scope = socket.assigns.current_scope

    params = normalize_static_targets(params)

    Logger.debug("[NetworksLive] save_group - params: #{inspect(params)}")

    ash_form = Form.validate(socket.assigns.ash_form, params)

    case Form.submit(ash_form, params: params) do
      {:ok, group} ->
        Logger.debug("[NetworksLive] save_group SUCCESS - saved group.target_query: #{inspect(group.target_query)}")

        flash_message = sweep_group_save_message(group.enabled)

        {:noreply,
         socket
         |> assign(:sweep_groups, load_sweep_groups(scope))
         |> put_flash(:info, flash_message)
         |> push_navigate(to: ~p"/settings/networks")}

      {:ok, group, _notifications} ->
        Logger.debug("[NetworksLive] save_group SUCCESS - saved group.target_query: #{inspect(group.target_query)}")

        flash_message = sweep_group_save_message(group.enabled)

        {:noreply,
         socket
         |> assign(:sweep_groups, load_sweep_groups(scope))
         |> put_flash(:info, flash_message)
         |> push_navigate(to: ~p"/settings/networks")}

      {:error, ash_form} ->
        Logger.warning("[NetworksLive] save_group ERROR - form errors: #{inspect(Form.errors(ash_form))}")

        {:noreply,
         socket
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))}
    end
  end

  def handle_event("save_profile", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    params = transform_profile_params(params)

    ash_form = Form.validate(socket.assigns.ash_form, params)

    case Form.submit(ash_form, params: params) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(:sweep_profiles, load_sweep_profiles(scope))
         |> put_flash(:info, "Scanner profile saved")
         |> push_navigate(to: ~p"/settings/networks")}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))}
    end
  end

  def handle_event("validate_cleanup_settings", %{"cleanup" => params}, socket) do
    form = Form.validate(socket.assigns.cleanup_form, params)

    {:noreply, assign(socket, :cleanup_form, to_form(form))}
  end

  def handle_event("save_cleanup_settings", %{"cleanup" => params}, socket) do
    scope = socket.assigns.current_scope

    form = Form.validate(socket.assigns.cleanup_form, params)

    case Form.submit(form, params: params) do
      {:ok, settings} ->
        _ = DeviceCleanupWorker.ensure_scheduled()
        updated_form = build_cleanup_form(scope, settings)

        {:noreply,
         socket
         |> assign(:cleanup_settings, settings)
         |> assign(:cleanup_form, updated_form)
         |> put_flash(:info, "Inventory cleanup settings saved")}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:cleanup_form, to_form(form))
         |> put_flash(:error, "Failed to save inventory cleanup settings")}
    end
  end

  def handle_event("run_cleanup_now", _params, socket) do
    scope = socket.assigns.current_scope

    case DeviceCleanupSettings.run_cleanup(scope: scope) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Cleanup job queued")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to queue cleanup: #{inspect(reason)}")}
    end
  end

  def handle_event("validate_group", %{"form" => params} = payload, socket) do
    scope = socket.assigns.current_scope
    params = normalize_static_targets(params)
    target_query = Map.get(params, "target_query")
    builder_event? = Map.has_key?(payload, "builder")

    # Memoize the device count on the target query: validate_group fires on
    # every keystroke, so re-running the live SRQL count unconditionally is a
    # round-trip per edit. Recompute only when the query string changed.
    device_count =
      if Map.get(socket.assigns, :last_target_query) == target_query do
        socket.assigns.target_device_count
      else
        count_target_devices(scope, target_query)
      end

    {parsed_builder, builder_sync} =
      if builder_event? do
        {socket.assigns.builder, socket.assigns.builder_sync}
      else
        TargetBuilder.parse_target_query_to_builder(target_query)
      end

    ash_form = Form.validate(socket.assigns.ash_form, params)

    socket =
      socket
      |> assign(:ash_form, ash_form)
      |> assign(:form, to_form(ash_form))
      |> assign(:target_device_count, device_count)
      |> assign(:last_target_query, target_query)
      |> assign(:builder_sync, builder_sync)

    socket =
      if builder_event? do
        socket
      else
        if builder_sync do
          assign(socket, :builder, parsed_builder)
        else
          socket
        end
      end

    {:noreply, socket}
  end

  def handle_event("validate_profile", %{"form" => params}, socket) do
    params = transform_profile_params(params)
    banner_grab_draft = Map.get(params, "banner_grab") || socket.assigns[:banner_grab_draft]

    ash_form = Form.validate(socket.assigns.ash_form, params)

    builder_sync = socket.assigns.builder_sync

    socket =
      if Map.has_key?(params, "target_query") do
        target_query = Map.get(params, "target_query")
        {parsed_builder, parsed_sync} = TargetBuilder.parse_target_query_to_builder(target_query)

        socket = assign(socket, :builder_sync, parsed_sync)

        if builder_sync do
          assign(socket, :builder, parsed_builder)
        else
          socket
        end
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))
     |> assign(:banner_grab_draft, banner_grab_draft)}
  end
end
