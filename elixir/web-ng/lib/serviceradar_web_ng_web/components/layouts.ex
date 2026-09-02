defmodule ServiceRadarWebNGWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.FeatureFlags

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"
  )

  attr(:srql, :map, default: %{}, doc: "SRQL query bar state for SRQL-driven pages")

  attr(:hide_breadcrumb, :boolean,
    default: false,
    doc: "Hide auto breadcrumb when page has custom one"
  )

  attr(:current_path, :string, default: nil, doc: "Current route path for shell navigation state")
  attr(:shell, :atom, default: :auto, doc: "Application shell variant")
  attr(:page_title, :string, default: nil, doc: "Title shown in the operations shell topbar")

  slot(:inner_block, required: true)

  slot(:topbar_actions,
    doc: "Optional page actions rendered in the shell topbar, before alerts and profile"
  )

  def app(assigns) do
    assigns = assign_new(assigns, :srql, fn -> %{} end)
    assigns = assign_new(assigns, :hide_breadcrumb, fn -> false end)
    current_scope = assigns[:current_scope]
    signed_in? = is_map(current_scope) and not is_nil(Map.get(current_scope, :user))
    current_path = assigns[:current_path] || Map.get(assigns.srql, :page_path)
    page_title = assigns[:page_title] || operations_page_title(current_path)
    brand_name = operations_brand_name(current_path)

    assigns =
      assign(assigns,
        signed_in?: signed_in?,
        current_path: current_path,
        page_title: page_title,
        brand_name: brand_name,
        show_page_title?: page_title != brand_name
      )

    cond do
      assigns.shell == :operations -> operations_app(assigns)
      assigns.shell == :standard -> standard_app(assigns)
      signed_in? -> operations_app(assigns)
      true -> standard_app(assigns)
    end
  end

  defp standard_app(assigns) do
    ~H"""
    <div class="sr-ui-drawer lg:sr-ui-drawer-open bg-sr-canvas text-sr-ink">
      <input id="sr-sidebar" type="checkbox" class="sr-ui-drawer-toggle" />

      <div class="sr-ui-drawer-content flex min-h-screen flex-col">
        <%!-- Public shell topbar aligned with marketing/control brand chrome --%>
        <header id="standard-topbar" class="sr-public-topbar">
          <div class="sr-public-topbar-inner flex-col gap-2 sm:flex-row sm:items-center">
            <div class="flex w-full items-center gap-3">
              <label
                :if={@signed_in?}
                for="sr-sidebar"
                class="inline-flex size-11 shrink-0 cursor-pointer items-center justify-center rounded-sr-control border border-sr-line bg-sr-control text-sr-ink shadow-sr-control outline-none transition-[transform,border-color,background-color] duration-200 ease-sr-out hover:border-sr-line-hover hover:bg-sr-subtle focus-visible:ring-2 focus-visible:ring-sr-focus active:translate-y-px lg:hidden"
                aria-label="Open navigation"
                title="Open navigation"
              >
                <.icon name="hero-bars-3" class="size-5" />
              </label>

              <.link href={~p"/"} id="standard-brand-link" class="sr-public-brand">
                <span class="sr-public-brand-mark">
                  <img
                    id="standard-brand-logo"
                    src={~p"/images/logo-animated.svg"}
                    alt=""
                    aria-hidden="true"
                    width="28"
                    height="28"
                  />
                </span>
                <span class="sr-public-brand-text">
                  <span class="sr-public-brand-name">ServiceRadar</span>
                  <span class="sr-public-brand-tagline">
                    Network Management, Security, and Observability
                  </span>
                </span>
              </.link>

              <div :if={Map.get(@srql, :enabled, false)} class="ml-auto min-w-0 flex-1 max-w-2xl">
                <.srql_query_bar
                  query={Map.get(@srql, :query)}
                  draft={Map.get(@srql, :draft)}
                  loading={Map.get(@srql, :loading, false)}
                  builder_available={Map.get(@srql, :builder_available, false)}
                  builder_open={Map.get(@srql, :builder_open, false)}
                  builder_supported={Map.get(@srql, :builder_supported, true)}
                  builder_sync={Map.get(@srql, :builder_sync, true)}
                  builder={Map.get(@srql, :builder, %{})}
                />
              </div>
              <div :if={not Map.get(@srql, :enabled, false)} class="ml-auto flex-1"></div>

              <div class="flex shrink-0 items-center gap-2">
                <%!-- Theme toggle hidden; app defaults to dark. Re-enable with <.theme_toggle /> --%>
                {render_slot(@topbar_actions)}

                <%= if not @signed_in? do %>
                  <.ui_button href={~p"/users/log-in"} variant="primary" size="sm">Log in</.ui_button>
                <% end %>
              </div>
            </div>

            <.breadcrumb_nav :if={@current_path && !@hide_breadcrumb} current_path={@current_path} />
          </div>
        </header>

        <div
          :if={Map.get(@srql, :builder_open, false) or Map.get(@srql, :error)}
          class="border-b border-sr-line bg-sr-surface"
        >
          <div class="px-4 sm:px-6 lg:px-8 py-4">
            <div :if={Map.get(@srql, :error)} class="mb-3 text-xs text-error">
              {Map.get(@srql, :error)}
            </div>

            <.srql_query_builder
              :if={Map.get(@srql, :builder_open, false)}
              supported={Map.get(@srql, :builder_supported, true)}
              sync={Map.get(@srql, :builder_sync, true)}
              builder={Map.get(@srql, :builder, %{})}
              mode_notice={Map.get(@srql, :builder_mode_notice)}
            />
          </div>
        </div>

        <main class="px-4 py-6 sm:px-6 lg:px-8 flex-1">
          {render_slot(@inner_block)}
        </main>

        <.flash_group flash={@flash} />
      </div>

      <div :if={@signed_in?} class="sr-ui-drawer-side z-30 overflow-visible">
        <label for="sr-sidebar" class="sr-ui-drawer-overlay" aria-label="Close navigation"></label>
        <aside class="flex min-h-full w-48 flex-col overflow-visible border-r border-sr-line bg-sr-surface">
          <div class="p-3">
            <.link href={~p"/"} class="sr-public-brand mb-4">
              <span class="sr-public-brand-mark">
                <img
                  src={~p"/images/logo-animated.svg"}
                  alt=""
                  aria-hidden="true"
                  width="28"
                  height="28"
                />
              </span>
              <span class="sr-public-brand-name">ServiceRadar</span>
            </.link>

            <ul class="sr-ui-menu sr-ui-menu-sm">
              <li>
                <.sidebar_link
                  href={~p"/dashboard"}
                  label="Dashboard"
                  icon="hero-home"
                  active={@current_path == "/dashboard"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/dashboards"}
                  label="Dashboards"
                  icon="hero-squares-2x2"
                  active={@current_path && String.starts_with?(@current_path, "/dashboards")}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/devices"}
                  label="Devices"
                  icon="hero-server"
                  active={@current_path == "/devices"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/services"}
                  label="Services"
                  icon="hero-cog-6-tooth"
                  active={
                    @current_path in ["/services", "/gateways"] or
                      (@current_path &&
                         String.starts_with?(@current_path, "/inventory/public-endpoints"))
                  }
                />
              </li>
              <li :if={FeatureFlags.god_view_enabled?()}>
                <.sidebar_link
                  href={~p"/topology"}
                  label="Topology"
                  icon="hero-share"
                  active={@current_path && String.starts_with?(@current_path, "/topology")}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/diagnostics/mtr"}
                  label="Diagnostics"
                  icon="hero-signal"
                  active={
                    @current_path &&
                      String.starts_with?(@current_path, "/diagnostics")
                  }
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/observability"}
                  label="Observability"
                  icon="hero-presentation-chart-line"
                  active={
                    @current_path &&
                      (String.starts_with?(@current_path, "/observability") ||
                         String.starts_with?(@current_path, "/logs") ||
                         String.starts_with?(@current_path, "/events") ||
                         String.starts_with?(@current_path, "/alerts") ||
                         String.starts_with?(@current_path, "/flows"))
                  }
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/security"}
                  label="Security"
                  icon="hero-shield-check"
                  active={@current_path && String.starts_with?(@current_path, "/security")}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/settings/cluster"}
                  label="Settings"
                  icon="hero-adjustments-horizontal"
                  active={
                    @current_path &&
                      (String.starts_with?(@current_path, "/settings") ||
                         String.starts_with?(@current_path, "/admin") ||
                         String.starts_with?(@current_path, "/users/settings"))
                  }
                />
              </li>
            </ul>
          </div>

          <div class="mt-auto border-t border-sr-line p-3">
            <.ui_dropdown
              align="start"
              placement="top"
              class="w-full"
              menu_class="w-56 max-w-56 left-0 right-auto"
            >
              <:trigger>
                <div class="flex w-full cursor-pointer items-center gap-2 rounded-lg p-2 hover:bg-sr-subtle">
                  <div class="flex size-8 items-center justify-center rounded-full bg-sr-subtle text-xs font-semibold text-sr-ink">
                    {user_initials(@current_scope.user.email)}
                  </div>
                  <.icon name="hero-chevron-up" class="ml-auto size-3 text-sr-muted" />
                </div>
              </:trigger>
              <:item :if={@current_scope && @current_scope.user}>
                <div class="flex flex-col gap-1 px-1 py-1">
                  <span class="text-[10px] uppercase tracking-wider text-sr-muted">
                    Signed in as
                  </span>
                  <span class="max-w-[180px] truncate text-sm font-medium text-sr-ink">
                    {@current_scope.user.email}
                  </span>
                  <span class="mt-1 text-[10px] uppercase tracking-wider text-sr-muted">Role</span>
                  <span class="text-xs font-medium text-sr-ink">
                    {format_role(@current_scope.user.role)}
                  </span>
                </div>
              </:item>
              <:item>
                <.link href={~p"/settings/profile"}>
                  <.icon name="hero-cog-6-tooth" class="size-4" /> Account
                </.link>
              </:item>
              <:item>
                <.link href={~p"/users/log-out"} method="delete">
                  <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
                </.link>
              </:item>
            </.ui_dropdown>
          </div>
        </aside>
      </div>
    </div>
    """
  end

  defp operations_app(assigns) do
    nav_items = [
      %{href: "/dashboard", label: "Dashboard", icon: "hero-home"},
      %{href: "/dashboards", label: "Dashboards", icon: "hero-squares-2x2"},
      %{href: "/devices", label: "Devices", icon: "hero-server-stack"},
      %{href: "/services", label: "Services", icon: "hero-bolt"},
      %{href: "/topology", label: "Topology", icon: "hero-share"},
      %{href: "/observability", label: "Observability", icon: "hero-presentation-chart-line"},
      %{href: "/security", label: "Security", icon: "hero-shield-check"},
      %{href: "/cameras", label: "Cameras", icon: "hero-video-camera"},
      %{href: "/spatial", label: "FieldSurvey", icon: "hero-wifi"},
      %{href: "/settings/cluster", label: "Settings", icon: "hero-cog-6-tooth"}
    ]

    assigns = assign(assigns, :nav_items, nav_items)

    ~H"""
    <div class="sr-ops-shell">
      <aside :if={@signed_in?} class="sr-ops-sidebar" aria-label="Primary navigation">
        <nav class="sr-ops-nav">
          <.link
            :for={item <- @nav_items}
            href={item.href}
            title={item.label}
            aria-label={item.label}
            aria-current={ops_nav_active?(@current_path, item.href) && "page"}
            class={[
              "sr-ops-nav-button",
              ops_nav_active?(@current_path, item.href) && "is-active"
            ]}
          >
            <.icon name={item.icon} class="size-5" />
          </.link>
        </nav>

        <div class="sr-ops-nav mt-auto">
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="sr-ops-nav-button"
            title="Log out"
            aria-label="Log out"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-5" />
          </.link>
        </div>
      </aside>

      <div class="sr-ops-main">
        <header id="ops-topbar" class="sr-ops-topbar">
          <div class="sr-ops-topbar-title">
            <div class="sr-ops-topbar-brand">
              <span class="sr-ops-brand-mark" aria-hidden="true">
                <img
                  id="ops-brand-logo"
                  src={~p"/images/logo-animated.svg"}
                  alt=""
                  width="28"
                  height="28"
                />
              </span>
              <span class="sr-ops-brand-name">{@brand_name}</span>
              <span :if={@show_page_title?} class="sr-ops-topbar-divider" aria-hidden="true"></span>
            </div>
            <h1 :if={@show_page_title?} class="sr-ops-page-title">
              {@page_title}
            </h1>
          </div>

          <div
            :if={Map.get(@srql, :enabled, false) and Map.get(@srql, :placement) == :topbar}
            class="sr-ops-topbar-query"
          >
            <.srql_query_bar
              query={Map.get(@srql, :query)}
              draft={Map.get(@srql, :draft)}
              loading={Map.get(@srql, :loading, false)}
              builder_available={Map.get(@srql, :builder_available, false)}
              builder_open={Map.get(@srql, :builder_open, false)}
              builder_supported={Map.get(@srql, :builder_supported, true)}
              builder_sync={Map.get(@srql, :builder_sync, true)}
              builder={Map.get(@srql, :builder, %{})}
            />
          </div>

          <div class="sr-ops-topbar-actions">
            <%!-- Theme toggle hidden; app defaults to dark. Re-enable with <.theme_toggle /> --%>
            {render_slot(@topbar_actions)}
            <.link
              navigate={~p"/observability/alerts"}
              class="sr-ops-topbar-icon"
              aria-label="Alerts"
              title="Alerts"
            >
              <.icon name="hero-bell-alert" class="size-5" />
            </.link>
            <details id="ops-profile-menu" phx-hook="DetailsState" class="group relative">
              <summary
                id="ops-profile-menu-toggle"
                class="sr-ops-avatar cursor-pointer list-none outline-none focus-visible:ring-2 focus-visible:ring-sr-focus [&::-webkit-details-marker]:hidden"
                aria-label="Open profile menu"
                title={profile_title(@current_scope)}
              >
                <%!-- Nested SVG must not receive the click: a summary child that
                     handles pointer events toggles <details> twice (open then close). --%>
                <span class="pointer-events-none inline-flex items-center">
                  <.icon name="hero-user-circle" class="size-6" />
                </span>
              </summary>
              <ul class="sr-ops-profile-menu" role="menu">
                <li role="none">
                  <.link navigate={~p"/settings/profile"} role="menuitem">
                    <.icon name="hero-user-circle" class="size-4" /> Profile
                  </.link>
                </li>
                <li role="none">
                  <a href="/api/v2/swaggerui" target="_blank" rel="noopener" role="menuitem">
                    <.icon name="hero-code-bracket" class="size-4" /> API docs
                  </a>
                </li>
                <li role="none">
                  <.link href={~p"/users/log-out"} method="delete" role="menuitem">
                    <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
                  </.link>
                </li>
              </ul>
            </details>
          </div>
        </header>

        <div
          :if={Map.get(@srql, :enabled, false) and Map.get(@srql, :placement) != :topbar}
          class="sr-ops-querybar"
        >
          <.srql_query_bar
            query={Map.get(@srql, :query)}
            draft={Map.get(@srql, :draft)}
            loading={Map.get(@srql, :loading, false)}
            builder_available={Map.get(@srql, :builder_available, false)}
            builder_open={Map.get(@srql, :builder_open, false)}
            builder_supported={Map.get(@srql, :builder_supported, true)}
            builder_sync={Map.get(@srql, :builder_sync, true)}
            builder={Map.get(@srql, :builder, %{})}
          />
        </div>

        <div
          :if={Map.get(@srql, :builder_open, false) or Map.get(@srql, :error)}
          class="sr-ops-querybuilder"
        >
          <div :if={Map.get(@srql, :error)} class="sr-ops-query-error">
            {Map.get(@srql, :error)}
          </div>

          <.srql_query_builder
            :if={Map.get(@srql, :builder_open, false)}
            supported={Map.get(@srql, :builder_supported, true)}
            sync={Map.get(@srql, :builder_sync, true)}
            builder={Map.get(@srql, :builder, %{})}
            mode_notice={Map.get(@srql, :builder_mode_notice)}
          />
        </div>

        <main class="sr-ops-content">
          {render_slot(@inner_block)}
        </main>

        <.flash_group flash={@flash} />
      </div>
    </div>
    """
  end

  defp user_initials(email) when is_binary(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp user_initials(_), do: "?"

  defp profile_title(%{user: %{email: email}}) when is_binary(email) and email != "", do: "Profile: #{email}"

  defp profile_title(_), do: "Profile"

  defp format_role(role) when is_atom(role) do
    role
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_role(role) when is_binary(role), do: role

  defp ops_nav_active?(current_path, href) when is_binary(current_path) and is_binary(href) do
    cond do
      current_path == href ->
        true

      href == "/dashboard" ->
        false

      href == "/observability" ->
        current_path in ["/observability", "/logs", "/events", "/alerts"] or
          String.starts_with?(current_path, "/observability/") or
          String.starts_with?(current_path, "/logs/") or
          String.starts_with?(current_path, "/events/") or
          String.starts_with?(current_path, "/alerts/")

      # The Settings gear links to /settings/cluster but owns the whole Settings
      # area (and the merged /admin/* + /users/settings routes), so it stays lit
      # on every settings page, not just the cluster landing.
      href == "/settings/cluster" ->
        String.starts_with?(current_path, "/settings") or
          String.starts_with?(current_path, "/admin") or
          String.starts_with?(current_path, "/users/settings")

      true ->
        String.starts_with?(current_path, href)
    end
  end

  defp ops_nav_active?(_, _), do: false

  defp operations_page_title("/dashboard"), do: "Unified Operations Dashboard"
  defp operations_page_title("/dashboards"), do: "Dashboards"
  defp operations_page_title("/devices/wifi"), do: "WiFi Inventory"
  defp operations_page_title("/cameras"), do: "Camera Multiview"
  defp operations_page_title("/topology"), do: "Topology"
  defp operations_page_title("/events"), do: "Events"
  defp operations_page_title("/alerts"), do: "Alerts"
  defp operations_page_title("/observability"), do: "Observability"
  defp operations_page_title("/observability/logs"), do: "Logs"
  defp operations_page_title("/observability/traces"), do: "Traces"
  defp operations_page_title("/observability/metrics"), do: "Metrics"
  defp operations_page_title("/observability/events"), do: "Events"
  defp operations_page_title("/observability/alerts"), do: "Alerts"
  defp operations_page_title("/observability/netflows"), do: "Network Flows"
  defp operations_page_title("/observability/flows"), do: "Network Flows"
  defp operations_page_title("/observability/flows/attributed"), do: "Attributed Flows"
  defp operations_page_title("/security"), do: "Security"
  defp operations_page_title("/spatial"), do: "FieldSurvey"

  defp operations_page_title(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/cameras/") -> "Camera Feed"
      String.starts_with?(path, "/dashboards") -> "Dashboards"
      String.starts_with?(path, "/devices") -> "Devices"
      String.starts_with?(path, "/services") -> "Services"
      String.starts_with?(path, "/diagnostics") -> "Diagnostics"
      String.starts_with?(path, "/settings") -> "Settings"
      String.starts_with?(path, "/observability") -> "Observability"
      String.starts_with?(path, "/security") -> "Security"
      true -> "ServiceRadar"
    end
  end

  defp operations_page_title(_), do: "ServiceRadar"

  defp operations_brand_name("/observability/flows/attributed"), do: "Attributed Flows"
  defp operations_brand_name(_), do: "ServiceRadar"

  attr(:href, :string, required: true)
  attr(:label, :string, required: true)
  attr(:icon, :string, default: nil)
  attr(:active, :boolean, default: false)

  def sidebar_link(assigns) do
    ~H"""
    <.link
      href={@href}
      aria-current={@active && "page"}
      class={[
        "flex items-center gap-2",
        @active && "active"
      ]}
    >
      <.icon :if={@icon} name={@icon} class="size-4 opacity-80" />
      <span class="truncate">{@label}</span>
    </.link>
    """
  end

  attr(:current_path, :string, required: true)

  defp breadcrumb_nav(assigns) do
    crumbs = build_breadcrumbs(assigns.current_path)
    assigns = assign(assigns, :crumbs, crumbs)

    ~H"""
    <nav aria-label="Breadcrumb" class="w-full text-xs sm:text-sm">
      <ol class="flex min-w-0 flex-wrap items-center gap-1.5 text-sr-muted">
        <li class="flex items-center gap-1.5">
          <.link
            href={~p"/dashboard"}
            class="inline-flex items-center gap-1.5 rounded-sr-small px-1 py-0.5 outline-none transition-colors hover:text-sr-ink focus-visible:ring-2 focus-visible:ring-sr-focus"
            title="Home"
          >
            <.icon name="hero-home-micro" class="size-3.5" />
            <span class="sr-only">Home</span>
          </.link>
        </li>
        <li :for={crumb <- @crumbs} class="flex min-w-0 items-center gap-1.5">
          <span class="text-sr-line-strong" aria-hidden="true">/</span>
          <.link
            :if={crumb.href != nil}
            href={crumb.href}
            class="inline-flex min-w-0 items-center gap-1.5 rounded-sr-small px-1 py-0.5 outline-none transition-colors hover:text-sr-ink focus-visible:ring-2 focus-visible:ring-sr-focus"
            title={crumb.label}
          >
            <.icon :if={crumb.icon} name={crumb.icon} class="size-3.5 shrink-0" />
            <span class="truncate">{crumb.label}</span>
          </.link>
          <span
            :if={crumb.href == nil}
            class="inline-flex min-w-0 max-w-[20rem] items-center gap-1.5 truncate px-1 py-0.5 font-medium text-sr-ink"
            title={crumb.label}
            aria-current="page"
          >
            {crumb.label}
          </span>
        </li>
      </ol>
    </nav>
    """
  end

  defp build_breadcrumbs(path) when is_binary(path) do
    segments =
      path
      |> String.trim_leading("/")
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    # Treat agents and gateways as children of infrastructure
    segments = normalize_infrastructure_path(segments)

    case segments do
      [] ->
        []

      [section] ->
        [%{label: section_label(section), icon: section_icon(section), href: nil}]

      [section, id] ->
        [
          %{
            label: section_label(section),
            icon: section_icon(section),
            href: section_href(section)
          },
          %{label: format_id(id), icon: nil, href: nil}
        ]

      [section, subsection, id] ->
        [
          %{
            label: section_label(section),
            icon: section_icon(section),
            href: section_href(section)
          },
          %{
            label: section_label(subsection),
            icon: section_icon(subsection),
            href: subsection_href(section, subsection)
          },
          %{label: format_id(id), icon: nil, href: nil}
        ]

      [section, id | _rest] ->
        [
          %{
            label: section_label(section),
            icon: section_icon(section),
            href: section_href(section)
          },
          %{label: format_id(id), icon: nil, href: nil}
        ]
    end
  end

  defp build_breadcrumbs(_), do: []

  defp section_href("diagnostics"), do: "/diagnostics/mtr"
  defp section_href(section), do: "/#{section}"

  defp subsection_href("diagnostics", subsection), do: "/diagnostics/#{subsection}"
  defp subsection_href(section, subsection), do: "/#{section}?tab=#{subsection}"

  # Normalize paths so agents and gateways appear under infrastructure
  defp normalize_infrastructure_path(["agents" | rest]) do
    ["infrastructure", "agents" | rest]
  end

  defp normalize_infrastructure_path(["gateways" | rest]) do
    ["infrastructure", "gateways" | rest]
  end

  defp normalize_infrastructure_path(segments), do: segments

  defp section_label("analytics"), do: "Analytics"
  defp section_label("devices"), do: "Devices"
  defp section_label("infrastructure"), do: "Infrastructure"
  defp section_label("gateways"), do: "Gateways"
  defp section_label("agents"), do: "Agents"
  defp section_label("nodes"), do: "Nodes"
  defp section_label("events"), do: "Events"
  defp section_label("alerts"), do: "Alerts"
  defp section_label("logs"), do: "Logs"
  defp section_label("observability"), do: "Observability"
  defp section_label("security"), do: "Security"
  defp section_label("services"), do: "Services"
  defp section_label("netflows"), do: "Network Flows"
  defp section_label("admin"), do: "Settings"
  defp section_label("settings"), do: "Settings"
  defp section_label(other), do: String.capitalize(other)

  defp section_icon("analytics"), do: "hero-chart-bar-micro"
  defp section_icon("devices"), do: "hero-server-micro"
  defp section_icon("infrastructure"), do: "hero-cpu-chip-micro"
  defp section_icon("gateways"), do: "hero-cog-6-tooth-micro"
  defp section_icon("agents"), do: "hero-cube-micro"
  defp section_icon("nodes"), do: "hero-server-stack-micro"
  defp section_icon("events"), do: "hero-bell-alert-micro"
  defp section_icon("alerts"), do: "hero-exclamation-triangle-micro"
  defp section_icon("logs"), do: "hero-presentation-chart-line-micro"
  defp section_icon("admin"), do: "hero-adjustments-horizontal-micro"
  defp section_icon("settings"), do: "hero-adjustments-horizontal-micro"
  defp section_icon("observability"), do: "hero-presentation-chart-line-micro"
  defp section_icon("security"), do: "hero-shield-check-micro"
  defp section_icon("services"), do: "hero-cog-6-tooth-micro"
  defp section_icon("netflows"), do: "hero-arrow-path-micro"
  defp section_icon(_), do: nil

  defp format_id(id) when is_binary(id), do: URI.decode(id)
  defp format_id(id), do: to_string(id)

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Dark / light / system theme toggle.

  **Not rendered in the topbar by default** — the app forces dark mode via
  `theme_init.js`. Keep this component and the `phx:set-theme` listener so the
  control can be dropped back into layouts later if needed.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      class="relative flex flex-row items-center rounded-full border border-sr-line bg-sr-subtle shadow-sr-control"
    >
      <div class="absolute left-0 h-full w-1/3 rounded-full border border-sr-line bg-sr-raised shadow-sr-control transition-[left] duration-200 ease-sr-out [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3" />

      <button
        type="button"
        class="relative z-[1] flex w-1/3 cursor-pointer p-2 text-sr-muted outline-none transition-colors hover:text-sr-ink focus-visible:text-sr-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        type="button"
        class="relative z-[1] flex w-1/3 cursor-pointer p-2 text-sr-muted outline-none transition-colors hover:text-sr-ink focus-visible:text-sr-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        type="button"
        class="relative z-[1] flex w-1/3 cursor-pointer p-2 text-sr-muted outline-none transition-colors hover:text-sr-ink focus-visible:text-sr-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
