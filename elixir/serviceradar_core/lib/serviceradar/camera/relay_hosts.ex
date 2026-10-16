defmodule ServiceRadar.Camera.RelayHosts do
  @moduledoc """
  Cluster-wide answer to "which core-elx node hosts this camera relay?".

  A relay's media pipeline, and every WebRTC viewer session attached to it, live
  on the one core-elx node that ingests the relay. The pipeline joins an OTP
  `:pg` group named for its relay session, and `:pg` replicates that membership
  to every node in the scope (core-elx and web-ng), where it is a local lookup.
  The same primitive backs Phoenix.PubSub's cross-node delivery; libcluster
  connects the nodes. Membership is tied to the pipeline process, so a relay
  stops being advertised the moment its pipeline or node goes away.
  """

  @scope :serviceradar_camera_relay_hosts

  def child_spec(_opts) do
    %{id: __MODULE__, start: {:pg, :start_link, [@scope]}}
  end

  @doc """
  Advertises `pid`, which must be local, as the host of `relay_session_id`.
  Without a running scope this is a no-op; callers then fall back to asking
  each node, which is slower but still correct.
  """
  @spec advertise(String.t(), pid()) :: :ok
  def advertise(relay_session_id, pid) when is_binary(relay_session_id) and is_pid(pid) do
    if Process.whereis(@scope), do: :pg.join(@scope, group(relay_session_id), pid), else: :ok
  end

  @doc "Returns the node hosting `relay_session_id`, or nil when none advertises it."
  @spec host_node(String.t()) :: node() | nil
  def host_node(relay_session_id) when is_binary(relay_session_id) do
    if Process.whereis(@scope) do
      case :pg.get_members(@scope, group(relay_session_id)) do
        [pid | _] -> node(pid)
        [] -> nil
      end
    end
  end

  defp group(relay_session_id), do: {:camera_relay, relay_session_id}
end
