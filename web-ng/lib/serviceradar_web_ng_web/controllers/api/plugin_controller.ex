defmodule ServiceRadarWebNG.Api.PluginController do
  @moduledoc """
  JSON API controller for plugin registry operations.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins

  action_fallback ServiceRadarWebNG.Api.FallbackController

  def index(conn, params) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)
      plugins = Plugins.list_plugins(scope: scope, limit: params["limit"])
      json(conn, Enum.map(plugins, &plugin_to_json/1))
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)

      case Plugins.get_plugin(id, scope: scope) do
        {:ok, plugin} -> json(conn, plugin_to_json(plugin))
        {:error, :not_found} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end
  end

  def create(conn, params) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)

      attrs = %{
        plugin_id: params["plugin_id"],
        name: params["name"],
        description: params["description"],
        source_repo_url: params["source_repo_url"],
        homepage_url: params["homepage_url"],
        disabled: params["disabled"] || false
      }

      case Plugins.create_plugin(attrs, scope: scope) do
        {:ok, plugin} ->
          conn
          |> put_status(:created)
          |> json(plugin_to_json(plugin))

        {:error, error} ->
          {:error, error}
      end
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)

      attrs = %{
        name: params["name"],
        description: params["description"],
        source_repo_url: params["source_repo_url"],
        homepage_url: params["homepage_url"],
        disabled: params["disabled"]
      }

      case Plugins.update_plugin(id, attrs, scope: scope) do
        {:ok, plugin} -> json(conn, plugin_to_json(plugin))
        {:error, error} -> {:error, error}
      end
    end
  end

  defp plugin_to_json(plugin) do
    %{
      plugin_id: plugin.plugin_id,
      name: plugin.name,
      description: plugin.description,
      source_repo_url: plugin.source_repo_url,
      homepage_url: plugin.homepage_url,
      disabled: plugin.disabled,
      inserted_at: format_datetime(plugin.inserted_at),
      updated_at: format_datetime(plugin.updated_at)
    }
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp get_scope(conn) do
    conn.assigns[:current_scope]
  end

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{} -> :ok
      _ -> {:error, :unauthorized}
    end
  end
end
