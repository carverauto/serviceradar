defmodule ServiceRadarWebNGWeb.DashboardPackageLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AuthoredDashboardLive.SettingsComponents, only: [sharing_settings: 1]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Dashboards.DashboardUserPreference
  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNGWeb.DashboardFrameChannel
  alias ServiceRadarWebNGWeb.DashboardPackageLive.AccessControls
  alias ServiceRadarWebNGWeb.DashboardPackageLive.Preferences
  alias ServiceRadarWebNGWeb.SRQL.Builder, as: SRQLBuilder
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  require Logger

  @mapbox_public_token_regex ~r/^pk\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/
  @dashboard_search_query "in:dashboards limit:100"
  @dashboard_search_limit 100

  @impl true
  def mount(%{"route_slug" => route_slug}, _session, socket) do
    socket =
      socket
      |> assign(:route_slug, route_slug)
      |> assign(:current_path, "/dashboards/#{route_slug}")
      |> assign(:page_title, "Dashboard")
      |> assign(:load_state, :loading)
      |> assign(:instance, nil)
      |> assign(:package, nil)
      |> assign(:query_text, "")
      |> assign(:frame_query_overrides, %{})
      |> assign(:dashboard_catalog_limit, @dashboard_search_limit)
      |> assign(:host_payload_json, "{}")
      |> assign(:can_share?, false)
      |> assign(:sharing_open?, false)
      |> assign(:access_grants, [])
      |> assign(:users, [])
      |> assign(:user_groups, [])
      |> assign(:can_view_groups?, AccessControls.can_view_groups?(socket.assigns.current_scope))
      |> assign(
        :can_view_share_principals?,
        AccessControls.can_view_share_principals?(socket.assigns.current_scope)
      )
      |> assign(:user_grant_params, AccessControls.default_user_grant_params())
      |> assign(:group_grant_params, AccessControls.default_group_grant_params())
      |> assign(:visibility_params, %{"visibility" => "public"})
      |> assign_grant_forms()
      |> assign_visibility_form()
      |> assign_dashboard_search_srql(dashboard_reference_query(route_slug))

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"route_slug" => route_slug} = params, _uri, socket) do
    overrides = authorized_frame_query_overrides(params, socket.assigns.current_scope)

    keep_host_mounted? =
      connected?(socket) and socket.assigns.load_state == :ready and
        socket.assigns.route_slug == route_slug

    socket =
      socket
      |> assign(:route_slug, route_slug)
      |> assign(:current_path, "/dashboards/#{route_slug}")
      |> assign(:frame_query_overrides, overrides)

    socket =
      if keep_host_mounted? do
        socket
      else
        assign(socket, :load_state, :loading)
      end

    socket =
      if connected?(socket) do
        scope = socket.assigns.current_scope

        start_async(socket, :dashboard_package_load, fn ->
          load_dashboard_package(route_slug, scope, overrides)
        end)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    query = params |> Map.get("q", "") |> to_string() |> String.trim()
    {:noreply, push_dashboard_search(socket, query)}
  end

  def handle_event("srql_reset", _params, socket) do
    query = dashboard_reference_query(socket.assigns.route_slug)
    path = socket.assigns.current_path || "/dashboards/#{socket.assigns.route_slug}"
    {:noreply, push_patch(socket, to: path <> "?" <> URI.encode_query(%{"q" => query}))}
  end

  def handle_event("dashboard_srql_query", params, socket) do
    query = params |> Map.get("q", "") |> to_string() |> String.trim()

    frame_queries =
      params
      |> authorized_frame_query_overrides(socket.assigns.current_scope)
      |> Map.delete("__first__")

    {:noreply, push_dashboard_queries(socket, query, frame_queries)}
  end

  def handle_event("dashboard_preference_update", params, socket) do
    key = params |> Map.get("key", "") |> to_string() |> String.trim()
    value = Map.get(params, "value")

    {:noreply, put_dashboard_preference(socket, key, value)}
  end

  def handle_event("dashboard_detail_request", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_toggle", %{},
       entity: "dashboards",
       limit_assign_key: :dashboard_catalog_limit
     )}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "dashboards")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "dashboards")}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    query =
      socket.assigns
      |> Map.get(:srql, %{})
      |> Map.get(:builder, %{})
      |> SRQLBuilder.build()

    {:noreply, push_dashboard_search(socket, query)}
  end

  def handle_event("run_query", %{"query" => %{"q" => query}}, socket) do
    {:noreply, push_dashboard_search(socket, query)}
  end

  def handle_event("toggle_sharing", _params, socket) do
    {:noreply, assign(socket, :sharing_open?, !socket.assigns.sharing_open?)}
  end

  def handle_event("close_sharing", _params, socket) do
    {:noreply, assign(socket, :sharing_open?, false)}
  end

  def handle_event("update_visibility", %{"instance" => params}, socket) do
    params = stringify_map(params)

    with :ok <- AccessControls.authorize_share(socket),
         %DashboardInstance{} = instance <- socket.assigns.instance,
         {:ok, updated} <-
           Dashboards.update_instance(instance.id, %{visibility: params["visibility"]},
             scope: socket.assigns.current_scope
           ) do
      {:noreply,
       socket
       |> assign(:instance, updated)
       |> assign(:visibility_params, %{"visibility" => to_string(updated.visibility)})
       |> assign_visibility_form()
       |> put_flash(:info, "Visibility updated")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Visibility update failed: #{format_share_error(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Visibility update failed")}
    end
  end

  def handle_event("validate_user_grant", %{"grant" => params}, socket) do
    {:noreply,
     socket
     |> assign(:user_grant_params, merge_grant_params(socket.assigns.user_grant_params, params))
     |> assign_grant_forms()}
  end

  def handle_event("validate_group_grant", %{"grant" => params}, socket) do
    {:noreply,
     socket
     |> assign(:group_grant_params, merge_grant_params(socket.assigns.group_grant_params, params))
     |> assign_grant_forms()}
  end

  def handle_event("grant_user", %{"grant" => params}, socket) do
    params = merge_grant_params(socket.assigns.user_grant_params, params)

    with :ok <- AccessControls.authorize_share(socket),
         %DashboardInstance{} = instance <- socket.assigns.instance,
         {:ok, _grant} <-
           Dashboards.grant_instance_to_user(
             socket.assigns.current_scope,
             Map.put(params, "dashboard_instance_id", instance.id)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "User access updated")
       |> assign(:user_grant_params, AccessControls.default_user_grant_params())
       |> reload_sharing()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:user_grant_params, params)
         |> assign_grant_forms()
         |> put_flash(:error, "User grant failed: #{format_share_error(reason)}")}
    end
  end

  def handle_event("grant_group", %{"grant" => params}, socket) do
    params = merge_grant_params(socket.assigns.group_grant_params, params)

    with :ok <- AccessControls.authorize_share(socket),
         %DashboardInstance{} = instance <- socket.assigns.instance,
         {:ok, _grant} <-
           Dashboards.grant_instance_to_group(
             socket.assigns.current_scope,
             Map.put(params, "dashboard_instance_id", instance.id)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Group access updated")
       |> assign(:group_grant_params, AccessControls.default_group_grant_params())
       |> reload_sharing()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:group_grant_params, params)
         |> assign_grant_forms()
         |> put_flash(:error, "Group grant failed: #{format_share_error(reason)}")}
    end
  end

  def handle_event("revoke_grant", %{"id" => id}, socket) do
    grant = Enum.find(socket.assigns.access_grants, &(to_string(&1.id) == to_string(id)))

    with :ok <- AccessControls.authorize_share(socket),
         %{} = grant <- grant,
         :ok <- Dashboards.revoke_instance_access_grant(socket.assigns.current_scope, grant) do
      {:noreply, socket |> put_flash(:info, "Access revoked") |> reload_sharing()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Revoke failed: #{format_share_error(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Revoke failed")}
    end
  end

  @impl true
  def handle_async(
        :dashboard_package_load,
        {:ok, {:ok, %DashboardInstance{} = instance, data_frames, frames, mapbox}},
        socket
      ) do
    package = instance.dashboard_package

    socket =
      socket
      |> assign(:load_state, :ready)
      |> assign(:instance, instance)
      |> assign(:package, package)
      |> assign(:page_title, instance.name)
      |> assign(:query_text, first_frame_query(data_frames))
      |> assign_dashboard_search_srql(dashboard_reference_query(instance.route_slug))
      |> assign_sharing(instance)
      |> assign(
        :host_payload_json,
        Jason.encode!(
          host_payload(
            instance,
            package,
            data_frames,
            frames,
            mapbox,
            socket.assigns.frame_query_overrides,
            stored_preferences(socket, instance.route_slug),
            current_user_id(socket)
          )
        )
      )

    {:noreply, socket}
  end

  def handle_async(:dashboard_package_load, {:ok, {:error, :not_found}}, socket) do
    if default_package_slug?(socket, socket.assigns.route_slug) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Your default dashboard is no longer available. Choose another from the library."
       )
       |> push_navigate(to: ~p"/dashboards")}
    else
      {:noreply, assign(socket, :load_state, :not_found)}
    end
  end

  def handle_async(:dashboard_package_load, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:load_state, :error) |> assign(:load_error, inspect(reason))}
  end

  def handle_async(:dashboard_package_load, {:exit, reason}, socket) do
    {:noreply, socket |> assign(:load_state, :error) |> assign(:load_error, inspect(reason))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title={@page_title}
      shell={:operations}
      hide_breadcrumb
      srql={@srql}
    >
      <%!-- Package dashboards fill the page; overlay chrome blocked renderer controls. --%>
      <:topbar_actions :if={@can_share?}>
        <.ui_button
          type="button"
          id="dashboard-package-share-button"
          phx-click="toggle_sharing"
          size="sm"
          variant="neutral"
          active={@sharing_open?}
          aria-expanded={to_string(@sharing_open?)}
          aria-controls="dashboard-package-share-modal"
        >
          <.icon name="hero-share" class="size-4" /> Share
        </.ui_button>
      </:topbar_actions>

      <.ui_modal
        :if={@can_share?}
        id="dashboard-package-share-modal"
        open={@sharing_open?}
        size="xl"
        on_cancel="close_sharing"
      >
        <:title>Share dashboard</:title>
        <.form
          for={@visibility_form}
          as={:instance}
          phx-submit="update_visibility"
          class="mb-4 space-y-3"
        >
          <.input
            field={@visibility_form[:visibility]}
            type="select"
            label="Visibility"
            options={AccessControls.visibility_options()}
          />
          <p class="text-xs text-sr-muted">
            Grants apply when visibility is Shared. Private is owner-only; Public is every signed-in user.
          </p>
          <.ui_button type="submit" size="sm" variant="primary">Save visibility</.ui_button>
        </.form>

        <.sharing_settings
          dashboard={@instance}
          access_grants={@access_grants}
          user_grant_form={@user_grant_form}
          group_grant_form={@group_grant_form}
          users={@users}
          user_groups={@user_groups}
          can_view_groups?={@can_view_groups?}
          show_pickers?={@can_view_share_principals?}
        />
      </.ui_modal>

      <div class="min-h-[calc(100vh-5rem)] bg-sr-surface">
        <div :if={@load_state == :loading} class="flex min-h-[28rem] items-center justify-center">
          <.ui_spinner size="lg" />
        </div>

        <div
          :if={@load_state == :not_found}
          class="mx-auto flex min-h-[28rem] max-w-2xl flex-col items-center justify-center gap-3 px-6 text-center"
        >
          <div class="text-lg font-semibold text-sr-ink">Dashboard package unavailable</div>
          <p class="text-sm text-sr-muted">
            This dashboard is not enabled, has not been verified, or no longer exists.
          </p>
          <.ui_button navigate={~p"/dashboard"} size="sm" variant="primary">
            Back to dashboard
          </.ui_button>
        </div>

        <div
          :if={@load_state == :error}
          class="mx-auto flex min-h-[28rem] max-w-2xl flex-col items-center justify-center gap-3 px-6 text-center"
        >
          <div class="text-lg font-semibold text-sr-ink">Dashboard package failed to load</div>
          <p class="text-sm text-sr-muted">{@load_error}</p>
          <.ui_button navigate={~p"/dashboard"} size="sm" variant="primary">
            Back to dashboard
          </.ui_button>
        </div>

        <section :if={@load_state == :ready} class="flex min-h-[calc(100vh-5rem)] flex-col">
          <div
            id={"dashboard-package-host-#{@instance.id}"}
            phx-hook="DashboardWasmHost"
            phx-update="ignore"
            data-host={@host_payload_json}
            data-timezone={@current_scope.user.timezone || "Etc/UTC"}
            class="relative min-h-[calc(100vh-5rem)] flex-1 bg-sr-surface px-3 py-3 sm:px-5 sm:py-4"
          >
            <div class="absolute inset-0 flex items-center justify-center">
              <div class="text-center">
                <.ui_spinner size="md" />
                <div class="mt-3 text-sm text-sr-muted">Loading dashboard renderer</div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp load_dashboard_package(route_slug, scope, overrides) do
    with {:ok, %DashboardInstance{} = instance} <-
           Dashboards.get_enabled_instance_by_slug(route_slug, scope: scope) do
      package = instance.dashboard_package
      data_frames = apply_frame_query_overrides(package.data_frames || [], overrides)
      initial_data_frames = initial_data_frames(data_frames)
      frames = pending_frames(initial_data_frames)
      mapbox = read_mapbox(scope)
      {:ok, instance, data_frames, frames, mapbox}
    end
  end

  defp pending_frames(data_frames) when is_list(data_frames) do
    Enum.map(data_frames, fn frame ->
      %{
        "id" => frame_id(frame),
        "query" => frame_value(frame, "query", :query),
        "requested_encoding" => frame_value(frame, "encoding", :encoding) || "json_rows",
        "encoding" => "json_rows",
        "limit" => frame_value(frame, "limit", :limit),
        "required" => required_frame?(frame),
        "status" => "loading",
        "results" => []
      }
    end)
  end

  defp pending_frames(_data_frames), do: []

  defp initial_data_frames(data_frames) when is_list(data_frames) do
    required_frames = Enum.filter(data_frames, &required_frame?/1)

    case required_frames do
      [] -> Enum.take(data_frames, 1)
      frames -> frames
    end
  end

  defp initial_data_frames(_data_frames), do: []

  defp required_frame?(frame) when is_map(frame) do
    case frame_value(frame, "required", :required) do
      false -> false
      "false" -> false
      _ -> true
    end
  end

  defp required_frame?(_frame), do: true

  defp frame_value(frame, string_key, atom_key) when is_map(frame) do
    cond do
      Map.has_key?(frame, string_key) -> Map.get(frame, string_key)
      Map.has_key?(frame, atom_key) -> Map.get(frame, atom_key)
      true -> nil
    end
  end

  defp dashboard_reference_query(dashboard_ref) do
    dashboard_ref = dashboard_ref |> to_string() |> String.trim()

    if dashboard_ref == "" do
      @dashboard_search_query
    else
      "in:dashboards dashboard_ref:#{escape_srql_value(dashboard_ref)} limit:#{@dashboard_search_limit}"
    end
  end

  defp escape_srql_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace(" ", "\\ ")
  end

  defp assign_dashboard_search_srql(socket, query) do
    query = to_string(query || "")
    {builder_supported, builder_sync, builder} = dashboard_search_builder(query)

    srql = %{
      enabled: true,
      placement: :topbar,
      entity: "dashboards",
      page_path: socket.assigns.current_path,
      query: query,
      draft: query,
      error: nil,
      loading: false,
      builder_available: true,
      builder_open: false,
      builder_supported: builder_supported,
      builder_sync: builder_sync,
      builder: builder
    }

    assign(socket, :srql, srql)
  end

  defp dashboard_search_builder(query) do
    case SRQLBuilder.parse(query) do
      {:ok, builder} -> {true, true, builder}
      {:error, _} -> {false, false, SRQLBuilder.default_state("dashboards", @dashboard_search_limit)}
    end
  end

  defp push_dashboard_search(socket, query) do
    query = normalize_dashboard_search_query(query)
    push_navigate(socket, to: ~p"/dashboards?#{%{q: query}}")
  end

  defp normalize_dashboard_search_query(query) do
    query = query |> to_string() |> String.trim()

    cond do
      query == "" -> @dashboard_search_query
      String.contains?(query, "in:dashboards") -> query
      true -> "in:dashboards #{query} limit:#{@dashboard_search_limit}"
    end
  end

  defp push_dashboard_queries(socket, query, frame_queries) do
    query = query |> to_string() |> String.trim()

    frame_params =
      Enum.reduce(frame_queries, %{}, fn {frame_id, frame_query}, acc ->
        frame_id = frame_id |> to_string() |> String.trim()
        frame_query = frame_query |> to_string() |> String.trim()

        if frame_id != "" and frame_query != "" do
          Map.put(acc, "frame_#{frame_id}", frame_query)
        else
          acc
        end
      end)

    to =
      if query == "" do
        case frame_params do
          params when map_size(params) == 0 -> ~p"/dashboards/#{socket.assigns.route_slug}"
          params -> ~p"/dashboards/#{socket.assigns.route_slug}?#{params}"
        end
      else
        ~p"/dashboards/#{socket.assigns.route_slug}?#{Map.put(frame_params, "q", query)}"
      end

    push_patch(socket, to: to)
  end

  # Renderer preferences are per user and per dashboard route, and live in the
  # `metadata` map of that user's DashboardUserPreference row for this package —
  # the same row that already records whether the dashboard is a favorite — so
  # this needs no new table.
  defp put_dashboard_preference(socket, "", _value), do: socket

  defp put_dashboard_preference(socket, key, value) do
    user = current_user(socket)
    route_slug = socket.assigns[:route_slug]

    if is_nil(user) or not is_binary(route_slug) do
      socket
    else
      existing = fetch_dashboard_preference(user, route_slug)

      attrs = %{
        user_id: user.id,
        target_type: :package,
        target_id: route_slug,
        metadata: Preferences.put(preference_metadata(existing), key, value),
        # `upsert_fields` includes :favorite and :is_default, so omitting them
        # here would silently reset the row's dashboard-level favorite to the
        # create action's default on every preference write.
        favorite: preference_flag(existing, :favorite),
        is_default: preference_flag(existing, :is_default)
      }

      case DashboardUserPreference.upsert_preference(attrs, actor: user) do
        {:ok, _preference} ->
          socket

        {:error, reason} ->
          Logger.warning("dashboard preference write failed: #{inspect(reason)}")
          socket
      end
    end
  end

  defp fetch_dashboard_preference(user, route_slug) do
    case DashboardUserPreference.for_user(user.id, actor: user) do
      {:ok, preferences} ->
        Enum.find(preferences, fn preference ->
          preference.target_type == :package and preference.target_id == route_slug
        end)

      {:error, _reason} ->
        nil
    end
  end

  defp preference_metadata(%DashboardUserPreference{metadata: metadata}) when is_map(metadata), do: metadata

  defp preference_metadata(_), do: %{}

  defp preference_flag(%DashboardUserPreference{} = preference, field), do: Map.get(preference, field) || false

  defp preference_flag(_preference, _field), do: false

  defp stored_preferences(socket, route_slug) do
    case current_user(socket) do
      nil -> %{}
      user -> user |> fetch_dashboard_preference(route_slug) |> preference_metadata()
    end
  end

  defp current_user(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: _id} = user} -> user
      _ -> nil
    end
  end

  defp host_payload(
         %DashboardInstance{} = instance,
         %DashboardPackage{} = package,
         data_frames,
         frames,
         mapbox,
         overrides,
         preferences,
         user_id
       ) do
    %{
      "host" => %{
        "version" => "dashboard-host-v1",
        "interface_version" => package.renderer["interface_version"] || "dashboard-wasm-v1"
      },
      "data_provider" => %{
        "version" => "dashboard-data-v1",
        "frames" => Enum.map(frames, &frame_summary/1),
        "stream_topic" => "dashboards:#{instance.route_slug}",
        "stream_token" =>
          DashboardFrameChannel.stream_token(
            instance.route_slug,
            data_frames,
            user_id,
            active_optional_frame_ids(data_frames, overrides)
          ),
        "refresh_interval_ms" => 15_000
      },
      "mapbox" => %{
        "enabled" => mapbox_enabled?(mapbox),
        "access_token" => mapbox_access_token(mapbox),
        "style_light" => mapbox_style_light(mapbox),
        "style_dark" => mapbox_style_dark(mapbox)
      },
      "instance" => %{
        "id" => instance.id,
        "name" => instance.name,
        "route_slug" => instance.route_slug,
        "placement" => Atom.to_string(instance.placement),
        # The instance's own settings are the seed; the signed-in user's stored
        # preferences win over them. The renderer reads both through
        # `settings.preferences`.
        "settings" => Preferences.merge(instance.settings || %{}, preferences)
      },
      "package" => %{
        "id" => package.id,
        "dashboard_id" => package.dashboard_id,
        "name" => package.name,
        "version" => package.version,
        "vendor" => package.vendor,
        "source_type" => Atom.to_string(package.source_type || :upload),
        "capabilities" => package.capabilities || [],
        "renderer" => package.renderer || %{},
        "data_frames" => data_frames,
        "frames" => frames,
        "renderer_url" => ~p"/dashboard-packages/#{package.id}/renderer?v=#{package.content_hash}",
        "wasm_url" => ~p"/dashboard-packages/#{package.id}/renderer.wasm?v=#{package.content_hash}"
      }
    }
  end

  defp authorized_frame_query_overrides(params, scope) do
    if AccessControls.can_manage_queries?(scope) do
      frame_query_overrides(params)
    else
      %{}
    end
  end

  defp frame_query_overrides(params) do
    q = params |> Map.get("q", "") |> to_string() |> String.trim()

    params
    |> Enum.reduce(%{}, fn
      {"frame_" <> frame_id, value}, acc ->
        value = value |> to_string() |> String.trim()
        if frame_id != "" and value != "", do: Map.put(acc, frame_id, value), else: acc

      _other, acc ->
        acc
    end)
    |> maybe_put_first_query(q)
  end

  defp maybe_put_first_query(overrides, ""), do: overrides
  defp maybe_put_first_query(overrides, query), do: Map.put(overrides, "__first__", query)

  defp active_optional_frame_ids(data_frames, overrides) when is_list(data_frames) and is_map(overrides) do
    optional_frame_ids =
      data_frames
      |> Enum.reject(&required_frame?/1)
      |> Enum.map(&frame_id/1)

    override_frame_ids =
      overrides
      |> Map.keys()
      |> Enum.reject(&(&1 == "__first__"))
      |> Enum.map(&to_string/1)

    (optional_frame_ids ++ override_frame_ids)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp active_optional_frame_ids(_data_frames, _overrides), do: []

  defp apply_frame_query_overrides(data_frames, overrides) when is_list(data_frames) do
    data_frames
    |> Enum.with_index()
    |> Enum.map(fn {frame, index} ->
      frame_id = frame_id(frame)
      query = Map.get(overrides, frame_id) || if(index == 0, do: Map.get(overrides, "__first__"))

      if is_binary(query) and query != "" do
        Map.put(frame, "query", query)
      else
        frame
      end
    end)
  end

  defp apply_frame_query_overrides(_data_frames, _overrides), do: []

  defp frame_id(%{"id" => id}) when is_binary(id), do: id
  defp frame_id(%{id: id}) when is_binary(id), do: id
  defp frame_id(_frame), do: ""

  defp first_frame_query([%{"query" => query} | _]) when is_binary(query), do: query
  defp first_frame_query([%{query: query} | _]) when is_binary(query), do: query
  defp first_frame_query(_data_frames), do: ""

  defp frame_summary(frame) when is_map(frame) do
    %{
      "id" => frame["id"],
      "status" => frame["status"],
      "encoding" => frame["encoding"],
      "requested_encoding" => frame["requested_encoding"],
      "row_count" => frame |> Map.get("results", []) |> row_count(),
      "byte_length" => Map.get(frame, "byte_length")
    }
  end

  defp frame_summary(_frame), do: %{"id" => nil, "status" => "error", "row_count" => 0}

  defp row_count(results) when is_list(results), do: length(results)
  defp row_count(_results), do: 0

  defp read_mapbox(_scope) do
    case MapboxSettings.get_settings(actor: SystemActor.system(:dashboard_package_host)) do
      {:ok, %MapboxSettings{} = settings} -> settings
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp mapbox_enabled?(%MapboxSettings{} = settings) do
    settings.enabled || mapbox_public_token?(settings.access_token)
  end

  defp mapbox_enabled?(_), do: false

  defp mapbox_access_token(%MapboxSettings{} = settings), do: settings.access_token || ""
  defp mapbox_access_token(_), do: ""

  defp mapbox_public_token?(token) when is_binary(token) do
    Regex.match?(@mapbox_public_token_regex, String.trim(token))
  end

  defp mapbox_public_token?(_), do: false

  defp mapbox_style_light(%MapboxSettings{} = settings) do
    settings.style_light || "mapbox://styles/mapbox/light-v11"
  end

  defp mapbox_style_light(_), do: "mapbox://styles/mapbox/light-v11"

  defp mapbox_style_dark(%MapboxSettings{} = settings) do
    settings.style_dark || "mapbox://styles/mapbox/dark-v11"
  end

  defp mapbox_style_dark(_), do: "mapbox://styles/mapbox/dark-v11"

  defp assign_sharing(socket, %DashboardInstance{} = instance) do
    scope = socket.assigns.current_scope
    can_share? = AccessControls.can_share_instance?(instance, scope)

    loaded =
      AccessControls.load(scope, instance, %{
        can_view_groups?: socket.assigns.can_view_groups?,
        can_view_share_principals?: socket.assigns.can_view_share_principals?
      })

    socket
    |> assign(:can_share?, can_share?)
    |> assign(:access_grants, loaded.access_grants)
    |> assign(:users, loaded.users)
    |> assign(:user_groups, loaded.user_groups)
    |> assign(:visibility_params, %{"visibility" => to_string(instance.visibility)})
    |> assign_grant_forms()
    |> assign_visibility_form()
  end

  defp reload_sharing(socket) do
    case socket.assigns.instance do
      %DashboardInstance{} = instance -> assign_sharing(socket, instance)
      _ -> socket
    end
  end

  defp assign_grant_forms(socket) do
    socket
    |> assign(:user_grant_form, to_form(socket.assigns.user_grant_params, as: :grant))
    |> assign(:group_grant_form, to_form(socket.assigns.group_grant_params, as: :grant))
  end

  defp assign_visibility_form(socket) do
    assign(socket, :visibility_form, to_form(socket.assigns.visibility_params, as: :instance))
  end

  defp merge_grant_params(current, incoming) when is_map(current) and is_map(incoming) do
    Map.merge(stringify_map(current), stringify_map(incoming))
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp current_user_id(socket) do
    case current_user(socket) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp default_package_slug?(socket, route_slug) when is_binary(route_slug) do
    user = current_user(socket)

    if is_nil(user) do
      false
    else
      case DashboardUserPreference.for_user(user.id, actor: user) do
        {:ok, preferences} ->
          Enum.any?(preferences, fn preference ->
            preference.is_default == true and
              preference.target_type in [:package, "package"] and
              preference.target_id == route_slug
          end)

        _ ->
          false
      end
    end
  end

  defp default_package_slug?(_socket, _route_slug), do: false

  defp format_share_error(%Ash.Error.Forbidden{}), do: "forbidden"
  defp format_share_error(%{message: message}) when is_binary(message), do: message
  defp format_share_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_share_error(reason) when is_binary(reason), do: reason
  defp format_share_error(reason), do: inspect(reason)
end
