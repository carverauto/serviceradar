defmodule Boombox.InternalBin.StorageEndpoints.H265 do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.InternalBin.Ready
  alias Boombox.InternalBin.StorageEndpoints
  alias Membrane.H265

  @spec create_input(String.t(), transport: :file | :http, framerate: H265.framerate_t()) ::
          Ready.t()
  def create_input(location, opts) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      |> child(:h265_parser, %H265.Parser{
        output_alignment: :au,
        generate_best_effort_timestamps: %{framerate: opts[:framerate]},
        output_stream_structure: :annexb
      })

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
      |> child(:h265_video_transcoder, %Membrane.Transcoder{
        output_stream_format: %H265{stream_structure: :annexb},
        transcoding_policy: transcoding_policy
      })
      |> child(:file_sink, %Membrane.File.Sink{location: location})
    end

    spec =
      StorageEndpoints.get_spec_for_single_track_output(:video, track_builders, pipeline_tail)

    %Ready{actions: [spec: spec]}
  end
end
