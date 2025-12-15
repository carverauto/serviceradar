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

  attr :query, :string, default: nil
  attr :draft, :string, default: nil
  attr :loading, :boolean, default: false
  attr :builder_open, :boolean, default: false
  attr :builder_supported, :boolean, default: true
  attr :builder_sync, :boolean, default: true
  attr :builder, :map, default: %{}

  def srql_query_bar(assigns) do
    assigns =
      assigns
      |> assign_new(:draft, fn -> assigns.query end)
      |> assign_new(:builder, fn -> %{} end)

    ~H"""
    <div class="w-full max-w-4xl">
      <form
        phx-change="srql_change"
        phx-submit="srql_submit"
        class="flex items-center gap-2 w-full"
        autocomplete="off"
      >
        <div class="flex-1 min-w-0">
          <input
            type="text"
            name="q"
            value={@draft || ""}
            placeholder="SRQL query (e.g. in:devices time:last_7d sort:last_seen:desc limit:100)"
            class="input input-bordered input-sm w-full font-mono text-xs"
          />
        </div>

        <button
          type="button"
          class={["btn btn-ghost btn-sm", @builder_open && "btn-active"]}
          phx-click="srql_builder_toggle"
          aria-label="Toggle query builder"
          title="Query builder"
        >
          <.icon name="hero-adjustments-horizontal" class="size-4" />
        </button>

        <button type="submit" class="btn btn-primary btn-sm">
          <span :if={@loading} class="loading loading-spinner loading-xs" /> Run
        </button>
      </form>
    </div>
    """
  end

  attr :supported, :boolean, default: true
  attr :sync, :boolean, default: true
  attr :builder, :map, default: %{}

  def srql_query_builder(assigns) do
    assigns =
      assigns
      |> assign_new(:builder, fn -> %{} end)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm overflow-hidden">
      <div class="px-4 py-3 bg-base-200/40 flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-sm font-semibold">Query Builder</div>
          <div class="text-xs text-base-content/70">
            Compose a query visually. SRQL text remains the source of truth.
          </div>
        </div>

        <div class="shrink-0 flex items-center gap-2">
          <span :if={not @supported} class="badge badge-warning badge-sm">Limited</span>
          <span :if={@supported and not @sync} class="badge badge-ghost badge-sm">Not applied</span>
          <button
            :if={not @supported or not @sync}
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="srql_builder_apply"
          >
            Replace query
          </button>
        </div>
      </div>

      <div class="px-4 py-4">
        <div :if={not @supported} class="mb-3 text-xs text-warning">
          This SRQL query can’t be fully represented by the builder yet. The builder won’t overwrite your query unless
          you click “Replace query”.
        </div>

        <form phx-change="srql_builder_change" autocomplete="off" class="overflow-x-auto">
          <div class="min-w-[880px]">
            <div class="flex items-start gap-10">
              <div class="flex flex-col items-start gap-5">
                <.srql_builder_pill label="In" root>
                  <select
                    name="builder[entity]"
                    class="bg-transparent text-sm font-medium outline-none disabled:opacity-60"
                    disabled={not @supported}
                  >
                    <option value="devices" selected={@builder["entity"] == "devices"}>
                      Devices
                    </option>
                    <option value="pollers" selected={@builder["entity"] == "pollers"}>
                      Pollers
                    </option>
                  </select>
                </.srql_builder_pill>

                <div class="pl-10 border-l-2 border-primary/30 flex flex-col gap-5">
                  <.srql_builder_pill label="Time">
                    <select
                      name="builder[time]"
                      class="bg-transparent text-sm font-medium outline-none disabled:opacity-60"
                      disabled={not @supported}
                    >
                      <option value="" selected={(@builder["time"] || "") == ""}>Any</option>
                      <option value="last_1h" selected={@builder["time"] == "last_1h"}>
                        Last 1h
                      </option>
                      <option value="last_24h" selected={@builder["time"] == "last_24h"}>
                        Last 24h
                      </option>
                      <option value="last_7d" selected={@builder["time"] == "last_7d"}>
                        Last 7d
                      </option>
                      <option value="last_30d" selected={@builder["time"] == "last_30d"}>
                        Last 30d
                      </option>
                    </select>
                  </.srql_builder_pill>

                  <div class="flex flex-col gap-3">
                    <div class="text-xs text-base-content/60 font-medium">Filters</div>

                    <div class="flex flex-col gap-3">
                      <%= for {filter, idx} <- Enum.with_index(Map.get(@builder, "filters", [])) do %>
                        <div class="flex items-center gap-3">
                          <.srql_builder_pill label="Filter">
                            <select
                              name={"builder[filters][#{idx}][field]"}
                              class="bg-transparent text-sm font-medium outline-none disabled:opacity-60"
                              disabled={not @supported}
                            >
                              <%= if @builder["entity"] == "pollers" do %>
                                <option value="poller_id" selected={filter["field"] == "poller_id"}>
                                  poller_id
                                </option>
                                <option value="status" selected={filter["field"] == "status"}>
                                  status
                                </option>
                                <option
                                  value="component_id"
                                  selected={filter["field"] == "component_id"}
                                >
                                  component_id
                                </option>
                                <option
                                  value="registration_source"
                                  selected={filter["field"] == "registration_source"}
                                >
                                  registration_source
                                </option>
                              <% else %>
                                <option value="hostname" selected={filter["field"] == "hostname"}>
                                  hostname
                                </option>
                                <option value="ip" selected={filter["field"] == "ip"}>ip</option>
                                <option value="device_id" selected={filter["field"] == "device_id"}>
                                  device_id
                                </option>
                                <option value="poller_id" selected={filter["field"] == "poller_id"}>
                                  poller_id
                                </option>
                                <option value="agent_id" selected={filter["field"] == "agent_id"}>
                                  agent_id
                                </option>
                              <% end %>
                            </select>

                            <span class="mx-2 text-xs text-base-content/50">contains</span>

                            <input
                              type="text"
                              name={"builder[filters][#{idx}][value]"}
                              value={filter["value"] || ""}
                              placeholder="value"
                              class="bg-transparent text-sm font-medium outline-none placeholder:text-base-content/40 w-56 disabled:opacity-60"
                              disabled={not @supported}
                            />
                          </.srql_builder_pill>

                          <button
                            type="button"
                            class="btn btn-ghost btn-xs"
                            phx-click="srql_builder_remove_filter"
                            phx-value-idx={idx}
                            disabled={not @supported}
                            aria-label="Remove filter"
                            title="Remove filter"
                          >
                            <.icon name="hero-x-mark" class="size-4" />
                          </button>
                        </div>
                      <% end %>

                      <button
                        type="button"
                        class="inline-flex items-center gap-2 rounded-md border border-dashed border-primary/40 px-3 py-2 text-sm text-primary/80 hover:bg-primary/5 w-fit disabled:opacity-60"
                        phx-click="srql_builder_add_filter"
                        disabled={not @supported}
                      >
                        <.icon name="hero-plus" class="size-4" /> Add filter
                      </button>
                    </div>
                  </div>

                  <div class="flex items-center gap-4 pt-2">
                    <div class="text-xs text-base-content/60 font-medium">Sort</div>
                    <.srql_builder_pill label="Sort">
                      <input
                        type="text"
                        name="builder[sort_field]"
                        value={@builder["sort_field"] || ""}
                        class="bg-transparent text-sm font-medium outline-none w-44 disabled:opacity-60"
                        disabled={not @supported}
                      />
                      <select
                        name="builder[sort_dir]"
                        class="bg-transparent text-sm font-medium outline-none disabled:opacity-60"
                        disabled={not @supported}
                      >
                        <option value="desc" selected={(@builder["sort_dir"] || "desc") == "desc"}>
                          desc
                        </option>
                        <option value="asc" selected={@builder["sort_dir"] == "asc"}>asc</option>
                      </select>
                    </.srql_builder_pill>

                    <div class="text-xs text-base-content/60 font-medium">Limit</div>
                    <.srql_builder_pill label="Limit">
                      <input
                        type="number"
                        name="builder[limit]"
                        value={@builder["limit"] || ""}
                        min="1"
                        max="500"
                        class="bg-transparent text-sm font-medium outline-none w-24 disabled:opacity-60"
                        disabled={not @supported}
                      />
                    </.srql_builder_pill>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </form>
      </div>
    </div>
    """
  end

  slot :inner_block, required: true
  attr :label, :string, required: true
  attr :root, :boolean, default: false

  def srql_builder_pill(assigns) do
    ~H"""
    <div class="relative">
      <div :if={not @root} class="absolute -left-10 top-1/2 h-0.5 w-10 bg-primary/30" />
      <div class="inline-flex items-center gap-2 rounded-md border border-base-300 bg-base-100 px-3 py-2 shadow-sm">
        <.icon name="hero-check-mini" class="size-4 text-success opacity-80" />
        <span class="text-xs text-base-content/60">{@label}</span>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
