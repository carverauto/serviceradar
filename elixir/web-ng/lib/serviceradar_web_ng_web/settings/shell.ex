defmodule ServiceRadarWebNGWeb.Settings.Shell do
  @moduledoc """
  The catalog-driven Settings shell (Phase 1).

  `settings_chrome/1` is the single wrapper the migrated Settings pages render
  their body into. It branches on the per-user `settings_ui` preference:

    * `:original` (default) — renders the untouched legacy
      `ServiceRadarWebNGWeb.SettingsComponents` chrome, so existing users are
      unaffected, and
    * `:catalog` — renders `settings_shell/1`, the new grid
      `[icon-rail w-16][view-list w-64][content]` that derives every navigation
      surface (icon rail, topbar category switcher, view list, breadcrumbs,
      status strip, Ctrl+K palette) from `ServiceRadarWebNGWeb.Settings.Catalog`.

  All catalog-derived assigns (`settings_active_view`, `settings_active_category`,
  `settings_breadcrumbs`, `settings_nav_tree`, `settings_palette`) are populated
  by `ServiceRadarWebNGWeb.Settings.ShellHook` from the connection URI.
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.Settings.Catalog
  alias ServiceRadarWebNGWeb.SettingsComponents

  @doc """
  Wrap a migrated Settings page body in the appropriate chrome.

  Renders the legacy chrome when `settings_ui` is `:original`, and the new
  catalog shell when `:catalog`.
  """
  attr(:settings_ui, :atom, default: :original)
  attr(:current_path, :string, required: true)
  attr(:current_scope, :map, default: nil)
  attr(:active_view, :map, default: nil)
  attr(:active_category, :map, default: nil)
  attr(:breadcrumbs, :list, default: [])
  attr(:nav_tree, :map, default: %{categories: [], views: []})
  attr(:palette, :list, default: [])
  attr(:stats, :map, default: %{})

  attr(:legacy_subnav, :atom,
    default: :none,
    doc:
      "Which built-in legacy sub-nav to render under :original chrome: " <>
        "`:audit` renders `settings_nav` + `audit_nav`; `:none` renders `settings_nav`; " <>
        "`:inline` renders NO nav here because the page's `inner_block` carries its own " <>
        "legacy nav guarded by `:if={@settings_ui == :original}` (used where the nav is " <>
        "nested inside a shared wrapper with the body and cannot be split into `:legacy`)."
  )

  slot(:legacy,
    doc:
      "The page's exact legacy nav markup (`settings_nav` + its category sub-nav), " <>
        "rendered verbatim only under :original. Preferred over `legacy_subnav` so a " <>
        "migrated page keeps a byte-identical legacy chrome."
  )

  slot(:inner_block, required: true)

  def settings_chrome(assigns) do
    ~H"""
    <%= if @settings_ui == :catalog do %>
      <.settings_shell
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@active_view}
        active_category={@active_category}
        breadcrumbs={@breadcrumbs}
        nav_tree={@nav_tree}
        palette={@palette}
        stats={@stats}
      >
        {render_slot(@inner_block)}
      </.settings_shell>
    <% else %>
      <SettingsComponents.settings_shell current_path={@current_path}>
        <%= cond do %>
          <% @legacy != [] -> %>
            {render_slot(@legacy)}
          <% @legacy_subnav == :inline -> %>
          <% true -> %>
            <SettingsComponents.settings_nav
              current_path={@current_path}
              current_scope={@current_scope}
            />
            <SettingsComponents.audit_nav
              :if={@legacy_subnav == :audit}
              current_path={@current_path}
              current_scope={@current_scope}
            />
        <% end %>
        {render_slot(@inner_block)}
      </SettingsComponents.settings_shell>
    <% end %>
    """
  end

  @doc """
  The new catalog-driven Settings shell: CSS grid
  `[icon-rail w-16][view-list w-64][content]`.
  """
  attr(:current_path, :string, required: true)
  attr(:current_scope, :map, default: nil)
  attr(:active_view, :map, default: nil)
  attr(:active_category, :map, default: nil)
  attr(:breadcrumbs, :list, default: [])
  attr(:nav_tree, :map, default: %{categories: [], views: []})
  attr(:palette, :list, default: [])
  attr(:stats, :map, default: %{})
  slot(:inner_block, required: true)

  def settings_shell(assigns) do
    assigns =
      assigns
      |> assign(:categories, Map.get(assigns.nav_tree, :categories, []))
      |> assign(:views, Map.get(assigns.nav_tree, :views, []))

    ~H"""
    <div class="grid grid-cols-[4rem_16rem_1fr] gap-0 rounded-lg border border-base-200 bg-base-100 overflow-hidden min-h-[70vh]">
      <.icon_rail current_path={@current_path} />

      <aside class="border-r border-base-200 bg-base-200/30 hidden md:block">
        <.view_list views={@views} active_view={@active_view} active_category={@active_category} />
      </aside>

      <section class="min-w-0 flex flex-col">
        <div class="flex items-center justify-between gap-3 border-b border-base-200 px-4 py-2 overflow-x-auto">
          <.category_switcher categories={@categories} active_category={@active_category} />
          <.ui_toggle current_path={@current_path} mode={:catalog} />
        </div>

        <div class="border-b border-base-200 px-4 py-2">
          <.breadcrumbs_bar breadcrumbs={@breadcrumbs} />
        </div>

        <.status_strip stats={@stats} />

        <div class="p-4 md:p-6 space-y-6">
          {render_slot(@inner_block)}
        </div>
      </section>

      <.command_palette palette={@palette} />
    </div>
    """
  end

  # --- Icon rail (reuses .sr-ops-sidebar styling) ----------------------------
  attr(:current_path, :string, required: true)

  defp icon_rail(assigns) do
    assigns = assign(assigns, :rail_groups, Catalog.rail_groups())

    ~H"""
    <aside class="sr-ops-sidebar !static !h-auto min-h-full" aria-label="Settings sections">
      <nav class="sr-ops-nav">
        <.link
          :for={group <- @rail_groups}
          navigate={group.route}
          title={group.title}
          aria-label={group.title}
          aria-current={rail_active?(@current_path, group) && "page"}
          class={[
            "sr-ops-nav-button",
            rail_active?(@current_path, group) && "is-active"
          ]}
        >
          <.icon name={group.icon} class="size-5" />
        </.link>
      </nav>
    </aside>
    """
  end

  # --- Topbar category switcher (overflow-x scroll, never flex-wrap) ----------
  attr(:categories, :list, default: [])
  attr(:active_category, :map, default: nil)

  defp category_switcher(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <div role="tablist" class="tabs tabs-boxed flex-nowrap w-max" aria-label="Settings categories">
        <.link
          :for={category <- @categories}
          role="tab"
          navigate={category_landing_route(category)}
          aria-selected={active_category?(@active_category, category)}
          class={[
            "tab whitespace-nowrap gap-1",
            active_category?(@active_category, category) && "tab-active"
          ]}
        >
          <.icon name={category.icon} class="size-4" />
          <span>{category.title}</span>
        </.link>
        <span :if={@categories == []} class="tab tab-disabled text-base-content/50">
          No settings categories available
        </span>
      </div>
    </div>
    """
  end

  # --- Left view list (daisyUI menu) -----------------------------------------
  attr(:views, :list, default: [])
  attr(:active_view, :map, default: nil)
  attr(:active_category, :map, default: nil)

  defp view_list(assigns) do
    ~H"""
    <ul class="menu w-full gap-0.5 p-2">
      <li :if={@active_category} class="menu-title">{@active_category.title}</li>
      <li :for={view <- @views}>
        <.link
          navigate={view.route}
          aria-current={active_view?(@active_view, view) && "page"}
          class={active_view?(@active_view, view) && "menu-active"}
        >
          <.icon name={view.icon} class="size-4 shrink-0" />
          <span class="truncate">{view.title}</span>
          <span :if={view.badge} class="badge badge-sm badge-primary ml-auto">{view.badge}</span>
        </.link>
      </li>
      <li :if={@views == []} class="px-3 py-2 text-sm text-base-content/50">
        No views available
      </li>
    </ul>
    """
  end

  # --- Breadcrumbs (daisyUI breadcrumbs) -------------------------------------
  attr(:breadcrumbs, :list, default: [])

  defp breadcrumbs_bar(assigns) do
    ~H"""
    <nav class="breadcrumbs text-sm" aria-label="Breadcrumb">
      <ul>
        <li :for={crumb <- @breadcrumbs}>
          <.link :if={crumb.route} navigate={crumb.route}>{crumb.label}</.link>
          <span :if={is_nil(crumb.route)}>{crumb.label}</span>
        </li>
      </ul>
    </nav>
    """
  end

  # --- Status card strip (daisyUI stats), degrades gracefully ----------------
  attr(:stats, :map, default: %{})

  defp status_strip(assigns) do
    ~H"""
    <div class="px-4 pt-3">
      <div class="stats stats-horizontal w-full overflow-x-auto border border-base-200 bg-base-100 shadow-sm">
        <div class="stat py-2">
          <div class="stat-title text-xs">Cluster health</div>
          <div class="stat-value text-lg">{stat_value(@stats, :cluster_health)}</div>
        </div>
        <div class="stat py-2">
          <div class="stat-title text-xs">Connected agents</div>
          <div class="stat-value text-lg">{stat_value(@stats, :connected_agents)}</div>
        </div>
        <div class="stat py-2">
          <div class="stat-title text-xs">Pending jobs</div>
          <div class="stat-value text-lg">{stat_value(@stats, :pending_jobs)}</div>
        </div>
        <div class="stat py-2">
          <div class="stat-title text-xs">Active alerts</div>
          <div class="stat-value text-lg">{stat_value(@stats, :active_alerts)}</div>
        </div>
      </div>
    </div>
    """
  end

  # --- Ctrl+K command palette (<dialog> + JS hook) ---------------------------
  attr(:palette, :list, default: [])

  defp command_palette(assigns) do
    ~H"""
    <dialog
      id="settings-command-palette"
      class="modal"
      phx-hook="CommandPalette"
      phx-update="ignore"
    >
      <div class="modal-box max-w-xl p-0" data-command-palette-box>
        <div class="border-b border-base-200 p-3">
          <label class="input input-bordered flex items-center gap-2">
            <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
            <input
              type="text"
              placeholder="Jump to a setting…"
              class="grow"
              data-command-palette-input
              autocomplete="off"
            />
            <kbd class="kbd kbd-sm">ESC</kbd>
          </label>
        </div>

        <ul class="menu w-full max-h-80 overflow-y-auto p-2" data-command-palette-list>
          <li
            :for={item <- @palette}
            data-command-palette-item
            data-search={palette_search(item)}
          >
            <.link navigate={item.route} class="flex items-center gap-2" data-command-palette-link>
              <.icon name={item.icon} class="size-4 shrink-0" />
              <span class="truncate">{item.view_title}</span>
              <span class="ml-auto text-xs text-base-content/50">{item.category_title}</span>
            </.link>
          </li>
          <li
            data-command-palette-empty
            class="hidden px-3 py-6 text-center text-sm text-base-content/50"
          >
            No matching settings.
          </li>
        </ul>

        <div class="flex items-center gap-3 border-t border-base-200 px-3 py-2 text-xs text-base-content/50">
          <span><kbd class="kbd kbd-xs">↑</kbd> <kbd class="kbd kbd-xs">↓</kbd> to navigate</span>
          <span><kbd class="kbd kbd-xs">↵</kbd> to open</span>
          <span class="ml-auto">
            <kbd class="kbd kbd-xs">Ctrl</kbd> + <kbd class="kbd kbd-xs">K</kbd>
          </span>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button>close</button>
      </form>
    </dialog>
    """
  end

  # --- Original-UI toggle link -----------------------------------------------
  attr(:current_path, :string, required: true)
  attr(:mode, :atom, required: true, doc: "The CURRENT mode; the link flips to the other.")

  def ui_toggle(assigns) do
    target = if assigns.mode == :catalog, do: "original", else: "catalog"
    label = if assigns.mode == :catalog, do: "Original UI", else: "New UI"

    assigns = assign(assigns, target: target, label: label)

    ~H"""
    <.link
      href={~p"/settings/ui-preference?#{[mode: @target, return_to: @current_path]}"}
      class="btn btn-ghost btn-xs gap-1 whitespace-nowrap"
      title={"Switch to the #{@label}"}
    >
      <.icon name="hero-arrows-right-left" class="size-3.5" />
      {@label}
    </.link>
    """
  end

  # --- Helpers ---------------------------------------------------------------

  defp active_category?(%{id: id}, %{id: id}), do: true
  defp active_category?(_, _), do: false

  defp active_view?(%{id: id}, %{id: id}), do: true
  defp active_view?(_, _), do: false

  defp category_landing_route(category) do
    case Catalog.views_for_category(category.id) do
      [%{route: route} | _] -> route
      _ -> "/settings/audit/events"
    end
  end

  defp rail_active?(current_path, %{route: "/settings" <> _}) when is_binary(current_path),
    do: String.starts_with?(current_path, "/settings")

  defp rail_active?(current_path, %{route: route}) when is_binary(current_path),
    do: current_path == route or String.starts_with?(current_path, route <> "/")

  defp rail_active?(_, _), do: false

  defp stat_value(stats, key) do
    case Map.get(stats, key) do
      nil -> "—"
      value -> value
    end
  end

  defp palette_search(item) do
    [item.view_title, item.category_title, item.route | item.keywords]
    |> Enum.join(" ")
    |> String.downcase()
  end
end
