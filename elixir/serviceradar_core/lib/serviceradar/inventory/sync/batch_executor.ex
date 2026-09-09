defmodule ServiceRadar.Inventory.Sync.BatchExecutor do
  @moduledoc "Runs serial inventory batches in their caller so transaction ownership is retained."

  def run([batch], process_batch, _concurrency), do: process_batch.(batch)

  def run(batches, process_batch, 1) do
    Enum.reduce_while(batches, :ok, fn batch, :ok ->
      case process_batch.(batch) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def run(batches, process_batch, concurrency) do
    batches
    |> Task.async_stream(process_batch,
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, _acc -> {:cont, :ok}
      {:ok, {:error, _} = error}, _acc -> {:halt, error}
      {:exit, reason}, _acc -> {:halt, {:error, reason}}
    end)
  end

  def collect(batches, process_batch) do
    batches
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, effects} ->
      case process_batch.(batch) do
        {:ok, effect} -> {:cont, {:ok, [effect | effects]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, effects} -> {:ok, Enum.reverse(effects)}
      {:error, _} = error -> error
    end
  end
end
