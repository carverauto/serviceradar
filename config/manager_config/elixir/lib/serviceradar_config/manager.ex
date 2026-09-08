defmodule ServiceradarConfig.Manager do
  @moduledoc """
  Resolves a component's environment configuration from one variable, and validates it before
  exposing a value.

  Decision 9 requires this to be callable from `config/runtime.exs`, before the application tree
  starts, so it depends on nothing but the generated schema modules and the validator.
  """

  alias Serviceradar.Config.V1.EnvironmentConfig
  alias ServiceradarConfig.Dsn
  alias ServiceradarConfig.Manager.{Identity, Source}
  alias ServiceradarConfig.Validator

  @enforce_keys [:identity, :source, :config]
  defstruct [:identity, :source, :config]

  @type t :: %__MODULE__{identity: Identity.t(), source: Source.t(), config: EnvironmentConfig.t()}

  @typedoc "The instances compiled into this release, keyed by identity."
  @type built_ins :: %{optional(String.t()) => binary()}

  @doc """
  Reads, decodes, confirms the artifact describes `identity`, and validates it.

  There is deliberately no entry point that skips any of the four. `read_mounted` is a function
  so the manager never decides how a deployment reaches its own configuration -- that is what
  keeps the bootstrap acyclic (Decision 12).

  There is no rule-set parameter. Validation still happens on every load -- that invariant is
  unchanged -- but the rules are an internal dependency of this module rather than something each
  caller must supply. See `ServiceradarConfig.Rules`, including why they are embedded rather than
  read from the same mount as the instance.
  """
  @spec load(Identity.t(), built_ins(), (String.t() -> {:ok, binary()} | {:error, term()})) ::
          {:ok, t()} | {:error, term()}
  def load(%Identity{} = identity, built_ins, read_mounted) do
    rules = ServiceradarConfig.Rules.embedded()
    source = Source.for_identity(identity)

    with {:ok, bytes} <- read(source, built_ins, read_mounted),
         {:ok, config} <- decode(bytes, source),
         :ok <- check_identity(config, identity, source),
         :ok <- check_rules(config, rules, source) do
      {:ok, %__MODULE__{identity: identity, source: source, config: config}}
    end
  end

  def identity(%__MODULE__{identity: identity}), do: identity

  @doc "Where the instance came from. Reported by `explain`."
  def source(%__MODULE__{source: source}), do: source

  def database(%__MODULE__{config: config}), do: config.database
  def nats(%__MODULE__{config: config}), do: config.nats
  def core(%__MODULE__{config: config}), do: config.core
  def dgraph(%__MODULE__{config: config}), do: config.dgraph

  @doc "The role that may CREATE and DROP databases, when the environment names one."
  @spec admin_role(t()) :: String.t() | nil
  def admin_role(%__MODULE__{config: config}), do: config.database && config.database.admin_role

  @doc """
  Where the CA bundle the database certificate chains to is published, when one is named.

  A URL rather than the PEM, and configuration rather than a secret: a CA bundle is what a client
  needs BEFORE it can authenticate anything, and a cert-manager issuer rotates, so any stored copy
  is correct until it silently is not.
  """
  @spec ca_bundle_url(t()) :: String.t() | nil
  def ca_bundle_url(%__MODULE__{config: config}),
    do: config.database && config.database.ca_bundle_url

  @doc "The DSN for the connecting role against the environment's own database."
  @spec database_url(t(), String.t()) :: {:ok, Dsn.t()} | :error
  def database_url(%__MODULE__{} = manager, password) do
    with %{database: database} when is_binary(database) <- database(manager) do
      database_url_named(manager, database, password)
    else
      _ -> :error
    end
  end

  @doc "The DSN for the connecting role against a named database on the same server."
  @spec database_url_named(t(), String.t(), String.t()) :: {:ok, Dsn.t()} | :error
  def database_url_named(%__MODULE__{} = manager, database, password) do
    with %{connecting_role: role} when is_binary(role) <- database(manager) do
      database_url_as(manager, role, database, password)
    else
      _ -> :error
    end
  end

  @doc """
  The DSN for a specific role and database.

  Assembled from typed fields rather than carried as one opaque string, which is what removes the
  parsing that used to recover the role, the database name and the TLS posture back out of it.

  `tls_server_name` is deliberately NOT in the DSN. It is a typed field the caller hands to its
  TLS connector, which is the only component that can act on it. Appending it as libpq's
  `&sslsni=1&host=<name>` broke two ways at once under tokio-postgres -- `sslsni` is not an
  accepted key, and a query-string `host` is read as an ADDITIONAL endpoint to dial.

  Mirrors `database_url_as` in //config/manager_config/rust; the two must agree, because the same
  fixture is reached by both.
  """
  @spec database_url_as(t(), String.t(), String.t(), String.t()) :: {:ok, Dsn.t()} | :error
  def database_url_as(%__MODULE__{} = manager, role, database, password) do
    with %{host: host, port: port, tls_mode: tls_mode} when is_binary(host) and is_integer(port) <-
           database(manager),
         {:ok, sslmode} <- sslmode(tls_mode) do
      {:ok,
       Dsn.new(
         "postgres://#{encode_userinfo(role)}:#{encode_userinfo(password)}@#{host}:#{port}/#{database}?sslmode=#{sslmode}"
       )}
    else
      _ -> :error
    end
  end

  defp sslmode(:TLS_MODE_DISABLE), do: {:ok, "disable"}
  defp sslmode(:TLS_MODE_REQUIRE), do: {:ok, "require"}
  defp sslmode(:TLS_MODE_VERIFY_CA), do: {:ok, "verify-ca"}
  defp sslmode(:TLS_MODE_VERIFY_FULL), do: {:ok, "verify-full"}

  # An unspecified mode never survives loading -- the committed rules reject it -- so this is
  # defence in depth behind validation, not the guard that makes a plaintext fallback impossible.
  defp sslmode(_), do: :error

  # Percent-encodes the characters that would otherwise terminate a DSN's userinfo field. CNPG
  # generates passwords that can contain them, and an unencoded `@` does not fail: it truncates
  # the userinfo and the DSN parses into something else entirely.
  defp encode_userinfo(raw) do
    raw
    |> String.replace("%", "%25")
    |> String.replace(":", "%3A")
    |> String.replace("@", "%40")
    |> String.replace("/", "%2F")
    |> String.replace("?", "%3F")
    |> String.replace("#", "%23")
  end

  defp read(%Source{kind: :built_in, name: name} = source, built_ins, _read) do
    case Map.fetch(built_ins, name) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:unknown_built_in, source, name, Map.keys(built_ins)}}
    end
  end

  # No cached fallback: a service that silently starts on last week's configuration is worse than
  # one that does not start.
  defp read(%Source{kind: :mounted, name: path} = source, _built_ins, read) do
    case read.(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:read, source, reason}}
    end
  end

  defp decode(bytes, source) do
    {:ok, EnvironmentConfig.decode(bytes)}
  rescue
    e -> {:error, {:decode, source, Exception.message(e)}}
  end

  # The artifact is self-describing and the selector is declared, so they can be compared. This
  # catches the wrong ConfigMap being mounted -- otherwise completely silent, and its blast radius
  # is the database a component connects to.
  defp check_identity(config, identity, source) do
    found = %Identity{kind: kind_name(config.kind), instance: config.instance}

    if found == identity do
      :ok
    else
      {:error, {:identity_mismatch, source, Identity.to_string(identity), Identity.to_string(found)}}
    end
  end

  defp check_rules(config, rules, source) do
    case Validator.validate(rules, config) do
      {:ok, []} -> :ok
      {:ok, violations} -> {:error, {:invalid, source, violations}}
      {:error, reason} -> {:error, {:rule_set, reason}}
    end
  end

  defp kind_name(nil), do: "<unset>"

  defp kind_name(kind) when is_atom(kind) do
    kind |> Atom.to_string() |> String.replace_prefix("ENVIRONMENT_KIND_", "") |> String.downcase()
  end

  defp kind_name(kind), do: "#{kind}"
end
