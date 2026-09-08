defmodule ServiceradarSecret.EnvProvider do
  @moduledoc """
  Secrets presented as environment variables.

  This is the provider the platform actually uses. `//helm/serviceradar` supplies every
  credential with `valueFrom.secretKeyRef`, which is a Kubernetes Secret projected as an
  ENVIRONMENT VARIABLE -- 38 of them across the chart -- and nothing anywhere mounts
  `ServiceradarSecret.FileProvider.mounted_secrets_dir/0`. BuildBuddy has no other channel at
  all: a workflow secret arrives as a variable, and a Bazel test action receives it only through
  `--test_env`.

  `ServiceradarSecret.FileProvider` remains for the other Kubernetes shape, a projected Secret
  volume, and for Docker secrets. Neither is deployed here today.

  Mirrors `//config/manager_secret/rust` `EnvProvider`. The two must agree on the variable name
  for a given logical name, because one language's component and another's `--test_env` list
  refer to the same secret.
  """

  alias ServiceradarSecret.Secret

  @prefix "SERVICERADAR_SECRET_"

  @doc "The prefix every secret variable carries."
  def prefix, do: @prefix

  defstruct label: "env(#{@prefix}*)"

  @type t :: %__MODULE__{label: String.t()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{label: label}), do: label

  @doc """
  The variable a logical name is read from: `database.password` ->
  `SERVICERADAR_SECRET_DATABASE_PASSWORD`.

  Total and mechanical, because the alternative is a mapping table -- a second place able to
  disagree with the manifest, which is the failure this whole system exists to remove. A caller
  that knows the logical name can compute the variable, so the workflow's `--test_env` list is
  generated rather than written.

  ASCII upcasing on purpose, matching Rust's `to_ascii_uppercase`. Logical names are ASCII, and
  full Unicode upcasing would make the two implementations disagree the first time one was not.
  """
  @spec variable_for(String.t()) :: String.t()
  def variable_for(name) when is_binary(name) do
    @prefix <> (name |> String.replace([".", "-", "/"], "_") |> String.upcase(:ascii))
  end

  @spec resolve(t(), String.t()) :: {:ok, Secret.t()} | {:error, term()}
  def resolve(%__MODULE__{label: label}, name) do
    case System.get_env(variable_for(name)) do
      nil ->
        {:error, {:unresolvable, name, label}}

      value ->
        # A trailing newline is an artefact of how the value was written -- `$(cat file)` in a
        # shell, a heredoc in a manifest -- not part of the secret. Everything else is
        # preserved: a password may legitimately contain spaces.
        #
        # An EMPTY variable is treated as absent, not as an empty credential, which is what
        # `Secret.new/1` enforces. A set-but-blank secret is how a misconfigured deployment
        # authenticates as nobody and gets a confusing error from the server instead of a clear
        # one from here.
        case value |> String.trim_trailing("\n") |> String.trim_trailing("\r") |> Secret.new() do
          {:ok, secret} -> {:ok, secret}
          :error -> {:error, {:unresolvable, name, label}}
        end
    end
  end
end
