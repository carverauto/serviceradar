defmodule ServiceRadarWebNGWeb.Settings.ShellHook do
  @moduledoc """
  `on_mount` hook that powers the catalog-driven Settings shell.

  Attached to the Settings-bearing `live_session`s. It:

    * reads the per-user `settings_ui` preference from the session
      (`:original | :catalog`, default `:original`) and assigns it, and
    * attaches a `:handle_params` hook that resolves the active view / category /
      breadcrumbs / scope-filtered nav tree from the **connection URI** via
      `ServiceRadarWebNGWeb.Settings.Catalog.view_for_path/1` — never a hand-typed
      `current_path`.

  While the preference is `:original` (the default) this is effectively dormant:
  the assigns are populated but only pages migrated to the new shell read them,
  so nothing changes for existing users. It is also a strict no-op for any path
  that does not resolve to a catalog view (e.g. non-Settings pages that happen to
  share the same `live_session`).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias ServiceRadarWebNGWeb.Settings.Catalog

  @session_key "settings_ui"

  @doc """
  The session key under which the `settings_ui` preference is stored.
  """
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc """
  Parse a raw session value into the `:original | :catalog` preference atom.

  Anything other than the literal string `"catalog"` resolves to `:original` so
  the default is always the legacy UI.
  """
  @spec parse_preference(term()) :: :original | :catalog
  def parse_preference("catalog"), do: :catalog
  def parse_preference(_), do: :original

  def on_mount(:default, _params, session, socket) do
    settings_ui = parse_preference(session[@session_key])

    socket =
      socket
      |> assign(:settings_ui, settings_ui)
      |> assign(:settings_active_view, nil)
      |> assign(:settings_active_category, nil)
      |> assign(:settings_breadcrumbs, [])
      |> assign(:settings_nav_tree, %{categories: [], views: []})
      |> assign(:settings_palette, [])
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
          |> assign(:settings_breadcrumbs, Catalog.breadcrumbs_for_path(path))
          |> assign(:settings_nav_tree, %{
            categories: Catalog.visible_categories(scope),
            views: nav_views(scope, category)
          })
          |> assign(:settings_palette, Catalog.palette_index(scope))
      end

    {:cont, socket}
  end

  defp nav_views(_scope, nil), do: []
  defp nav_views(scope, %{id: category_id}), do: Catalog.visible_views(scope, category_id)

  defp uri_path(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) -> path
      _ -> "/"
    end
  end

  defp uri_path(_), do: "/"
end
