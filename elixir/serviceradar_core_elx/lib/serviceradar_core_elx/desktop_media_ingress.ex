defmodule ServiceRadarCoreElx.DesktopMediaIngress do
  @moduledoc """
  ERTS-native ingress boundary for gateway-forwarded desktop media frames.
  """

  alias ServiceRadarCoreElx.DesktopMediaIngressSession
  alias ServiceRadarCoreElx.DesktopMediaIngressSupervisor
  alias ServiceRadarCoreElx.RemoteDesktop.MediaSessionManager

  def forward_frame(%Desktopmedia.DesktopMediaFrameChunk{} = frame, session, opts \\ []) when is_map(session) do
    with {:ok, ingress_pid} <- supervisor(opts).start_session(session, session_opts(opts)) do
      DesktopMediaIngressSession.forward_frame(ingress_pid, frame, timeout(opts))
    end
  end

  def close_session(desktop_session_id, opts \\ []) when is_binary(desktop_session_id) do
    with :ok <- supervisor(opts).stop_session(desktop_session_id, supervisor_opts(opts)) do
      media_manager(opts).close_session(desktop_session_id, media_manager_opts(opts))
    end
  end

  defp timeout(opts), do: opts[:timeout] || 15_000

  defp supervisor(opts) do
    Keyword.get(opts, :supervisor, DesktopMediaIngressSupervisor)
  end

  defp session_opts(opts), do: Keyword.take(opts, [:media_manager, :idle_timeout_ms])

  defp media_manager(opts), do: Keyword.get(opts, :media_manager, MediaSessionManager)
  defp media_manager_opts(opts), do: Keyword.take(opts, [:server])

  defp supervisor_opts(opts) do
    opts
    |> Keyword.take([:registry])
    |> Keyword.put(:supervisor, supervisor(opts))
  end
end
