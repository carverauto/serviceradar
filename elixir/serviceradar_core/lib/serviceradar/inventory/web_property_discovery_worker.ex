defmodule ServiceRadar.Inventory.WebPropertyDiscoveryWorker do
  @moduledoc """
  Periodic Oban worker that discovers and reconciles L7 `WebProperty` records
  from Kubernetes public endpoints (`platform.public_endpoints_current`), refreshes
  lightweight DNS/CDN/TLS posture, and auto-links unambiguous direct origin
  devices (`source: :auto_vip_match`).

  CRITICAL INVARIANT: This worker NEVER writes to `platform.ocsf_devices` or
  DIRE (`ServiceRadar.Inventory.Identity.*`). Shared Anycast/CDN/Gateway VIPs
  remain isolated in `platform.web_properties` and `platform.web_property_bindings`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.WebProperty
  alias ServiceRadar.Inventory.WebPropertyBinding
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @default_probe_timeout_ms 3_000
  @http_ports [80, 443, 8080, 8443]
  @http_route_kinds ["HTTPRoute", "Ingress"]

  @cdn_asns %{
    20_940 => "akamai",
    16_625 => "akamai",
    12_222 => "akamai",
    35_994 => "akamai",
    13_335 => "cloudflare",
    54_113 => "fastly",
    16_509 => "cloudfront"
  }

  @type posture_result :: %{
          optional(:edge_provider) => String.t() | nil,
          optional(:observed_vips) => [String.t()],
          optional(:observed_asns) => [integer()],
          optional(:tls_not_after) => DateTime.t() | nil,
          optional(:tls_issuer) => String.t() | nil
        }

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    opts =
      if is_map(args) and Map.get(args, "refresh_posture") == false do
        [refresh_posture: false]
      else
        []
      end

    case run_reconcile(opts) do
      {:ok, _stats} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs a single reconciliation pass. Accepts injectable probe callbacks in `opts`:
  - `:network_probes` (boolean, defaults to app env or `true`)
  - `:dns_probe` (`(String.t() -> {:ok, [String.t()]} | {:error, term()})`)
  - `:tls_probe` (`(String.t(), pos_integer() -> {:ok, %{tls_not_after: DateTime.t() | nil, tls_issuer: String.t() | nil}} | {:error, term()})`)
  - `:asn_probe` (`([String.t()] -> {:ok, [integer()]} | {:error, term()})`)
  - `:edge_probe` (`(WebProperty.t(), [String.t()], [integer()], String.t() | nil -> String.t() | nil)`)
  - `:refresh_posture` (boolean, default `true`)
  """
  @spec run_reconcile(keyword()) :: {:ok, map()} | {:error, term()}
  def run_reconcile(opts \\ []) do
    actor = SystemActor.system(:web_property_discovery)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, endpoints} <- fetch_active_public_endpoints(),
         {:ok, ep_stats} <- reconcile_public_endpoints(endpoints, actor, now),
         {:ok, posture_stats} <- maybe_refresh_postures(actor, endpoints, now, opts),
         {:ok, vip_stats} <- reconcile_origin_device_bindings(actor, now) do
      stats = ep_stats |> Map.merge(posture_stats) |> Map.merge(vip_stats)
      {:ok, stats}
    end
  rescue
    error ->
      Logger.warning("WebPropertyDiscoveryWorker reconcile failed",
        error: inspect(error),
        reason: Exception.message(error)
      )

      {:error, error}
  end

  @doc """
  Converts an active `public_endpoints_current` row into `{:ok, normalized_origin}`
  or `:ignore` if it does not represent a web/HTTP endpoint.
  """
  @spec endpoint_to_origin(map()) :: {:ok, String.t()} | :ignore
  def endpoint_to_origin(endpoint) when is_map(endpoint) do
    hostname = endpoint |> Map.get(:hostname) |> trim_or_nil()
    port = Map.get(endpoint, :port)
    route_kind = endpoint |> Map.get(:route_kind) |> trim_or_nil()
    listener_name = endpoint |> Map.get(:listener_name) |> trim_or_nil()
    protocol = endpoint |> Map.get(:protocol, "TCP") |> to_string() |> String.upcase()

    web_candidate? =
      is_binary(hostname) and
        not String.ends_with?(String.downcase(hostname), ".svc.cluster.local") and
        protocol in ["TCP", "HTTP", "HTTPS"] and
        (route_kind in @http_route_kinds or port in @http_ports)

    if web_candidate? do
      scheme = infer_scheme(port, listener_name)
      port_part = if is_integer(port) and port > 0, do: ":#{port}", else: ""

      case WebProperty.normalize_canonical_origin("#{scheme}://#{hostname}#{port_part}") do
        {:ok, origin} -> {:ok, origin}
        {:error, _} -> :ignore
      end
    else
      :ignore
    end
  end

  def endpoint_to_origin(_), do: :ignore

  @doc """
  Given a list of live `{device_uid, ip}` matches for a `WebProperty`'s `observed_vips`,
  returns `{:ok, sole_uid}` when **strictly 1** distinct active device matches,
  `:ambiguous` when multiple live devices share the VIP, or `:none` when zero match.
  """
  @spec match_sole_origin_device([String.t()]) :: {:ok, String.t()} | :none | :ambiguous
  def match_sole_origin_device(device_uids) when is_list(device_uids) do
    case Enum.uniq(Enum.reject(device_uids, &(is_nil(&1) or &1 == ""))) do
      [sole_uid] -> {:ok, sole_uid}
      [] -> :none
      _multiple -> :ambiguous
    end
  end

  @doc """
  Detects the edge/CDN provider from observed ASNs, TLS issuer, K8s exposure class,
  or existing provider value. Pure helper suitable for deterministic unit tests.
  """
  @spec detect_edge_provider([integer()], String.t() | nil, String.t() | nil, String.t() | nil) ::
          String.t() | nil
  def detect_edge_provider(asns, tls_issuer, exposure_class, current_provider \\ nil) do
    asn_match = Enum.find_value(asns || [], &Map.get(@cdn_asns, &1))
    issuer_lower = String.downcase(tls_issuer || "")

    cond do
      is_binary(asn_match) ->
        asn_match

      String.contains?(issuer_lower, "akamai") ->
        "akamai"

      String.contains?(issuer_lower, "cloudflare") ->
        "cloudflare"

      String.contains?(issuer_lower, "fastly") ->
        "fastly"

      exposure_class == "Gateway" ->
        "envoy_gateway"

      is_binary(current_provider) and current_provider != "" ->
        current_provider

      true ->
        "direct"
    end
  end

  defp fetch_active_public_endpoints do
    query =
      from(pe in {"public_endpoints_current", :platform},
        prefix: "platform",
        where: is_nil(pe.deleted_at) and fragment("coalesce(btrim(?), '') <> ''", pe.hostname),
        select: %{
          endpoint_key: pe.endpoint_key,
          cluster_id: pe.cluster_id,
          ip: pe.ip,
          hostname: pe.hostname,
          port: pe.port,
          protocol: pe.protocol,
          exposure_class: pe.exposure_class,
          namespace: pe.namespace,
          service_name: pe.service_name,
          gateway_name: pe.gateway_name,
          listener_name: pe.listener_name,
          route_kind: pe.route_kind,
          route_name: pe.route_name,
          observed_at: pe.observed_at
        }
      )

    {:ok, Repo.all(query)}
  rescue
    error ->
      Logger.warning("WebPropertyDiscoveryWorker failed querying public_endpoints_current",
        error: inspect(error),
        reason: Exception.message(error)
      )

      {:error, error}
  end

  defp reconcile_public_endpoints(endpoints, actor, now) do
    {active_keys, created_props, upserted_bindings} =
      Enum.reduce(endpoints, {MapSet.new(), 0, 0}, fn ep, {keys, props_acc, bind_acc} ->
        case endpoint_to_origin(ep) do
          {:ok, origin} ->
            {wp, created?} = find_or_create_web_property(origin, ep, actor)

            case wp do
              %WebProperty{} = property ->
                binding_key = upsert_k8s_binding(property, ep, actor, now)

                {
                  if(binding_key, do: MapSet.put(keys, binding_key), else: keys),
                  props_acc + if(created?, do: 1, else: 0),
                  bind_acc + if(binding_key, do: 1, else: 0)
                }

              nil ->
                {keys, props_acc, bind_acc}
            end

          :ignore ->
            {keys, props_acc, bind_acc}
        end
      end)

    pruned_bindings = prune_stale_k8s_bindings(active_keys, actor)

    {:ok,
     %{
       properties_created: created_props,
       k8s_bindings_upserted: upserted_bindings,
       k8s_bindings_pruned: pruned_bindings
     }}
  end

  defp find_or_create_web_property(origin, ep, actor) do
    case WebProperty.get_by_canonical_origin(origin, actor: actor) do
      {:ok, %WebProperty{} = existing} ->
        {existing, false}

      {:error, _} ->
        hostname = trim_or_nil(ep[:hostname]) || origin
        edge_provider = if ep[:exposure_class] == "Gateway", do: "envoy_gateway"
        observed_vips = if is_binary(ep[:ip]) and ep[:ip] != "", do: [ep[:ip]], else: []

        attrs = %{
          name: hostname,
          canonical_origin: origin,
          allowed_origins: [origin],
          environment: :production,
          edge_provider: edge_provider
        }

        case WebProperty
             |> Ash.Changeset.for_create(:create, attrs, actor: actor)
             |> Ash.create() do
          {:ok, created} ->
            created =
              if observed_vips == [] do
                created
              else
                case created
                     |> Ash.Changeset.for_update(
                       :update_posture,
                       %{observed_vips: observed_vips},
                       actor: actor
                     )
                     |> Ash.update() do
                  {:ok, updated} -> updated
                  _ -> created
                end
              end

            {created, true}

          {:error, reason} ->
            Logger.warning("WebPropertyDiscoveryWorker failed creating WebProperty",
              host: hostname,
              reason: inspect(reason)
            )

            {nil, false}
        end
    end
  end

  defp upsert_k8s_binding(property, ep, actor, now) do
    cluster_id = trim_or_nil(ep[:cluster_id]) || "default"
    namespace = ep[:namespace] || ""
    resource_kind = trim_or_nil(ep[:route_kind]) || "Service"

    resource_name =
      trim_or_nil(ep[:route_name]) || trim_or_nil(ep[:service_name]) || ep[:endpoint_key]

    observed_at = ep[:observed_at] || now
    key = {property.id, cluster_id, namespace, resource_kind, resource_name}

    existing =
      WebPropertyBinding
      |> Ash.Query.filter(
        web_property_id == ^property.id and
          binding_kind == :k8s_public_endpoint and
          cluster_id == ^cluster_id and
          namespace == ^namespace and
          resource_kind == ^resource_kind and
          resource_name == ^resource_name
      )
      |> Ash.read_one(actor: actor)

    case existing do
      {:ok, %WebPropertyBinding{} = binding} ->
        _ =
          binding
          |> Ash.Changeset.for_update(
            :update,
            %{
              endpoint_key: ep[:endpoint_key],
              last_observed_at: observed_at,
              metadata: k8s_binding_metadata(ep)
            },
            actor: actor
          )
          |> Ash.update()

        key

      {:ok, nil} ->
        attrs = %{
          web_property_id: property.id,
          binding_kind: :k8s_public_endpoint,
          source: :k8s_discovery,
          cluster_id: cluster_id,
          namespace: namespace,
          resource_kind: resource_kind,
          resource_name: resource_name,
          endpoint_key: ep[:endpoint_key],
          last_observed_at: observed_at,
          metadata: k8s_binding_metadata(ep)
        }

        case WebPropertyBinding
             |> Ash.Changeset.for_create(:create, attrs, actor: actor)
             |> Ash.create() do
          {:ok, _} ->
            key

          {:error, reason} ->
            Logger.warning("WebPropertyDiscoveryWorker failed creating k8s binding",
              id: property.id,
              endpoint_key: ep[:endpoint_key],
              reason: inspect(reason)
            )

            nil
        end

      {:error, _} ->
        nil
    end
  end

  defp k8s_binding_metadata(ep) do
    %{
      "exposure_class" => ep[:exposure_class],
      "gateway_name" => ep[:gateway_name],
      "listener_name" => ep[:listener_name],
      "service_name" => ep[:service_name],
      "ip" => ep[:ip],
      "port" => ep[:port]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp prune_stale_k8s_bindings(active_keys, actor) do
    WebPropertyBinding
    |> Ash.Query.filter(binding_kind == :k8s_public_endpoint and source == :k8s_discovery)
    |> Ash.read!(actor: actor)
    |> Enum.reduce(0, fn binding, count ->
      key =
        {binding.web_property_id, binding.cluster_id, binding.namespace || "",
         binding.resource_kind, binding.resource_name}

      if MapSet.member?(active_keys, key) do
        count
      else
        case Ash.destroy(binding, actor: actor) do
          :ok -> count + 1
          {:ok, _} -> count + 1
          _ -> count
        end
      end
    end)
  end

  defp maybe_refresh_postures(actor, endpoints, now, opts) do
    if Keyword.get(opts, :refresh_posture, true) do
      endpoint_vips_by_origin = build_endpoint_vips_map(endpoints)
      properties = Ash.read!(WebProperty, actor: actor)

      updated =
        Enum.reduce(properties, 0, fn wp, acc ->
          case refresh_single_posture(wp, endpoint_vips_by_origin, actor, now, opts) do
            :ok -> acc + 1
            :skip -> acc
          end
        end)

      {:ok, %{postures_updated: updated}}
    else
      {:ok, %{postures_updated: 0}}
    end
  end

  defp build_endpoint_vips_map(endpoints) do
    Enum.reduce(endpoints, %{}, fn ep, acc ->
      case endpoint_to_origin(ep) do
        {:ok, origin} ->
          ip = trim_or_nil(ep[:ip])
          entry = {ip, ep[:exposure_class]}
          Map.update(acc, origin, [entry], &[entry | &1])

        :ignore ->
          acc
      end
    end)
  end

  defp refresh_single_posture(%WebProperty{} = wp, endpoint_vips_by_origin, actor, now, opts) do
    probes_enabled? =
      Keyword.get(
        opts,
        :network_probes,
        :serviceradar_core
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:network_probes, true)
      )

    has_custom_probes? =
      is_function(opts[:dns_probe], 1) or is_function(opts[:tls_probe], 2) or
        is_function(opts[:asn_probe], 1) or is_function(opts[:edge_probe], 4)

    ep_entries = Map.get(endpoint_vips_by_origin, wp.canonical_origin, [])
    ep_vips = ep_entries |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    exposure_class = ep_entries |> Enum.map(&elem(&1, 1)) |> Enum.find(&is_binary/1)

    if not probes_enabled? and not has_custom_probes? and ep_vips == [] do
      :skip
    else
      uri = URI.parse(wp.canonical_origin)
      host = uri.host
      port = uri.port || if(uri.scheme == "https", do: 443, else: 80)

      dns_vips = probe_dns(host, probes_enabled?, opts[:dns_probe])
      observed_vips = Enum.uniq(ep_vips ++ dns_vips ++ (wp.observed_vips || []))

      observed_vips =
        if dns_vips != [] or ep_vips != [],
          do: Enum.uniq(ep_vips ++ dns_vips),
          else: observed_vips

      observed_asns =
        case opts[:asn_probe] do
          fun when is_function(fun, 1) ->
            case fun.(observed_vips) do
              {:ok, asns} when is_list(asns) -> Enum.uniq(asns)
              _ -> wp.observed_asns || []
            end

          _ ->
            wp.observed_asns || []
        end

      {tls_not_after, tls_issuer} =
        probe_tls(uri.scheme, host, port, probes_enabled?, opts[:tls_probe], wp)

      edge_provider =
        case opts[:edge_probe] do
          fun when is_function(fun, 4) ->
            fun.(wp, observed_vips, observed_asns, tls_issuer)

          _ ->
            detect_edge_provider(observed_asns, tls_issuer, exposure_class, wp.edge_provider)
        end

      attrs = %{
        edge_provider: edge_provider,
        observed_vips: observed_vips,
        observed_asns: observed_asns,
        tls_not_after: tls_not_after,
        tls_issuer: tls_issuer,
        last_posture_checked_at: now
      }

      case wp
           |> Ash.Changeset.for_update(:update_posture, attrs, actor: actor)
           |> Ash.update() do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("WebPropertyDiscoveryWorker failed updating posture",
            id: wp.id,
            host: host,
            reason: inspect(reason)
          )

          :skip
      end
    end
  end

  defp probe_dns(host, _enabled?, dns_probe) when is_function(dns_probe, 1) do
    case dns_probe.(host) do
      {:ok, ips} when is_list(ips) -> Enum.filter(ips, &is_binary/1)
      _ -> []
    end
  end

  defp probe_dns(host, true, _nil) when is_binary(host) do
    char_host = String.to_charlist(host)

    v4 =
      case :inet.getaddrs(char_host, :inet) do
        {:ok, addrs} -> Enum.map(addrs, &to_string(:inet.ntoa(&1)))
        _ -> []
      end

    v6 =
      case :inet.getaddrs(char_host, :inet6) do
        {:ok, addrs} -> Enum.map(addrs, &to_string(:inet.ntoa(&1)))
        _ -> []
      end

    Enum.uniq(v4 ++ v6)
  rescue
    _ -> []
  end

  defp probe_dns(_, _, _), do: []

  defp probe_tls("https", host, port, _enabled?, tls_probe, wp) when is_function(tls_probe, 2) do
    case tls_probe.(host, port) do
      {:ok, %{tls_not_after: not_after, tls_issuer: issuer}} -> {not_after, issuer}
      _ -> {wp.tls_not_after, wp.tls_issuer}
    end
  end

  defp probe_tls("https", host, port, true, _nil, wp) when is_binary(host) do
    char_host = String.to_charlist(host)

    ssl_opts = [
      verify: :verify_none,
      server_name_indication: char_host,
      active: false
    ]

    case :ssl.connect(char_host, port, ssl_opts, @default_probe_timeout_ms) do
      {:ok, sock} ->
        try do
          case :ssl.peercert(sock) do
            {:ok, der} -> extract_cert_posture(der, wp)
            _ -> {wp.tls_not_after, wp.tls_issuer}
          end
        after
          :ssl.close(sock)
        end

      {:error, reason} ->
        Logger.debug("WebPropertyDiscoveryWorker TLS probe skipped",
          host: host,
          port: port,
          reason: inspect(reason)
        )

        {wp.tls_not_after, wp.tls_issuer}
    end
  rescue
    _ -> {wp.tls_not_after, wp.tls_issuer}
  end

  defp probe_tls(_scheme, _host, _port, _enabled?, _tls_probe, wp) do
    {wp.tls_not_after, wp.tls_issuer}
  end

  defp extract_cert_posture(der, wp) do
    cert = :public_key.pkix_decode_cert(der, :otp)
    tbs = elem(cert, 1)
    issuer_rdn = elem(tbs, 4)
    validity = elem(tbs, 5)
    not_after_asn1 = elem(validity, 2)

    {parse_asn1_time(not_after_asn1) || wp.tls_not_after,
     extract_issuer_name(issuer_rdn) || wp.tls_issuer}
  rescue
    _ -> {wp.tls_not_after, wp.tls_issuer}
  end

  defp parse_asn1_time({:utcTime, chars}) do
    str = List.to_string(chars)

    case Regex.run(~r/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/, str) do
      [_, yy, mm, dd, hh, mi, ss] ->
        year_two = String.to_integer(yy)
        year = if year_two >= 50, do: 1900 + year_two, else: 2000 + year_two
        build_utc_datetime(year, mm, dd, hh, mi, ss)

      _ ->
        nil
    end
  end

  defp parse_asn1_time({:generalTime, chars}) do
    str = List.to_string(chars)

    case Regex.run(~r/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/, str) do
      [_, yyyy, mm, dd, hh, mi, ss] ->
        build_utc_datetime(String.to_integer(yyyy), mm, dd, hh, mi, ss)

      _ ->
        nil
    end
  end

  defp parse_asn1_time(_), do: nil

  defp build_utc_datetime(year, mm, dd, hh, mi, ss) do
    with {:ok, date} <-
           Date.new(year, String.to_integer(mm), String.to_integer(dd)),
         {:ok, time} <-
           Time.new(String.to_integer(hh), String.to_integer(mi), String.to_integer(ss)),
         {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
      dt
    else
      _ -> nil
    end
  end

  defp extract_issuer_name({:rdnSequence, rdns}) when is_list(rdns) do
    attrs = List.flatten(rdns)
    find_rdn_value(attrs, {2, 5, 4, 3}) || find_rdn_value(attrs, {2, 5, 4, 10})
  end

  defp extract_issuer_name(_), do: nil

  defp find_rdn_value(attrs, oid) do
    Enum.find_value(attrs, fn
      {:AttributeTypeAndValue, ^oid, {:utf8String, val}} -> to_string(val)
      {:AttributeTypeAndValue, ^oid, {:printableString, val}} -> List.to_string(val)
      {:AttributeTypeAndValue, ^oid, {:ia5String, val}} -> List.to_string(val)
      {:AttributeTypeAndValue, ^oid, val} when is_binary(val) -> val
      _ -> nil
    end)
  end

  # Auto-links :origin_device (source: :auto_vip_match) ONLY when edge_provider == "direct"
  # and the property's observed_vips match strictly 1 active (non-tombstoned) live Device.
  # Never writes to ocsf_devices or DIRE.
  defp reconcile_origin_device_bindings(actor, now) do
    properties = Ash.read!(WebProperty, actor: actor)

    {linked, pruned} =
      Enum.reduce(properties, {0, 0}, fn wp, {linked_acc, pruned_acc} ->
        existing_auto =
          WebPropertyBinding
          |> Ash.Query.filter(
            web_property_id == ^wp.id and
              binding_kind == :origin_device and
              source == :auto_vip_match
          )
          |> Ash.read!(actor: actor)

        if wp.edge_provider == "direct" and wp.observed_vips != [] do
          live_uids = fetch_live_device_uids_by_ips(wp.observed_vips)

          case match_sole_origin_device(live_uids) do
            {:ok, sole_uid} ->
              {upserted?, pruned_for_wp} =
                reconcile_sole_origin_device(wp, sole_uid, existing_auto, actor, now)

              {linked_acc + if(upserted?, do: 1, else: 0), pruned_acc + pruned_for_wp}

            _ ->
              {linked_acc, pruned_acc + destroy_bindings(existing_auto, actor)}
          end
        else
          {linked_acc, pruned_acc + destroy_bindings(existing_auto, actor)}
        end
      end)

    {:ok, %{origin_devices_linked: linked, origin_devices_pruned: pruned}}
  end

  defp reconcile_sole_origin_device(wp, sole_uid, existing_auto, actor, now) do
    to_prune = Enum.reject(existing_auto, &(&1.device_uid == sole_uid))
    pruned = destroy_bindings(to_prune, actor)

    existing_any =
      WebPropertyBinding
      |> Ash.Query.filter(
        web_property_id == ^wp.id and
          binding_kind == :origin_device and
          device_uid == ^sole_uid
      )
      |> Ash.read_one(actor: actor)

    case existing_any do
      {:ok, %WebPropertyBinding{} = binding} ->
        if binding.source == :auto_vip_match do
          _ =
            binding
            |> Ash.Changeset.for_update(:update, %{last_observed_at: now}, actor: actor)
            |> Ash.update()
        end

        {false, pruned}

      {:ok, nil} ->
        attrs = %{
          web_property_id: wp.id,
          binding_kind: :origin_device,
          source: :auto_vip_match,
          device_uid: sole_uid,
          last_observed_at: now,
          metadata: %{"matched_vips" => wp.observed_vips}
        }

        case WebPropertyBinding
             |> Ash.Changeset.for_create(:create, attrs, actor: actor)
             |> Ash.create() do
          {:ok, _} -> {true, pruned}
          {:error, _} -> {false, pruned}
        end

      {:error, _} ->
        {false, pruned}
    end
  end

  defp destroy_bindings(bindings, actor) do
    Enum.reduce(bindings, 0, fn binding, acc ->
      case Ash.destroy(binding, actor: actor) do
        :ok -> acc + 1
        {:ok, _} -> acc + 1
        _ -> acc
      end
    end)
  end

  defp fetch_live_device_uids_by_ips([]), do: []

  defp fetch_live_device_uids_by_ips(ips) do
    query =
      from(d in {"ocsf_devices", :platform},
        prefix: "platform",
        where: is_nil(d.deleted_at) and d.ip in ^ips,
        select: d.uid
      )

    Repo.all(query)
  rescue
    error ->
      Logger.warning("WebPropertyDiscoveryWorker failed querying ocsf_devices",
        error: inspect(error),
        reason: Exception.message(error)
      )

      []
  end

  defp infer_scheme(port, listener_name) do
    listener_lower = String.downcase(listener_name || "")

    cond do
      port in [443, 8443] -> "https"
      String.contains?(listener_lower, "https") -> "https"
      String.contains?(listener_lower, "tls") -> "https"
      true -> "http"
    end
  end

  defp trim_or_nil(nil), do: nil

  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(value), do: to_string(value)
end
