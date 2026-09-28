defmodule ServiceRadar.Ash.Page do
  @moduledoc false

  alias Ash.Page.Keyset
  alias Ash.Page.Offset

  @spec unwrap(any()) :: {:ok, any()} | {:error, any()}
  def unwrap(%Keyset{results: results}), do: {:ok, results}
  def unwrap(%Offset{results: results}), do: {:ok, results}
  def unwrap({:ok, %Keyset{results: results}}), do: {:ok, results}
  def unwrap({:ok, %Offset{results: results}}), do: {:ok, results}
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

  # One page of a paginated read is not the match set. `unwrap/1` drops `more?`,
  # and Ash's default page is 250, so callers that need every row stream.
  # `batch_size` is that page, not a cap: the stream follows the cursor itself.
  @stream_batch_size 250

  @spec stream!(Ash.Query.t(), keyword()) :: Enumerable.t()
  def stream!(query, opts \\ []) do
    Ash.stream!(query, Keyword.put_new(opts, :batch_size, @stream_batch_size))
  end
end
