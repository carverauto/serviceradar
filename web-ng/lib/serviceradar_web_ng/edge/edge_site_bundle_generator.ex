defmodule ServiceRadarWebNg.Edge.EdgeSiteBundleGenerator do
  @moduledoc """
  Generates downloadable bundles for NATS leaf server deployments.

  The bundle contains everything needed to deploy a NATS leaf server
  at a customer's edge site:

  - NATS configuration file
  - TLS certificates (leaf and server)
  - NATS account credentials
  - Setup script
  - README with instructions

  ## Bundle Structure

  ```
  edge-site-{slug}/
  ├── nats/
  │   ├── nats-leaf.conf
  │   └── certs/
  │       ├── nats-server.pem
  │       ├── nats-server-key.pem
  │       ├── nats-leaf.pem
  │       ├── nats-leaf-key.pem
  │       └── ca-chain.pem
  ├── creds/
  │   └── tenant.creds
  ├── setup.sh
  └── README.md
  ```
  """

  alias ServiceRadar.Edge.NatsLeafConfigGenerator

  @doc """
  Creates a tarball bundle for an edge site.

  ## Parameters

  - `edge_site` - The EdgeSite record
  - `leaf_server` - The NatsLeafServer record (with decrypted keys)
  - `tenant` - The Tenant record
  - `nats_creds` - The decrypted NATS credentials content

  ## Options

  - `:leaf_key_pem` - Decrypted leaf private key (required)
  - `:server_key_pem` - Decrypted server private key (required)

  ## Returns

  `{:ok, tarball_binary}` or `{:error, reason}`
  """
  @spec create_tarball(map(), map(), map(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def create_tarball(edge_site, leaf_server, tenant, nats_creds, opts \\ []) do
    leaf_key_pem = Keyword.fetch!(opts, :leaf_key_pem)
    server_key_pem = Keyword.fetch!(opts, :server_key_pem)

    bundle_name = "edge-site-#{edge_site.slug}"

    files = [
      # NATS configuration
      {"#{bundle_name}/nats/nats-leaf.conf",
       NatsLeafConfigGenerator.generate_config(edge_site, leaf_server)},

      # Server certificates (for local client connections)
      {"#{bundle_name}/nats/certs/nats-server.pem", leaf_server.server_cert_pem},
      {"#{bundle_name}/nats/certs/nats-server-key.pem", server_key_pem},

      # Leaf certificates (for upstream connection)
      {"#{bundle_name}/nats/certs/nats-leaf.pem", leaf_server.leaf_cert_pem},
      {"#{bundle_name}/nats/certs/nats-leaf-key.pem", leaf_key_pem},

      # CA chain
      {"#{bundle_name}/nats/certs/ca-chain.pem", leaf_server.ca_chain_pem},

      # NATS credentials
      {"#{bundle_name}/creds/tenant.creds", nats_creds},

      # Setup script
      {"#{bundle_name}/setup.sh", NatsLeafConfigGenerator.generate_setup_script(edge_site)},

      # README
      {"#{bundle_name}/README.md", NatsLeafConfigGenerator.generate_readme(edge_site, tenant)}
    ]

    # Validate all files have content
    case validate_files(files) do
      :ok ->
        create_tar_gz(files)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the suggested filename for the bundle.
  """
  @spec bundle_filename(map()) :: String.t()
  def bundle_filename(edge_site) do
    "edge-site-#{edge_site.slug}.tar.gz"
  end

  # Private functions

  defp validate_files(files) do
    missing =
      files
      |> Enum.filter(fn {_path, content} -> is_nil(content) or content == "" end)
      |> Enum.map(fn {path, _} -> path end)

    case missing do
      [] -> :ok
      paths -> {:error, {:missing_content, paths}}
    end
  end

  defp create_tar_gz(files) do
    try do
      # Convert files to format expected by :erl_tar
      file_entries =
        Enum.map(files, fn {path, content} ->
          {String.to_charlist(path), content}
        end)

      # Create tar in memory
      {:ok, tar_data} = :erl_tar.create({:binary, []}, file_entries, [:memory, :compressed])

      {:ok, tar_data}
    rescue
      e -> {:error, {:tar_creation_failed, e}}
    end
  end
end
