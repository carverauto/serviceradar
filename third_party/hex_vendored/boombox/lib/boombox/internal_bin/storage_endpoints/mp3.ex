defmodule Boombox.InternalBin.StorageEndpoints.MP3 do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.InternalBin.Ready
  alias Boombox.InternalBin.StorageEndpoints

  @spec create_input(String.t(), transport: :file | :http) :: Ready.t()
  def create_input(location, opts) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      # transcoder is used just to ensure that a proper MPEGAudio stream format is resolved
      # as there is no MP3 parser that could do it
      |> child(:mp3_stream_format_overrider, %Membrane.Transcoder{
        output_stream_format: Membrane.MPEGAudio,
        assumed_input_stream_format: %Membrane.RemoteStream{
          content_format: Membrane.MPEGAudio
        }
      })

    %Ready{track_builders: %{audio: spec}}
  end

  @spec link_output(
          String.t(),
          [Boombox.transcoding_policy_opt()],
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, opts, track_builders, _spec_builder) do
    transcoding_policy = opts |> Keyword.get(:transcoding_policy, :if_needed)

    pipeline_tail = fn builder ->
      builder
      |> child(:mp3_audio_transcoder, %Membrane.Transcoder{
        output_stream_format: Membrane.MPEGAudio,
        transcoding_policy: transcoding_policy
      })
      |> child(:file_sink, %Membrane.File.Sink{location: location})
    end

    spec =
      StorageEndpoints.get_spec_for_single_track_output(:audio, track_builders, pipeline_tail)

    %Ready{actions: [spec: spec]}
  end
end
