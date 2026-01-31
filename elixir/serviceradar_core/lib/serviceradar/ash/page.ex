defmodule ServiceRadar.Ash.Page do
  @moduledoc false

  @spec unwrap({:ok, any()} | {:error, any()}) :: {:ok, any()} | {:error, any()}
  def unwrap({:ok, %Ash.Page.Keyset{results: results}}), do: {:ok, results}
  def unwrap({:ok, %Ash.Page.Offset{results: results}}), do: {:ok, results}
  def unwrap({:ok, results}), do: {:ok, results}
  def unwrap({:error, _} = error), do: error

  @spec unwrap!({:ok, any()} | {:error, any()}) :: any()
  def unwrap!(result) do
    case unwrap(result) do
      {:ok, results} -> results
      {:error, error} -> raise error
    end
  end
end
