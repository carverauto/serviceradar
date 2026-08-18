defmodule ServiceradarConfig.Manager do
  @moduledoc """
  Resolves a component's environment configuration from one variable, and validates it before
  exposing a value.

  Decision 9 requires this to be callable from `config/runtime.exs`, before the application tree
  starts, so it depends on nothing but the generated schema modules and the validator.
  """

  alias Serviceradar.Config.V1.{EnvironmentConfig, RuleSet}
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
  """
  @spec load(Identity.t(), built_ins(), RuleSet.t(), (String.t() -> {:ok, binary()} | {:error, term()})) ::
          {:ok, t()} | {:error, term()}
  def load(%Identity{} = identity, built_ins, %RuleSet{} = rules, read_mounted) do
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
