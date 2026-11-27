defmodule ServiceRadarUI.Shell do
  @moduledoc """
  Page shell pieces: skip link, sticky top bar, footer, theme toggle and flash
  group.

  Branding and navigation are slots, so each application keeps its own logo,
  links and actions:

      <.skip_link />
      <.top_bar>
        <:brand><.link navigate={~p"/"}>Acme</.link></:brand>
        <:nav><.link navigate={~p"/devices"}>Devices</.link></:nav>
        <:actions><.theme_toggle /></:actions>
      </.top_bar>
      <main id="main" tabindex="-1">...</main>
      <.flash_group flash={@flash} />
      <.footer>
        <:leading>&copy; Acme</:leading>
        <:trailing><.link href="/status">Status</.link></:trailing>
      </.footer>
  """

  use Phoenix.Component

  import ServiceRadarUI.Components, only: [flash: 1, icon: 1]

  alias Phoenix.LiveView.JS

  @doc """
  Renders a "skip to content" link that becomes visible on keyboard focus.
  Point `target` at the id of the page's `<main>` element.
  """
  attr :target, :string, default: "main"
  attr :label, :string, default: "Skip to content"
  attr :class, :any, default: nil

  def skip_link(assigns) do
    ~H"""
    <a href={"##{@target}"} class={["sr-ui-skip-link", @class]}>{@label}</a>
    """
  end

  @doc """
  Renders a sticky top bar with brand, navigation and action slots.
  """
  attr :id, :string, default: "sr-top-bar"
  attr :sticky, :boolean, default: true
  attr :nav_label, :string, default: "Main"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :brand, required: true
  slot :nav
  slot :actions

  def top_bar(assigns) do
    ~H"""
    <header id={@id} class={["sr-ui-topbar", @sticky && "sr-ui-topbar-sticky", @class]} {@rest}>
      <div class="sr-ui-topbar-inner">
        <div class="sr-ui-topbar-brand">{render_slot(@brand)}</div>
        <nav :if={@nav != []} class="sr-ui-topbar-nav" aria-label={@nav_label}>
          {render_slot(@nav)}
        </nav>
        <div :if={@actions != []} class="sr-ui-topbar-actions">{render_slot(@actions)}</div>
      </div>
    </header>
    """
  end

  @doc """
  Renders a page footer with leading and trailing slots.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :leading
  slot :trailing
  slot :inner_block

  def footer(assigns) do
    ~H"""
    <footer class={["sr-ui-footer", @class]} {@rest}>
      <div class="sr-ui-footer-inner">
        <div :if={@leading != []} class="sr-ui-footer-start">{render_slot(@leading)}</div>
        {render_slot(@inner_block)}
        <div :if={@trailing != []} class="sr-ui-footer-end">{render_slot(@trailing)}</div>
      </div>
    </footer>
    """
  end

  @doc """
  Renders a system / light / dark theme switch.

  Each button dispatches an `sr:set-theme` event, which
  `priv/static/theme_init.js` handles: it stores the choice in `localStorage`
  and sets `data-theme` and `data-theme-preference` on `<html>`.
  """
  attr :id, :string, default: "sr-theme-toggle"
  attr :class, :any, default: nil

  attr :labels, :map,
    default: %{system: "System theme", light: "Light theme", dark: "Dark theme"},
    doc: "accessible labels for the three buttons"

  def theme_toggle(assigns) do
    assigns =
      assign(assigns, :choices, [
        {"system", "hero-computer-desktop-micro", assigns.labels[:system]},
        {"light", "hero-sun-micro", assigns.labels[:light]},
        {"dark", "hero-moon-micro", assigns.labels[:dark]}
      ])

    ~H"""
    <div id={@id} class={["sr-ui-theme-toggle", @class]} role="group" aria-label="Theme">
      <span class="sr-ui-theme-toggle-thumb" aria-hidden="true"></span>
      <button
        :for={{theme, icon, label} <- @choices}
        type="button"
        class="sr-ui-theme-toggle-button"
        phx-click={JS.dispatch("sr:set-theme", detail: %{theme: theme})}
        data-sr-theme={theme}
        aria-label={label}
        title={label}
      >
        <.icon name={icon} class="sr-ui-icon-sm" />
      </button>
    </div>
    """
  end

  @doc """
  Renders the info and error flashes plus the LiveView connection notices.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group"
  attr :disconnected_title, :string, default: "We can't find the internet"
  attr :server_error_title, :string, default: "Something went wrong!"
  attr :reconnecting_label, :string, default: "Attempting to reconnect"
  attr :class, :any, default: nil

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class={["sr-ui-flash-group", @class]} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash
        id={"#{@id}-client-error"}
        kind={:error}
        title={@disconnected_title}
        phx-disconnected={JS.remove_attribute("hidden", to: ".phx-client-error ##{@id}-client-error")}
        phx-connected={JS.set_attribute({"hidden", ""}, to: "##{@id}-client-error")}
        hidden
      >
        {@reconnecting_label}
        <.icon name="hero-arrow-path" class="sr-ui-icon-xs sr-ui-spin" />
      </.flash>
      <.flash
        id={"#{@id}-server-error"}
        kind={:error}
        title={@server_error_title}
        phx-disconnected={JS.remove_attribute("hidden", to: ".phx-server-error ##{@id}-server-error")}
        phx-connected={JS.set_attribute({"hidden", ""}, to: "##{@id}-server-error")}
        hidden
      >
        {@reconnecting_label}
        <.icon name="hero-arrow-path" class="sr-ui-icon-xs sr-ui-spin" />
      </.flash>
    </div>
    """
  end
end
