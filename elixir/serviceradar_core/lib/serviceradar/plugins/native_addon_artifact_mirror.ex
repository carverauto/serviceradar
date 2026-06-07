defmodule ServiceRadar.Plugins.NativeAddonArtifactMirror do
  @moduledoc """
  Mirrors a verified native add-on per-arch tarball into ServiceRadar object
  storage (issue 3425, add-native-addon-build-signing §4.2), and supplies the
  `:mirror` callback `ServiceRadar.Plugins.NativeAddonImporter.import_entry/4`
  expects: `(os, arch, tarball_bytes -> {:ok, object_key} | {:error, term})`.

  Each tarball lands under a deterministic, traversal-safe key
  `native-addons/<addon_id>/<version>/<os>/<arch>/<sha256>.tar.gz`, which the
  importer records on `AddonPackage.artifacts["os/arch"].object_key` for the agent
  to fetch. The upload itself goes through the datasvc object store via
  `ServiceRadar.Sync.Client.upload_object`, mirroring `ReleaseArtifactMirror`; the
  upload function is injectable so the key/metadata logic is testable without a
  channel.
  """

  alias ServiceRadar.DataService.Client
  alias ServiceRadar.Sync.Client, as: SyncClient

  @default_timeout 30_000
  @content_type "application/gzip"
  @storage_backend "datasvc_object_store"

  @typedoc "The mirror callback shape NativeAddonImporter.import_entry/4 calls."
  @type mirror_fun :: (String.t(), String.t(), binary() -> {:ok, String.t()} | {:error, term()})

  @doc """
  Build the `:mirror` callback for one add-on import. `addon_id` and `version`
  scope the object keys; options:

    * `:upload_object` — `(Proto.ObjectMetadata.t(), binary(), keyword() -> {:ok, term} | {:error, term})`.
      Defaults to the datasvc object-store upload. Override in tests.
    * `:timeout` — upload timeout in ms (default #{@default_timeout}).
  """
  @spec mirror_fun(String.t(), String.t(), keyword()) :: mirror_fun()
  def mirror_fun(addon_id, version, opts \\ []) do
    upload_object = Keyword.get(opts, :upload_object, &default_upload_object/3)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    fn os, arch, data when is_binary(data) ->
      sha256 = :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
      key = object_key(addon_id, version, os, arch, sha256)
      metadata = build_metadata(key, addon_id, version, os, arch, sha256, byte_size(data))

      case upload_object.(metadata, data, timeout: timeout) do
        {:ok, _response} -> {:ok, key}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Fetch a mirrored native add-on artifact from datasvc object storage.

  Options:

    * `:download_object` - `(object_key, keyword() -> {:ok, {info, binary}} | {:ok, binary} | {:error, term})`.
      Defaults to the datasvc object-store download. Override in tests.
    * `:timeout` - download timeout in ms (default #{@default_timeout}).
  """
  @spec fetch_blob(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def fetch_blob(object_key, opts \\ [])

  def fetch_blob(object_key, opts) when is_binary(object_key) do
    download_object = Keyword.get(opts, :download_object, &default_download_object/2)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case download_object.(object_key, timeout: timeout) do
      {:ok, {_info, data}} when is_binary(data) -> {:ok, data}
      {:ok, data} when is_binary(data) -> {:ok, data}
      {:error, %GRPC.RPCError{status: 5}} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def fetch_blob(_object_key, _opts), do: {:error, :invalid_key}

  @doc "Deterministic, traversal-safe object key for a per-arch artifact."
  @spec object_key(String.t(), String.t(), String.t(), String.t(), String.t()) :: String.t()
  def object_key(addon_id, version, os, arch, sha256) do
    "native-addons/#{seg(addon_id)}/#{seg(version)}/#{seg(os)}/#{seg(arch)}/#{seg(sha256)}.tar.gz"
  end

  # Make each path segment safe: collapse anything outside [A-Za-z0-9._-] (notably
  # "/") to "-", then neutralize an all-dots segment ("." / "..") to "_" so a crafted
  # addon_id/version/os/arch can never become a traversal component or escape the
  # native-addons/ prefix.
  defp seg(value) do
    cleaned = value |> to_string() |> String.replace(~r/[^A-Za-z0-9._-]/, "-")

    if Regex.match?(~r/^\.+$/, cleaned), do: "_", else: cleaned
  end

  defp build_metadata(key, addon_id, version, os, arch, sha256, size) do
    %Proto.ObjectMetadata{
      key: key,
      content_type: @content_type,
      sha256: sha256,
      total_size: size,
      attributes: %{
        "addon_id" => to_string(addon_id),
        "version" => to_string(version),
        "os" => to_string(os),
        "arch" => to_string(arch),
        "distribution_backend" => @storage_backend
      }
    }
  end

  defp default_upload_object(metadata, data, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Client.with_channel(
      fn channel ->
        SyncClient.upload_object(channel, metadata, data, timeout: timeout)
      end,
      timeout: timeout
    )
  end

  defp default_download_object(object_key, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Client.with_direct_channel(
      fn channel ->
        SyncClient.download_object(channel, object_key, timeout: timeout)
      end,
      timeout: timeout,
      connect_timeout_ms: timeout
    )
  end
end
