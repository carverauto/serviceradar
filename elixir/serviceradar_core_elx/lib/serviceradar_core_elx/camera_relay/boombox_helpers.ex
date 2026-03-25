defmodule ServiceRadarCoreElx.CameraRelay.BoomboxHelpers do
  @moduledoc false

  @spec start_reader(binary()) :: {:ok, Boombox.Reader.t()} | {:error, term()}
  def start_reader(path) do
    case Boombox.run(
           input: {:h264, path, transport: :file},
           output: {:reader, video: :image, audio: false, pace_control: false}
         ) do
      %Boombox.Reader{server_reference: server_reference}
      when is_pid(server_reference) ->
        {:ok, %Boombox.Reader{server_reference: server_reference}}

      other ->
        {:error, {:boombox_start_failed, {:unexpected_reader, inspect(other)}}}
    end
  rescue
    error -> {:error, {:boombox_start_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:boombox_start_failed, format_reason(reason)}}
    kind, reason -> {:error, {kind, format_reason(reason)}}
  end

  def format_reason({:error, reason}), do: format_reason(reason)
  def format_reason({%_{} = exception, _stacktrace}), do: Exception.message(exception)
  def format_reason(%_{} = exception), do: Exception.message(exception)
  def format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(reason), do: inspect(reason)
end
