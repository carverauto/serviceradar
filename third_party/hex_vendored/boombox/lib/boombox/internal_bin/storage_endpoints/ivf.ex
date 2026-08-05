defmodule Boombox.InternalBin.StorageEndpoints.IVF do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.InternalBin.Ready
  alias Boombox.InternalBin.StorageEndpoints
  alias Membrane.{VP8, VP9}

  @spec create_input(String.t(), transport: :file | :http) :: Ready.t()
  def create_input(location, opts) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      |> child(:ivf_deserializer, Membrane.IVF.Deserializer)

    %Ready{track_builders: %{video: spec}}
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
      |> child(:ivf_video_transcoder, %Membrane.Transcoder{
        output_stream_format: fn
          %VP8{} -> VP8
          %Membrane.RemoteStream{content_format: VP8} -> VP8
          %VP9{} -> VP9
          _other -> VP9
        end,
        transcoding_policy: transcoding_policy
      })
      |> child(:ivf_serializer, Membrane.IVF.Serializer)
      |> child(:file_sink, %Membrane.File.Sink{location: location})
    end

    spec =
      StorageEndpoints.get_spec_for_single_track_output(:video, track_builders, pipeline_tail)

    %Ready{actions: [spec: spec]}
  end
end
