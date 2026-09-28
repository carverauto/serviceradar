defmodule ServiceRadar.PrefixTags.Preview do
  @moduledoc "IP previews served by the node that owns ingestion snapshots. Callers authorize access."

  alias ServiceRadar.PrefixTags.ExternalSources
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.ProcessRegistry

  @unavailable "Prefix tag preview is unavailable while core is disconnected or loading snapshots"

  def lookup(ip) do
    if ExternalSources.enabled?() do
      local_lookup(ip)
    else
      case ProcessRegistry.core_node() do
        nil ->
          {:error, @unavailable}

        core ->
          case :rpc.call(core, __MODULE__, :local_lookup, [ip], 5_000) do
            {:ok, matches} when is_list(matches) -> {:ok, matches}
            _ -> {:error, @unavailable}
          end
      end
    end
  end

  @doc false
  def local_lookup(ip) do
    case ServiceRadar.PrefixTags.Loader.status() do
      %{initial_boot_complete?: true, external_errors: errors} when map_size(errors) == 0 ->
        {:ok, Store.lookup(ip)}

      _ ->
        {:error, @unavailable}
    end
  rescue
    _ -> {:error, @unavailable}
  end
end
