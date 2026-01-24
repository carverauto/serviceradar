defmodule ServiceRadarWebNG.Api.PluginPackageController do
  @moduledoc """
  JSON API controller for plugin package import and review operations.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins

  action_fallback ServiceRadarWebNG.Api.FallbackController

  def index(conn, params) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)
      packages = Plugins.list_packages(params, scope: scope)
      json(conn, Enum.map(packages, &package_to_json/1))
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)

      case Plugins.get_package(id, scope: scope) do
        {:ok, package} -> json(conn, package_to_json(package))
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
        version: params["version"],
        description: params["description"],
        entrypoint: params["entrypoint"],
        runtime: params["runtime"],
        outputs: params["outputs"],
        manifest: params["manifest"],
        config_schema: params["config_schema"],
        wasm_object_key: params["wasm_object_key"],
        content_hash: params["content_hash"],
        signature: params["signature"],
        source_type: normalize_source_type(params["source_type"]),
        source_repo_url: params["source_repo_url"],
        source_commit: params["source_commit"],
        gpg_key_id: params["gpg_key_id"],
        gpg_verified_at: parse_datetime(params["gpg_verified_at"])
      }

      case attrs.source_type do
        :invalid ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: "invalid_source_type"})

        _ ->
          case Plugins.create_package(attrs, scope: scope) do
            {:ok, package} ->
              conn
              |> put_status(:created)
              |> json(package_to_json(package))

            {:error, {:invalid_manifest, errors}} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "validation_error", details: format_manifest_errors(errors)})

            {:error, error} ->
              {:error, error}
          end
      end
    end
  end

  def approve(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)
      approved_by = get_actor(conn)

      attrs = %{
        approved_capabilities: parse_list(params["approved_capabilities"]),
        approved_permissions: params["approved_permissions"],
        approved_resources: params["approved_resources"]
      }

      case Plugins.approve_package(id, attrs, scope: scope, approved_by: approved_by) do
        {:ok, package} -> json(conn, package_to_json(package))
        {:error, error} -> {:error, error}
      end
    end
  end

  def deny(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)

      attrs = %{
        denied_reason: params["denied_reason"]
      }

      case Plugins.deny_package(id, attrs, scope: scope) do
        {:ok, package} -> json(conn, package_to_json(package))
        {:error, error} -> {:error, error}
      end
    end
  end

  def revoke(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)

      attrs = %{
        denied_reason: params["denied_reason"]
      }

      case Plugins.revoke_package(id, attrs, scope: scope) do
        {:ok, package} -> json(conn, package_to_json(package))
        {:error, error} -> {:error, error}
      end
    end
  end

  def restage(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)

      case Plugins.restage_package(id, scope: scope) do
        {:ok, package} -> json(conn, package_to_json(package))
        {:error, error} -> {:error, error}
      end
    end
  end

  defp package_to_json(package) do
    %{
      id: package.id,
      plugin_id: package.plugin_id,
      name: package.name,
      version: package.version,
      description: package.description,
      entrypoint: package.entrypoint,
      runtime: package.runtime,
      outputs: package.outputs,
      manifest: package.manifest,
      config_schema: package.config_schema,
      wasm_object_key: package.wasm_object_key,
      content_hash: package.content_hash,
      signature: package.signature,
      source_type: to_str(package.source_type),
      source_repo_url: package.source_repo_url,
      source_commit: package.source_commit,
      gpg_key_id: package.gpg_key_id,
      gpg_verified_at: format_datetime(package.gpg_verified_at),
      status: to_str(package.status),
      approved_capabilities: package.approved_capabilities,
      approved_permissions: package.approved_permissions,
      approved_resources: package.approved_resources,
      approved_by: package.approved_by,
      approved_at: format_datetime(package.approved_at),
      denied_reason: package.denied_reason,
      inserted_at: format_datetime(package.inserted_at),
      updated_at: format_datetime(package.updated_at)
    }
  end

  defp parse_list(nil), do: nil
  defp parse_list(""), do: nil

  defp parse_list(value) when is_list(value), do: value

  defp parse_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_list(_), do: nil

  defp normalize_source_type(nil), do: nil
  defp normalize_source_type(""), do: nil
  defp normalize_source_type(:upload), do: :upload
  defp normalize_source_type(:github), do: :github
  defp normalize_source_type("upload"), do: :upload
  defp normalize_source_type("github"), do: :github
  defp normalize_source_type(_), do: :invalid

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(_), do: nil

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp to_str(nil), do: nil
  defp to_str(value), do: value

  defp format_manifest_errors(errors) do
    Enum.map(errors, fn error -> %{message: error} end)
  end

  defp get_actor(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{email: email}} -> email
      _ -> nil
    end
  end

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
