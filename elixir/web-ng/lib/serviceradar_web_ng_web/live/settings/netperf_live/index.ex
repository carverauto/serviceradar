defmodule ServiceRadarWebNGWeb.Settings.NetperfLive.Index do
  @moduledoc """
  LiveView for managing embedded agent Hub & Spoke network performance
  policies, Hub Responders, test profiles, and on-demand `netperf.run` checks.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandsPubSub
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Monitoring.NetperfPolicy
  alias ServiceRadar.Monitoring.NetperfProfile
  alias ServiceRadar.Monitoring.NetperfResponder
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.NetperfLive.Data
  alias ServiceRadarWebNGWeb.Settings.NetperfLive.Forms
  alias ServiceRadarWebNGWeb.Settings.NetperfLive.View

  @current_path "/settings/networks/netperf"
  @manage_permission "settings.networks.manage"
  @supported_tabs ~w(policies responders profiles)

  @doc "In-page tab query parameter values handled by this LiveView."
  @spec supported_tabs() :: [String.t()]
  def supported_tabs, do: @supported_tabs

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:current_scope]

    if can_manage?(scope) do
      if connected?(socket) do
        AgentCommandsPubSub.subscribe()
      end

      {:ok,
       socket
       |> assign(:page_title, "Network Performance")
       |> assign(:current_path, @current_path)
       |> assign(:active_tab, "policies")
       |> assign(:loading?, true)
       |> assign(:show_form, nil)
       |> assign(:editing_record, nil)
       |> assign(:form, nil)
       |> assign(:form_params, %{})
       |> assign(:show_run_modal, false)
       |> assign(:run_form, nil)
       |> assign(:run_params, Forms.default_run_params())
       |> assign(:run_error, nil)
       |> assign(:active_run, nil)
       |> assign(:dashboard_route, nil)
       |> assign(:responders_list, [])
       |> assign(:profiles_list, [])
       |> assign(:agents_list, [])
       |> assign(:online_agent_ids, MapSet.new())
       |> assign(:netperf_agent_ids, MapSet.new())
       |> assign(:policies_count, 0)
       |> assign(:responders_count, 0)
       |> assign(:profiles_count, 0)
       |> assign(:recent_runs_count, 0)
       |> stream(:policies, [])
       |> stream(:responders, [])
       |> stream(:profiles, [])
       |> stream(:recent_runs, [])}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage network performance settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if fresh_can_manage?(socket.assigns[:current_scope]) do
      if connected?(socket) do
        socket =
          socket
          |> load_and_assign_data()
          |> assign(:loading?, false)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}
      else
        {:noreply, apply_disconnected_params(socket, socket.assigns.live_action, params)}
      end
    else
      {:noreply, unauthorized(socket)}
    end
  end

  @impl true
  def handle_event("validate_policy", %{"policy" => params}, socket) do
    authorize_manage_event(socket, fn ->
      {:noreply,
       socket
       |> assign(:form_params, params)
       |> assign(:form, to_form(params, as: :policy))}
    end)
  end

  def handle_event("save_policy", %{"policy" => params}, socket) do
    authorize_manage_event(socket, fn ->
      scope = socket.assigns.current_scope
      {attrs, responder_ids} = Forms.build_policy_attrs(params)

      result =
        save_policy_with_responders(
          socket.assigns.show_form,
          socket.assigns.editing_record,
          attrs,
          responder_ids,
          scope
        )

      case result do
        {:ok, _policy} ->
          {:noreply,
           socket
           |> put_flash(:info, "Network performance policy saved")
           |> push_navigate(to: ~p"/settings/networks/netperf?tab=policies")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:form_params, params)
           |> assign(:form, to_form(params, as: :policy))
           |> put_flash(:error, "Failed to save policy: #{Forms.format_dispatch_error(reason)}")}
      end
    end)
  end

  def handle_event("toggle_policy", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      scope = socket.assigns.current_scope

      with {:ok, policy} <- NetperfPolicy.get_by_id(id, scope: scope),
           {:ok, _updated} <- toggle_policy_record(policy, scope) do
        {:noreply,
         socket
         |> load_and_assign_data()
         |> put_flash(
           :info,
           if(policy.enabled, do: "Policy disabled", else: "Policy enabled")
         )}
      else
        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to update policy: #{Forms.format_dispatch_error(reason)}"
           )}
      end
    end)
  end

  def handle_event("delete_policy", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      scope = socket.assigns.current_scope

      with {:ok, policy} <- NetperfPolicy.get_by_id(id, scope: scope),
           :ok <- NetperfPolicy.delete_policy(policy, scope: scope) do
        {:noreply,
         socket
         |> load_and_assign_data()
         |> put_flash(:info, "Network performance policy deleted")}
      else
        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to delete policy: #{Forms.format_dispatch_error(reason)}"
           )}
      end
    end)
  end

  def handle_event("validate_responder", %{"responder" => params}, socket) do
    authorize_manage_event(socket, fn ->
      {:noreply,
       socket
       |> assign(:form_params, params)
       |> assign(:form, to_form(params, as: :responder))}
    end)
  end

  def handle_event("save_responder", %{"responder" => params}, socket) do
    authorize_manage_event(socket, fn ->
      scope = socket.assigns.current_scope

      result =
        case socket.assigns.show_form do
          :new_responder ->
            attrs = Forms.build_responder_attrs(params, true)
            NetperfResponder.create_responder(attrs, scope: scope)

          :edit_responder ->
            attrs = Forms.build_responder_attrs(params, false)
            NetperfResponder.update_responder(socket.assigns.editing_record, attrs, scope: scope)
        end

      case result do
        {:ok, _responder} ->
          {:noreply,
           socket
           |> put_flash(:info, "Hub Responder saved")
           |> push_navigate(to: ~p"/settings/networks/netperf?tab=responders")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:form_params, params)
           |> assign(:form, to_form(params, as: :responder))
           |> put_flash(
             :error,
             "Failed to save Hub Responder: #{Forms.format_dispatch_error(reason)}"
           )}
      end
    end)
  end

  def handle_event("toggle_responder", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      scope = socket.assigns.current_scope

      with {:ok, responder} <- NetperfResponder.get_by_id(id, scope: scope),
           {:ok, _updated} <- toggle_responder_record(responder, scope) do
        {:noreply,
         socket
         |> load_and_assign_data()
         |> put_flash(
           :info,
           if(responder.enabled,
             do: "Hub Responder disabled and authority epoch bumped",
             else: "Hub Responder enabled"
           )
         )}
      else
        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to update Hub Responder: #{Forms.format_dispatch_error(reason)}"
           )}
      end
    end)
  end

  def handle_event("bump_authority_epoch", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      scope = socket.assigns.current_scope

      with {:ok, responder} <- NetperfResponder.get_by_id(id, scope: scope),
           {:ok, updated} <- NetperfResponder.bump_authority_epoch(responder, scope: scope) do
        {:noreply,
         socket
         |> load_and_assign_data()
         |> put_flash(:info, "Authority epoch bumped to #{updated.authority_epoch}")}
      else
        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to bump authority epoch: #{Forms.format_dispatch_error(reason)}"
           )}
      end
    end)
  end

  def handle_event("delete_responder", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      scope = socket.assigns.current_scope

      with {:ok, responder} <- NetperfResponder.get_by_id(id, scope: scope),
           :ok <- NetperfResponder.delete_responder(responder, scope: scope) do
        {:noreply,
         socket
         |> load_and_assign_data()
         |> put_flash(:info, "Hub Responder deleted")}
      else
        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to delete Hub Responder: #{Forms.format_dispatch_error(reason)}"
           )}
      end
    end)
  end

  def handle_event("validate_profile", %{"profile" => params}, socket) do
    authorize_manage_event(socket, fn ->
      {:noreply,
       socket
       |> assign(:form_params, params)
       |> assign(:form, to_form(params, as: :profile))}
    end)
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    authorize_manage_event(socket, fn ->
      scope = socket.assigns.current_scope
      attrs = Forms.build_profile_attrs(params)

      result =
        case socket.assigns.show_form do
          :new_profile ->
            NetperfProfile.create_profile(attrs, scope: scope)

          :edit_profile ->
            NetperfProfile.update_profile(socket.assigns.editing_record, attrs, scope: scope)
        end

      case result do
        {:ok, _profile} ->
          {:noreply,
           socket
           |> put_flash(:info, "Network performance profile saved")
           |> push_navigate(to: ~p"/settings/networks/netperf?tab=profiles")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:form_params, params)
           |> assign(:form, to_form(params, as: :profile))
           |> put_flash(:error, "Failed to save profile: #{Forms.format_dispatch_error(reason)}")}
      end
    end)
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      scope = socket.assigns.current_scope

      with {:ok, profile} <- NetperfProfile.get_by_id(id, scope: scope),
           :ok <- NetperfProfile.delete_profile(profile, scope: scope) do
        {:noreply,
         socket
         |> load_and_assign_data()
         |> put_flash(:info, "Network performance profile deleted")}
      else
        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to delete profile: #{Forms.format_dispatch_error(reason)}"
           )}
      end
    end)
  end

  def handle_event("open_run_modal", _params, socket) do
    authorize_manage_event(socket, fn ->
      defaults = initial_run_params(socket.assigns)

      {:noreply,
       socket
       |> assign(:show_run_modal, true)
       |> assign(:run_error, nil)
       |> assign(:run_params, defaults)
       |> assign(:run_form, to_form(defaults, as: :run))}
    end)
  end

  def handle_event("close_run_modal", _params, socket) do
    authorize_manage_event(socket, fn ->
      {:noreply,
       socket
       |> assign(:show_run_modal, false)
       |> assign(:run_error, nil)}
    end)
  end

  def handle_event("validate_run", %{"run" => params}, socket) do
    authorize_manage_event(socket, fn ->
      merged =
        Forms.apply_run_presets(
          params,
          socket.assigns.responders_list,
          socket.assigns.profiles_list,
          &Data.resolve_responder_address/1
        )

      {:noreply,
       socket
       |> assign(:run_error, nil)
       |> assign(:run_params, merged)
       |> assign(:run_form, to_form(merged, as: :run))}
    end)
  end

  def handle_event("run_netperf_test", %{"run" => params}, socket) do
    authorize_manage_event(socket, fn ->
      scope = socket.assigns.current_scope
      sender_agent_id = String.trim(Map.get(params, "sender_agent_id", ""))
      run_params = Forms.build_run_params(params)

      case dispatch_netperf_run(sender_agent_id, run_params, actor: scope.user) do
        {:ok, command_id} ->
          active_run = %{
            command_id: command_id,
            sender_agent_id: sender_agent_id,
            responder_agent_id: run_params.responder_agent_id,
            target_address: run_params.target_address,
            target_port: run_params.target_port,
            protocol: run_params.protocol,
            direction: run_params.direction,
            state: :sent,
            progress_percent: nil,
            message: "Dispatched to sender agent #{sender_agent_id}",
            result_payload: nil
          }

          socket =
            socket
            |> assign(:show_run_modal, false)
            |> assign(:run_error, nil)
            |> assign(:active_run, active_run)
            |> maybe_insert_command_into_stream(command_id, scope)
            |> put_flash(:info, "Dispatched netperf.run (#{command_id})")

          {:noreply, socket}

        {:error, reason} ->
          error_message = Forms.format_dispatch_error(reason)

          {:noreply,
           socket
           |> assign(:run_error, error_message)
           |> assign(:run_params, params)
           |> assign(:run_form, to_form(params, as: :run))
           |> put_flash(:error, error_message)}
      end
    end)
  end

  @impl true
  def handle_info({kind, data}, socket)
      when kind in [:command_ack, :command_progress, :command_result] and is_map(data) do
    active_run = Forms.reduce_command_event(socket.assigns.active_run, {kind, data})
    command_type = Map.get(data, :command_type) || Map.get(data, "command_type")
    command_id = Map.get(data, :command_id) || Map.get(data, "command_id")

    matches_active? =
      match?(%{command_id: ^command_id}, socket.assigns.active_run)

    socket = assign(socket, :active_run, active_run)

    socket =
      if (command_type == "netperf.run" or matches_active?) and is_binary(command_id) and
           connected?(socket) do
        maybe_insert_command_into_stream(socket, command_id, socket.assigns.current_scope)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns), do: View.render(assigns)

  defp apply_disconnected_params(socket, :index, params) do
    assign(socket, :active_tab, normalize_tab(Map.get(params, "tab")))
  end

  defp apply_disconnected_params(socket, action, _params) when action in [:new_policy, :edit_policy] do
    assign(socket, :active_tab, "policies")
  end

  defp apply_disconnected_params(socket, action, _params) when action in [:new_responder, :edit_responder] do
    assign(socket, :active_tab, "responders")
  end

  defp apply_disconnected_params(socket, action, _params) when action in [:new_profile, :edit_profile] do
    assign(socket, :active_tab, "profiles")
  end

  defp apply_action(socket, :index, params) do
    socket
    |> assign(:page_title, "Network Performance")
    |> assign(:active_tab, normalize_tab(Map.get(params, "tab")))
    |> assign(:show_form, nil)
    |> assign(:editing_record, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new_policy, _params) do
    params = Forms.default_policy_params(socket.assigns.profiles_list)

    socket
    |> assign(:page_title, "New Network Performance Policy")
    |> assign(:active_tab, "policies")
    |> assign(:show_form, :new_policy)
    |> assign(:editing_record, nil)
    |> assign(:form_params, params)
    |> assign(:form, to_form(params, as: :policy))
  end

  defp apply_action(socket, :edit_policy, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case NetperfPolicy
         |> Ash.Query.for_read(:by_id, %{id: id})
         |> Ash.Query.load([:profile, :responders])
         |> Ash.read_one(scope: scope) do
      {:ok, %NetperfPolicy{} = policy} ->
        params = Forms.policy_to_form_params(policy)

        socket
        |> assign(:page_title, "Edit Policy: #{policy.name}")
        |> assign(:active_tab, "policies")
        |> assign(:show_form, :edit_policy)
        |> assign(:editing_record, policy)
        |> assign(:form_params, params)
        |> assign(:form, to_form(params, as: :policy))

      _ ->
        socket
        |> put_flash(:error, "Network performance policy not found")
        |> push_navigate(to: ~p"/settings/networks/netperf?tab=policies")
    end
  end

  defp apply_action(socket, :new_responder, _params) do
    params = Forms.default_responder_params()

    socket
    |> assign(:page_title, "New Hub Responder")
    |> assign(:active_tab, "responders")
    |> assign(:show_form, :new_responder)
    |> assign(:editing_record, nil)
    |> assign(:form_params, params)
    |> assign(:form, to_form(params, as: :responder))
  end

  defp apply_action(socket, :edit_responder, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case NetperfResponder.get_by_id(id, scope: scope) do
      {:ok, %NetperfResponder{} = responder} ->
        params = Forms.responder_to_form_params(responder)

        socket
        |> assign(:page_title, "Edit Hub Responder: #{responder.name}")
        |> assign(:active_tab, "responders")
        |> assign(:show_form, :edit_responder)
        |> assign(:editing_record, responder)
        |> assign(:form_params, params)
        |> assign(:form, to_form(params, as: :responder))

      _ ->
        socket
        |> put_flash(:error, "Hub Responder not found")
        |> push_navigate(to: ~p"/settings/networks/netperf?tab=responders")
    end
  end

  defp apply_action(socket, :new_profile, _params) do
    params = Forms.default_profile_params()

    socket
    |> assign(:page_title, "New Network Performance Profile")
    |> assign(:active_tab, "profiles")
    |> assign(:show_form, :new_profile)
    |> assign(:editing_record, nil)
    |> assign(:form_params, params)
    |> assign(:form, to_form(params, as: :profile))
  end

  defp apply_action(socket, :edit_profile, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case NetperfProfile.get_by_id(id, scope: scope) do
      {:ok, %NetperfProfile{} = profile} ->
        params = Forms.profile_to_form_params(profile)

        socket
        |> assign(:page_title, "Edit Profile: #{profile.name}")
        |> assign(:active_tab, "profiles")
        |> assign(:show_form, :edit_profile)
        |> assign(:editing_record, profile)
        |> assign(:form_params, params)
        |> assign(:form, to_form(params, as: :profile))

      _ ->
        socket
        |> put_flash(:error, "Network performance profile not found")
        |> push_navigate(to: ~p"/settings/networks/netperf?tab=profiles")
    end
  end

  defp load_and_assign_data(socket) do
    scope = socket.assigns.current_scope
    loaded = Data.load_all(scope)

    socket
    |> assign(:dashboard_route, loaded.dashboard_route)
    |> assign(:responders_list, loaded.responders)
    |> assign(:profiles_list, loaded.profiles)
    |> assign(:agents_list, loaded.agents)
    |> assign(:online_agent_ids, loaded.online_agent_ids)
    |> assign(:netperf_agent_ids, loaded.netperf_agent_ids)
    |> assign(:policies_count, length(loaded.policies))
    |> assign(:responders_count, length(loaded.responders))
    |> assign(:profiles_count, length(loaded.profiles))
    |> assign(:recent_runs_count, length(loaded.recent_runs))
    |> stream(:policies, loaded.policies, reset: true)
    |> stream(:responders, loaded.responders, reset: true)
    |> stream(:profiles, loaded.profiles, reset: true)
    |> stream(:recent_runs, loaded.recent_runs, reset: true)
  end

  defp save_policy_with_responders(:new_policy, _record, attrs, responder_ids, scope) do
    Repo.transaction(fn ->
      with {:ok, policy} <- NetperfPolicy.create_policy(attrs, scope: scope),
           :ok <- NetperfPolicy.sync_responders(policy.id, responder_ids, scope: scope) do
        policy
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp save_policy_with_responders(:edit_policy, policy, attrs, responder_ids, scope) do
    Repo.transaction(fn ->
      with {:ok, updated} <- NetperfPolicy.update_policy(policy, attrs, scope: scope),
           :ok <- NetperfPolicy.sync_responders(updated.id, responder_ids, scope: scope) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp toggle_policy_record(%{enabled: true} = policy, scope), do: NetperfPolicy.disable_policy(policy, scope: scope)

  defp toggle_policy_record(policy, scope), do: NetperfPolicy.enable_policy(policy, scope: scope)

  defp toggle_responder_record(%{enabled: true} = responder, scope),
    do: NetperfResponder.disable_responder(responder, scope: scope)

  defp toggle_responder_record(responder, scope), do: NetperfResponder.enable_responder(responder, scope: scope)

  defp initial_run_params(assigns) do
    enabled_responder =
      Enum.find(assigns.responders_list, &(&1.enabled != false)) ||
        List.first(assigns.responders_list)

    default_sender =
      Enum.find_value(assigns.agents_list, "", fn agent ->
        if is_nil(enabled_responder) or agent.uid != enabled_responder.agent_uid,
          do: agent.uid
      end)

    Forms.default_run_params()
    |> Map.put("sender_agent_id", default_sender)
    |> maybe_put_initial_responder(enabled_responder)
    |> Forms.apply_run_presets(
      assigns.responders_list,
      assigns.profiles_list,
      &Data.resolve_responder_address/1
    )
  end

  defp maybe_put_initial_responder(params, nil), do: params

  defp maybe_put_initial_responder(params, responder) do
    Map.put(params, "responder_agent_id", responder.agent_uid)
  end

  defp maybe_insert_command_into_stream(socket, command_id, scope) do
    case Data.get_command(command_id, scope) do
      nil ->
        socket

      command ->
        socket
        |> assign(:recent_runs_count, max(socket.assigns.recent_runs_count, 1))
        |> stream_insert(:recent_runs, command, at: 0)
    end
  end

  defp dispatch_netperf_run(sender_agent_id, params, opts) do
    command_bus = Application.get_env(:serviceradar_web_ng, :netperf_command_bus, AgentCommandBus)
    command_bus.dispatch_netperf_run(sender_agent_id, params, opts)
  end

  defp normalize_tab(tab) when tab in @supported_tabs, do: tab
  defp normalize_tab(_), do: "policies"

  defp authorize_manage_event(socket, fun) when is_function(fun, 0) do
    if fresh_can_manage?(socket.assigns[:current_scope]) do
      fun.()
    else
      {:noreply, unauthorized(socket)}
    end
  end

  defp unauthorized(socket) do
    socket
    |> put_flash(:error, "Not authorized to manage network performance settings")
    |> redirect(to: ~p"/settings/profile")
  end

  defp fresh_can_manage?(%{user: user}) when not is_nil(user) do
    ServiceRadar.Identity.RBAC.clear_process_cache()
    ServiceRadar.Identity.RBAC.has_permission?(user, @manage_permission)
  end

  defp fresh_can_manage?(scope), do: can_manage?(scope)

  defp can_manage?(scope), do: RBAC.can?(scope, @manage_permission)
end
