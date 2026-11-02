defmodule ServiceRadar.Edge.ManagedComponentRegistration do
  @moduledoc "Binds one installed service to an enrolled host and an existing edge inventory record."
  alias Ash.Error.Query.InvalidArgument
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.ComponentCertificateAuthority
  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.Edge.NatsLeafCertificateIssuer
  alias ServiceRadar.Infrastructure.Agent

  require Ash.Query

  def register(params, opts) do
    case Ash.transact([ManagedComponent, EdgeSite], fn ->
           case do_register(params, opts) do
             {:error, reason} when is_atom(reason) ->
               {:error,
                InvalidArgument.exception(
                  field: :registration,
                  value: reason,
                  message: "component registration refused"
                )}

             result ->
               result
           end
         end) do
      {:ok, result} -> result
      {:error, %InvalidArgument{field: :registration, value: reason}} -> {:error, reason}
      error -> error
    end
  end

  defp do_register(params, opts) do
    with host when is_binary(host) <- params["host_agent_id"],
         service when is_binary(service) <- params["service"],
         {:ok, %Agent{status: status}} when status != :superseded <- Ash.get(Agent, host, opts),
         {:ok, attrs} <- source(params, service, opts),
         {:ok, existing} <-
           Ash.get(
             ManagedComponent,
             attrs.component_id,
             Keyword.put(opts, :not_found_error?, false)
           ) do
      if existing do
        if existing.host_agent_id == host && existing.component_type == service &&
             existing.edge_site_id == attrs[:edge_site_id] &&
             existing.collector_id == attrs[:collector_id] &&
             existing.server_hosts == attrs.server_hosts,
           do: {:ok, existing},
           else: {:error, :component_binding_conflict}
      else
        with {:ok, evidence} <- AgentCommandBus.resolve_control_session_evidence(host),
             {:ok, nil} <-
               ManagedComponent
               |> Ash.Query.filter(host_agent_id == ^host and component_type == ^service)
               |> Ash.read_one(opts) do
          attrs
          |> Map.merge(%{
            host_agent_id: host,
            partition_id: evidence.partition_id,
            component_type: service
          })
          |> ComponentCertificateAuthority.enroll_component(opts)
        else
          {:ok, %ManagedComponent{}} -> {:error, :host_service_already_managed}
          error -> error
        end
      end
    else
      {:ok, _} -> {:error, :invalid_host_agent}
      {:error, _} = error -> error
      _ -> {:error, :invalid_registration}
    end
  end

  def service_for(:flowgger), do: "log-collector"
  def service_for(:otel), do: "log-collector"
  def service_for(:netflow), do: "flow-collector"
  def service_for(:sflow), do: "flow-collector"
  def service_for(:trapd), do: "trapd"
  def service_for(:bmp), do: "bmp-collector"
  def service_for(_), do: nil

  defp source(%{"edge_site_id" => id} = params, "nats-leaf", opts) when is_binary(id) do
    with false <- Map.has_key?(params, "collector_id"),
         {:ok, %EdgeSite{} = site} <- Ash.get(EdgeSite, id, opts),
         {:ok, site} <- advertise(site, params["advertise_url"], opts) do
      {:ok,
       %{
         component_id: "leaf-#{site.slug}",
         edge_site_id: site.id,
         server_hosts: NatsLeafCertificateIssuer.local_hosts(site)
       }}
    else
      _ -> {:error, :invalid_edge_site}
    end
  end

  defp source(%{"collector_id" => id} = params, service, opts) when is_binary(id) do
    with false <- Map.has_key?(params, "edge_site_id"),
         {:ok, %CollectorPackage{status: status} = package} when status != :revoked <-
           Ash.get(CollectorPackage, id, opts),
         true <- service_for(package.collector_type) == service,
         {:ok, hosts} <- server_hosts(params["server_hosts"], package.hostname) do
      {:ok,
       %{
         component_id: "collector-#{package.id}",
         collector_id: package.id,
         edge_site_id: package.edge_site_id,
         server_hosts: hosts
       }}
    else
      _ -> {:error, :invalid_collector}
    end
  end

  defp source(_, _, _), do: {:error, :invalid_source_binding}

  defp advertise(site, nil, _opts) do
    case advertised_url(site.nats_leaf_url) do
      {:ok, _} -> {:ok, site}
      error -> error
    end
  end

  defp advertise(site, url, opts) do
    with {:ok, normalized} <- advertised_url(url) do
      site
      |> Ash.Changeset.for_update(:update, %{nats_leaf_url: normalized}, opts)
      |> Ash.update(opts)
    end
  end

  defp advertised_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "tls",
        host: host,
        port: port,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      } = uri
      when is_binary(host) and is_integer(port) and port in 1..65_535 and path in [nil, ""] ->
        if host in ["localhost", "127.0.0.1", "::1", "0.0.0.0", "::"],
          do: {:error, :invalid_advertise_url},
          else: {:ok, URI.to_string(uri)}

      _ ->
        {:error, :invalid_advertise_url}
    end
  end

  defp advertised_url(_), do: {:error, :advertise_url_required}

  defp server_hosts(nil, hostname),
    do: server_hosts(Enum.reject(["localhost", "127.0.0.1", hostname], &is_nil/1), nil)

  defp server_hosts(hosts, _) when is_list(hosts) and length(hosts) in 1..16 do
    if Enum.all?(hosts, fn host ->
         is_binary(host) && byte_size(host) <= 253 &&
           (match?({:ok, _}, :inet.parse_address(String.to_charlist(host))) ||
              Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\z/, host))
       end), do: {:ok, Enum.sort(Enum.uniq(hosts))}, else: {:error, :invalid_server_hosts}
  end

  defp server_hosts(_, _), do: {:error, :invalid_server_hosts}
end
