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
          <div class="px-4 sm:px-6 lg:px-8 py-3 flex items-center gap-4">
            <div class="flex items-center gap-3 shrink-0">
              <label
                :if={@signed_in?}
                for="sr-sidebar"
                class="btn btn-ghost btn-sm lg:hidden"
                aria-label="Open navigation"
                title="Open navigation"
              >
                <.icon name="hero-bars-3" class="size-5" />
              </label>

              <.link href={~p"/"} class="flex items-center gap-2">
                <img
                  src={~p"/images/logo.svg"}
                  alt="ServiceRadar"
                  class="size-7 opacity-95"
                  width="28"
                  height="28"
                />
                <span class="font-semibold tracking-tight">ServiceRadar</span>
              </.link>
            </div>

            <div class="flex-1 min-w-0">
              <.srql_query_bar
                :if={Map.get(@srql, :enabled, false)}
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

            <div class="flex items-center gap-2 shrink-0">
              <.theme_toggle />

              <%= if not @signed_in? do %>
                <.ui_button href={~p"/users/register"} variant="ghost" size="sm">Register</.ui_button>
                <.ui_button href={~p"/users/log-in"} variant="primary" size="sm">Log in</.ui_button>
              <% end %>
            </div>
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
        <aside class="w-72 bg-base-100 border-r border-base-200 min-h-full flex flex-col">
          <div class="p-4">
            <div class="text-xs font-semibold text-base-content/50 mb-2">Navigation</div>
            <ul class="menu menu-sm">
              <li>
                <.sidebar_link
                  href={~p"/dashboard"}
                  label="Dashboard"
                  icon="hero-squares-2x2"
                  active={@current_path == "/dashboard"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/devices"}
                  label="Devices"
                  icon="hero-computer-desktop"
                  active={@current_path == "/devices"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/pollers"}
                  label="Pollers"
                  icon="hero-signal"
                  active={@current_path == "/pollers"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/events"}
                  label="Events"
                  icon="hero-bolt"
                  active={@current_path == "/events"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/logs"}
                  label="Logs"
                  icon="hero-rectangle-stack"
                  active={@current_path == "/logs"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/services"}
                  label="Services"
                  icon="hero-wrench-screwdriver"
                  active={@current_path == "/services"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/interfaces"}
                  label="Interfaces"
                  icon="hero-arrows-right-left"
                  active={@current_path == "/interfaces"}
                />
              </li>
            </ul>
          </div>

          <div class="mt-auto p-4 border-t border-base-200">
            <div class="text-xs font-semibold text-base-content/50 mb-2">Account</div>

            <div class="text-sm text-base-content/80 truncate mb-3">
              {@current_scope.user.email}
            </div>

            <div class="flex flex-col gap-2">
              <.ui_button href={~p"/users/settings"} variant="ghost" size="sm" class="justify-start">
                <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
              </.ui_button>
              <.ui_button
                href={~p"/users/log-out"}
                method="delete"
                variant="ghost"
                size="sm"
                class="justify-start"
              >
                <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
              </.ui_button>
            </div>
          </div>
        </aside>
      </div>
    </div>
    """
  end

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
