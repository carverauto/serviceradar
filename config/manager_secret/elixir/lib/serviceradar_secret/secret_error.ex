defmodule ServiceradarSecret.SecretError do
  @moduledoc "Why a secret could not be resolved. Never a default, never an empty value."

  @spec message(term()) :: String.t()
  def message({:undeclared, name, declared}) do
    "secret #{inspect(name)} was requested but is not declared by this component. " <>
      "Declared: [#{Enum.join(declared, ", ")}]. Add it to the component's secret manifest, or " <>
      "stop requesting it -- a provider that answered undeclared names would give every " <>
      "component the whole store."
  end

  def message({:unresolvable, name, provider}) do
    "secret #{inspect(name)} is declared but the #{provider} provider has no entry for it. " <>
      "There is no default and no empty fallback: a component that continued here would " <>
      "authenticate with a blank credential."
  end

  def message({:provider_failed, name, provider, detail}) do
    "the #{provider} provider failed resolving #{inspect(name)}: #{detail}"
  end
end
