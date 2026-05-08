defmodule ServiceRadarWebNG.PluginStorageTestClient do
  @moduledoc false

  def start_link(name) when is_atom(name) do
    Agent.start_link(fn -> %{} end, name: name)
  end

  def put_blob(object_key, payload) when is_binary(object_key) and is_binary(payload) do
    Agent.update(store(), &Map.put(&1, object_key, payload))
  end

  def put_blob_file(object_key, source_path) when is_binary(source_path) do
    with {:ok, payload} <- File.read(source_path) do
      put_blob(object_key, payload)
    end
  end

  def fetch_blob(object_key) when is_binary(object_key) do
    case Agent.get(store(), &Map.fetch(&1, object_key)) do
      {:ok, payload} -> {:ok, {:binary, payload}}
      :error -> {:error, :not_found}
    end
  end

  def delete_blob(object_key) when is_binary(object_key) do
    Agent.update(store(), &Map.delete(&1, object_key))
  end

  def blob_exists?(object_key) when is_binary(object_key) do
    Agent.get(store(), &Map.has_key?(&1, object_key))
  end

  defp store do
    :serviceradar_web_ng
    |> Application.fetch_env!(:plugin_storage)
    |> Keyword.fetch!(:test_store)
  end
end
