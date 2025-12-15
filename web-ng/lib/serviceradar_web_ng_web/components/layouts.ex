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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
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
  attr :error, :string, default: nil
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
          Run
        </button>
      </form>

      <div :if={@error} class="mt-2 text-xs text-error">
        {@error}
      </div>

      <.srql_query_builder
        :if={@builder_open}
        supported={@builder_supported}
        sync={@builder_sync}
        builder={@builder}
      />
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
    <div class="mt-3 rounded-lg border border-base-200 bg-base-100 p-3 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-sm font-semibold">Query Builder</div>
          <div class="text-xs text-base-content/70">
            Build SRQL from structured inputs. SRQL text remains the source of truth.
          </div>
        </div>

        <div class="shrink-0 flex items-center gap-2">
          <span :if={not @supported} class="badge badge-warning badge-sm">Limited</span>
          <span :if={@supported and not @sync} class="badge badge-ghost badge-sm">Not applied</span>
        </div>
      </div>

      <div :if={not @supported} class="mt-2 text-xs text-warning">
        This SRQL query can’t be fully represented by the builder yet. The builder won’t overwrite your query unless you
        click “Replace with builder output”.
      </div>

      <form class="mt-3 grid grid-cols-1 md:grid-cols-12 gap-3" phx-change="srql_builder_change">
        <div class="md:col-span-3">
          <label class="label py-0">
            <span class="label-text text-xs">Entity</span>
          </label>
          <select
            name="builder[entity]"
            class="select select-bordered select-sm w-full"
            disabled={not @supported}
          >
            <option value="devices" selected={@builder["entity"] == "devices"}>Devices</option>
            <option value="pollers" selected={@builder["entity"] == "pollers"}>Pollers</option>
          </select>
        </div>

        <div class="md:col-span-3">
          <label class="label py-0">
            <span class="label-text text-xs">Time</span>
          </label>
          <select
            name="builder[time]"
            class="select select-bordered select-sm w-full"
            disabled={not @supported}
          >
            <option value="" selected={(@builder["time"] || "") == ""}>Any</option>
            <option value="last_1h" selected={@builder["time"] == "last_1h"}>Last 1h</option>
            <option value="last_24h" selected={@builder["time"] == "last_24h"}>Last 24h</option>
            <option value="last_7d" selected={@builder["time"] == "last_7d"}>Last 7d</option>
            <option value="last_30d" selected={@builder["time"] == "last_30d"}>Last 30d</option>
          </select>
        </div>

        <div class="md:col-span-3">
          <label class="label py-0">
            <span class="label-text text-xs">Sort</span>
          </label>
          <div class="flex gap-2">
            <input
              type="text"
              name="builder[sort_field]"
              value={@builder["sort_field"] || ""}
              placeholder="last_seen"
              class="input input-bordered input-sm w-full"
              disabled={not @supported}
            />
            <select
              name="builder[sort_dir]"
              class="select select-bordered select-sm"
              disabled={not @supported}
            >
              <option value="desc" selected={(@builder["sort_dir"] || "desc") == "desc"}>desc</option>
              <option value="asc" selected={@builder["sort_dir"] == "asc"}>asc</option>
            </select>
          </div>
        </div>

        <div class="md:col-span-3">
          <label class="label py-0">
            <span class="label-text text-xs">Limit</span>
          </label>
          <input
            type="number"
            name="builder[limit]"
            value={@builder["limit"] || ""}
            min="1"
            max="500"
            class="input input-bordered input-sm w-full"
            disabled={not @supported}
          />
        </div>

        <div class="md:col-span-4">
          <label class="label py-0">
            <span class="label-text text-xs">Search Field</span>
          </label>
          <input
            type="text"
            name="builder[search_field]"
            value={@builder["search_field"] || ""}
            placeholder="hostname"
            class="input input-bordered input-sm w-full"
            disabled={not @supported}
          />
        </div>

        <div class="md:col-span-8">
          <label class="label py-0">
            <span class="label-text text-xs">Search</span>
          </label>
          <input
            type="text"
            name="builder[search]"
            value={@builder["search"] || ""}
            placeholder="contains…"
            class="input input-bordered input-sm w-full"
            disabled={not @supported}
          />
        </div>
      </form>

      <div class="mt-3 flex justify-end gap-2">
        <button
          :if={not @supported or not @sync}
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="srql_builder_apply"
        >
          Replace with builder output
        </button>
      </div>
    </div>
    """
  end
end
