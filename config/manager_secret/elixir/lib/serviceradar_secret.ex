defmodule ServiceradarSecret do
  @moduledoc """
  Resolves a component's secrets through the provider its environment selects.

  The environment comes from `SERVICERADAR_ENV`, the same single variable ConfigManager reads; a
  component never names a provider.

  It holds the component's manifest, so a name the component did not declare is refused before the
  provider is consulted at all -- the provider never learns the component tried.
  """

  alias ServiceradarSecret.Manifest

  @enforce_keys [:provider, :resolve_fun, :manifest]
  defstruct [:provider, :resolve_fun, :manifest]

  @type t :: %__MODULE__{provider: String.t(), resolve_fun: (String.t() -> term()), manifest: Manifest.t()}

  @doc """
  Builds a manager over a provider.

  `resolve_fun` is a function rather than a behaviour so a caller supplies the transport, which is
  what keeps the bootstrap acyclic: the manager never decides that reaching a store needs
  ServiceRadar-managed configuration.
  """
  @spec new(String.t(), (String.t() -> term()), Manifest.t()) :: t()
  def new(provider, resolve_fun, %Manifest{} = manifest) do
    %__MODULE__{provider: provider, resolve_fun: resolve_fun, manifest: manifest}
  end

  @doc "The provider in use, for `explain`."
  def provider(%__MODULE__{provider: provider}), do: provider
  def manifest(%__MODULE__{manifest: manifest}), do: manifest

  @doc """
  Resolves one declared secret.

  Refusal precedes resolution: an undeclared name is an error about the MANIFEST, and answering it
  -- even to say "not found" -- would tell a component whether a secret it may not have exists.
  """
  @spec resolve(t(), String.t()) :: {:ok, term()} | {:error, term()}
  def resolve(%__MODULE__{manifest: manifest, resolve_fun: resolve_fun}, name) do
    if Manifest.declares?(manifest, name) do
      resolve_fun.(name)
    else
      {:error, {:undeclared, name, Manifest.declared(manifest)}}
    end
  end

  @doc """
  Resolves everything the component declared, failing on the first that cannot be resolved.

  Startup calls this: a component that resolves lazily discovers a missing secret when it first
  needs it, which is under load and far from the deploy that caused it.
  """
  @spec resolve_all(t()) :: {:ok, [{String.t(), term()}]} | {:error, term()}
  def resolve_all(%__MODULE__{manifest: manifest} = manager) do
    manifest
    |> Manifest.declared()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case resolve(manager, name) do
        {:ok, secret} -> {:cont, {:ok, [{name, secret} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end
end
