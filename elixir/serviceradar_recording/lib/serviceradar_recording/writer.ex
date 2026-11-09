defmodule ServiceRadarRecording.Writer do
  @moduledoc """
  Process-owned packaging and provisional local block writing.

  The caller serializes operations and supplies its admission check. The check
  runs before and after each filesystem mutation; a late write produces no
  receipt. Sealing proves only the local journal, never publication or playback
  authority. The owning process must close the packager on exit.
  """

  alias ServiceRadarRecording.Packaging
  alias ServiceRadarRecording.Spool

  defstruct [:storage, :identity, :limits, :packager, :spool, :init_format, :init]

  def open(storage, identity, clock, limits, packaging_options \\ []) do
    with {:ok, packager} <- Packaging.start([clock: clock] ++ packaging_options) do
      {:ok, %__MODULE__{storage: storage, identity: identity, limits: limits, packager: packager}}
    end
  end

  @doc """
  Append packaged fragments. An optional next-block callback runs after a full
  block is sealed, with its snapshot and init format. It must reserve capacity
  and return {:ok, identity} before the next block is created. Without it, the
  writer retains its single-block behavior. The packager continues across blocks.
  """
  def push(writer, unit, check, next_block \\ nil) do
    with :ok <- check.(),
         {:ok, events} <- Packaging.push(writer.packager, unit),
         do: persist(writer, events, check, next_block)
  end

  def flush(writer, check, next_block \\ nil) do
    with :ok <- check.(),
         {:ok, events} <- Packaging.finish(writer.packager),
         do: persist(writer, events, check, next_block)
  end

  def seal(%{spool: nil}, _check), do: {:error, :no_recorded_media}

  def seal(writer, check) do
    with :ok <- check.(),
         {:ok, spool} <- Spool.seal(writer.spool),
         :ok <- check.(),
         do: {:ok, %{writer | spool: spool}}
  end

  def snapshot(%{spool: nil}), do: nil
  def snapshot(writer), do: Spool.snapshot(writer.spool)
  def close(writer), do: Packaging.stop(writer.packager)

  defp persist(writer, events, check, next_block) do
    Enum.reduce_while(events, {:ok, writer}, fn event, {:ok, current} ->
      with :ok <- check.(),
           {:ok, next} <- store(current, event, check, next_block),
           :ok <- check.() do
        {:cont, {:ok, next}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp store(writer, {:init, init}, _check, _next_block) do
    identity = Map.put(writer.identity, "clock", init.clock)

    with {:ok, spool} <- Spool.create(writer.storage, identity, init.payload, writer.limits) do
      {:ok, %{writer | spool: spool, init: init, init_format: Map.take(init, [:sha256, :timescale, :codecs])}}
    end
  end

  defp store(writer, {:fragment, fragment}, check, next_block) do
    case append(writer, fragment) do
      {:error, :block_full} when is_function(next_block, 2) and writer.spool.high_water > 0 ->
        rotate(writer, fragment, check, next_block)

      result ->
        result
    end
  end

  defp append(writer, fragment) do
    with {:ok, spool, _entry} <- Spool.append(writer.spool, fragment.payload, fragment),
         do: {:ok, %{writer | spool: spool}}
  end

  defp rotate(writer, fragment, check, next_block) do
    with {:ok, writer} <- seal(writer, check),
         {:ok, identity} <- next_block.(snapshot(writer), writer.init_format),
         :ok <- check.(),
         {:ok, writer} <- store(%{writer | identity: identity}, {:init, writer.init}, check, next_block),
         :ok <- check.() do
      append(writer, fragment)
    end
  end
end
