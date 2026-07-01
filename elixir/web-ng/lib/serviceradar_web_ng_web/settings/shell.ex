defmodule ServiceRadarWebNGWeb.Settings.Shell do
  @moduledoc """
  The catalog-driven Settings shell.

  `settings_chrome/1` is the single wrapper every Settings page renders its body
  into. It always renders `settings_shell/1`.

  The catalog shell renders **inside the application layout**, which already
  provides the global icon rail, so the shell renders NO icon rail of its own.
  Its layout mirrors the product mockup:

    * A header row with the ServiceRadar Console branding and a "Press Ctrl+K to
      jump anywhere" palette trigger.
    * A full-width topbar of the three catalog categories (System · Network
      Services · Edge Ops), sized to fit on one line with no horizontal scroll.
    * A two-column grid: the left panel is a "Search views…" filter over a
      collapsible **2-level tree** (parent-group → subgroup → leaf view), and the
      content column carries the breadcrumbs, the contextual status-card strip,
      and the page body.

  All catalog-derived assigns (`settings_active_view`, `settings_active_category`,
  `settings_breadcrumbs`, `settings_nav_tree`, `settings_palette`,
  `settings_stats`) are populated by `ServiceRadarWebNGWeb.Settings.ShellHook`
  from the connection URI.
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.Settings.Catalog

  @doc """
  Wrap a Settings page body in the catalog shell chrome.
  """
  attr(:current_path, :string, required: true)
  attr(:current_scope, :map, default: nil)
  attr(:active_view, :map, default: nil)
  attr(:active_category, :map, default: nil)
  attr(:breadcrumbs, :list, default: [])
  attr(:nav_tree, :map, default: %{categories: [], groups: []})
  attr(:palette, :list, default: [])
  attr(:stats, :any, default: [])
  slot(:inner_block, required: true)

  def settings_chrome(assigns) do
    ~H"""
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
    """
  end

  @doc """
  The new catalog-driven Settings shell. Renders to the right of the application
  layout's global icon rail: a full-width category switcher above a
  `[view-tree w-64][content]` grid.
  """
  attr(:current_path, :string, required: true)
  attr(:current_scope, :map, default: nil)
  attr(:active_view, :map, default: nil)
  attr(:active_category, :map, default: nil)
  attr(:breadcrumbs, :list, default: [])
  attr(:nav_tree, :map, default: %{categories: [], groups: []})
  attr(:palette, :list, default: [])
  attr(:stats, :any, default: [])
  slot(:inner_block, required: true)

  def settings_shell(assigns) do
    groups = Map.get(assigns.nav_tree, :groups, [])

    assigns =
      assigns
      |> assign(:categories, Map.get(assigns.nav_tree, :categories, []))
      |> assign(:groups, groups)
      |> assign(:sibling_views, sibling_views(groups, assigns.active_view))

    ~H"""
    <div class="flex flex-col rounded-lg border border-base-200 bg-base-100 overflow-hidden min-h-[70vh]">
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-200 bg-base-200/40 px-4 py-2.5">
        <div class="min-w-0">
          <div class="flex items-center gap-2 font-semibold">
            <.icon name="hero-cog-6-tooth" class="size-4 text-accent" />
            <span class="truncate">Settings Console</span>
          </div>
          <p class="text-xs text-base-content/55">
            Unified Administrative Platform &amp; Settings Control
          </p>
        </div>

        <button
          type="button"
          data-command-palette-open
          class="btn btn-sm btn-ghost gap-2 border border-base-300 bg-base-100 font-normal text-base-content/70"
          title="Search settings (Ctrl+K)"
        >
          <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
          <span class="hidden sm:inline">Press Ctrl+K to jump anywhere</span>
          <span class="ml-1 flex items-center gap-0.5">
            <kbd class="kbd kbd-xs">Ctrl</kbd>
            <kbd class="kbd kbd-xs">K</kbd>
          </span>
        </button>
      </div>

      <div class="border-b border-base-200 px-3 py-2">
        <.category_switcher categories={@categories} active_category={@active_category} />
      </div>

      <div class="relative flex-1 min-h-0 md:grid md:grid-cols-[16rem_1fr]">
        <%!-- Mobile off-canvas drawer state: a CSS-only peer checkbox toggled by the
              hamburger/backdrop labels. On md+ the aside is a static grid column. --%>
        <input type="checkbox" id="settings-nav-drawer" class="peer hidden" aria-hidden="true" />

        <label
          for="settings-nav-drawer"
          class="hidden peer-checked:max-md:block fixed inset-0 z-40 bg-black/40"
          aria-label="Close settings navigation"
        >
        </label>

        <aside class={[
          "hidden peer-checked:block md:block",
          "max-md:absolute max-md:inset-y-0 max-md:left-0 max-md:z-50 max-md:w-72",
          "max-md:overflow-y-auto max-md:shadow-xl max-md:bg-base-100",
          "border-b md:border-b-0 md:border-r border-base-200 bg-base-200/30"
        ]}>
          <div class="flex items-center justify-between px-3 pt-2 md:hidden">
            <span class="text-sm font-semibold">
              {@active_category && @active_category.title}
            </span>
            <label
              for="settings-nav-drawer"
              class="btn btn-ghost btn-xs btn-circle"
              aria-label="Close navigation"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </label>
          </div>

          <.view_tree groups={@groups} active_view={@active_view} />
        </aside>

        <section class="min-w-0 flex flex-col">
          <div class="flex items-center gap-2 border-b border-base-200 px-3 py-2 md:px-4">
            <label
              for="settings-nav-drawer"
              class="btn btn-ghost btn-sm btn-square md:hidden"
              aria-label="Open settings navigation"
              title="Settings menu"
            >
              <.icon name="hero-bars-3" class="size-5" />
            </label>
            <div class="min-w-0 flex-1 overflow-x-auto">
              <.breadcrumbs_bar
                breadcrumbs={@breadcrumbs}
                views={@sibling_views}
                active_view={@active_view}
              />
            </div>
          </div>

          <.status_strip stats={@stats} />

          <div class="p-4 md:p-6 space-y-6">
            {render_slot(@inner_block)}
          </div>
        </section>
      </div>

      <.command_palette palette={@palette} />
    </div>
    """
  end

  # --- Topbar category switcher ----------------------------------------------
  # On md+ the three categories share the full row width evenly (`flex-1`) and
  # show their full labels with no horizontal scroll. On narrow/mobile viewports
  # they size to content and scroll horizontally with snap points instead of
  # cramming into unreadable slivers.
  attr(:categories, :list, default: [])
  attr(:active_category, :map, default: nil)

  defp category_switcher(assigns) do
    ~H"""
    <div
      role="tablist"
      class="flex items-center gap-1 overflow-x-auto md:overflow-hidden snap-x scroll-smooth"
      aria-label="Settings categories"
    >
      <.link
        :for={category <- @categories}
        role="tab"
        navigate={Catalog.category_landing_route(category)}
        aria-selected={active_category?(@active_category, category)}
        title={category.title}
        class={[
          "flex flex-none md:flex-1 min-w-0 snap-start items-center justify-center gap-1.5",
          "whitespace-nowrap rounded-md px-3 md:px-2 py-1.5 text-sm",
          if(active_category?(@active_category, category),
            do: "bg-base-300 text-accent border border-base-300 shadow-sm font-bold",
            else: "text-base-content/70 hover:bg-base-200"
          )
        ]}
      >
        <.icon
          name={category.icon}
          class={["size-4 shrink-0", active_category?(@active_category, category) && "text-accent"]}
        />
        <span class="truncate">{category.title}</span>
      </.link>
      <span :if={@categories == []} class="text-sm text-base-content/50">
        No settings categories available
      </span>
    </div>
    """
  end

  # --- Left 2-level view tree (collapsible parent-groups) ---------------------
  # A "Search views…" live filter over collapsible parent-groups. Each group is a
  # native `<details>` so it collapses with no JS; the `SettingsNavTree` hook adds
  # localStorage persistence and search-aware expansion. Only parent-group headers
  # carry a chevron (they have children); leaf views never do. The active group is
  # rendered `open` AND flagged `data-active-group` so a deep-link always reveals
  # the active leaf (the hook keeps it open even over a stale persisted collapse),
  # while every other group restores its persisted state. The active leaf gets a
  # blue highlighted box.
  attr(:groups, :list, default: [])
  attr(:active_view, :map, default: nil)

  defp view_tree(assigns) do
    ~H"""
    <div id="settings-view-tree" phx-hook="SettingsNavTree" class="p-2 space-y-1">
      <label class="input input-sm input-bordered flex items-center gap-2 mb-1">
        <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
        <input
          type="text"
          placeholder="Search views…"
          class="grow"
          data-view-filter-input
          autocomplete="off"
          aria-label="Search views"
        />
      </label>

      <div
        data-view-filter-empty
        class="hidden px-3 py-2 text-sm text-base-content/50"
      >
        No matching views.
      </div>

      <details
        :for={%{group: group, sections: sections} <- @groups}
        data-nav-group
        data-group-id={group.id}
        data-active-group={active_group?(group, @active_view)}
        open={active_group?(group, @active_view)}
        class="group/nav rounded-lg"
      >
        <summary class="flex cursor-pointer list-none items-center gap-2 rounded-lg px-3 py-2 text-sm font-semibold text-base-content/80 hover:bg-base-200 [&::-webkit-details-marker]:hidden">
          <.icon name={group.icon} class="size-4 shrink-0 opacity-70" />
          <span class="truncate flex-1">{group.title}</span>
          <.icon
            name="hero-chevron-down"
            class="size-4 shrink-0 opacity-60 transition-transform group-open/nav:rotate-180"
          />
        </summary>

        <div class="mt-0.5 pl-2">
          <div :for={section <- sections}>
            <div
              :if={section.subgroup}
              data-view-filter-skip
              class="px-3 pt-2 pb-0.5 text-[11px] font-semibold uppercase tracking-wide text-base-content/45"
            >
              {section.subgroup}
            </div>
            <ul class="menu w-full gap-0.5 p-0">
              <li :for={view <- section.views} data-view-search={view_search(view)}>
                <.link
                  navigate={view.route}
                  aria-current={active_view?(@active_view, view) && "page"}
                  class={[
                    "gap-2 rounded-lg",
                    active_view?(@active_view, view) &&
                      "text-info bg-info/10 font-semibold border border-info/20"
                  ]}
                >
                  <.icon name={view.icon} class="size-4 shrink-0" />
                  <span class="truncate">{view.title}</span>
                  <span :if={view.badge} class="badge badge-sm badge-primary ml-auto">
                    {view.badge}
                  </span>
                </.link>
              </li>
            </ul>
          </div>
        </div>
      </details>

      <div :if={@groups == []} class="px-3 py-2 text-sm text-base-content/50">
        No views available
      </div>
    </div>
    """
  end

  # --- Breadcrumbs (daisyUI breadcrumbs) -------------------------------------
  # The final segment (current view) is a dropdown that jumps to sibling views in
  # the same parent-group.
  attr(:breadcrumbs, :list, default: [])
  attr(:views, :list, default: [])
  attr(:active_view, :map, default: nil)

  defp breadcrumbs_bar(assigns) do
    assigns = assign(assigns, :last_index, length(assigns.breadcrumbs) - 1)

    ~H"""
    <nav class="breadcrumbs text-sm min-w-0" aria-label="Breadcrumb">
      <ul>
        <li :for={{crumb, index} <- Enum.with_index(@breadcrumbs)}>
          <%= cond do %>
            <% index == @last_index and @views != [] -> %>
              <div class="dropdown dropdown-bottom">
                <div
                  tabindex="0"
                  role="button"
                  class="inline-flex items-center gap-1 font-medium text-accent cursor-pointer"
                  title="Jump to a sibling view"
                >
                  <span class="truncate">{crumb.label}</span>
                  <.icon name="hero-chevron-down" class="size-3.5" />
                </div>
                <div
                  tabindex="0"
                  class="dropdown-content z-[60] mt-1 w-64 rounded-lg border border-base-200 bg-base-100 shadow-lg"
                >
                  <div class="px-3 pt-2 text-[11px] font-semibold uppercase tracking-wide text-base-content/50">
                    Navigate Views
                  </div>
                  <ul class="menu w-full p-2">
                    <li :for={view <- @views}>
                      <.link
                        navigate={view.route}
                        class={active_view?(@active_view, view) && "text-accent font-semibold"}
                      >
                        <.icon name={view.icon} class="size-4 shrink-0" />
                        <span class="truncate">{view.title}</span>
                        <.icon
                          :if={active_view?(@active_view, view)}
                          name="hero-check"
                          class="size-4 ml-auto text-accent"
                        />
                      </.link>
                    </li>
                  </ul>
                </div>
              </div>
            <% crumb.route -> %>
              <.link navigate={crumb.route}>{crumb.label}</.link>
            <% true -> %>
              <span>{crumb.label}</span>
          <% end %>
        </li>
      </ul>
    </nav>
    """
  end

  # --- Contextual status card strip (daisyUI stats) --------------------------
  # Renders whatever card list the shell is handed. Suppressed entirely when the
  # active page renders its own metrics (`:suppressed`) or there are no cards.
  # Each card value degrades to an em dash when nil.
  attr(:stats, :any, default: [])

  defp status_strip(assigns) do
    ~H"""
    <div :if={is_list(@stats) and @stats != []} class="px-3 pt-3 md:px-4">
      <div class="stats stats-vertical sm:stats-horizontal w-full overflow-x-auto border border-base-200 bg-base-100 shadow-sm">
        <div :for={card <- @stats} class="stat py-2">
          <div class="stat-title text-xs">{card.title}</div>
          <div class="stat-value text-lg">{stat_display(card.value)}</div>
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
      <div class="modal-box max-w-2xl p-0" data-command-palette-box>
        <div class="border-b border-base-200 p-3">
          <label class="input input-bordered flex items-center gap-2">
            <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
            <input
              type="text"
              placeholder="Search settings, tools, actions… (e.g. sweeps, certificates)"
              class="grow"
              data-command-palette-input
              autocomplete="off"
              autofocus
            />
            <button type="button" class="btn btn-ghost btn-xs btn-circle" data-command-palette-close>
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </label>
        </div>

        <div class="flex items-center justify-between px-4 pt-3 pb-1 text-[11px] font-semibold uppercase tracking-wide text-base-content/50">
          <span>Settings &amp; Deep Sections</span>
          <span>(<span data-command-palette-count>{length(@palette)}</span>)</span>
        </div>

        <ul
          class="menu menu-vertical flex-nowrap w-full max-h-[min(24rem,60vh)] overflow-y-auto p-2"
          data-command-palette-list
        >
          <li
            :for={item <- @palette}
            data-command-palette-item
            data-search={palette_search(item)}
          >
            <.link
              navigate={item.route}
              class="flex items-start gap-3"
              data-command-palette-link
            >
              <span class="mt-0.5 rounded-md bg-base-200 p-1.5">
                <.icon name={item.icon} class="size-4" />
              </span>
              <span class="min-w-0 flex-1">
                <span class="flex items-center gap-2">
                  <span class="truncate font-medium" data-command-palette-title>
                    {item.view_title}
                  </span>
                  <span class="badge badge-xs badge-ghost uppercase tracking-wide">
                    {item.category_title}
                  </span>
                </span>
                <span :if={item.description} class="block truncate text-xs text-base-content/55">
                  {item.description}
                </span>
              </span>
              <span
                class="ml-auto hidden items-center gap-1 self-center text-xs text-accent"
                data-command-palette-jump
              >
                Jump <kbd class="kbd kbd-xs">↵</kbd>
              </span>
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
          <span>Navigation:</span>
          <span><kbd class="kbd kbd-xs">↑</kbd> <kbd class="kbd kbd-xs">↓</kbd> Arrow Keys</span>
          <span><kbd class="kbd kbd-xs">↵</kbd> Select</span>
          <span><kbd class="kbd kbd-xs">ESC</kbd> Close</span>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button>close</button>
      </form>
    </dialog>
    """
  end

  # --- Helpers ---------------------------------------------------------------

  defp active_category?(%{id: id}, %{id: id}), do: true
  defp active_category?(_, _), do: false

  defp active_view?(%{id: id}, %{id: id}), do: true
  defp active_view?(_, _), do: false

  # A parent-group is the active one when it owns the active view. Used both to
  # render `open` by default and to flag `data-active-group` for the nav hook.
  defp active_group?(%{id: group_id}, %{parent_group: group_id}), do: true
  defp active_group?(_, _), do: false

  # Flatten the active view's parent-group into a sibling list for the breadcrumb
  # "Navigate Views" dropdown.
  defp sibling_views(_groups, nil), do: []

  defp sibling_views(groups, %{parent_group: group_id}) do
    groups
    |> Enum.find(fn %{group: %{id: id}} -> id == group_id end)
    |> case do
      %{sections: sections} -> Enum.flat_map(sections, & &1.views)
      _ -> []
    end
  end

  defp stat_display(nil), do: "—"
  defp stat_display(value), do: value

  defp palette_search(item) do
    [item.view_title, item.category_title, item.route | item.keywords]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp view_search(view) do
    [view.title, view.route | List.wrap(Map.get(view, :keywords))]
    |> Enum.join(" ")
    |> String.downcase()
  end
end
