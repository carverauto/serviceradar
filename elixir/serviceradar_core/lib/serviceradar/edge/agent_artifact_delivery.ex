defmodule ServiceRadar.Edge.AgentArtifactDelivery do
  @moduledoc """
  Resolves agent-gateway-served artifact downloads for agent-facing objects.

  Agents never fetch catalog or package objects from web-ng or JetStream directly.
  The agent-gateway validates the caller identity and token, asks core to authorize
  the exact object key, then streams the object from DataService.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.BumblebeeCatalogSnapshot
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @bumblebee_catalog_token_id "bumblebee-catalog"

  @spec resolve_plugin_download(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_plugin_download(package_id, object_key, caller_agent_id)
      when is_binary(package_id) and is_binary(object_key) and is_binary(caller_agent_id) do
    actor = SystemActor.system(:agent_artifact_download)

    with {:ok, %PluginPackage{} = package} <- plugin_package(package_id, actor),
         true <- same_object_key?(package.wasm_object_key, object_key) do
      {:ok,
       %{
         object_key: object_key,
         file_name: plugin_file_name(package),
         content_type: "application/wasm",
         agent_id: caller_agent_id
       }}
    else
      false -> {:error, :unauthorized}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  def resolve_plugin_download(_package_id, _object_key, _caller_agent_id),
    do: {:error, :unauthorized}

  @spec resolve_addon_download(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_addon_download(package_id, object_key, caller_agent_id)
      when is_binary(package_id) and is_binary(object_key) and is_binary(caller_agent_id) do
    actor = SystemActor.system(:agent_artifact_download)

    with {:ok, %AddonPackage{} = package} <- addon_package(package_id, actor),
         true <- addon_owns_object_key?(package, object_key) do
      {:ok,
       %{
         object_key: object_key,
         file_name: addon_file_name(package),
         content_type: "application/gzip",
         agent_id: caller_agent_id
       }}
    else
      false -> {:error, :unauthorized}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  def resolve_addon_download(_package_id, _object_key, _caller_agent_id),
    do: {:error, :unauthorized}

  @spec resolve_bumblebee_catalog_download(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_bumblebee_catalog_download(token_id, object_key, caller_agent_id)
      when token_id == @bumblebee_catalog_token_id and is_binary(object_key) and
             is_binary(caller_agent_id) do
    actor = SystemActor.system(:agent_artifact_download)

    with {:ok, %BumblebeeCatalogSnapshot{} = snapshot} <- active_bumblebee_catalog(actor),
         true <- same_object_key?(snapshot.object_key, object_key) do
      {:ok,
       %{
         object_key: object_key,
         file_name: "bumblebee-catalog.json",
         content_type: "application/json",
         agent_id: caller_agent_id
       }}
    else
      false -> {:error, :unauthorized}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  def resolve_bumblebee_catalog_download(_token_id, _object_key, _caller_agent_id),
    do: {:error, :unauthorized}

  defp plugin_package(package_id, actor) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> normalize_read_one()
  end

  defp addon_package(package_id, actor) do
    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> normalize_read_one()
  end

  defp active_bumblebee_catalog(actor) do
    BumblebeeCatalogSnapshot
    |> Ash.Query.for_read(:active, %{}, actor: actor)
    |> Ash.read_one(actor: actor)
    |> normalize_read_one()
  end

  defp normalize_read_one({:ok, nil}), do: {:error, :not_found}
  defp normalize_read_one({:ok, record}), do: {:ok, record}
  defp normalize_read_one({:error, reason}), do: {:error, reason}

  defp addon_owns_object_key?(%AddonPackage{artifacts: artifacts}, object_key)
       when is_map(artifacts) and is_binary(object_key) do
    Enum.any?(artifacts, fn {_platform, entry} ->
      entry
      |> artifact_object_key()
      |> same_object_key?(object_key)
    end)
  end

  defp addon_owns_object_key?(_package, _object_key), do: false

  defp artifact_object_key(entry) when is_map(entry) do
    case Map.get(entry, "object_key") || Map.get(entry, :object_key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp artifact_object_key(_entry), do: nil

  defp plugin_file_name(%PluginPackage{} = package) do
    "#{safe_segment(package.plugin_id)}-#{safe_segment(package.version)}.wasm"
  end

  defp addon_file_name(%AddonPackage{} = package) do
    "#{safe_segment(package.addon_id)}-#{safe_segment(package.version)}.tar.gz"
  end

  defp safe_segment(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "artifact"
      segment -> segment
    end
  end

  defp safe_segment(_value), do: "artifact"

  defp same_object_key?(expected, actual)
       when is_binary(expected) and is_binary(actual) and byte_size(expected) == byte_size(actual) do
    Plug.Crypto.secure_compare(expected, actual)
  end

  defp same_object_key?(_expected, _actual), do: false
end
