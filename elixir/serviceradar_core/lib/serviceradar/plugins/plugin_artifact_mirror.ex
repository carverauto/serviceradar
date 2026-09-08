defmodule ServiceRadar.Plugins.PluginArtifactMirror do
  @moduledoc """
  Mirrors a plugin WASM blob into the datasvc object store (`serviceradar-objects`)
  so agents can fetch it through `serviceradar_agent_gateway -> datasvc`.

  web-ng persists plugin blobs in the `serviceradar_plugins` JetStream bucket
  (`ServiceRadarWebNG.Plugins.Storage`), but agents download plugin WASM by object
  key from datasvc's `serviceradar-objects` bucket via the agent-gateway. Without a
  mirror the key `plugins/<plugin_id>/<version>/<package_id>.wasm` never lands in
  the read bucket and the agent fetch fails with "object not found".

  This module is the plugin analogue of
  `ServiceRadar.Plugins.NativeAddonArtifactMirror`: it uploads the blob through the
  datasvc object store via `ServiceRadar.Sync.Client.upload_object`, under the exact
  canonical key the agent will request (`PluginPackage.wasm_object_key`). The upload
  function is injectable so the key/metadata logic is testable without a channel.
  """

  alias ServiceRadar.DataService.Client
  alias ServiceRadar.Sync.Client, as: SyncClient

  @default_timeout 30_000
  @content_type "application/wasm"
  @storage_backend "datasvc_object_store"

  @typedoc "Injectable datasvc upload: (metadata, data, opts) -> {:ok, term} | {:error, term}."
  @type upload_fun ::
          (Proto.ObjectMetadata.t(), binary(), keyword() -> {:ok, term()} | {:error, term()})

  @doc """
  Mirror a single plugin WASM blob into datasvc object storage under `object_key`.

  `object_key` MUST be the canonical key the agent will request — pass
  `PluginPackage.wasm_object_key` directly so the mirrored key matches exactly.

  Options:

    * `:upload_object` — `upload_fun()`. Defaults to the datasvc object-store upload.
      Override in tests.
    * `:attributes` — extra string attributes recorded on the object metadata
      (e.g. `%{"plugin_id" => ..., "version" => ..., "package_id" => ...}`).
    * `:timeout` — upload timeout in ms (default #{@default_timeout}).
  """
  @spec mirror(String.t(), binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def mirror(object_key, data, opts \\ [])

  def mirror(object_key, data, opts) when is_binary(object_key) and is_binary(data) do
    case String.trim(object_key) do
      "" ->
        {:error, :invalid_key}

      key ->
        upload_object = Keyword.get(opts, :upload_object, &default_upload_object/3)
        timeout = Keyword.get(opts, :timeout, @default_timeout)
        attributes = Keyword.get(opts, :attributes, %{})

        sha256 = :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
        metadata = build_metadata(key, sha256, byte_size(data), attributes)

        case upload_object.(metadata, data, timeout: timeout) do
          {:ok, _response} -> {:ok, key}
          {:error, _reason} = error -> error
        end
    end
  end

  def mirror(_object_key, _data, _opts), do: {:error, :invalid_key}

  @doc """
  Deterministic, traversal-safe object key for a plugin WASM blob.

  Mirrors `ServiceRadarWebNG.Plugins.Storage.object_key_for/1` shape so the mirrored
  key matches the canonical `wasm_object_key`. Prefer passing `wasm_object_key` to
  `mirror/3`; this helper exists for parity/tests and key derivation when needed.
  """
  @spec object_key(String.t(), String.t(), String.t()) :: String.t()
  def object_key(plugin_id, version, package_id) do
    "plugins/#{seg(plugin_id)}/#{seg(version)}/#{seg(package_id)}.wasm"
  end

  # Make each path segment safe: collapse anything outside [A-Za-z0-9._-] (notably
  # "/") to "-", then neutralize an all-dots segment ("." / "..") to "_" so a crafted
  # plugin_id/version/package_id can never become a traversal component or escape the
  # plugins/ prefix.
  defp seg(value) do
    cleaned = value |> to_string() |> String.replace(~r/[^A-Za-z0-9._-]/, "-")

    if Regex.match?(~r/^\.+$/, cleaned), do: "_", else: cleaned
  end

  defp build_metadata(key, sha256, size, attributes) do
    %Proto.ObjectMetadata{
      key: key,
      content_type: @content_type,
      sha256: sha256,
      total_size: size,
      attributes: normalize_attributes(attributes)
    }
  end

  defp normalize_attributes(attributes) when is_map(attributes) do
    attributes
    |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> Map.put("distribution_backend", @storage_backend)
  end

  defp normalize_attributes(_attributes), do: %{"distribution_backend" => @storage_backend}

  defp default_upload_object(metadata, data, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Client.with_channel(
      fn channel ->
        SyncClient.upload_object(channel, metadata, data, timeout: timeout)
      end,
      timeout: timeout
    )
  end
end
