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

      params
      |> create_package_attrs()
      |> create_package(conn, scope)
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
          upload_url: Storage.upload_url(package.id),
          upload_token: token,
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
          download_url: Storage.download_url(package.id),
          download_token: token,
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

  def upload_blob(conn, %{"id" => id}) do
    actor = SystemActor.system(:plugin_blob)

    with {:ok, token} <- extract_blob_token(conn, :upload),
         {:ok, %{id: token_id, key: object_key}} <- Storage.verify_token(:upload, token),
         true <- token_id == id,
         {:ok, package} <- fetch_package_for_blob(id),
         true <- same_object_key?(object_key, package.wasm_object_key) do
      case read_body_to_tempfile(conn, Storage.max_upload_bytes()) do
        {:ok, upload_path, conn} ->
          try do
            case Packages.upload_blob_file(package, upload_path, actor: actor) do
              {:ok, _package} ->
                send_resp(conn, :created, "")

              {:error, reason} ->
                Logger.error("plugin blob API upload failed package_id=#{id} error=#{inspect(reason)}")
                {:error, reason}
            end
          after
            File.rm(upload_path)
          end

        {:error, :payload_too_large} ->
          conn
          |> put_status(:request_entity_too_large)
          |> json(%{error: "payload_too_large"})

        {:error, reason} ->
          Logger.error("plugin blob API upload failed package_id=#{id} error=#{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :missing_token} ->
        unauthorized(conn)

      {:error, :invalid_token} ->
        unauthorized(conn)

      false ->
        unauthorized(conn)
    end
  end

  @sobelow_skip ["Traversal.SendFile"]
  def download_blob(conn, %{"id" => id}) do
    with {:ok, token} <- extract_blob_token(conn, :download),
         {:ok, %{id: token_id, key: object_key}} <- Storage.verify_token(:download, token),
         true <- token_id == id,
         {:ok, package} <- fetch_package_for_blob(id),
         true <- same_object_key?(object_key, package.wasm_object_key),
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
      {:error, :missing_token} ->
        unauthorized(conn)

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

        {:error, :trusted_upload_signers_not_configured} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "trusted_upload_signers_not_configured"})

        {:error, :invalid_signature} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "invalid_signature"})

        {:error, :unsupported_signature_algorithm} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "unsupported_signature_algorithm"})

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

  defp create_package_attrs(params) do
    %{
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
      content_hash: params["content_hash"],
      signature: params["signature"],
      source_type: normalize_source_type(params["source_type"]),
      source_repo_url: params["source_repo_url"],
      source_commit: params["source_commit"],
      gpg_key_id: params["gpg_key_id"],
      gpg_verified_at: parse_datetime(params["gpg_verified_at"])
    }
  end

  defp create_package(%{source_type: :invalid}, conn, _scope) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_source_type"})
  end

  defp create_package(attrs, conn, scope) do
    attrs
    |> Plugins.create_package(scope: scope)
    |> render_create_package_result(conn)
  end

  defp render_create_package_result({:ok, package}, conn) do
    conn
    |> put_status(:created)
    |> json(package_to_json(package))
  end

  defp render_create_package_result({:error, :missing_repo_url}, conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing_repo_url"})
  end

  defp render_create_package_result({:error, :invalid_repo_url}, conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_repo_url"})
  end

  defp render_create_package_result({:error, :untrusted_repo}, conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "untrusted_repo"})
  end

  defp render_create_package_result({:error, :invalid_ref}, conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_ref"})
  end

  defp render_create_package_result({:error, :invalid_manifest_path}, conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_manifest_path"})
  end

  defp render_create_package_result({:error, :invalid_wasm_path}, conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_wasm_path"})
  end

  defp render_create_package_result({:error, :verification_required}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "verification_required"})
  end

  defp render_create_package_result({:error, :payload_too_large}, conn) do
    conn
    |> put_status(:request_entity_too_large)
    |> json(%{error: "payload_too_large"})
  end

  defp render_create_package_result({:error, {:invalid_manifest, errors}}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "validation_error", details: format_manifest_errors(errors)})
  end

  defp render_create_package_result({:error, error}, _conn), do: {:error, error}

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

  defp extract_blob_token(conn, action) do
    case request_blob_token(conn) || fallback_blob_token(conn, action) do
      nil -> {:error, :missing_token}
      token -> {:ok, token}
    end
  end

  defp normalize_blob_token(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blob_token(_value), do: nil

  defp request_blob_token(conn) do
    conn
    |> Plug.Conn.get_req_header("x-serviceradar-plugin-token")
    |> List.first()
    |> normalize_blob_token()
  end

  defp fallback_blob_token(conn, :download) do
    body_blob_token(conn, "token") || body_blob_token(conn, "download_token")
  end

  defp fallback_blob_token(_conn, _action), do: nil

  defp body_blob_token(conn, key) do
    conn
    |> body_param(key)
    |> normalize_blob_token()
  end

  defp body_param(conn, key) when is_binary(key) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> nil
      body when is_map(body) -> Map.get(body, key)
      _ -> nil
    end
  end

  defp read_full_body(conn, max_bytes) do
    tmp_path = plugin_upload_temp_path()

    case File.open(tmp_path, [:write, :binary, :exclusive]) do
      {:ok, io_device} ->
        try do
          case read_body_more(conn, max_bytes, io_device, 0) do
            {:ok, conn, _size} ->
              {:ok, tmp_path, conn}

            {:error, _reason} = error ->
              File.rm(tmp_path)
              error
          end
        after
          File.close(io_device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_body_to_tempfile(conn, max_bytes), do: read_full_body(conn, max_bytes)

  defp plugin_upload_temp_path do
    random_name =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    Path.join(System.tmp_dir!(), "serviceradar-plugin-upload-#{random_name}.wasm")
  end

  defp read_body_more(conn, max_bytes, io_device, size) do
    if size >= max_bytes do
      {:error, :payload_too_large}
    else
      conn
      |> read_body(length: max_bytes - size, read_length: min(1_000_000, max_bytes - size))
      |> handle_read_body_result(max_bytes, io_device, size)
    end
  end

  defp handle_read_body_result({:ok, body, conn}, max_bytes, io_device, size) do
    write_body_chunk(body, max_bytes, io_device, size, fn next_size ->
      {:ok, conn, next_size}
    end)
  end

  defp handle_read_body_result({:more, body, conn}, max_bytes, io_device, size) do
    write_body_chunk(body, max_bytes, io_device, size, fn next_size ->
      read_body_more(conn, max_bytes, io_device, next_size)
    end)
  end

  defp handle_read_body_result({:error, reason}, _max_bytes, _io_device, _size) do
    {:error, reason}
  end

  defp write_body_chunk(body, max_bytes, io_device, size, continuation) do
    next_size = size + byte_size(body)

    if next_size > max_bytes do
      {:error, :payload_too_large}
    else
      :ok = IO.binwrite(io_device, body)
      continuation.(next_size)
    end
  end

  defp same_object_key?(expected, actual)
       when is_binary(expected) and is_binary(actual) and byte_size(expected) == byte_size(actual) do
    Plug.Crypto.secure_compare(expected, actual)
  end

  defp same_object_key?(_expected, _actual), do: false

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
