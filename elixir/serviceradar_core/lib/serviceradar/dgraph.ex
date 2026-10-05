defmodule ServiceRadar.Dgraph do
  @moduledoc """
  Elixir facade over the Dgraph topology NIF.

  Writes go through typed functions and never concatenate DQL. The DQL escape
  hatch is read-only and refuses mutations both here and in the NIF.

  Connection string, ACL userinfo, namespace, and TLS mode come from runtime
  config / env (`DGRAPH_URL`, or `DGRAPH_HOST`/`DGRAPH_PORT`/`DGRAPH_TLS_MODE`),
  not from `network_credential_secrets`.

  ## Deadlines, backpressure and retry

  Calls are asynchronous NIFs (see `ServiceRadar.Dgraph.Call`): a stalled
  Dgraph holds no scheduler, and every call ends by its deadline with
  `{:error, reason}`. Single-item reads and writes get `:item_deadline_ms`
  (default 30 s). Whole-graph reads, pruning and the canonical rebuild get
  `:bulk_deadline_ms` (default 300 s). Calls beyond the native in-flight limit
  wait for a slot, and that wait counts against the deadline.

  Idempotent upserts are retried on a timeout or transient failure, up to
  `:max_attempts` (default 3) with jittered exponential backoff
  (`:retry_base_ms`, `:retry_max_ms`). Pruning, hosted-edge replacement and
  retirement, the canonical rebuild and reads are not retried: their result or
  their guard depends on state a repeat could observe differently. All of
  these are read from `config :serviceradar_core, ServiceRadar.Dgraph, ...`.
  """

  alias ServiceRadar.Dgraph.Call
  alias ServiceRadar.Dgraph.Native

  @defaults [
    item_deadline_ms: 30_000,
    bulk_deadline_ms: 300_000,
    reply_margin_ms: 2_000,
    max_attempts: 3,
    retry_base_ms: 200,
    retry_max_ms: 2_000
  ]

  @type write_result :: :ok | {:error, String.t()}
  @type count_result :: {:ok, non_neg_integer()} | {:error, String.t()}
  @type query_result :: {:ok, term()} | {:error, String.t()}
  @type edges_result :: {:ok, [map()]} | {:error, String.t()}
  @type graph_result :: {:ok, %{nodes: [map()], edges: [map()]}} | {:error, String.t()}

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
      call(:upsert_device, :item, true, &Native.upsert_device(url, device_map(device), &1))
    end
  end

  @spec upsert_interface(map()) :: write_result()
  def upsert_interface(iface) when is_map(iface) do
    with {:ok, url} <- url() do
      call(
        :upsert_interface,
        :item,
        true,
        &Native.upsert_interface(url, interface_map(iface), &1)
      )
    end
  end

  @spec upsert_prefix(map()) :: write_result()
  def upsert_prefix(prefix) when is_map(prefix) do
    with {:ok, url} <- url() do
      call(:upsert_prefix, :item, true, &Native.upsert_prefix(url, prefix_map(prefix), &1))
    end
  end

  @spec attach_prefix(String.t(), String.t()) :: write_result()
  def attach_prefix(iface_key, cidr) when is_binary(iface_key) and is_binary(cidr) do
    with {:ok, url} <- url() do
      call(:attach_prefix, :item, true, &Native.attach_prefix(url, iface_key, cidr, &1))
    end
  end

  @spec upsert_change(map()) :: write_result()
  def upsert_change(change) when is_map(change) do
    with {:ok, url} <- url() do
      call(:upsert_change, :item, true, &Native.upsert_change(url, change_map(change), &1))
    end
  end

  @spec upsert_hop(map()) :: write_result()
  def upsert_hop(hop) when is_map(hop) do
    with {:ok, url} <- url() do
      call(:upsert_hop, :item, true, &Native.upsert_hop(url, hop_map(hop), &1))
    end
  end

  @spec upsert_edge(map()) :: write_result()
  def upsert_edge(edge) when is_map(edge) do
    with {:ok, url} <- url() do
      call(:upsert_edge, :item, true, &Native.upsert_edge(url, edge_map(edge), &1))
    end
  end

  def retire_hosted_edge(source, target, observed_at) do
    with {:ok, url} <- url() do
      call(
        :retire_hosted_edge,
        :item,
        false,
        &Native.retire_hosted_edge(url, source, target, observed_at, &1)
      )
    end
  end

  @spec replace_hosted_edge(map()) :: write_result()
  def replace_hosted_edge(edge) when is_map(edge) do
    with {:ok, url} <- url() do
      call(
        :replace_hosted_edge,
        :item,
        false,
        &Native.replace_hosted_edge(url, edge_map(edge), &1)
      )
    end
  end

  @spec upsert_canonical_edge(map()) :: write_result()
  def upsert_canonical_edge(edge) when is_map(edge) do
    with {:ok, url} <- url() do
      call(
        :upsert_canonical_edge,
        :item,
        true,
        &Native.upsert_canonical_edge(url, edge_map(edge), &1)
      )
    end
  end

  @doc "Refresh rates without changing an existing edge's discovery timestamp or evidence."
  @spec update_canonical_edge_telemetry(map()) :: write_result()
  def update_canonical_edge_telemetry(edge) when is_map(edge) do
    with {:ok, url} <- url() do
      call(
        :update_canonical_edge_telemetry,
        :item,
        true,
        &Native.update_canonical_edge_telemetry(url, edge_map(edge), &1)
      )
    end
  end

  @spec upsert_mtr_path(map()) :: write_result()
  def upsert_mtr_path(edge) when is_map(edge) do
    with {:ok, url} <- url() do
      call(:upsert_mtr_path, :item, true, &Native.upsert_mtr_path(url, edge_map(edge), &1))
    end
  end

  @spec prune_stale(String.t(), [String.t()]) :: count_result()
  def prune_stale(cutoff, kinds) when is_binary(cutoff) and is_list(kinds) do
    with {:ok, url} <- url() do
      call(:prune_stale, :bulk, false, &Native.prune_stale(url, cutoff, kinds, &1))
    end
  end

  @spec rebuild_canonical([map()]) :: write_result()
  def rebuild_canonical(edges) when is_list(edges) do
    edge_maps = Enum.map(edges, &edge_map/1)

    with {:ok, url} <- url() do
      case call(:rebuild_canonical, :bulk, false, fn deadline_ms ->
             Native.rebuild_canonical(url, edge_maps, deadline_ms)
           end) do
        :ok ->
          _ = ServiceRadar.NetworkDiscovery.WorldWorker.enqueue_reconcile()
          :ok

        error ->
          error
      end
    end
  end

  @spec query_canonical_edges() :: edges_result()
  def query_canonical_edges do
    with {:ok, url} <- url() do
      call(:query_canonical_edges, :bulk, false, &Native.query_canonical_edges(url, &1))
    end
  end

  @doc "Reads all canonical vertices and edges through bounded pages from one Dgraph snapshot."
  @spec query_canonical_graph() :: graph_result()
  def query_canonical_graph do
    with {:ok, url} <- url() do
      call(:query_canonical_graph, :bulk, false, &Native.query_canonical_graph(url, &1))
    end
  end

  @doc """
  Graph fact after Prefix expansion. Returns `:reachable` or `:disjoint`.
  Does not return postpone/sequence.
  """
  @spec downstream_of([String.t()], [String.t()]) ::
          {:ok, :reachable | :disjoint} | {:error, String.t()}
  def downstream_of(from_ids, to_ids) when is_list(from_ids) and is_list(to_ids) do
    with {:ok, url} <- url() do
      case call(:downstream_of, :item, false, &Native.downstream_of(url, from_ids, to_ids, &1)) do
        {:ok, fact} when fact in [:reachable, :disjoint] -> {:ok, fact}
        {:error, reason} -> {:error, reason}
        other -> {:error, "unexpected downstream_of result: #{inspect(other)}"}
      end
    end
  end

  @spec query_neighbourhood(String.t()) :: edges_result()
  def query_neighbourhood(device_id) when is_binary(device_id) do
    with {:ok, url} <- url() do
      call(:query_neighbourhood, :item, false, &Native.query_neighbourhood(url, device_id, &1))
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
             {:ok, json} <- call(:query_dql, :item, false, &Native.query_dql(url, dql, &1)) do
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

  @doc false
  # Options for `ServiceRadar.Dgraph.Call.run/3`, shared with the topology atlas
  # read so every Dgraph NIF call has the same deadline and backstop policy.
  @spec call_options(:item | :bulk, boolean()) :: keyword()
  def call_options(class, retry?) when class in [:item, :bulk] and is_boolean(retry?) do
    config = Keyword.merge(@defaults, Application.get_env(:serviceradar_core, __MODULE__, []))

    deadline_key = if class == :bulk, do: :bulk_deadline_ms, else: :item_deadline_ms

    [
      deadline_ms: Keyword.fetch!(config, deadline_key),
      reply_margin_ms: Keyword.fetch!(config, :reply_margin_ms),
      retry?: retry?,
      max_attempts: Keyword.fetch!(config, :max_attempts),
      retry_base_ms: Keyword.fetch!(config, :retry_base_ms),
      retry_max_ms: Keyword.fetch!(config, :retry_max_ms)
    ]
  end

  defp call(operation, class, retry?, submit) do
    Call.run(operation, submit, [cancel: &Native.cancel/1] ++ call_options(class, retry?))
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
      window_start: attr(attrs, :window_start),
      window_end: attr(attrs, :window_end),
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
      agent_id: attr(attrs, :agent_id),
      pair_support_rank: attr(attrs, :pair_support_rank) || 0
    }
  end
end
