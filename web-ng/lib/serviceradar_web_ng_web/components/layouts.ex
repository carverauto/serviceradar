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
              <.link href={~p"/devices"} class="btn btn-ghost btn-sm">Devices</.link>
              <.link href={~p"/pollers"} class="btn btn-ghost btn-sm">Pollers</.link>
            </div>
          <% end %>

          <div class="flex-1 min-w-0">
            <.srql_query_bar
              :if={Map.get(@srql, :enabled, false)}
              query={Map.get(@srql, :query)}
              draft={Map.get(@srql, :draft)}
              loading={Map.get(@srql, :loading, false)}
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

            <.link href={~p"/users/settings"} class="btn btn-ghost btn-sm">Settings</.link>
            <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-sm">
              Log out
            </.link>
          <% else %>
            <.link href={~p"/users/register"} class="btn btn-ghost btn-sm">Register</.link>
            <.link href={~p"/users/log-in"} class="btn btn-primary btn-sm">Log in</.link>
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
