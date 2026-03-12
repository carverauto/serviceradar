defmodule ServiceRadar.Ash.Page do
  @moduledoc false

  @spec unwrap(any()) :: {:ok, any()} | {:error, any()}
  def unwrap(%Ash.Page.Keyset{results: results}), do: {:ok, results}
  def unwrap(%Ash.Page.Offset{results: results}), do: {:ok, results}
  def unwrap({:ok, %Ash.Page.Keyset{results: results}}), do: {:ok, results}
  def unwrap({:ok, %Ash.Page.Offset{results: results}}), do: {:ok, results}
  def unwrap({:ok, results}), do: {:ok, results}
  def unwrap({:error, _} = error), do: error
  def unwrap(results), do: {:ok, results}

  @spec unwrap!(any()) :: any()
  def unwrap!(result) do
    case unwrap(result) do
      {:ok, results} -> results
      {:error, error} -> raise error
    end
  end
end
