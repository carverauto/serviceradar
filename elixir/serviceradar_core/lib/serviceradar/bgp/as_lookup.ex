defmodule ServiceRadar.BGP.ASLookup do
  @moduledoc """
  AS number to organization name lookup.

  Provides mapping of AS numbers to their registered organization names.
  Queries the GeoIP and ipinfo enrichment caches populated by the
  background IP enrichment pipeline from GeoLite2-ASN.mmdb and
  ipinfo_lite.mmdb databases. Results are cached in ETS to minimize
  database queries.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.IpGeoEnrichmentCache
  alias ServiceRadar.Observability.IpIpinfoCache

  require Logger

  @cache_ttl to_timeout(day: 1)

  ## Client API

  @doc """
  Start the AS lookup cache server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lookup organization name for an AS number.

  Checks in order:
  1. Local ETS cache
  2. GeoIP enrichment cache (GeoLite2-ASN data)
  3. ipinfo enrichment cache (ipinfo lite data)

  Returns the organization name or "AS {number}" if not found.

  ## Examples

      iex> ASLookup.lookup(15169)
      "Google LLC"

      iex> ASLookup.lookup(99999999)
      "AS 99999999"
  """
  def lookup(as_number) when is_integer(as_number) do
    case GenServer.call(__MODULE__, {:lookup, as_number}, 10_000) do
      {:ok, name} -> name
      {:error, _} -> "AS #{as_number}"
    end
  end

  def lookup(_), do: "Unknown AS"

  @doc """
  Format AS number with organization name.

  Returns formatted string like "AS 15169 (Google LLC)".

  ## Examples

      iex> ASLookup.format(15169)
      "AS 15169 (Google LLC)"
  """
  def format(as_number) when is_integer(as_number) do
    org = lookup(as_number)

    if String.starts_with?(org, "AS ") do
      org
    else
      "AS #{as_number} (#{org})"
    end
  end

  def format(_), do: "Unknown AS"

  ## Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(:as_lookup_cache, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:lookup, as_number}, _from, state) do
    now = System.system_time(:second)

    case :ets.lookup(:as_lookup_cache, as_number) do
      [{^as_number, name, cached_at}] when now - cached_at < @cache_ttl ->
        {:reply, {:ok, name}, state}

      _ ->
        case lookup_from_enrichment_caches(as_number) do
          {:ok, name} ->
            :ets.insert(:as_lookup_cache, {as_number, name, now})
            {:reply, {:ok, name}, state}

          :not_found ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  ## Private Functions

  defp lookup_from_enrichment_caches(as_number) do
    actor = SystemActor.system(:as_lookup)

    case lookup_geo_cache(as_number, actor) do
      {:ok, name} ->
        {:ok, name}

      :not_found ->
        lookup_ipinfo_cache(as_number, actor)
    end
  end

  defp lookup_geo_cache(as_number, actor) do
    IpGeoEnrichmentCache
    |> Ash.Query.for_read(:by_asn, %{asn: as_number})
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%{as_org: org} | _]} when is_binary(org) and org != "" ->
        {:ok, org}

      _ ->
        :not_found
    end
  rescue
    _ -> :not_found
  end

  defp lookup_ipinfo_cache(as_number, actor) do
    IpIpinfoCache
    |> Ash.Query.for_read(:by_as_number, %{as_number: as_number})
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%{as_name: name} | _]} when is_binary(name) and name != "" ->
        {:ok, name}

      _ ->
        :not_found
    end
  rescue
    _ -> :not_found
  end
end
