defmodule ServiceRadar.DB.FixtureConfig do
  @moduledoc """
  The fixture's connection coordinates, resolved from `SERVICERADAR_ENV` alone.

  One variable, and everything else follows from the identity it names -- host, port, roles and
  TLS posture from ConfigManager, the password from the provider that same identity selects, and
  the CA from the bundle the instance points at. Nothing here reads a per-setting environment
  variable.

  This is the Elixir half of what `//rust/integration-db` `config/mod.rs` does, and it exists for
  the same reason: `SRQL_TEST_DATABASE_URL` carried host, port, database, user, password and
  `sslmode` in one opaque string, so every property had to be recovered by PARSING it back out.

  ## Why it is loaded with `-r` rather than compiled

  The values have to be in the process environment BEFORE `config/test.exs` runs, because that
  file builds `ServiceRadar.Repo`'s settings while the config loader evaluates it. A module in
  `lib/` would be compiled and started too late to matter.
  """

  alias ServiceradarConfig.Dsn
  alias ServiceradarConfig.Manager
  alias ServiceradarConfig.Manager.Identity
  alias ServiceradarSecret.EnvironmentProvider
  alias ServiceradarSecret.Manifest
  alias ServiceradarSecret.Names
  alias ServiceradarSecret.Secret

  @doc """
  Everything needed to reach one database on the fixture.

  Returns `%{url: String.t(), ca_pem: binary() | nil, tls_server_name: String.t() | nil}`. The
  URL is exposed as a plain string because its only consumer is `System.put_env/2`, which cannot
  take a `Dsn` -- every other path keeps it wrapped.
  """
  def resolve!(database, opts \\ []) when is_binary(database) do
    identity = identity!()
    manager = load!(identity)
    ca_fetcher = Keyword.get(opts, :ca_fetcher, &fetch_ca!/1)

    %{
      url: url!(manager, database, password!(identity)),
      ca_pem: ca_pem!(manager, identity, ca_fetcher),
      tls_server_name: tls_server_name(manager)
    }
  end

  @doc "The typed administrator DSN for a named database on the same fixture server."
  def admin_url!(database) when is_binary(database) do
    identity = identity!()
    manager = load!(identity)

    role =
      Manager.admin_role(manager) ||
        raise "the loaded configuration has no database.admin_role"

    case Manager.database_url_as(manager, role, database, admin_password!(identity)) do
      {:ok, dsn} ->
        Dsn.expose(dsn)

      :error ->
        raise "the loaded configuration has no usable admin database section for #{database}"
    end
  end

  defp identity! do
    case Identity.from_env() do
      {:ok, identity} ->
        identity

      {:error, reason} ->
        raise """
        #{Identity.env_var()} is required and has no default (#{inspect(reason)}).

        A component that guessed an environment would guess a DATABASE, and the wrong guess is
        silent: the migrations would be applied somewhere nobody is looking. Bazel invocations
        pass it as --test_env=#{Identity.env_var()}=ci; see //buildbuddy.yaml.
        """
    end
  end

  defp load!(identity) do
    path = instance_path!(identity.kind)

    built_ins = %{Identity.to_string(identity) => File.read!(path)}

    case Manager.load(identity, built_ins, &no_mount/1) do
      {:ok, manager} ->
        manager

      {:error, reason} ->
        raise "loading #{path} as #{Identity.to_string(identity)} failed: #{inspect(reason)}"
    end
  end

  # A test action has no platform mounting anything into /etc. Guarded database targets stage the
  # built-in `ci` instance only; reaching this with a deployed identity must fail rather than read
  # an ambient mount.
  defp no_mount(path) do
    {:error, "a guarded test action has no #{path}; it carries only the built-in ci instance"}
  end

  # The instance is a DECLARED BUILD INPUT, so the artifact under test is the one the build just
  # produced and validated, and Bazel reruns this when it changes.
  #
  # The launcher does `cd "${TEST_TMPDIR}/elixir/serviceradar_core"` before running, so runfiles
  # sit two levels up -- the same relative shape as the `-r ../../build/...` in elixir_opts. The
  # other candidates cover `mix` from the project root and a runfiles tree located by env.
  defp instance_path!(kind) do
    relative = Path.join("config/environments", "#{kind}.binpb")

    candidates =
      Enum.reject(
        [
          Path.join("../..", relative),
          relative,
          runfiles_candidate("TEST_SRCDIR", relative),
          runfiles_candidate("RUNFILES_DIR", relative)
        ],
        &is_nil/1
      )

    Enum.find(candidates, &File.exists?/1) ||
      raise """
      no compiled instance for #{Identity.env_var()}=#{kind}.

      Guarded database targets declare only //config/environments:ci_binpb; use
      SERVICERADAR_ENV=ci through the BuildBuddy lifecycle rather than adding another endpoint.

      Tried, from #{File.cwd!()}:
      #{Enum.map_join(candidates, "\n", &"  #{&1}")}
      """
  end

  defp runfiles_candidate(variable, relative) do
    case System.get_env(variable) do
      dir when is_binary(dir) and dir != "" -> Path.join([dir, "_main", relative])
      _ -> nil
    end
  end

  defp password!(identity), do: secret!(identity, Names.database_password())
  defp admin_password!(identity), do: secret!(identity, Names.database_admin_password())

  defp secret!(identity, name) do
    secrets = EnvironmentProvider.manager(identity.kind, Manifest.new([name]))

    case ServiceradarSecret.resolve(secrets, name) do
      {:ok, secret} ->
        Secret.expose(secret)

      {:error, reason} ->
        raise """
        secret #{name} did not resolve: #{inspect(reason)}

        For every kind but localhost this is the environment variable
        #{ServiceradarSecret.EnvProvider.variable_for(name)}, which a Bazel test action receives
        only if the invocation forwards it by name with --test_env.
        """
    end
  end

  defp url!(manager, database, password) do
    case Manager.database_url_named(manager, database, password) do
      {:ok, dsn} ->
        Dsn.expose(dsn)

      :error ->
        raise "the loaded configuration has no usable database section for #{database}"
    end
  end

  defp tls_server_name(manager) do
    case Manager.database(manager) do
      %{tls_server_name: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  # A named bundle wins, and nothing carries the PEM. A cert-manager issuer rotates, so any copy
  # -- a CI secret, an instance file -- is correct until it is not, and the failure lands on
  # whoever runs the suite that day rather than on whoever stored it.
  defp ca_pem!(manager, identity, ca_fetcher) do
    case Manager.ca_bundle_url(manager) do
      url when is_binary(url) and url != "" -> ca_fetcher.(url)
      _ -> ca_secret(manager, identity)
    end
  end

  defp ca_secret(manager, identity) do
    name = Names.database_ca_cert()
    secrets = EnvironmentProvider.manager(identity.kind, Manifest.new([name]))

    case {ServiceradarSecret.resolve(secrets, name), verifying?(manager)} do
      {{:ok, secret}, _} ->
        Secret.expose(secret)

      {{:error, _}, false} ->
        nil

      {{:error, reason}, true} ->
        raise "tls_mode verifies the server, so #{name} is required: #{inspect(reason)}"
    end
  end

  defp verifying?(manager) do
    case Manager.database(manager) do
      %{tls_mode: mode} -> mode in [:TLS_MODE_VERIFY_CA, :TLS_MODE_VERIFY_FULL]
      _ -> false
    end
  end

  # Not a secret and not authenticated by us: a CA bundle is what a client needs BEFORE it can
  # authenticate anything, so it is published unauthenticated -- the same bootstrap shape as
  # fetching a JWKS.
  defp fetch_ca!(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    case :httpc.request(:get, {String.to_charlist(url), []}, http_options(url),
           body_format: :binary
         ) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        # A bundle that is not a certificate is a misrouted request -- a proxy error page, a
        # login redirect -- and handing it to :ssl produces "invalid certificate" far from the
        # cause.
        if String.contains?(body, "BEGIN CERTIFICATE") do
          body
        else
          raise "#{url} returned #{byte_size(body)} bytes that are not PEM"
        end

      {:ok, {{_version, status, reason}, _headers, _body}} ->
        raise "fetch CA bundle #{url}: HTTP #{status} #{reason}"

      {:error, reason} ->
        raise "fetch CA bundle #{url}: #{inspect(reason)}"
    end
  end

  defp http_options("https://" <> _rest) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp http_options(_url), do: []
end
