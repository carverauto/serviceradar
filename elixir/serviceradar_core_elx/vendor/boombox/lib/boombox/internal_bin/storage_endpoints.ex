defmodule Boombox.InternalBin.StorageEndpoints do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Logger

  defguard is_storage_endpoint_type(endpoint_type)
           when endpoint_type in [:mp4, :h264, :h265, :aac, :wav, :mp3, :ivf, :ogg]

  defguard is_storage_endpoint_extension(extension)
           when extension in [".mp4", ".h264", ".h265", ".aac", ".wav", ".mp3", ".ivf", ".ogg"]

  @spec get_storage_endpoint_type!(String.t()) :: atom() | no_return()
  def get_storage_endpoint_type!("." <> type) do
    String.to_existing_atom(type)
  end

  @spec get_source(String.t(), :file | :http, boolean()) :: Membrane.ChildrenSpec.builder()
  def get_source(location, transport, seekable \\ false)

  def get_source(location, :file, seekable) do
    child(:file_source, %Membrane.File.Source{location: location, seekable?: seekable})
  end

  def get_source(location, :http, _seekable) do
    child(:http_source, %Membrane.Hackney.Source{
      location: location,
      hackney_opts: [follow_redirect: true]
    })
  end

  @spec get_spec_for_single_track_output(
          :audio | :video,
          Boombox.InternalBin.track_builders(),
          (Membrane.ChildrenSpec.Builder.t() -> Membrane.ChildrenSpec.t())
        ) ::
          Membrane.ChildrenSpec.t()
  def get_spec_for_single_track_output(supported_media_type, track_builders, pipeline_tail) do
    unsupported_media_type =
      case supported_media_type do
        :audio -> :video
        :video -> :audio
      end

    if not Map.has_key?(track_builders, supported_media_type) do
      raise "Output endpoint supports only #{supported_media_type}, but no #{supported_media_type} track is present"
    end

    supported_media_spec =
      [
        track_builders[supported_media_type]
        |> pipeline_tail.()
      ]

    unsupported_media_spec =
      if Map.has_key?(track_builders, unsupported_media_type) do
        Logger.info(
          "Output endpoint supports only #{supported_media_type}, discarding #{unsupported_media_type} track"
        )

        [
          track_builders[unsupported_media_type]
          |> child({unsupported_media_type, :fake_sink}, Membrane.Fake.Sink)
        ]
      else
        []
      end

    supported_media_spec ++ unsupported_media_spec
  end
end
