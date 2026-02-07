defmodule ServiceRadar.Types.Cidr do
  @moduledoc """
  Ash type for Postgres `cidr`/`inet` values.

  Represented as a string (e.g. "10.0.0.0/8") in Ash, stored as `:inet` in Ecto.
  """

  use Ash.Type

  @impl true
  def storage_type(_), do: :inet

  @impl true
  def matches_type?(%Postgrex.INET{}, _), do: true
  def matches_type?(value, _) when is_binary(value), do: true
  def matches_type?(_, _), do: false

  @impl true
  def cast_input("", _), do: {:ok, nil}
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(%Postgrex.INET{} = inet, _), do: {:ok, to_string(inet)}

  def cast_input(value, _constraints) when is_binary(value) do
    case Ecto.Type.cast(:inet, value) do
      {:ok, _} -> {:ok, value}
      :error -> :error
    end
  end

  def cast_input(_, _), do: :error

  @impl true
  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(%Postgrex.INET{} = inet, _), do: {:ok, to_string(inet)}
  def cast_stored(value, _) when is_binary(value), do: {:ok, value}
  def cast_stored(_, _), do: :error

  @impl true
  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native(%Postgrex.INET{} = inet, _), do: {:ok, inet}

  def dump_to_native(value, _constraints) when is_binary(value) do
    case Ecto.Type.cast(:inet, value) do
      {:ok, inet} -> {:ok, inet}
      :error -> :error
    end
  end

  def dump_to_native(_, _), do: :error
end
