import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/serviceradar_web_ng start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint, server: true
end

config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() != :test do
  admin_username = System.get_env("ADMIN_BASIC_AUTH_USERNAME")
  admin_password = System.get_env("ADMIN_BASIC_AUTH_PASSWORD")

  if admin_username && admin_password do
    config :serviceradar_web_ng, :admin_basic_auth,
      username: admin_username,
      password: admin_password
  end

  oban_poll_interval_ms =
    System.get_env("OBAN_SCHEDULER_POLL_INTERVAL_MS", "30000") |> String.to_integer()

  oban_default_queue_limit =
    System.get_env("OBAN_DEFAULT_QUEUE_LIMIT", "10") |> String.to_integer()

  oban_maintenance_queue_limit =
    System.get_env("OBAN_MAINTENANCE_QUEUE_LIMIT", "2") |> String.to_integer()

  oban_node = System.get_env("OBAN_NODE")

  oban_config = [
    plugins: [{ServiceRadarWebNG.Jobs.Scheduler, poll_interval_ms: oban_poll_interval_ms}],
    queues: [
      default: oban_default_queue_limit,
      maintenance: oban_maintenance_queue_limit
    ]
  ]

  oban_config =
    if oban_node do
      Keyword.put(oban_config, :node, oban_node)
    else
      oban_config
    end

  config :serviceradar_web_ng, Oban, oban_config
end

if config_env() == :prod do
  database_url = System.get_env("DATABASE_URL")

  cnpg_host = System.get_env("CNPG_HOST")
  cnpg_port = String.to_integer(System.get_env("CNPG_PORT", "5432"))
  cnpg_database = System.get_env("CNPG_DATABASE", "serviceradar")
  cnpg_username = System.get_env("CNPG_USERNAME", "serviceradar")
  cnpg_password = System.get_env("CNPG_PASSWORD", "serviceradar")

  cnpg_ssl_mode = System.get_env("CNPG_SSL_MODE", "disable")
  cnpg_ssl_enabled = cnpg_ssl_mode != "disable"
  cnpg_tls_server_name = System.get_env("CNPG_TLS_SERVER_NAME", cnpg_host || "")

  cnpg_cert_dir = System.get_env("CNPG_CERT_DIR", "")

  cnpg_ca_file =
    System.get_env(
      "CNPG_CA_FILE",
      if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "root.pem"), else: "")
    )

  cnpg_cert_file =
    System.get_env(
      "CNPG_CERT_FILE",
      if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "workstation.pem"), else: "")
    )

  cnpg_key_file =
    System.get_env(
      "CNPG_KEY_FILE",
      if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "workstation-key.pem"), else: "")
    )

  cnpg_verify_peer = cnpg_ssl_mode in ~w(verify-ca verify-full)

  cnpg_ssl_opts =
    [verify: if(cnpg_verify_peer, do: :verify_peer, else: :verify_none)]
    |> then(fn opts ->
      if cnpg_verify_peer and cnpg_ca_file != "" do
        Keyword.put(opts, :cacertfile, cnpg_ca_file)
      else
        opts
      end
    end)
    |> then(fn opts ->
      if cnpg_cert_file != "" and cnpg_key_file != "" do
        opts
        |> Keyword.put(:certfile, cnpg_cert_file)
        |> Keyword.put(:keyfile, cnpg_key_file)
      else
        opts
      end
    end)
    |> then(fn opts ->
      if cnpg_ssl_mode == "verify-full" and cnpg_tls_server_name != "" do
        opts
        |> Keyword.put(:server_name_indication, String.to_charlist(cnpg_tls_server_name))
        |> Keyword.put(:customize_hostname_check,
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        )
      else
        opts
      end
    end)

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  repo_url =
    cond do
      database_url ->
        database_url

      cnpg_host ->
        "ecto://#{URI.encode_www_form(cnpg_username)}:#{URI.encode_www_form(cnpg_password)}@#{cnpg_host}:#{cnpg_port}/#{cnpg_database}"

      true ->
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """
    end

  config :serviceradar_web_ng, ServiceRadarWebNG.Repo,
    url: repo_url,
    ssl: if(cnpg_ssl_enabled, do: cnpg_ssl_opts, else: false),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"

  dev_routes =
    case System.get_env("SERVICERADAR_DEV_ROUTES") do
      "true" -> true
      "1" -> true
      "yes" -> true
      _ -> false
    end

  local_mailer =
    case System.get_env("SERVICERADAR_LOCAL_MAILER") do
      "true" -> true
      "1" -> true
      "yes" -> true
      _ -> false
    end

  # Security mode for edge onboarding: "mtls" for docker deployments, "spire" for k8s
  security_mode =
    case System.get_env("SERVICERADAR_SECURITY_MODE") do
      "mtls" -> "mtls"
      "spire" -> "spire"
      _ -> "mtls"  # Default to mTLS for docker deployments
    end

  check_origin =
    case System.get_env("PHX_CHECK_ORIGIN") do
      nil -> :conn
      "" -> :conn
      "false" -> false
      "true" -> :conn
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :serviceradar_web_ng, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :serviceradar_web_ng, dev_routes: dev_routes
  config :serviceradar_web_ng, security_mode: security_mode

  # Datasvc gRPC client configuration for KV store access
  # Used for fetching component templates and other KV data
  datasvc_address = System.get_env("DATASVC_ADDRESS")

  if datasvc_address do
    datasvc_cert_dir = System.get_env("DATASVC_CERT_DIR", "/etc/serviceradar/certs")
    datasvc_server_name = System.get_env("DATASVC_SERVER_NAME", "datasvc.serviceradar")

    # Build TLS config if cert dir exists
    tls_config =
      if File.exists?(datasvc_cert_dir) do
        [
          cacertfile: Path.join(datasvc_cert_dir, "root.pem"),
          certfile: Path.join(datasvc_cert_dir, "web.pem"),
          keyfile: Path.join(datasvc_cert_dir, "web-key.pem"),
          server_name_indication: String.to_charlist(datasvc_server_name)
        ]
      else
        nil
      end

    datasvc_config = [
      address: datasvc_address,
      timeout: String.to_integer(System.get_env("DATASVC_TIMEOUT", "5000"))
    ]

    datasvc_config =
      if tls_config do
        Keyword.put(datasvc_config, :tls, tls_config)
      else
        datasvc_config
      end

    config :datasvc, :datasvc, datasvc_config
  end

  if local_mailer do
    config :swoosh, local: true
  end

  config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    check_origin: check_origin,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :serviceradar_web_ng, ServiceRadarWebNG.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
