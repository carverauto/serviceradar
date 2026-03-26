defmodule ServiceRadarWebNGWeb.Api.PluginPackageController do
  @moduledoc """
  JSON API controller for plugin package import and review operations.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.RBAC

  require Ash.Query
  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  def index(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "plugins.view") do
      scope = get_scope(conn)
      packages = Plugins.list_packages(params, scope: scope)
      json(conn, Enum.map(packages, &package_to_json/1))
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "plugins.view") do
      scope = get_scope(conn)

      case Plugins.get_package(id, scope: scope) do
        {:ok, package} -> json(conn, package_to_json(package))
        {:error, :not_found} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end
  end

  def create(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "plugins.stage") do
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
        display_contract: params["display_contract"],
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

            {:error, :missing_repo_url} ->
              conn
              |> put_status(:bad_request)
              |> json(%{error: "missing_repo_url"})

            {:error, :invalid_repo_url} ->
              conn
              |> put_status(:bad_request)
              |> json(%{error: "invalid_repo_url"})

            {:error, :verification_required} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "verification_required"})

            {:error, :payload_too_large} ->
              conn
              |> put_status(:request_entity_too_large)
              |> json(%{error: "payload_too_large"})

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

  def upload_url(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "plugins.stage") do
      scope = get_scope(conn)
      ttl = parse_ttl_seconds(params["ttl_seconds"], Storage.upload_ttl_seconds())

      with {:ok, package} <- Plugins.get_package(id, scope: scope),
           {:ok, package} <- ensure_object_key(package, scope),
           {token, expires_at} <-
             Storage.sign_token(:upload, package.id, package.wasm_object_key, ttl) do
        json(conn, %{
          upload_url: Storage.upload_url(package.id, token),
          expires_at: format_datetime(expires_at),
          object_key: package.wasm_object_key
        })
      end
    end
  end

  def download_url(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "plugins.view") do
      scope = get_scope(conn)
      ttl = parse_ttl_seconds(params["ttl_seconds"], Storage.download_ttl_seconds())

      with {:ok, package} <- Plugins.get_package(id, scope: scope),
           {:ok, package} <- ensure_object_key(package, scope),
           true <- package.wasm_object_key not in [nil, ""] do
        {token, expires_at} =
          Storage.sign_token(:download, package.id, package.wasm_object_key, ttl)

        json(conn, %{
          download_url: Storage.download_url(package.id, token),
          expires_at: format_datetime(expires_at),
          object_key: package.wasm_object_key
        })
      else
        false ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "missing_wasm_object_key"})
      end
    end
  end

  def upload_blob(conn, %{"id" => id, "token" => token}) do
    actor = SystemActor.system(:plugin_blob)

    with {:ok, %{id: token_id, key: object_key}} <- Storage.verify_token(:upload, token),
         true <- token_id == id,
         {:ok, package} <- fetch_package_for_blob(id),
         true <- object_key == package.wasm_object_key,
         {:ok, payload, conn} <- read_full_body(conn, Storage.max_upload_bytes()),
         {:ok, _package} <- Packages.upload_blob(package, payload, actor: actor) do
      send_resp(conn, :created, "")
    else
      {:error, :invalid_token} ->
        unauthorized(conn)

      {:error, :payload_too_large} ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{error: "payload_too_large"})

      false ->
        unauthorized(conn)

      {:error, reason} ->
        Logger.error("plugin blob API upload failed package_id=#{id} error=#{inspect(reason)}")

        {:error, reason}
    end
  end

  def upload_blob(conn, _params) do
    unauthorized(conn)
  end

  @sobelow_skip ["Traversal.SendFile"]
  def download_blob(conn, %{"id" => id, "token" => token}) do
    with {:ok, %{id: token_id, key: object_key}} <- Storage.verify_token(:download, token),
         true <- token_id == id,
         {:ok, package} <- fetch_package_for_blob(id),
         true <- object_key == package.wasm_object_key,
         {:ok, blob} <- Storage.fetch_blob(object_key) do
      case blob do
        {:file, path} ->
          conn
          |> put_resp_content_type("application/wasm")
          |> send_file(200, path)

        {:binary, data} ->
          conn
          |> put_resp_content_type("application/wasm")
          |> send_resp(200, data)
      end
    else
      {:error, :invalid_token} ->
        unauthorized(conn)

      false ->
        unauthorized(conn)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def download_blob(conn, _params) do
    unauthorized(conn)
  end

  def approve(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "plugins.approve") do
      scope = get_scope(conn)
      approved_by = get_actor(conn)

      attrs = %{
        approved_capabilities: parse_list(params["approved_capabilities"]),
        approved_permissions: params["approved_permissions"],
        approved_resources: params["approved_resources"]
      }

      case Plugins.approve_package(id, attrs, scope: scope, approved_by: approved_by) do
        {:ok, package} ->
          json(conn, package_to_json(package))

        {:error, :verification_required} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "verification_required"})

        {:error, :signature_required} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "signature_required"})

        {:error, error} ->
          {:error, error}
      end
    end
  end

  def deny(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "plugins.approve") do
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
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "plugins.approve") do
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
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "plugins.stage") do
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
      display_contract: package.display_contract,
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

  defp ensure_object_key(package, scope) do
    if package.wasm_object_key in [nil, ""] do
      object_key = Storage.object_key_for(package)

      package
      |> Ash.Changeset.for_update(:update, %{wasm_object_key: object_key})
      |> Ash.update(scope: scope)
    else
      {:ok, package}
    end
  end

  defp fetch_package_for_blob(id) do
    actor = SystemActor.system(:plugin_blob)

    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp read_full_body(conn, max_bytes) do
    conn
    |> read_body(length: max_bytes, read_length: 1_000_000)
    |> case do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, body, conn} -> read_body_more(conn, max_bytes, body, byte_size(body))
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_body_more(conn, max_bytes, acc, size) do
    if size >= max_bytes do
      {:error, :payload_too_large}
    else
      conn
      |> read_body(length: max_bytes - size, read_length: 1_000_000)
      |> case do
        {:ok, body, conn} ->
          {:ok, acc <> body, conn}

        {:more, body, conn} ->
          read_body_more(conn, max_bytes, acc <> body, size + byte_size(body))

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized"})
  end

  defp parse_ttl_seconds(nil, default), do: default
  defp parse_ttl_seconds("", default), do: default

  defp parse_ttl_seconds(value, _default) when is_integer(value) and value > 0 do
    value
  end

  defp parse_ttl_seconds(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_ttl_seconds(_, default), do: default

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
      %Scope{user: user} when not is_nil(user) -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp require_permission(conn, permission) when is_binary(permission) do
    scope = conn.assigns[:current_scope]

    if RBAC.can?(scope, permission) do
      :ok
    else
      {:error, :forbidden}
    end
  end
end
