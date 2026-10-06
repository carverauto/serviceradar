defmodule ServiceRadar.Edge.NatsLeafConfigGenerator do
  @moduledoc """
  Generates NATS leaf server configuration files.

  Configuration is based on the template at `build/packaging/nats/config/nats-leaf.conf`
  and includes:

  - Server name based on edge site slug
  - Local listener for collector connections (mTLS)
  - JetStream with "edge" domain for local buffering
  - Leaf node connection to SaaS NATS cluster (mTLS)

  ## Certificate Paths

  The generated config uses standard paths:
  - `/etc/nats/certs/nats-server.pem` - Server certificate for local clients
  - `/etc/nats/certs/nats-server-key.pem` - Server private key
  - `/etc/nats/certs/nats-leaf.pem` - Leaf certificate for upstream
  - `/etc/nats/certs/nats-leaf-key.pem` - Leaf private key
  - `/etc/nats/certs/ca-chain.pem` - CA certificate chain
  - `/etc/nats/creds/account.creds` - NATS account credentials
  """

  @doc """
  Generates the NATS leaf configuration for an edge site.

  ## Parameters

  - `edge_site` - The EdgeSite record
  - `leaf_server` - The NatsLeafServer record
  - `opts` - Additional options

  ## Options

  - `:local_listen` - Override local listen address (default from leaf_server)
  - `:jetstream_max_memory` - JetStream memory limit (default: "1G")
  - `:jetstream_max_file` - JetStream file limit (default: "10G")
  - `:debug` - Enable debug logging (default: false)
  - `:with_credentials` - reference `/etc/nats/creds/account.creds` in the
    leaf remote (default: false; set only when the bundle ships minted creds)
  - `:direct_leaf_identities` - assignment-scoped identities and their derived
    subject scopes to render as local NATS authorization users

  ## Returns

  The NATS configuration file content as a string.
  """
  @spec generate_config(map(), map(), keyword()) :: String.t()
  def generate_config(edge_site, leaf_server, opts \\ []) do
    local_listen = Keyword.get(opts, :local_listen, leaf_server.local_listen || "0.0.0.0:4222")
    jetstream_max_memory = Keyword.get(opts, :jetstream_max_memory, "1G")
    jetstream_max_file = Keyword.get(opts, :jetstream_max_file, "10G")
    debug = Keyword.get(opts, :debug, false)
    credentials_line = render_credentials_line(Keyword.get(opts, :with_credentials, false))

    direct_leaf_authorization =
      opts
      |> Keyword.get(:direct_leaf_identities, [])
      |> render_direct_leaf_authorization()

    server_name = "nats-#{edge_site.slug}"

    """
    # NATS Leaf Server Configuration
    # Generated for EdgeSite: #{edge_site.name} (#{edge_site.slug})
    # Generated at: #{DateTime.to_iso8601(DateTime.utc_now())}

    server_name: #{server_name}
    logfile: "/var/log/nats/nats.log"
    debug: #{debug}

    # Listen for local clients (collectors)
    listen: #{local_listen}

    # Enable mTLS for local client communication
    tls {
        cert_file: "/etc/nats/certs/nats-server.pem"
        key_file: "/etc/nats/certs/nats-server-key.pem"
        ca_file: "/etc/nats/certs/ca-chain.pem"
        verify_and_map: true
    }

    #{direct_leaf_authorization}

    # Enable JetStream for local buffering during WAN outages
    jetstream {
        store_dir: /var/lib/nats/jetstream
        max_memory_store: #{jetstream_max_memory}
        max_file_store: #{jetstream_max_file}
        domain: edge
    }

    # Leaf Node configuration to connect to the SaaS NATS cluster
    leafnodes {
        remotes = [
            {
                url: "#{leaf_server.upstream_url}"
    #{credentials_line}

                # mTLS configuration for leaf-to-SaaS connection
                tls {
                    cert_file: "/etc/nats/certs/nats-leaf.pem"
                    key_file: "/etc/nats/certs/nats-leaf-key.pem"
                    ca_file: "/etc/nats/certs/ca-chain.pem"
                }
            }
        ]
    }
    """
  end

  defp render_credentials_line(true) do
    """
                # NATS account credentials minted for this leaf
                credentials: "/etc/nats/creds/account.creds"
    """
  end

  # The hub authenticates the leaf by its mTLS certificate; no creds file ships.
  defp render_credentials_line(_), do: ""

  @doc false
  @spec render_direct_leaf_authorization(list()) :: String.t()
  def render_direct_leaf_authorization([]), do: ""

  def render_direct_leaf_authorization(identities) when is_list(identities) do
    users =
      identities
      |> Enum.map(&render_direct_leaf_user/1)
      |> Enum.reject(&is_nil/1)

    if users == [] do
      ""
    else
      String.trim("""
      # Assignment-scoped direct OTEL identities. This block is rendered from
      # server-owned identity records; no account seed or broad platform user
      # is installed on the leaf.
      authorization {
          # Preserve the existing local collector behavior when an ACL block
          # is introduced. Every direct identity below has explicit
          # permissions and therefore does not inherit these defaults.
          default_permissions: {
              publish: {
                  allow: ["logs.>", "logs.otel", "otel.traces.>",
                          "otel.metrics.>", "events.netflow.>",
                          "events.falco.>", "netflow.>", "flow.host-slice.>",
                          "flow.raw.>", "$JS.API.>", "$JS.ACK.>", "_INBOX.>"]
                  deny: ["$SYS.>"]
              }
              subscribe: {
                  allow: ["$JS.API.>", "$JS.ACK.>", "_INBOX.>"]
                  deny: ["$SYS.>"]
              }
          }
          users: [
      #{Enum.join(users, ",\n")}
          ]
      }
      """)
    end
  end

  def render_direct_leaf_authorization(_identities), do: ""

  defp render_direct_leaf_user(identity) when is_map(identity) do
    component_id = map_value(identity, :component_id)
    partition_id = map_value(identity, :partition_id)
    scope = map_value(identity, :scope)

    with component_id when is_binary(component_id) <- component_id,
         partition_id when is_binary(partition_id) <- partition_id,
         scope when is_map(scope) <- scope,
         publish when is_list(publish) <- map_value(scope, :publish),
         subscribe when is_list(subscribe) <- map_value(scope, :subscribe) do
      cn = "CN=#{component_id}.#{partition_id}.serviceradar"

      String.trim("""
          {
              user: #{nats_string(cn)}
              permissions: {
                  publish: {
                      allow: #{nats_strings(publish)}
                      deny: ["$SYS.>", "_INBOX.>"]
                  }
                  subscribe: {
                      allow: #{nats_strings(subscribe)}
                      deny: ["$SYS.>"]
                  }
              }
          }
      """)
    else
      _ -> nil
    end
  end

  defp render_direct_leaf_user(_identity), do: nil

  defp nats_strings(values), do: values |> Enum.map_join(", ", &nats_string/1) |> then(&"[#{&1}]")
  defp nats_string(value), do: Jason.encode!(to_string(value))

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil

  @doc """
  Generates the setup script for deploying the NATS leaf server.

  The script targets the `serviceradar-nats` package (Oracle Linux 9 / RHEL
  RPM, or the Debian package): it installs the config at
  `/etc/nats/nats-server.conf` (backing up the packaged file), the certificates
  under `/etc/nats/certs` and, when present, `creds/account.creds` under
  `/etc/nats/creds`, owned by the packaged `nats` user and `serviceradar` group.
  It validates the config with `nats-server -t` before enabling and restarting
  `serviceradar-nats.service`. It runs from any working directory.

  Options:
    * `:with_credentials` - also install `creds/account.creds` (default: false)
  """
  @spec generate_setup_script(map(), keyword()) :: String.t()
  def generate_setup_script(edge_site, opts \\ []) do
    site_name = shell_single_quote(edge_site.name)
    with_credentials = Keyword.get(opts, :with_credentials, false)

    creds_block =
      if with_credentials do
        """
        install -d -m 0750 -o nats -g serviceradar /etc/nats/creds
        install -m 0600 -o nats -g serviceradar creds/account.creds /etc/nats/creds/account.creds
        """
      else
        ""
      end

    """
    #!/bin/bash
    # NATS Leaf Server Setup Script
    # Generated for EdgeSite: #{edge_site.name} (#{edge_site.slug})
    #
    # Requires the serviceradar-nats package (provides /usr/bin/nats-server and
    # serviceradar-nats.service). Run as root from anywhere.

    set -euo pipefail

    SITE_NAME='#{site_name}'
    UNIT=serviceradar-nats
    BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$BUNDLE_DIR"

    printf 'Setting up NATS leaf server for %s...\\n' "$SITE_NAME"

    if [ "$(id -u)" -ne 0 ]; then
        echo "Please run as root or with sudo" >&2
        exit 1
    fi

    if [ ! -x /usr/bin/nats-server ] || ! systemctl cat "$UNIT.service" >/dev/null 2>&1; then
        echo "ERROR: the serviceradar-nats package is not installed." >&2
        echo "Install it first, e.g. on Oracle Linux 9 / RHEL:" >&2
        echo "  sudo dnf install ./serviceradar-nats-<version>.x86_64.rpm" >&2
        exit 1
    fi

    if ! id -u nats >/dev/null 2>&1 || ! getent group serviceradar >/dev/null; then
        echo "ERROR: the nats user or serviceradar group is missing (reinstall serviceradar-nats)." >&2
        exit 1
    fi

    echo "Installing certificates..."
    install -d -m 0750 -o nats -g serviceradar /etc/nats /etc/nats/certs
    install -m 0644 -o nats -g serviceradar nats/certs/nats-server.pem /etc/nats/certs/nats-server.pem
    install -m 0600 -o nats -g serviceradar nats/certs/nats-server-key.pem /etc/nats/certs/nats-server-key.pem
    install -m 0644 -o nats -g serviceradar nats/certs/nats-leaf.pem /etc/nats/certs/nats-leaf.pem
    install -m 0600 -o nats -g serviceradar nats/certs/nats-leaf-key.pem /etc/nats/certs/nats-leaf-key.pem
    install -m 0644 -o nats -g serviceradar nats/certs/ca-chain.pem /etc/nats/certs/ca-chain.pem
    #{creds_block}
    install -d -m 0750 -o nats -g serviceradar /var/lib/nats /var/lib/nats/jetstream /var/log/nats

    echo "Validating configuration..."
    nats-server -c nats/nats-leaf.conf -t

    echo "Installing configuration..."
    if [ -f /etc/nats/nats-server.conf ] && ! cmp -s nats/nats-leaf.conf /etc/nats/nats-server.conf; then
        cp -p /etc/nats/nats-server.conf "/etc/nats/nats-server.conf.bak.$(date +%Y%m%d%H%M%S)"
    fi
    install -m 0640 -o nats -g serviceradar nats/nats-leaf.conf /etc/nats/nats-server.conf

    # SELinux (Oracle Linux 9): give the installed files their default labels.
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R /etc/nats /var/lib/nats /var/log/nats || true
    fi

    echo "Enabling and restarting $UNIT..."
    systemctl daemon-reload
    systemctl enable "$UNIT"
    systemctl restart "$UNIT"

    sleep 2
    if systemctl is-active --quiet "$UNIT"; then
        echo ""
        echo "NATS leaf server is running."
        echo "Check status: systemctl status $UNIT"
        echo "View logs:    journalctl -u $UNIT -f   (and /var/log/nats/nats.log)"
    else
        echo "" >&2
        echo "ERROR: $UNIT failed to start" >&2
        echo "Check logs: journalctl -u $UNIT -n 50; tail -n 50 /var/log/nats/nats.log" >&2
        exit 1
    fi
    """
  end

  @doc """
  TLS URL collectors on this host use to reach the leaf.

  A wildcard bind (`0.0.0.0`, `::`, `*`) is not a client address. Collectors
  installed beside the leaf dial loopback. An operator who places collectors
  on another machine sets `nats_leaf_url` instead.
  """
  @spec client_url(String.t() | nil) :: String.t()
  def client_url(listen) when is_binary(listen) do
    trimmed = String.trim(listen)

    cond do
      trimmed == "" ->
        "tls://127.0.0.1:4222"

      String.starts_with?(trimmed, "tls://") ->
        trimmed

      true ->
        {host, port} = split_listen(trimmed)
        "tls://#{format_client_host(loopback_host(host))}:#{port}"
    end
  end

  def client_url(_listen), do: "tls://127.0.0.1:4222"

  defp split_listen(listen) do
    case Regex.run(~r/^\[([^\]]+)\]:(\d+)$/, listen) do
      [_, host, port] ->
        {host, port}

      _ ->
        case Regex.run(~r/^([^:]+):(\d+)$/, listen) do
          [_, host, port] -> {host, port}
          _ -> {"127.0.0.1", "4222"}
        end
    end
  end

  defp loopback_host(host) when host in ["0.0.0.0", "*", ""], do: "127.0.0.1"
  defp loopback_host("::"), do: "::1"
  defp loopback_host(host), do: host

  defp format_client_host(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  @doc """
  Generates the README for the edge site bundle.
  """
  @spec generate_readme(map(), keyword()) :: String.t()
  def generate_readme(edge_site, opts \\ []) do
    creds_line =
      if Keyword.get(opts, :with_credentials, false) do
        "- `creds/account.creds` - NATS user credentials minted for this leaf\n"
      else
        ""
      end

    """
    # NATS Leaf Server Bundle

    **Site:** #{edge_site.name}
    **Generated:** #{DateTime.to_iso8601(DateTime.utc_now())}

    ## Contents

    - `nats/nats-leaf.conf` - NATS server configuration
    - `nats/certs/` - TLS certificates
      - `nats-server.pem` / `nats-server-key.pem` - server certificate for local clients
      - `nats-leaf.pem` / `nats-leaf-key.pem` - leaf certificate for the upstream connection
      - `ca-chain.pem` - CA certificate chain
    #{creds_line}- `setup.sh` - automated setup script
    - `README.md` - this file

    The leaf authenticates to the ServiceRadar hub with `nats-leaf.pem` (mTLS).

    ## Quick Start (Oracle Linux 9)

    1. Install the serviceradar-nats package:

       ```bash
       sudo dnf install ./serviceradar-nats-<version>.x86_64.rpm
       ```

    2. Run the setup script:

       ```bash
       sudo bash ./setup.sh
       ```

    3. Verify the connection:

       ```bash
       systemctl status serviceradar-nats
       journalctl -u serviceradar-nats -f
       ```

    ## Manual Installation

    1. Copy `nats/certs/*` to `/etc/nats/certs/` (owner `nats:serviceradar`, keys mode 0600)
    2. Copy `nats/nats-leaf.conf` to `/etc/nats/nats-server.conf`
    3. Validate: `nats-server -c /etc/nats/nats-server.conf -t`
    4. Restart: `systemctl restart serviceradar-nats`

    ## Connecting Collectors

    Collectors deployed at this site should connect to:

    ```
    #{collector_client_url(edge_site, opts)}
    ```

    The local listener requires TLS with a client certificate from the
    ServiceRadar CA.

    ## Troubleshooting

    - Status: `systemctl status serviceradar-nats`
    - Logs: `journalctl -u serviceradar-nats -f` and `/var/log/nats/nats.log`
    - Config check: `nats-server -c /etc/nats/nats-server.conf -t`
    - Look for "Leafnode connection created" in the log to confirm the upstream link.

    ## Certificate Expiration

    Certificates in this bundle are valid for 1 year. To renew, regenerate the
    configuration in the ServiceRadar admin console, download a new bundle and
    run `setup.sh` again.
    """
  end

  defp collector_client_url(edge_site, opts) do
    case Map.get(edge_site, :nats_leaf_url) do
      url when is_binary(url) and url != "" -> url
      _ -> client_url(Keyword.get(opts, :local_listen))
    end
  end

  defp shell_single_quote(value) do
    value
    |> to_string()
    |> String.replace("'", "'\"'\"'")
  end
end
