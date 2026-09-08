defmodule ServiceRadarWebNGWeb.Settings.ShellHook do
  @moduledoc """
  `on_mount` hook that powers the catalog-driven Settings shell.

  Attached to the Settings-bearing `live_session`s. It attaches a
  `:handle_params` hook that resolves the active view / category / breadcrumbs /
  scope-filtered nav tree from the **connection URI** via
  `ServiceRadarWebNGWeb.Settings.Catalog.view_for_path/1` — never a hand-typed
  `current_path`.

  It is a strict no-op for any path that does not resolve to a catalog view
  (e.g. non-Settings pages that happen to share the same `live_session`).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias ServiceRadarWebNGWeb.Settings.Catalog
  alias ServiceRadarWebNGWeb.Settings.PendingApprovals
  alias ServiceRadarWebNGWeb.Settings.StatusCards

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:settings_active_view, nil)
      |> assign(:settings_active_category, nil)
      |> assign(:settings_breadcrumbs, [])
      |> assign(:settings_nav_tree, %{categories: [], groups: []})
      |> assign(:settings_siblings, [])
      |> assign(:settings_palette, [])
      |> assign(:settings_stats, [])
      |> attach_hook(:settings_shell_active_view, :handle_params, &resolve_active_view/3)

    {:cont, socket}
  end

  defp resolve_active_view(_params, uri, socket) do
    path = uri_path(uri)
    scope = socket.assigns[:current_scope]

    socket =
      case Catalog.view_for_path(path) do
        nil ->
          socket

        view ->
          category = Catalog.category_for_view(view)

          socket
          |> assign(:settings_active_view, view)
          |> assign(:settings_active_category, category)
          |> assign(:settings_breadcrumbs, Catalog.breadcrumbs_for_path(path, scope))
          |> assign(:settings_nav_tree, %{
            categories: Catalog.visible_categories(scope),
            groups: nav_groups(scope, category)
          })
          |> assign(:settings_siblings, Catalog.siblings(scope, view))
          |> assign(:settings_palette, Catalog.palette_index(scope))
          |> maybe_load_stats(view)
      end

    {:cont, socket}
  end

  # The topbar lists every visible category; the left panel renders the selected
  # category's 2-level tree (parent-group → subgroup → view).
  defp nav_groups(_scope, nil), do: []

  defp nav_groups(scope, %{id: category_id}) do
    scope
    |> Catalog.nav_tree(category_id)
    |> decorate_badges(scope)
  end

  # `Catalog` is a compile-time `@views` list, so `:badge` is necessarily nil
  # there -- a count is a runtime question and a scoped one. The shell already
  # renders `view.badge`, so the counts are applied here, over the tree the
  # catalog just produced, rather than by making the catalog itself impure.
  #
  # Only decorates views that have a pending count, so every other view keeps
  # the nil the catalog gave it.
  defp decorate_badges(groups, scope) do
    case PendingApprovals.counts(scope) do
      empty when empty == %{} ->
        groups

      counts ->
        Enum.map(groups, fn group ->
          Map.update!(group, :sections, fn sections ->
            Enum.map(sections, fn section ->
              Map.update!(section, :views, fn views ->
                Enum.map(views, &apply_badge(&1, counts))
              end)
            end)
          end)
        end)
    end
  end

  defp apply_badge(view, counts) do
    case Map.get(counts, view.id) do
      nil -> view
      count -> Map.put(view, :badge, count)
    end
  end

  # Compute the CONTEXTUAL status cards for the active view. The result is either
  # `:suppressed` (page renders its own metrics) or a list of `%{title, value}`
  # cards resolved from view → parent-group → category.
  defp maybe_load_stats(socket, view) do
    assign(socket, :settings_stats, StatusCards.for_view(view, socket.assigns[:current_scope]))
  end

  defp uri_path(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) -> path
      _ -> "/"
    end
  end

  defp uri_path(_), do: "/"
end
