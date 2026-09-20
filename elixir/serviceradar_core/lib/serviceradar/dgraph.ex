defmodule ServiceRadar.Dgraph do
  @moduledoc """
  Elixir facade over the Dgraph topology NIF.

  Writes go through typed functions and never concatenate DQL. The DQL escape
  hatch is read-only and refuses mutations both here and in the NIF.

  Connection string, ACL userinfo, namespace, and TLS mode come from runtime
  config / env (`DGRAPH_URL`, or `DGRAPH_HOST`/`DGRAPH_PORT`/`DGRAPH_TLS_MODE`),
  not from `network_credential_secrets`.
  """

  alias ServiceRadar.Dgraph.Native

  @type write_result :: :ok | {:error, String.t()}
  @type count_result :: {:ok, non_neg_integer()} | {:error, String.t()}
  @type query_result :: {:ok, term()} | {:error, String.t()}
  @type edges_result :: {:ok, [map()]} | {:error, String.t()}

  @doc """
  Resolve the `dgraph://` URL.

  `DGRAPH_URL` wins. Otherwise `DGRAPH_HOST` (or `:dgraph_host`) is assembled
  with `:dgraph_port` and `:dgraph_tls_mode`. Missing host is an error; there
  is no silent localhost fallback.
  """
  @spec url() :: {:ok, String.t()} | {:error, String.t()}
  def url do
    cond do
      url = nonempty(System.get_env("DGRAPH_URL")) ->
        {:ok, url}

      url = nonempty(Application.get_env(:serviceradar_core, :dgraph_url)) ->
        {:ok, url}

      host = host() ->
        {:ok, assemble_url(host)}

      true ->
        {:error, "dgraph url is not configured"}
    end
  end

  @spec upsert_device(map()) :: write_result()
  def upsert_device(device) when is_map(device) do
    with {:ok, url} <- url() do
      Native.upsert_device(url, device_map(device))
    end
  end

  @spec upsert_interface(map()) :: write_result()
  def upsert_interface(iface) when is_map(iface) do
    with {:ok, url} <- url() do
      Native.upsert_interface(url, interface_map(iface))
    end
  end

  @spec upsert_prefix(map()) :: write_result()
  def upsert_prefix(prefix) when is_map(prefix) do
    with {:ok, url} <- url() do
      Native.upsert_prefix(url, prefix_map(prefix))
    end
  end

  @spec attach_prefix(String.t(), String.t()) :: write_result()
  def attach_prefix(iface_key, cidr) when is_binary(iface_key) and is_binary(cidr) do
    with {:ok, url} <- url() do
      Native.attach_prefix(url, iface_key, cidr)
    end
  end

  @spec upsert_change(map()) :: write_result()
  def upsert_change(change) when is_map(change) do
    with {:ok, url} <- url() do
      Native.upsert_change(url, change_map(change))
    end
  end

  @spec upsert_hop(map()) :: write_result()
  def upsert_hop(hop) when is_map(hop) do
    with {:ok, url} <- url() do
      Native.upsert_hop(url, hop_map(hop))
    end
  end

  @spec upsert_edge(map()) :: write_result()
  def upsert_edge(edge) when is_map(edge) do
    with {:ok, url} <- url() do
      Native.upsert_edge(url, edge_map(edge))
    end
  end

  @spec upsert_canonical_edge(map()) :: write_result()
  def upsert_canonical_edge(edge) when is_map(edge) do
    with {:ok, url} <- url() do
      Native.upsert_canonical_edge(url, edge_map(edge))
    end
  end

  @spec upsert_mtr_path(map()) :: write_result()
  def upsert_mtr_path(edge) when is_map(edge) do
    with {:ok, url} <- url() do
      Native.upsert_mtr_path(url, edge_map(edge))
    end
  end

  @spec prune_stale(String.t(), [String.t()]) :: count_result()
  def prune_stale(cutoff, kinds) when is_binary(cutoff) and is_list(kinds) do
    with {:ok, url} <- url() do
      Native.prune_stale(url, cutoff, kinds)
    end
  end

  @spec rebuild_canonical([map()]) :: write_result()
  def rebuild_canonical(edges) when is_list(edges) do
    with {:ok, url} <- url() do
      Native.rebuild_canonical(url, Enum.map(edges, &edge_map/1))
    end
  end

  @spec query_canonical_edges() :: edges_result()
  def query_canonical_edges do
    with {:ok, url} <- url() do
      Native.query_canonical_edges(url)
    end
  end

  @spec query_neighbourhood(String.t()) :: edges_result()
  def query_neighbourhood(device_id) when is_binary(device_id) do
    with {:ok, url} <- url() do
      Native.query_neighbourhood(url, device_id)
    end
  end

  @doc """
  Read-only DQL escape hatch. Mutations (`mutation`, `set {`, `delete {`,
  `upsert {`) are refused without contacting Dgraph.
  """
  @spec query(String.t()) :: query_result()
  def query(dql) when is_binary(dql) do
    cond do
      String.trim(dql) == "" ->
        {:error, "dql query is empty"}

      mutation?(dql) ->
        {:error, "dql escape hatch refuses mutations"}

      true ->
        with {:ok, url} <- url(),
             {:ok, json} <- Native.query_dql(url, dql) do
          decode_json(json)
        end
    end
  end

  @doc false
  @spec mutation?(String.t()) :: boolean()
  def mutation?(dql) when is_binary(dql) do
    compact =
      dql
      |> String.downcase()
      |> String.replace(~r/\s+/, " ")

    String.contains?(compact, "mutation ") or
      String.contains?(compact, "mutation{") or
      String.contains?(compact, "set {") or
      String.contains?(compact, "set{") or
      String.contains?(compact, "delete {") or
      String.contains?(compact, "delete{") or
      String.contains?(compact, "upsert {") or
      String.contains?(compact, "upsert{")
  end

  defp host do
    nonempty(System.get_env("DGRAPH_HOST")) ||
      nonempty(Application.get_env(:serviceradar_core, :dgraph_host))
  end

  defp assemble_url(host) do
    port = port()
    tls_mode = tls_mode()
    "dgraph://#{host}:#{port}?sslmode=#{tls_mode}"
  end

  defp port do
    case nonempty(System.get_env("DGRAPH_PORT")) do
      nil -> Application.get_env(:serviceradar_core, :dgraph_port, 9080)
      port -> port
    end
  end

  defp tls_mode do
    nonempty(System.get_env("DGRAPH_TLS_MODE")) ||
      Application.get_env(:serviceradar_core, :dgraph_tls_mode, "disable")
  end

  defp nonempty(nil), do: nil
  defp nonempty(""), do: nil
  defp nonempty(value) when is_binary(value), do: value
  defp nonempty(_), do: nil

  defp decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, err} -> {:error, Exception.message(err)}
    end
  end

  defp attr(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp fetch!(map, key) do
    case attr(map, key) do
      nil -> raise ArgumentError, "dgraph write is missing #{inspect(key)}"
      value -> value
    end
  end

  defp device_map(attrs) do
    %{
      id: fetch!(attrs, :id),
      hostname: attr(attrs, :hostname),
      ip: attr(attrs, :ip),
      config_revision_id: attr(attrs, :config_revision_id),
      pkg_worst_severity: attr(attrs, :pkg_worst_severity),
      pkg_critical_count: attr(attrs, :pkg_critical_count),
      pkg_kev_count: attr(attrs, :pkg_kev_count),
      pkg_has_unpatched_rce: attr(attrs, :pkg_has_unpatched_rce),
      pkg_risk_summary_at: attr(attrs, :pkg_risk_summary_at)
    }
  end

  defp interface_map(attrs) do
    %{
      key: fetch!(attrs, :key),
      device_id: fetch!(attrs, :device_id),
      name: attr(attrs, :name),
      if_index: attr(attrs, :if_index)
    }
  end

  defp prefix_map(attrs) do
    %{
      cidr: fetch!(attrs, :cidr),
      family: fetch!(attrs, :family)
    }
  end

  defp change_map(attrs) do
    %{
      id: fetch!(attrs, :id),
      kind: fetch!(attrs, :kind),
      status: fetch!(attrs, :status),
      source: fetch!(attrs, :source),
      affects_prefix_cidrs: List.wrap(attr(attrs, :affects_prefix_cidrs)),
      affects_device_ids: List.wrap(attr(attrs, :affects_device_ids))
    }
  end

  defp hop_map(attrs) do
    %{ip: fetch!(attrs, :ip)}
  end

  defp edge_map(attrs) do
    %{
      source: fetch!(attrs, :source),
      target: fetch!(attrs, :target),
      kind: fetch!(attrs, :kind),
      protocol: fetch!(attrs, :protocol),
      evidence_class: fetch!(attrs, :evidence_class),
      ingestor: attr(attrs, :ingestor) || "mapper_topology_v1",
      if_name_ab: attr(attrs, :if_name_ab),
      if_name_ba: attr(attrs, :if_name_ba),
      if_index_ab: attr(attrs, :if_index_ab),
      if_index_ba: attr(attrs, :if_index_ba),
      confidence_tier: attr(attrs, :confidence_tier),
      flow_pps_ab: attr(attrs, :flow_pps_ab),
      flow_pps_ba: attr(attrs, :flow_pps_ba),
      flow_bps_ab: attr(attrs, :flow_bps_ab),
      flow_bps_ba: attr(attrs, :flow_bps_ba),
      capacity_bps: attr(attrs, :capacity_bps),
      telemetry_eligible: attr(attrs, :telemetry_eligible),
      last_seen: attr(attrs, :last_seen),
      mutation_id: attr(attrs, :mutation_id),
      agent_id: attr(attrs, :agent_id)
    }
  end
end
