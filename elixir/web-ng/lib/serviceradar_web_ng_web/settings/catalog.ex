defmodule ServiceRadarWebNGWeb.Settings.Catalog do
  @moduledoc """
  Declarative catalog of the web-ng Settings navigation.

  This module is the single source of truth for the Settings information
  architecture. It is modeled on `ServiceRadar.Identity.RBAC.Catalog`: two
  literal data structures (`@categories` and a flat `@views`) plus pure derived
  accessors. Every Settings navigation surface — the icon rail, the topbar
  category switcher, the left view list, the breadcrumbs, and the Ctrl+K command
  palette — renders entirely from this catalog, so adding a page is one map entry
  with zero layout risk.

  ## Why here (web-ng) and not in serviceradar_core

  The RBAC permission catalog lives in `serviceradar_core` because permissions
  are shared by web-ng and the API. This navigation catalog references
  web-ng-only concerns (LiveView modules, `~p` routes, heroicon names, feature
  flags), so it belongs in web-ng. It does **not** inline permission strings:
  each view's `:permission` field carries a KEY that must exist in
  `ServiceRadar.Identity.RBAC.Catalog.permission_keys/0` (a symbolic reference,
  validated by the catalog test), analogous to how the RBAC catalog references
  role constants.

  ## Active-view resolution

  The active view is resolved by `view_for_path/1`, a deterministic
  longest-prefix match over all views' match prefixes. This structurally
  replaces the legacy per-page `current_path` strings and negated
  `String.starts_with?/2` denylists: `/settings/networks` (Sweep Profiles) and
  `/settings/networks/bmp` (BGP / BMP) coexist because the longest matching
  prefix always wins.

  ## Phased population

  Phase 1 populates the full `@categories` set (7 target categories) but only the
  `Audit & System Log` pilot category's `@views`. Remaining categories are
  populated view-by-view in follow-up phases. Categories with no permitted,
  enabled child views are hidden from the switcher, so the six not-yet-populated
  categories simply do not render until their views land.
  """

  alias ServiceRadarWebNG.Capabilities
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.FeatureFlags

  @typedoc "A settings category (topbar switcher entry)."
  @type category :: %{
          id: atom(),
          title: String.t(),
          icon: String.t(),
          order: non_neg_integer(),
          rail_group: atom(),
          permission: String.t() | nil,
          feature_flag: atom() | nil
        }

  @typedoc "A settings view (left-list entry + deep-linkable page)."
  @type view :: %{
          id: atom(),
          category: atom(),
          title: String.t(),
          icon: String.t(),
          route: String.t(),
          live_view: module(),
          permission: String.t() | nil,
          order: non_neg_integer(),
          feature_flag: atom() | nil,
          capability: atom() | nil,
          match_prefixes: [String.t()] | nil,
          keywords: [String.t()],
          badge: atom() | nil,
          hidden_from_nav: boolean()
        }

  # ---------------------------------------------------------------------------
  # Categories (topbar switcher order). Seven target categories from the mockups.
  # ---------------------------------------------------------------------------
  @categories [
    %{
      id: :core_cluster,
      title: "Core Cluster",
      icon: "hero-server-stack",
      order: 10,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :discovery_sweeps,
      title: "Discovery & Sweeps",
      icon: "hero-magnifying-glass",
      order: 20,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :edge_ops,
      title: "Edge Ops",
      icon: "hero-cpu-chip",
      order: 30,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :network_services,
      title: "Network Services",
      icon: "hero-globe-alt",
      order: 40,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :mail_alerts,
      title: "Mail & Alerts",
      icon: "hero-envelope",
      order: 50,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :security_auth,
      title: "Security & Auth",
      icon: "hero-shield-check",
      order: 60,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :audit_system_log,
      title: "Audit & System Log",
      icon: "hero-clipboard-document-list",
      order: 70,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    }
  ]

  # ---------------------------------------------------------------------------
  # Views (flat list; each carries `category:` as an FK into @categories).
  #
  # Phase 1 pilot: only the `Audit & System Log` category is populated. Each
  # entry maps to an existing route + LiveView verified against the router.
  # ---------------------------------------------------------------------------
  @views [
    %{
      id: :audit_trail,
      category: :audit_system_log,
      title: "Audit Trail",
      icon: "hero-finger-print",
      route: "/settings/audit/events",
      live_view: ServiceRadarWebNGWeb.Settings.AuditLive.Events,
      permission: "settings.audit.view",
      order: 10,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["security", "events", "audit", "denials", "signature", "policy", "csp"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :lockouts,
      category: :audit_system_log,
      title: "Lockouts",
      icon: "hero-lock-closed",
      route: "/settings/audit/lockouts",
      live_view: ServiceRadarWebNGWeb.Settings.AuditLive.Lockouts,
      permission: "settings.audit.view",
      order: 20,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["lockout", "auth", "failed", "login", "rate limit"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :history,
      category: :audit_system_log,
      title: "History",
      icon: "hero-clock",
      route: "/settings/audit/history",
      live_view: ServiceRadarWebNGWeb.Settings.AuditLive.History,
      permission: "settings.audit.view",
      order: 30,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["history", "papertrail", "versions", "changes", "diff", "timeline"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :system_event_logs,
      category: :audit_system_log,
      title: "System Event Logs",
      icon: "hero-document-text",
      route: "/logs",
      live_view: ServiceRadarWebNGWeb.LogLive.Index,
      permission: "observability.logs.view",
      order: 40,
      feature_flag: nil,
      capability: nil,
      match_prefixes: ["/logs"],
      keywords: ["logs", "syslog", "system", "otel", "explorer"],
      badge: nil,
      hidden_from_nav: false
    }
  ]

  # ---------------------------------------------------------------------------
  # Icon rail roots (persistent, global). Reuses the operations app rail targets.
  # ---------------------------------------------------------------------------
  @rail_groups [
    %{id: :home, title: "Dashboard", icon: "hero-home", route: "/dashboard"},
    %{id: :apps, title: "Dashboards", icon: "hero-squares-2x2", route: "/dashboards"},
    %{id: :stack, title: "Devices", icon: "hero-server-stack", route: "/devices"},
    %{id: :settings, title: "Settings", icon: "hero-cog-6-tooth", route: "/settings/audit/events"}
  ]

  # ---------------------------------------------------------------------------
  # Raw literal accessors
  # ---------------------------------------------------------------------------

  @doc "All categories, unsorted (declaration order)."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc "All views, unsorted (declaration order)."
  @spec views() :: [view()]
  def views, do: @views

  @doc "The icon-rail roots (home / apps / stack / settings)."
  @spec rail_groups() :: [map()]
  def rail_groups, do: @rail_groups

  @doc "Look up a category by id."
  @spec category(atom()) :: category() | nil
  def category(id) when is_atom(id), do: Enum.find(@categories, &(&1.id == id))

  @doc "Look up a view by id."
  @spec view(atom()) :: view() | nil
  def view(id) when is_atom(id), do: Enum.find(@views, &(&1.id == id))

  @doc "All views belonging to a category, sorted by `:order`."
  @spec views_for_category(atom()) :: [view()]
  def views_for_category(category_id) when is_atom(category_id) do
    @views
    |> Enum.filter(&(&1.category == category_id))
    |> Enum.sort_by(& &1.order)
  end

  @doc """
  The match prefixes for a view.

  Defaults to `[view.route]` unless the view overrides `:match_prefixes`.
  """
  @spec match_prefixes(view()) :: [String.t()]
  def match_prefixes(%{match_prefixes: prefixes}) when is_list(prefixes) and prefixes != [], do: prefixes

  def match_prefixes(%{route: route}), do: [route]

  # ---------------------------------------------------------------------------
  # Active-view resolution (longest-prefix winner)
  # ---------------------------------------------------------------------------

  @doc """
  Resolve the active view for a path via longest-prefix match across all views.

  Returns the view whose matching prefix is the longest, or `nil` when no view
  matches. This is the structural fix for shared URI roots (e.g.
  `/settings/networks` vs `/settings/networks/bmp`).
  """
  @spec view_for_path(String.t() | nil) :: view() | nil
  def view_for_path(path) when is_binary(path) do
    normalized = normalize_path(path)

    @views
    |> Enum.flat_map(fn view ->
      Enum.map(match_prefixes(view), fn prefix -> {view, prefix} end)
    end)
    |> Enum.filter(fn {_view, prefix} -> prefix_match?(normalized, prefix) end)
    |> Enum.max_by(fn {_view, prefix} -> String.length(prefix) end, fn -> nil end)
    |> case do
      nil -> nil
      {view, _prefix} -> view
    end
  end

  def view_for_path(_), do: nil

  @doc "The category that owns the given view."
  @spec category_for_view(view() | nil) :: category() | nil
  def category_for_view(%{category: category_id}), do: category(category_id)
  def category_for_view(_), do: nil

  @doc """
  Breadcrumb trail for a path: `[Settings, Category, View]`.

  Each crumb is `%{label: String.t(), route: String.t() | nil}`. When the path
  does not resolve to a view, only the root `Settings` crumb is returned.
  """
  @spec breadcrumbs_for_path(String.t() | nil) :: [%{label: String.t(), route: String.t() | nil}]
  def breadcrumbs_for_path(path) do
    root = %{label: "Settings", route: nil}

    case view_for_path(path) do
      nil ->
        [root]

      view ->
        category = category_for_view(view)

        [
          root,
          %{label: category_title(category), route: nil},
          %{label: view.title, route: view.route}
        ]
    end
  end

  # ---------------------------------------------------------------------------
  # Scope-aware visibility (RBAC + feature flags + capabilities)
  # ---------------------------------------------------------------------------

  @doc """
  Whether a view is visible to `scope`: permitted AND feature-flag enabled AND
  capability enabled.
  """
  @spec visible_view?(term(), view()) :: boolean()
  def visible_view?(scope, view) do
    permitted?(scope, view.permission) and
      feature_enabled?(view.feature_flag) and
      capability_enabled?(view.capability)
  end

  @doc """
  Categories that have at least one view visible to `scope`, sorted by `:order`.

  A category with its own `:permission`/`:feature_flag` must also pass those
  gates.
  """
  @spec visible_categories(term()) :: [category()]
  def visible_categories(scope) do
    @categories
    |> Enum.filter(fn category ->
      permitted?(scope, category.permission) and
        feature_enabled?(category.feature_flag) and
        Enum.any?(visible_views(scope, category.id))
    end)
    |> Enum.sort_by(& &1.order)
  end

  @doc """
  Views in a category that are visible to `scope` and not hidden from nav,
  sorted by `:order`.
  """
  @spec visible_views(term(), atom()) :: [view()]
  def visible_views(scope, category_id) when is_atom(category_id) do
    category_id
    |> views_for_category()
    |> Enum.filter(fn view -> not view.hidden_from_nav and visible_view?(scope, view) end)
  end

  @doc """
  Flattened palette index for the Ctrl+K command palette, over the views visible
  to `scope` (including nav-hidden but deep-linkable views), sorted by category
  then view order.

  Each entry: `%{category_title, view_title, route, icon, keywords, id}`.
  """
  @spec palette_index(term()) :: [map()]
  def palette_index(scope) do
    @views
    |> Enum.filter(fn view -> visible_view?(scope, view) end)
    |> Enum.sort_by(fn view -> {category_order(view.category), view.order} end)
    |> Enum.map(fn view ->
      %{
        id: view.id,
        category_title: category_title(category(view.category)),
        view_title: view.title,
        route: view.route,
        icon: view.icon,
        keywords: view.keywords
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp category_title(nil), do: "Settings"
  defp category_title(%{title: title}), do: title

  defp category_order(category_id) do
    case category(category_id) do
      %{order: order} -> order
      _ -> 9_999
    end
  end

  defp normalize_path(path) do
    path
    |> strip_query()
    |> strip_trailing_slash()
  end

  defp strip_query(path) do
    path
    |> String.split("?", parts: 2)
    |> List.first()
  end

  defp strip_trailing_slash("/"), do: "/"

  defp strip_trailing_slash(path) do
    String.replace_suffix(path, "/", "")
  end

  defp prefix_match?(path, prefix) do
    path == prefix or String.starts_with?(path, prefix <> "/")
  end

  # permission: nil means "no gate" (visible to any authenticated scope).
  defp permitted?(_scope, nil), do: true
  defp permitted?(scope, permission) when is_binary(permission), do: RBAC.can?(scope, permission)

  # feature_flag: nil means "always on". Known flags map to FeatureFlags.
  defp feature_enabled?(nil), do: true
  defp feature_enabled?(:remote_access_ssh), do: FeatureFlags.remote_access_ssh_enabled?()
  defp feature_enabled?(:remote_access_desktop_rdp), do: FeatureFlags.remote_access_desktop_rdp_enabled?()
  defp feature_enabled?(:remote_access_app), do: FeatureFlags.remote_access_app_enabled?()
  defp feature_enabled?(:remote_access_tcp), do: FeatureFlags.remote_access_tcp_enabled?()
  defp feature_enabled?(:god_view), do: FeatureFlags.god_view_enabled?()
  # Unknown flag atoms default to disabled so a mis-typed flag hides the view
  # rather than silently exposing it.
  defp feature_enabled?(_), do: false

  # capability: nil means "no capability gate". An unknown capability atom
  # hides the view (fail-closed) rather than crashing the whole nav.
  defp capability_enabled?(nil), do: true

  defp capability_enabled?(capability) do
    Capabilities.enabled?(capability)
  rescue
    _ -> false
  end
end
