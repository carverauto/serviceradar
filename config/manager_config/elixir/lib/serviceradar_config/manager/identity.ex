defmodule ServiceradarConfig.Manager.Identity do
  @moduledoc """
  The environment identity, parsed from the one variable that decides it.

  `SERVICERADAR_ENV` is the only input. It is required and has no default: a component that
  guessed an environment would guess a database, and the wrong guess is silent.

  Mirrors `config/manager_config/rust` and `config/manager_config/go`. Where the three disagree,
  one of them is a bug -- the same value must yield the same identity in every language, or a
  deployment behaves differently depending on which service reads it.
  """

  @env_var "SERVICERADAR_ENV"
  @onprem "onprem"
  @single_instance_kinds ~w(localhost ci saas demo)

  @enforce_keys [:kind]
  defstruct [:kind, :instance]

  @type t :: %__MODULE__{kind: String.t(), instance: String.t() | nil}

  def env_var, do: @env_var
  def single_instance_kinds, do: @single_instance_kinds
  def onprem, do: @onprem

  @doc """
  Parses the identity from the variable's value.

  Takes the value rather than reading the environment, so it stays a total function of its input
  and is testable without mutating process state.
  """
  @spec parse(String.t() | nil) :: {:ok, t()} | {:error, term()}
  def parse(value) do
    # Empty is unset, not a choice: a shell exporting SERVICERADAR_ENV= has selected nothing, and
    # this repository's build tooling pins several variables to "" deliberately.
    case value && String.trim(value) do
      nil -> {:error, :absent}
      "" -> {:error, :absent}
      trimmed -> parse_trimmed(trimmed)
    end
  end

  @doc "Reads the one variable from the process environment."
  @spec from_env() :: {:ok, t()} | {:error, term()}
  def from_env, do: parse(System.get_env(@env_var))

  defp parse_trimmed(value) do
    {kind, instance} =
      case String.split(value, ":", parts: 2) do
        [k] -> {k, nil}
        [k, i] -> {k, i}
      end

    cond do
      kind == @onprem and instance in [nil, ""] -> {:error, {:instance_required, @onprem}}
      kind == @onprem -> {:ok, %__MODULE__{kind: kind, instance: instance}}
      kind not in @single_instance_kinds -> {:error, {:unknown_kind, value}}
      not is_nil(instance) -> {:error, {:instance_not_accepted, kind}}
      true -> {:ok, %__MODULE__{kind: kind, instance: nil}}
    end
  end

  @doc "The exact spelling `SERVICERADAR_ENV` accepts, so an error can quote back something a reader can paste into a manifest."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{kind: kind, instance: nil}), do: kind
  def to_string(%__MODULE__{kind: kind, instance: instance}), do: "#{kind}:#{instance}"
end

defimpl String.Chars, for: ServiceradarConfig.Manager.Identity do
  def to_string(identity), do: ServiceradarConfig.Manager.Identity.to_string(identity)
end
