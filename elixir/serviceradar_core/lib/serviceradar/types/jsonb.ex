defmodule ServiceRadar.Types.Jsonb do
  @moduledoc """
  Ash type for JSONB values that may be maps or lists.

  This is used for OCSF JSONB columns that store arrays (e.g. observables).
  """

  use Ash.Type

  @impl true
  def storage_type(_), do: :map

  @impl true
  def matches_type?(value, _constraints) do
    is_map(value) or is_list(value)
  end

  @impl true
  def cast_input("", _), do: {:ok, nil}
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, _constraints) when is_map(value) or is_list(value),
    do: {:ok, value}

  def cast_input(value, constraints) when is_binary(value) do
    case Ash.Helpers.json_module().decode(value) do
      {:ok, decoded} -> cast_input(decoded, constraints)
      _ -> :error
    end
  end

  def cast_input(_, _), do: :error

  @impl true
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(value, _constraints) when is_map(value) or is_list(value),
    do: {:ok, value}

  def cast_stored(_, _), do: :error

  @impl true
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(value, _constraints) when is_map(value) or is_list(value),
    do: {:ok, value}

  def dump_to_native(_, _), do: :error
end
