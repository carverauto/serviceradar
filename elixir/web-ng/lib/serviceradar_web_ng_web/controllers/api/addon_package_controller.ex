defmodule ServiceRadarWebNGWeb.Api.AddonPackageController do
  @moduledoc """
  JSON API controller for native add-on package blob delivery.

  Mirrors the WASM plugin blob download path (`PluginPackageController.download_blob/2`):
  agents fetch signed native add-on (e.g. netprobe) artifacts THROUGH this
  gateway-proxied HTTPS endpoint instead of touching the object store directly. The
  per-poll signed download token (minted by `ServiceRadar.Plugins.StorageToken`) is
  verified with the same mechanism as plugins; only the package resource and the set
  of object keys it may unlock differ (an add-on package has a per-arch `artifacts`
  map keyed by "os/arch", whereas a plugin package has a single `wasm_object_key`).
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.NativeAddonArtifactMirror
  alias ServiceRadarWebNG.Plugins.Storage

  require Ash.Query

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @sobelow_skip ["Traversal.SendFile"]
  def download_blob(conn, %{"id" => id}) do
    with {:ok, token} <- extract_blob_token(conn),
         {:ok, %{id: token_id, key: object_key}} <- Storage.verify_token(:download, token),
         true <- token_id == id,
         {:ok, package} <- fetch_package_for_blob(id),
         true <- known_artifact_object_key?(package, object_key),
         {:ok, blob} <- fetch_addon_blob(conn, object_key) do
      case blob do
        {:file, path} ->
          conn
          |> put_resp_content_type("application/gzip")
          |> send_file(200, path)

        {:binary, data} ->
          conn
          |> put_resp_content_type("application/gzip")
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

  defp fetch_package_for_blob(id) do
    actor = SystemActor.system(:addon_blob)

    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_addon_blob(conn, object_key) do
    opts =
      conn.private
      |> Map.get(:addon_package_controller_opts, [])
      |> Keyword.take([:download_object, :timeout])

    with {:ok, data} <- NativeAddonArtifactMirror.fetch_blob(object_key, opts) do
      {:ok, {:binary, data}}
    end
  end

  # The token's `key` must be one of the object keys the package actually mirrors in
  # its per-arch artifacts map (%{"os/arch" => %{"object_key" => ...}}). This is the
  # entitlement check: a signed token for one package id cannot be used to pull an
  # arbitrary object key, only the keys that package owns. Constant-time compared.
  defp known_artifact_object_key?(%AddonPackage{artifacts: artifacts}, object_key)
       when is_map(artifacts) and is_binary(object_key) do
    Enum.any?(artifacts, fn {_platform, entry} ->
      entry
      |> artifact_object_key()
      |> same_object_key?(object_key)
    end)
  end

  defp known_artifact_object_key?(_package, _object_key), do: false

  defp artifact_object_key(entry) when is_map(entry) do
    case Map.get(entry, "object_key") || Map.get(entry, :object_key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp artifact_object_key(_entry), do: nil

  defp extract_blob_token(conn) do
    case request_blob_token(conn) || body_blob_token(conn, "token") ||
           body_blob_token(conn, "download_token") do
      nil -> {:error, :missing_token}
      token -> {:ok, token}
    end
  end

  defp request_blob_token(conn) do
    conn
    |> Plug.Conn.get_req_header("x-serviceradar-plugin-token")
    |> List.first()
    |> normalize_blob_token()
  end

  defp body_blob_token(conn, key) do
    conn
    |> body_param(key)
    |> normalize_blob_token()
  end

  defp body_param(conn, key) when is_binary(key) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> nil
      body when is_map(body) -> Map.get(body, key)
    end
  end

  defp normalize_blob_token(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blob_token(_value), do: nil

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
end
