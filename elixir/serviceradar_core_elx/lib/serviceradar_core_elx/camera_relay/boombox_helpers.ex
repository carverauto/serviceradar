defmodule ServiceRadarCoreElx.CameraRelay.BoomboxHelpers do
  @moduledoc false

  alias Boombox.Packet
  alias Vix.Vips.Image, as: VipsImage

  @spec start_reader(binary()) :: {:ok, Boombox.Reader.t()} | {:error, term()}
  def start_reader(path) do
    case Boombox.run(
           input: {:h264, path, transport: :file},
           output: {:reader, video: :image, audio: false, pace_control: false}
         ) do
      %Boombox.Reader{} = reader ->
        {:ok, reader}

      other ->
        {:error, {:boombox_start_failed, {:unexpected_reader, inspect(other)}}}
    end
  rescue
    error -> {:error, {:boombox_start_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:boombox_start_failed, format_reason(reason)}}
    kind, reason -> {:error, {kind, format_reason(reason)}}
  end

  @spec decode_capture(binary()) ::
          {:ok, %{width: non_neg_integer(), height: non_neg_integer()}} | {:error, term()}
  def decode_capture(path) do
    with {:ok, %Boombox.Reader{} = reader} <- start_reader(path) do
      try do
        case Boombox.Server.produce_packet(reader.server_reference) do
          {:ok, %Packet{payload: %VipsImage{} = image}} ->
            {:ok, %{width: VipsImage.width(image), height: VipsImage.height(image)}}

          {:ok, _packet} ->
            {:ok, %{width: 0, height: 0}}

          :finished ->
            {:error, :no_packet}

          {:error, reason} ->
            {:error, reason}
        end
      catch
        :exit, reason -> {:error, {:boombox_read_failed, format_reason(reason)}}
      after
        _ = Boombox.Server.finish_producing(reader.server_reference)
      end
    end
  end

  def format_reason({:error, reason}), do: format_reason(reason)
  def format_reason({%_{} = exception, _stacktrace}), do: Exception.message(exception)
  def format_reason(%_{} = exception), do: Exception.message(exception)
  def format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(reason), do: inspect(reason)
end
