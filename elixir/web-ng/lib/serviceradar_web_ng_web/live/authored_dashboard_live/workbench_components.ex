defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.WorkbenchComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.AuthoredDashboardLive.SettingsComponents
  import ServiceRadarWebNGWeb.AuthoredDashboardLive.SourceQueryComponents

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.AccessControls
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.CanvasState
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.SourceQueries

  attr :dashboard, :any, default: nil
  attr :route_param, :string, default: nil

  def dashboard_breadcrumb_header(assigns) do
    canonical_id = Dashboards.authored_dashboard_canonical_id(assigns.dashboard)

    assigns =
      assigns
      |> assign(:canonical_id, canonical_id)
      |> assign(
        :show_canonical_id?,
        show_canonical_id?(assigns.dashboard, assigns.route_param, canonical_id)
      )

    ~H"""
    <header
      id="authored-dashboard-header"
      class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1.5"
    >
      <nav class="sr-ui-breadcrumbs min-w-0 text-sm" aria-label="Breadcrumb">
        <ul>
          <li>
            <.link navigate={~p"/dashboards"}>Dashboards</.link>
          </li>
          <li class="min-w-0 font-medium text-sr-ink" aria-current="page">
            <span class="truncate">{if @dashboard, do: @dashboard.title, else: "Dashboard"}</span>
          </li>
        </ul>
      </nav>

      <div
        :if={@show_canonical_id?}
        id="authored-dashboard-canonical-id"
        class="flex shrink-0 items-center gap-1.5 text-xs text-sr-muted"
      >
        <span>ID</span>
        <code class="font-mono text-xs text-sr-muted">{@canonical_id}</code>
        <.ui_button
          type="button"
          size="xs"
          variant="ghost"
          phx-click="copy_dashboard_id"
          aria-label="Copy canonical dashboard ID"
        >
          Copy ID
        </.ui_button>
      </div>
    </header>
    """
  end

  attr :dashboard, :any, required: true
  attr :settings_open?, :boolean, default: false
  attr :source_query_form, :any, required: true
  attr :source_query_preview, :any, default: nil
  attr :panel_results, :map, default: %{}
  attr :editing_panel_id, :string, default: nil
  attr :access_grants, :list, default: []
  attr :user_grant_form, :any, required: true
  attr :group_grant_form, :any, required: true
  attr :users, :list, default: []
  attr :user_groups, :list, default: []
  attr :can_view_groups?, :boolean, default: false
  attr :can_edit?, :boolean, default: false
  attr :can_share?, :boolean, default: false
  attr :can_schedule_reports?, :boolean, default: false
  attr :report_schedule_form, :any, required: true
  attr :current_scope, :any, required: true

  def dashboard_workbench(assigns) do
    ~H"""
    <section
      :if={
        @settings_open? and AccessControls.settings_available?(@dashboard, access_assigns(assigns))
      }
      class="rounded-lg border border-slate-800/80 bg-[#0b1220]/90 text-slate-100 shadow-xl shadow-cyan-950/10 backdrop-blur-md"
    >
      <div class="flex flex-col gap-3 border-b border-slate-800/80 px-4 py-3 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <p class="text-xs font-semibold uppercase tracking-normal text-cyan-400">
            Dashboard Workbench
          </p>
          <h2 class="mt-1 text-lg font-semibold tracking-normal text-slate-100">
            Compose and arrange panels
          </h2>
          <p class="text-xs text-slate-400">
            Map SRQL output into supported visuals, then drag and resize panels on the canvas.
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <.ui_button
            :if={AccessControls.can_manage?(@dashboard, access_assigns(assigns))}
            type="button"
            phx-click="new_panel"
            size="sm"
            variant="primary"
          >
            <.icon name="hero-plus" class="size-4" /> Add Panel
          </.ui_button>
          <.ui_button
            :if={AccessControls.can_manage?(@dashboard, access_assigns(assigns))}
            type="button"
            phx-click="compact_layout"
            size="sm"
            variant="neutral"
          >
            <.icon name="hero-squares-plus" class="size-4" /> Compact Layout
          </.ui_button>
          <.ui_button type="button" phx-click="close_settings" size="sm" variant="ghost">
            <.icon name="hero-x-mark" class="size-4" /> Close
          </.ui_button>
        </div>
      </div>

      <div class="space-y-6 p-4">
        <section
          :if={AccessControls.can_manage?(@dashboard, access_assigns(assigns))}
          class="rounded-lg border border-slate-800/80 bg-slate-950/40"
        >
          <div class="space-y-4 p-4">
            <.source_query_workbench
              form={@source_query_form}
              preview={@source_query_preview}
              source_queries={SourceQueries.source_queries(@dashboard)}
              templates={SourceQueries.templates()}
              can_manage?={AccessControls.can_manage?(@dashboard, access_assigns(assigns))}
              timezone={@current_scope.user.timezone || "Etc/UTC"}
            />

            <.dashboard_builder_canvas
              id={"authored-dashboard-canvas-#{@dashboard.id}"}
              panels={CanvasState.panels(@dashboard, @panel_results)}
              visual_options={CanvasState.visual_options()}
              selected_id={CanvasState.selected_panel_id(@editing_panel_id, @dashboard)}
              can_manage={AccessControls.can_manage?(@dashboard, access_assigns(assigns))}
              timezone={@current_scope.user.timezone || "Etc/UTC"}
            />
          </div>
        </section>

        <.sharing_settings
          :if={AccessControls.can_share_dashboard?(@dashboard, access_assigns(assigns))}
          dashboard={@dashboard}
          access_grants={@access_grants}
          user_grant_form={@user_grant_form}
          group_grant_form={@group_grant_form}
          users={@users}
          user_groups={@user_groups}
          can_view_groups?={@can_view_groups?}
        />

        <.report_schedule_settings
          :if={AccessControls.can_schedule_dashboard?(@dashboard, access_assigns(assigns))}
          dashboard={@dashboard}
          report_schedule_form={@report_schedule_form}
          timezone={@current_scope.user.timezone || "Etc/UTC"}
        />
      </div>
    </section>
    """
  end

  defp access_assigns(assigns) do
    assigns
    |> Map.take([:can_edit?, :can_share?, :can_schedule_reports?, :can_view_groups?])
    |> Map.put(:current_scope, assigns.current_scope)
  end

  defp show_canonical_id?(%{slug: slug}, route_param, canonical_id)
       when is_binary(slug) and slug != "" and canonical_id != "" do
    is_nil(route_param) or route_param == slug or route_param != canonical_id
  end

  defp show_canonical_id?(_dashboard, _route_param, _canonical_id), do: false
end
