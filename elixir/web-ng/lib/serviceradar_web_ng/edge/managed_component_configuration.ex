defmodule ServiceRadarWebNG.Edge.ManagedComponentConfiguration do
  @moduledoc "Projects fixed service filenames from authorized component and edge inventory records."
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.Edge.NatsLeafConfigGenerator
  alias ServiceRadarWebNG.Edge.CollectorBundleGenerator

  require Ash.Query

  def build(%{component_type: "nats-leaf"} = component, opts) do
    with {:ok, site} <- Ash.get(EdgeSite, component.edge_site_id, Keyword.put(opts, :load, :nats_leaf_server)),
         %{nats_leaf_server: %{upstream_url: url} = leaf} when is_binary(url) <- site do
      {:ok,
       %{
         configuration: %{
           "nats-leaf.conf" =>
             NatsLeafConfigGenerator.generate_config(site, leaf, managed_component_id: component.component_id)
         },
         local_leaf_binding: nil
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :leaf_not_ready}
    end
  end

  def build(component, opts) do
    with {:ok, %CollectorPackage{} = package} <-
           Ash.get(CollectorPackage, component.collector_id, Keyword.put(opts, :load, :edge_site)),
         {:ok, binding} <- local_binding(package, opts) do
      {:ok,
       %{
         configuration: CollectorBundleGenerator.managed_configuration(package, component, binding),
         local_leaf_binding: binding
       }}
    end
  end

  defp local_binding(%{edge_site_id: nil}, _opts), do: {:ok, nil}

  defp local_binding(%{edge_site: site}, opts) do
    with {:ok, %ManagedComponent{blocked: false} = leaf} <-
           ManagedComponent
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(edge_site_id == ^site.id and component_type == "nats-leaf")
           |> Ash.read_one(opts),
         %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path} = uri
         when scheme in ["nats", "tls"] and is_binary(host) and path in [nil, ""] <- URI.parse(site.nats_leaf_url || "") do
      {:ok,
       %{
         version: 1,
         endpoint: URI.to_string(%{uri | scheme: "tls", port: uri.port || 4222}),
         server_dns_name: "#{leaf.component_id}-server.#{leaf.partition_id}.serviceradar"
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :managed_leaf_required}
    end
  end
end
