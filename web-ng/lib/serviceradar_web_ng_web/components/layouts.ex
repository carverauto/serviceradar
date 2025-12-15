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

    ~H"""
    <header class="sticky top-0 z-20 border-b border-base-200 bg-base-100/90 backdrop-blur">
      <div class="px-4 sm:px-6 lg:px-8 py-3 flex items-center gap-4">
        <div class="flex items-center gap-2 shrink-0">
          <.link href={~p"/"} class="flex items-center gap-2">
            <img src={~p"/images/logo.svg"} width="28" class="opacity-90" />
            <span class="font-semibold tracking-tight">ServiceRadar</span>
          </.link>
        </div>

        <nav class="flex-1 flex items-center gap-4 min-w-0">
          <%= if @current_scope do %>
            <div class="flex items-center gap-2 shrink-0">
              <.ui_tabs
                size="sm"
                tabs={[
                  %{
                    label: "Dashboard",
                    href: ~p"/dashboard",
                    active: Map.get(@srql, :page_path) == "/dashboard"
                  },
                  %{
                    label: "Devices",
                    href: ~p"/devices",
                    active: Map.get(@srql, :page_path) == "/devices"
                  },
                  %{
                    label: "Pollers",
                    href: ~p"/pollers",
                    active: Map.get(@srql, :page_path) == "/pollers"
                  },
                  %{
                    label: "Events",
                    href: ~p"/events",
                    active: Map.get(@srql, :page_path) == "/events"
                  },
                  %{label: "Logs", href: ~p"/logs", active: Map.get(@srql, :page_path) == "/logs"},
                  %{
                    label: "Services",
                    href: ~p"/services",
                    active: Map.get(@srql, :page_path) == "/services"
                  },
                  %{
                    label: "Interfaces",
                    href: ~p"/interfaces",
                    active: Map.get(@srql, :page_path) == "/interfaces"
                  }
                ]}
              />
            </div>
          <% end %>

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
        </nav>

        <div class="flex items-center gap-2 shrink-0">
          <.theme_toggle />

          <%= if @current_scope do %>
            <div class="text-sm text-base-content/70 hidden sm:block">
              {@current_scope.user.email}
            </div>

            <.ui_button href={~p"/users/settings"} variant="ghost" size="sm">Settings</.ui_button>
            <.ui_button href={~p"/users/log-out"} method="delete" variant="ghost" size="sm">
              Log out
            </.ui_button>
          <% else %>
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

    <main class="px-4 py-6 sm:px-6 lg:px-8">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
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
