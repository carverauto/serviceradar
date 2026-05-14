defmodule ServiceRadarCoreElx.DesktopMediaIngress do
  @moduledoc """
  ERTS-native ingress boundary for gateway-forwarded desktop media frames.
  """

  alias ServiceRadarCoreElx.DesktopMediaIngressSession
  alias ServiceRadarCoreElx.DesktopMediaIngressSupervisor

  def forward_frame(%Desktopmedia.DesktopMediaFrameChunk{} = frame, session, opts \\ []) when is_map(session) do
    with {:ok, ingress_pid} <- supervisor(opts).start_session(session, session_opts(opts)) do
      DesktopMediaIngressSession.forward_frame(ingress_pid, frame, timeout(opts))
    end
  end

  defp timeout(opts), do: opts[:timeout] || 15_000

  defp supervisor(opts) do
    Keyword.get(opts, :supervisor, DesktopMediaIngressSupervisor)
  end

  defp session_opts(_opts), do: []
end
