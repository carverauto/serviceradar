defmodule ServiceRadarWebNGWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ServiceRadarWebNGWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

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
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :srql, :map, default: %{}, doc: "SRQL query bar state for SRQL-driven pages"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign_new(assigns, :srql, fn -> %{} end)
    current_scope = assigns[:current_scope]
    signed_in? = is_map(current_scope) and not is_nil(Map.get(current_scope, :user))
    current_path = Map.get(assigns.srql, :page_path)
    assigns = assign(assigns, signed_in?: signed_in?, current_path: current_path)

    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="sr-sidebar" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex min-h-screen flex-col">
        <header class="sticky top-0 z-20 border-b border-base-200 bg-base-100/90 backdrop-blur">
          <div class="px-4 sm:px-6 lg:px-8 py-3 flex flex-col gap-2">
            <%!-- Top row: hamburger, SRQL bar, and auth buttons --%>
            <div class="flex items-center gap-3">
              <label
                :if={@signed_in?}
                for="sr-sidebar"
                class="btn btn-ghost btn-sm lg:hidden shrink-0"
                aria-label="Open navigation"
                title="Open navigation"
              >
                <.icon name="hero-bars-3" class="size-5" />
              </label>

              <div :if={Map.get(@srql, :enabled, false)} class="flex-1 min-w-0">
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
              <div :if={not Map.get(@srql, :enabled, false)} class="flex-1"></div>

              <div class="flex items-center gap-2 shrink-0">
                <.theme_toggle :if={not @signed_in?} />

                <%= if not @signed_in? do %>
                  <.ui_button href={~p"/users/register"} variant="ghost" size="sm">
                    Register
                  </.ui_button>
                  <.ui_button href={~p"/users/log-in"} variant="primary" size="sm">Log in</.ui_button>
                <% end %>
              </div>
            </div>

            <%!-- Second row: breadcrumb navigation (all on one line) --%>
            <.breadcrumb_nav :if={@current_path} current_path={@current_path} />
          </div>
        </header>

        <div
          :if={Map.get(@srql, :builder_open, false) or Map.get(@srql, :error)}
          class="border-b border-base-200 bg-base-100"
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
            />
          </div>
        </div>

        <main class="px-4 py-6 sm:px-6 lg:px-8 flex-1">
          {render_slot(@inner_block)}
        </main>

        <.flash_group flash={@flash} />
      </div>

      <div :if={@signed_in?} class="drawer-side z-30">
        <label for="sr-sidebar" class="drawer-overlay" aria-label="Close navigation"></label>
        <aside class="w-48 bg-base-100 border-r border-base-200 min-h-full flex flex-col">
          <div class="p-3">
            <.link href={~p"/"} class="flex items-center gap-2 mb-4">
              <img
                src={~p"/images/logo.svg"}
                alt="ServiceRadar"
                class="size-6 opacity-95"
                width="24"
                height="24"
              />
              <span class="font-semibold text-sm tracking-tight">ServiceRadar</span>
            </.link>

            <ul class="menu menu-sm">
              <li>
                <.sidebar_link
                  href={~p"/analytics"}
                  label="Analytics"
                  icon="hero-chart-bar"
                  active={@current_path == "/analytics"}
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
                  active={@current_path in ["/services", "/pollers"]}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/agents"}
                  label="Agents"
                  icon="hero-cpu-chip"
                  active={@current_path == "/agents"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/interfaces"}
                  label="Interfaces"
                  icon="hero-globe-alt"
                  active={@current_path == "/interfaces"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/events"}
                  label="Events"
                  icon="hero-bell-alert"
                  active={@current_path == "/events"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/observability"}
                  label="Observability"
                  icon="hero-presentation-chart-line"
                  active={@current_path in ["/observability", "/logs"]}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/admin/jobs"}
                  label="Settings"
                  icon="hero-adjustments-horizontal"
                  active={@current_path && String.starts_with?(@current_path, "/admin")}
                />
              </li>
            </ul>
          </div>

          <div class="mt-auto p-3 border-t border-base-200">
            <div class="dropdown dropdown-top w-full">
              <div
                tabindex="0"
                role="button"
                class="flex items-center gap-2 p-2 rounded-lg hover:bg-base-200 cursor-pointer w-full"
              >
                <div class="avatar avatar-placeholder">
                  <div class="bg-neutral text-neutral-content w-8 rounded-full">
                    <span class="text-xs">{user_initials(@current_scope.user.email)}</span>
                  </div>
                </div>
                <.icon name="hero-chevron-up" class="size-3 text-base-content/50 ml-auto" />
              </div>
              <ul
                tabindex="0"
                class="dropdown-content menu bg-base-200 rounded-box z-10 w-56 p-2 shadow-lg mb-2"
              >
                <li>
                  <div class="flex flex-col gap-2">
                    <span class="text-[10px] uppercase tracking-wider text-base-content/60">
                      Theme
                    </span>
                    <.theme_toggle />
                  </div>
                </li>
                <li>
                  <.link href={~p"/users/settings"} class="text-sm">
                    <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
                  </.link>
                </li>
                <li>
                  <.link href={~p"/users/log-out"} method="delete" class="text-sm">
                    <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
                  </.link>
                </li>
              </ul>
            </div>
          </div>
        </aside>
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

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :active, :boolean, default: false

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

  attr :current_path, :string, required: true

  defp breadcrumb_nav(assigns) do
    crumbs = build_breadcrumbs(assigns.current_path)
    assigns = assign(assigns, :crumbs, crumbs)

    ~H"""
    <nav class="text-xs sm:text-sm">
      <div class="breadcrumbs">
        <ul class="flex items-center flex-wrap min-w-0">
          <li>
            <.link
              href={~p"/analytics"}
              class="flex items-center gap-1.5 text-base-content/60 hover:text-base-content"
              title="Home"
            >
              <.icon name="hero-home-micro" class="size-3.5" />
            </.link>
          </li>
          <li :for={crumb <- @crumbs}>
            <.link
              :if={crumb.href != nil}
              href={crumb.href}
              class="flex items-center gap-1.5 text-base-content/60 hover:text-base-content"
              title={crumb.label}
            >
              <.icon :if={crumb.icon} name={crumb.icon} class="size-3.5 shrink-0" />
              <span>{crumb.label}</span>
            </.link>
            <span
              :if={crumb.href == nil}
              class="flex items-center gap-1.5 font-medium text-base-content truncate max-w-[20rem]"
              title={crumb.label}
            >
              {crumb.label}
            </span>
          </li>
        </ul>
      </div>
    </nav>
    """
  end

  defp build_breadcrumbs(path) when is_binary(path) do
    segments =
      path
      |> String.trim_leading("/")
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    case segments do
      [] ->
        []

      [section] ->
        [%{label: section_label(section), icon: section_icon(section), href: nil}]

      [section, id] ->
        [
          %{label: section_label(section), icon: section_icon(section), href: "/#{section}"},
          %{label: format_id(id), icon: nil, href: nil}
        ]

      [section, id | _rest] ->
        [
          %{label: section_label(section), icon: section_icon(section), href: "/#{section}"},
          %{label: format_id(id), icon: nil, href: nil}
        ]
    end
  end

  defp build_breadcrumbs(_), do: []

  defp section_label("analytics"), do: "Analytics"
  defp section_label("devices"), do: "Devices"
  defp section_label("pollers"), do: "Pollers"
  defp section_label("agents"), do: "Agents"
  defp section_label("events"), do: "Events"
  defp section_label("logs"), do: "Logs"
  defp section_label("observability"), do: "Observability"
  defp section_label("services"), do: "Services"
  defp section_label("interfaces"), do: "Interfaces"
  defp section_label("admin"), do: "Settings"
  defp section_label(other), do: String.capitalize(other)

  defp section_icon("analytics"), do: "hero-chart-bar-micro"
  defp section_icon("devices"), do: "hero-server-micro"
  defp section_icon("pollers"), do: "hero-cog-6-tooth-micro"
  defp section_icon("agents"), do: "hero-cpu-chip-micro"
  defp section_icon("events"), do: "hero-bell-alert-micro"
  defp section_icon("logs"), do: "hero-presentation-chart-line-micro"
  defp section_icon("admin"), do: "hero-adjustments-horizontal-micro"
  defp section_icon("observability"), do: "hero-presentation-chart-line-micro"
  defp section_icon("services"), do: "hero-cog-6-tooth-micro"
  defp section_icon("interfaces"), do: "hero-globe-alt-micro"
  defp section_icon(_), do: nil

  defp format_id(id) when is_binary(id), do: URI.decode(id)
  defp format_id(id), do: to_string(id)

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

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
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
