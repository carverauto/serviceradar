defmodule Boombox.InternalBin.RTMP do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Logger
  alias Boombox.InternalBin.{Ready, Wait}
  alias Membrane.{RTMP, RTMPServer}

  @spec create_input(String.t() | pid(), pid()) :: Wait.t()
  def create_input(client_ref, _utility_supervisor) when is_pid(client_ref) do
    handle_connection(client_ref)
  end

  def create_input(uri, utility_supervisor) do
    {use_ssl?, port, target_app, target_stream_key} = RTMPServer.parse_url(uri)

    boombox = self()

    handle_new_client = fn client_ref, app, stream_key ->
      if app == target_app and stream_key == target_stream_key do
        send(boombox, {:rtmp_client_ref, client_ref})
        Membrane.RTMP.Source.ClientHandlerImpl
      else
        Membrane.Logger.warning("Unexpected client connected on /#{app}/#{stream_key}")
      end
    end

    server_options = %{
      port: port,
      use_ssl?: use_ssl?,
      handle_new_client: handle_new_client,
      client_timeout: Membrane.Time.seconds(60)
    }

    {:ok, _server} =
      Membrane.UtilitySupervisor.start_link_child(
        utility_supervisor,
        {RTMPServer, server_options}
      )

    %Wait{actions: [notify_parent: :external_resource_ready]}
  end

  @spec handle_connection(pid()) :: Ready.t()
  def handle_connection(client_ref) do
    spec =
      child(:rtmp_source, %RTMP.SourceBin{client_ref: client_ref})
      |> via_out(:audio)
      |> child(:rtmp_in_aac_parser, Membrane.AAC.Parser)

    track_builders = %{
      audio: get_child(:rtmp_in_aac_parser),
      video: get_child(:rtmp_source) |> via_out(:video)
    }

    %Ready{spec_builder: spec, track_builders: track_builders}
  end
end
