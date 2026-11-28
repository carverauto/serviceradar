defmodule ServiceRadarUI.Shell do
  @moduledoc """
  Page shell pieces: skip link, brand lockup, sticky top bar, segmented control,
  footer, theme toggle and flash group.

  Every ServiceRadar property can compose the canonical branded header and
  footer while keeping its own navigation items and actions:

      <.skip_link />
      <.top_bar>
        <:brand>
          <.brand_lockup
            navigate={~p"/"}
            title="ServiceRadar"
            subtitle="Network Management, Security, and Observability"
          />
        </:brand>
        <:nav><.link navigate={~p"/devices"}>Devices</.link></:nav>
        <:actions><.theme_toggle /></:actions>
      </.top_bar>
      <main id="main" tabindex="-1">...</main>
      <.flash_group flash={@flash} />
      <.footer>
        <:leading>&copy; Carver Automation</:leading>
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
  Renders the canonical ServiceRadar brand lockup: framed radar emblem plus
  stacked product title and optional subtitle.

  Pass `href`, `navigate` or `patch` to render as a link; otherwise renders as a
  non-interactive container. Serve `priv/static/logo-animated.svg` under
  `/serviceradar_ui/` or override `logo_src`.
  """
  attr :title, :string, default: "ServiceRadar"
  attr :subtitle, :string, default: nil
  attr :logo_src, :string, default: "/serviceradar_ui/logo-animated.svg"
  attr :logo_alt, :string, default: ""
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(href navigate patch target rel)

  def brand_lockup(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :link?, not is_nil(rest[:href] || rest[:navigate] || rest[:patch]))

    ~H"""
    <.link :if={@link?} class={["sr-ui-brand-lockup", @class]} {@rest}>
      <span class="sr-ui-brand-mark" aria-hidden="true">
        <img src={@logo_src} width="28" height="28" alt={@logo_alt} class="sr-ui-brand-logo" />
      </span>
      <span class="sr-ui-brand-text">
        <span class="sr-ui-brand-title">{@title}</span>
        <span :if={@subtitle} class="sr-ui-brand-subtitle">{@subtitle}</span>
      </span>
    </.link>
    <div :if={not @link?} class={["sr-ui-brand-lockup", @class]} {@rest}>
      <span class="sr-ui-brand-mark" aria-hidden="true">
        <img src={@logo_src} width="28" height="28" alt={@logo_alt} class="sr-ui-brand-logo" />
      </span>
      <span class="sr-ui-brand-text">
        <span class="sr-ui-brand-title">{@title}</span>
        <span :if={@subtitle} class="sr-ui-brand-subtitle">{@subtitle}</span>
      </span>
    </div>
    """
  end

  @doc """
  Renders a sticky glass top bar with brand, navigation, optional mobile nav
  strip, and action slots.

  Set `contained={false}` to span the full viewport width instead of centering
  inside the standard 1280px container.
  """
  attr :id, :string, default: "sr-top-bar"
  attr :sticky, :boolean, default: true
  attr :contained, :boolean, default: true
  attr :nav_label, :string, default: "Main"
  attr :mobile_nav_label, :string, default: "Mobile navigation"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :brand, required: true
  slot :nav
  slot :mobile_nav
  slot :actions

  def top_bar(assigns) do
    ~H"""
    <header id={@id} class={["sr-ui-topbar", @sticky && "sr-ui-topbar-sticky", @class]} {@rest}>
      <div class={["sr-ui-topbar-inner", @contained && "sr-ui-topbar-contained"]}>
        <div class="sr-ui-topbar-brand">{render_slot(@brand)}</div>
        <nav :if={@nav != []} class="sr-ui-topbar-nav" aria-label={@nav_label}>
          {render_slot(@nav)}
        </nav>
        <div :if={@actions != []} class="sr-ui-topbar-actions">{render_slot(@actions)}</div>
      </div>
      <nav
        :if={@mobile_nav != []}
        class={["sr-ui-topbar-mobile-nav", @contained && "sr-ui-topbar-contained"]}
        aria-label={@mobile_nav_label}
      >
        {render_slot(@mobile_nav)}
      </nav>
    </header>
    """
  end

  @doc """
  Renders a segmented pill control for window, view, or filter switches.

  Each `:item` slot accepts `active` plus link attributes (`href`, `navigate`,
  `patch`) or button event attributes (`click`, `value`).
  """
  attr :label, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  slot :item, required: true do
    attr :active, :boolean
    attr :href, :string
    attr :navigate, :string
    attr :patch, :string
    attr :click, :string
    attr :value, :string
  end

  def segmented_nav(assigns) do
    ~H"""
    <nav aria-label={@label} class={["sr-ui-segmented", @class]} {@rest}>
      <span :for={item <- @item} class="sr-ui-segmented-slot">
        <.link
          :if={item[:href] || item[:navigate] || item[:patch]}
          href={item[:href]}
          navigate={item[:navigate]}
          patch={item[:patch]}
          aria-current={item[:active] && "page"}
          class={["sr-ui-segmented-item", item[:active] && "sr-ui-segmented-item-active"]}
        >
          {render_slot(item)}
        </.link>
        <button
          :if={is_nil(item[:href] || item[:navigate] || item[:patch])}
          type="button"
          phx-click={item[:click]}
          phx-value-item={item[:value]}
          aria-pressed={to_string(item[:active] == true)}
          class={["sr-ui-segmented-item", item[:active] && "sr-ui-segmented-item-active"]}
        >
          {render_slot(item)}
        </button>
      </span>
    </nav>
    """
  end

  @doc """
  Renders a page footer with leading and trailing slots.
  """
  attr :contained, :boolean, default: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :leading
  slot :trailing
  slot :inner_block

  def footer(assigns) do
    ~H"""
    <footer class={["sr-ui-footer", @class]} {@rest}>
      <div class={["sr-ui-footer-inner", @contained && "sr-ui-footer-contained"]}>
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
