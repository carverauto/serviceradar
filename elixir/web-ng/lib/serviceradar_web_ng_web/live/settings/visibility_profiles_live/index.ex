defmodule ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.Index do
  @moduledoc """
  LiveView for host network visibility profile management.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.Components
  import ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.FormState
  import ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.TargetBuilder

  alias ServiceRadar.AgentConfig.Compilers.VisibilityCompiler
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.Inventory.VisibilityProfile
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @current_path "/settings/networks/visibility-profiles"
  @read_permission "visibility_profiles:read"
  @write_permission "visibility_profiles:write"
  @delete_permission "visibility_profiles:delete"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @read_permission) do
      socket =
        socket
        |> assign(:page_title, "Visibility Profiles")
        |> assign(:current_path, @current_path)
        |> assign(:profiles, load_profiles(scope))
        |> assign(:selected_profile, nil)
        |> assign(:show_form, nil)
        |> assign(:form, default_form())
        |> assign(:errors, [])
        |> assign(:json_preview, nil)
        |> assign(:target_device_count, nil)
        |> assign(:builder_open, false)
        |> assign(:builder, default_builder_state())
        |> assign(:builder_sync, true)
        |> assign(:can_write, RBAC.can?(scope, @write_permission))
        |> assign(:can_delete, RBAC.can?(scope, @delete_permission))

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to Visibility Profiles")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Visibility Profiles")
    |> assign(:show_form, nil)
    |> assign(:selected_profile, nil)
    |> assign(:form, default_form())
    |> assign(:errors, [])
    |> assign(:json_preview, nil)
    |> assign(:target_device_count, nil)
    |> assign(:builder_open, false)
    |> assign(:builder, default_builder_state())
    |> assign(:builder_sync, true)
  end

  defp apply_action(socket, :new_profile, _params) do
    if socket.assigns.can_write do
      socket
      |> assign(:page_title, "New Visibility Profile")
      |> assign(:show_form, :new_profile)
      |> assign(:selected_profile, nil)
      |> assign(:form, default_form())
      |> assign(:errors, [])
      |> assign(:json_preview, nil)
      |> assign(:target_device_count, nil)
      |> assign(:builder_open, false)
      |> assign(:builder, default_builder_state())
      |> assign(:builder_sync, true)
    else
      socket
      |> put_flash(:error, "You cannot create Visibility Profiles")
      |> push_navigate(to: ~p"/settings/networks/visibility-profiles")
    end
  end

  defp apply_action(socket, :edit_profile, %{"id" => id}) do
    if socket.assigns.can_write do
      case load_profile(socket.assigns.current_scope, id) do
        nil ->
          socket
          |> put_flash(:error, "Visibility Profile not found")
          |> push_navigate(to: ~p"/settings/networks/visibility-profiles")

        profile ->
          form = form_from_profile(profile)
          device_count = count_target_devices(socket.assigns.current_scope, profile.target_query)
          {builder, builder_sync} = parse_target_query_to_builder(profile.target_query)

          socket
          |> assign(:page_title, "Edit #{profile.name}")
          |> assign(:show_form, :edit_profile)
          |> assign(:selected_profile, profile)
          |> assign(:form, form)
          |> assign(:errors, [])
          |> assign(:json_preview, compile_profile_preview(profile))
          |> assign(:target_device_count, device_count)
          |> assign(:builder_open, false)
          |> assign(:builder, builder)
          |> assign(:builder_sync, builder_sync)
      end
    else
      socket
      |> put_flash(:error, "You cannot edit Visibility Profiles")
      |> push_navigate(to: ~p"/settings/networks/visibility-profiles")
    end
  end

  @impl true
  def handle_event("validate_profile", %{"form" => params}, socket) do
    form = normalize_form(params)
    {builder, builder_sync} = parse_target_query_to_builder(form["target_query"])

    socket =
      socket
      |> assign(:form, form)
      |> assign(:errors, validate_form(form))
      |> assign(:target_device_count, count_target_devices(socket.assigns.current_scope, form["target_query"]))
      |> assign(:builder_sync, builder_sync)

    socket = if builder_sync, do: assign(socket, :builder, builder), else: socket

    {:noreply, socket}
  end

  def handle_event("save_profile", %{"form" => params}, socket) do
    if socket.assigns.can_write do
      form = normalize_form(params)

      case validate_form(form) do
        [] ->
          save_profile(socket, form)

        errors ->
          {:noreply, socket |> assign(:form, form) |> assign(:errors, errors)}
      end
    else
      {:noreply, put_flash(socket, :error, "You cannot save Visibility Profiles")}
    end
  end

  def handle_event("toggle_profile", %{"id" => id}, socket) do
    if socket.assigns.can_write do
      scope = socket.assigns.current_scope

      case load_profile(scope, id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Visibility Profile not found")}

        profile ->
          profile
          |> Ash.Changeset.for_update(:update, %{enabled: !profile.enabled})
          |> Ash.update(scope: scope)
          |> case do
            {:ok, _updated} ->
              _ = ConfigServer.invalidate(:visibility)

              {:noreply,
               socket
               |> assign(:profiles, load_profiles(scope))
               |> put_flash(:info, "Visibility Profile updated")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, error_message(reason))}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "You cannot update Visibility Profiles")}
    end
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    if socket.assigns.can_delete do
      scope = socket.assigns.current_scope

      case load_profile(scope, id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Visibility Profile not found")}

        profile ->
          case Ash.destroy(profile, scope: scope) do
            :ok ->
              _ = ConfigServer.invalidate(:visibility)

              {:noreply,
               socket
               |> assign(:profiles, load_profiles(scope))
               |> put_flash(:info, "Visibility Profile deleted")}

            {:ok, _} ->
              _ = ConfigServer.invalidate(:visibility)

              {:noreply,
               socket
               |> assign(:profiles, load_profiles(scope))
               |> put_flash(:info, "Visibility Profile deleted")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, error_message(reason))}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "You cannot delete Visibility Profiles")}
    end
  end

  def handle_event("preview_json", %{"id" => id}, socket) do
    case load_profile(socket.assigns.current_scope, id) do
      nil -> {:noreply, put_flash(socket, :error, "Visibility Profile not found")}
      profile -> {:noreply, assign(socket, :json_preview, compile_profile_preview(profile))}
    end
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, :json_preview, nil)}
  end

  def handle_event("builder_toggle", _params, socket) do
    if socket.assigns.builder_open do
      {:noreply, assign(socket, :builder_open, false)}
    else
      {builder, builder_sync} = parse_target_query_to_builder(socket.assigns.form["target_query"])

      {:noreply,
       socket
       |> assign(:builder_open, true)
       |> assign(:builder, builder)
       |> assign(:builder_sync, builder_sync)}
    end
  end

  def handle_event("builder_change", %{"builder" => builder_params}, socket) do
    builder = update_builder(socket.assigns.builder, builder_params)

    {:noreply,
     socket
     |> assign(:builder, builder)
     |> assign(:builder_sync, true)
     |> maybe_sync_builder_to_form()}
  end

  def handle_event("builder_add_filter", _params, socket) do
    builder = socket.assigns.builder
    filters = Map.get(builder, "filters", [])
    filter = List.first(default_builder_state()["filters"])

    {:noreply,
     socket
     |> assign(:builder, Map.put(builder, "filters", filters ++ [filter]))
     |> assign(:builder_sync, true)
     |> maybe_sync_builder_to_form()}
  end

  def handle_event("builder_remove_filter", %{"idx" => idx_str}, socket) do
    idx = parse_int(idx_str, -1)
    builder = socket.assigns.builder

    filters =
      builder
      |> Map.get("filters", [])
      |> Enum.with_index()
      |> Enum.reject(fn {_filter, i} -> i == idx end)
      |> Enum.map(fn {filter, _i} -> filter end)

    filters = if filters == [], do: default_builder_state()["filters"], else: filters

    {:noreply,
     socket
     |> assign(:builder, Map.put(builder, "filters", filters))
     |> assign(:builder_sync, true)
     |> maybe_sync_builder_to_form()}
  end

  def handle_event("builder_apply", _params, socket) do
    query = build_target_query(socket.assigns.builder)
    form = Map.put(socket.assigns.form, "target_query", query)

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:errors, validate_form(form))
     |> assign(:target_device_count, count_target_devices(socket.assigns.current_scope, query))
     |> assign(:builder_sync, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <%= if @show_form in [:new_profile, :edit_profile] do %>
          <.profile_form
            form={@form}
            errors={@errors}
            show_form={@show_form}
            selected_profile={@selected_profile}
            target_device_count={@target_device_count}
            builder_open={@builder_open}
            builder={@builder}
            builder_sync={@builder_sync}
          />
        <% else %>
          <.profiles_panel profiles={@profiles} can_write={@can_write} can_delete={@can_delete} />
        <% end %>

        <.json_preview_modal :if={@json_preview && @show_form == nil} json_preview={@json_preview} />
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp save_profile(socket, form) do
    scope = socket.assigns.current_scope
    attrs = form_attrs(form)

    result =
      case socket.assigns.show_form do
        :new_profile ->
          VisibilityProfile
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create(scope: scope)

        :edit_profile ->
          socket.assigns.selected_profile
          |> Ash.Changeset.for_update(:update, attrs)
          |> Ash.update(scope: scope)
      end

    case result do
      {:ok, _profile} ->
        _ = ConfigServer.invalidate(:visibility)

        {:noreply,
         socket
         |> assign(:profiles, load_profiles(scope))
         |> put_flash(:info, "Visibility Profile saved")
         |> push_navigate(to: ~p"/settings/networks/visibility-profiles")}

      {:error, reason} ->
        {:noreply, socket |> assign(:form, form) |> assign(:errors, [error_message(reason)])}
    end
  end

  defp load_profiles(scope) do
    case Ash.read(VisibilityProfile, scope: scope) do
      {:ok, profiles} -> Enum.sort_by(profiles, fn profile -> {-profile.priority, profile.name} end)
      {:error, _reason} -> []
    end
  end

  defp load_profile(scope, id) do
    case Ash.get(VisibilityProfile, id, scope: scope) do
      {:ok, profile} -> profile
      {:error, _reason} -> nil
    end
  end

  defp compile_profile_preview(profile) do
    profile
    |> VisibilityCompiler.compile_profile("192.0.2.10")
    |> Jason.encode!(pretty: true)
  rescue
    _ -> ~s({"error":"Failed to compile visibility config"})
  end

  defp count_target_devices(_scope, nil), do: nil
  defp count_target_devices(_scope, ""), do: nil

  defp count_target_devices(scope, target_query) when is_binary(target_query) do
    query = String.trim(target_query)

    full_query =
      cond do
        query == "" -> ~s|in:devices stats:"count() as total"|
        String.starts_with?(query, "in:") -> ~s|#{query} stats:"count() as total"|
        true -> ~s|in:devices #{query} stats:"count() as total"|
      end

    case srql_module().query(full_query, %{scope: scope}) do
      {:ok, %{"results" => [%{"total" => count} | _]}} when is_integer(count) -> count
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp maybe_sync_builder_to_form(socket) do
    if socket.assigns.builder_sync do
      query = build_target_query(socket.assigns.builder)
      form = Map.put(socket.assigns.form, "target_query", query)

      socket
      |> assign(:form, form)
      |> assign(:target_device_count, count_target_devices(socket.assigns.current_scope, query))
    else
      socket
    end
  end

  defp error_message(reason), do: Exception.message(Ash.Error.to_error_class(reason))
end
