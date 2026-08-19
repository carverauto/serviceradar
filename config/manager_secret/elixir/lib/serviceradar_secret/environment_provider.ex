defmodule ServiceradarSecret.EnvironmentProvider do
  @moduledoc """
  The provider `SERVICERADAR_ENV` chooses.

  It exists so a component never names a provider. Selection sits behind one function, so adding
  a provider is an edit here rather than at every call site -- and so the claim that a component
  never names one stays true.

  Mirrors `//config/manager_secret/rust` `EnvironmentProvider`. Rust dispatches statically over
  an enum; here the providers are plain structs and dispatch is by pattern match, which is the
  same closed set expressed the BEAM way.
  """

  alias ServiceradarSecret.{EnvProvider, FileProvider, Manifest, Secret}

  @type t :: EnvProvider.t() | FileProvider.t()

  @doc """
  Selects by environment kind.

  Everything except `localhost` reads the environment, because that is what the platform does:
  `//helm/serviceradar` supplies every credential through `valueFrom.secretKeyRef`, and a
  BuildBuddy workflow secret has no other form. `localhost` keeps the file store -- a developer
  machine has nothing injecting variables into a test action, and asking one to export a password
  per shell is how a password ends up in a shell history file.
  """
  @spec for_kind(String.t()) :: t()
  def for_kind("localhost"), do: FileProvider.for_kind("localhost")
  def for_kind(_kind), do: EnvProvider.new()

  @spec describe(t()) :: String.t()
  def describe(%EnvProvider{} = provider), do: EnvProvider.describe(provider)
  def describe(%FileProvider{} = provider), do: FileProvider.describe(provider)

  @spec resolve(t(), String.t()) :: {:ok, Secret.t()} | {:error, term()}
  def resolve(%EnvProvider{} = provider, name), do: EnvProvider.resolve(provider, name)
  def resolve(%FileProvider{} = provider, name), do: FileProvider.resolve(provider, name)

  @doc """
  A `ServiceradarSecret` over the provider this environment selects.

  The manager takes a resolve function rather than a behaviour, so wiring it is three lines that
  every caller would otherwise repeat -- and one of them is the provider label, which is what a
  refusal reports. Getting that pair out of call sites is the point.
  """
  @spec manager(String.t(), Manifest.t()) :: ServiceradarSecret.t()
  def manager(kind, %Manifest{} = manifest) do
    provider = for_kind(kind)
    ServiceradarSecret.new(describe(provider), &resolve(provider, &1), manifest)
  end
end
