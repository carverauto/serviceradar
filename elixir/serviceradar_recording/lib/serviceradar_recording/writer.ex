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

  defstruct [:storage, :identity, :limits, :packager, :spool, :init_format]

  def open(storage, identity, clock, limits, packaging_options \\ []) do
    with {:ok, packager} <- Packaging.start([clock: clock] ++ packaging_options) do
      {:ok, %__MODULE__{storage: storage, identity: identity, limits: limits, packager: packager}}
    end
  end

  def push(writer, unit, check) do
    with :ok <- check.(),
         {:ok, events} <- Packaging.push(writer.packager, unit),
         do: persist(writer, events, check)
  end

  def flush(writer, check) do
    with :ok <- check.(),
         {:ok, events} <- Packaging.finish(writer.packager),
         do: persist(writer, events, check)
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

  defp persist(writer, events, check) do
    Enum.reduce_while(events, {:ok, writer}, fn event, {:ok, current} ->
      with :ok <- check.(),
           {:ok, next} <- store(current, event),
           :ok <- check.() do
        {:cont, {:ok, next}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp store(writer, {:init, init}) do
    identity = Map.put(writer.identity, "clock", init.clock)

    with {:ok, spool} <- Spool.create(writer.storage, identity, init.payload, writer.limits) do
      {:ok, %{writer | spool: spool, init_format: Map.take(init, [:sha256, :timescale, :codecs])}}
    end
  end

  defp store(writer, {:fragment, fragment}) do
    with {:ok, spool, _entry} <- Spool.append(writer.spool, fragment.payload, fragment),
         do: {:ok, %{writer | spool: spool}}
  end
end
