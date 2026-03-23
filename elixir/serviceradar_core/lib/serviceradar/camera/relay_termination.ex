defmodule ServiceRadar.Camera.RelayTermination do
  @moduledoc """
  Normalizes relay shutdown outcomes into a stable classification.
  """

  @type kind ::
          :failure
          | :viewer_idle
          | :transport_drain
          | :manual_stop
          | :source_complete
          | :closed
          | nil

  @spec kind(map() | struct() | nil) :: kind()
  def kind(session)

  def kind(nil), do: nil

  def kind(session) when is_map(session) do
    status = normalize_status(value(session, :status))
    close_reason = normalize_reason(value(session, :close_reason))
    failure_reason = normalize_reason(value(session, :failure_reason))

    cond do
      status == :failed or not is_nil(failure_reason) ->
        :failure

      close_reason == "viewer idle timeout" ->
        :viewer_idle

      transport_drain_reason?(close_reason) ->
        :transport_drain

      source_complete_reason?(close_reason) ->
        :source_complete

      status in [:closing, :closed] and not is_nil(close_reason) ->
        :manual_stop

      status == :closed ->
        :closed

      true ->
        nil
    end
  end

  def kind(_session), do: nil

  @spec kind_string(map() | struct() | nil) :: String.t() | nil
  def kind_string(session) do
    case kind(session) do
      nil -> nil
      value -> Atom.to_string(value)
    end
  end

  @spec label(map() | struct() | kind() | String.t() | nil) :: String.t() | nil
  def label(value)

  def label(value) when is_map(value), do: value |> kind() |> label()

  def label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "failure" -> label(:failure)
      "viewer_idle" -> label(:viewer_idle)
      "transport_drain" -> label(:transport_drain)
      "manual_stop" -> label(:manual_stop)
      "source_complete" -> label(:source_complete)
      "closed" -> label(:closed)
      _other -> nil
    end
  end

  def label(:failure), do: "Failure"
  def label(:viewer_idle), do: "Viewer idle stop"
  def label(:transport_drain), do: "Transport drain"
  def label(:manual_stop), do: "Manual stop"
  def label(:source_complete), do: "Source complete"
  def label(:closed), do: "Closed"
  def label(_value), do: nil

  defp transport_drain_reason?(reason) when is_binary(reason) do
    String.contains?(String.downcase(reason), "drain")
  end

  defp transport_drain_reason?(_reason), do: false

  defp source_complete_reason?(reason) when is_binary(reason) do
    String.downcase(reason) in [
      "camera relay source completed",
      "camera relay source eof",
      "camera relay completed"
    ]
  end

  defp source_complete_reason?(_reason), do: false

  defp normalize_status(value) when is_atom(value), do: value

  defp normalize_status(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "requested" -> :requested
      "opening" -> :opening
      "active" -> :active
      "closing" -> :closing
      "closed" -> :closed
      "failed" -> :failed
      _other -> nil
    end
  end

  defp normalize_status(_value), do: nil

  defp normalize_reason(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_reason(nil), do: nil
  defp normalize_reason(value), do: to_string(value)

  defp value(session, key) do
    Map.get(session, key) || Map.get(session, Atom.to_string(key))
  end
end
