defmodule ServiceRadarNVR do
  @moduledoc """
  Local service boundary for one finite, provisional recording block.

  Only trusted code in this VM may call this API. It is not an enrollment,
  assignment or offline-authority protocol. Only health probes are exposed over HTTP; no media or control listener exists.
  The caller is the sole producer and owns the returned bounded Inbox; media
  enters through Inbox.offer/2 and ends through Inbox.finish/1. Terminal results
  arrive as `{:nvr_recording, pid, result}`. A sealed local snapshot is not a
  catalog, archive or playback receipt.
  """

  alias ServiceRadarNVR.Session

  def start_recording(identity, clock) do
    case DynamicSupervisor.start_child(ServiceRadarNVR.Sessions, {Session, {self(), identity, clock}}) do
      {:ok, pid} -> {:ok, pid, GenServer.call(pid, :inbox)}
      {:error, _} = error -> error
    end
  catch
    :exit, _ -> {:error, :recording_unavailable}
  end

  def status(pid), do: GenServer.call(pid, :status)
  def stop(pid), do: GenServer.call(pid, :stop)

  @doc "Read-only local capacity observation, not a reservation or pool capability."
  def capacity, do: ServiceRadarNVR.Capacity.status()
end
