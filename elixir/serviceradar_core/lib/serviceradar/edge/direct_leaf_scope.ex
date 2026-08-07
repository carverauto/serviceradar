defmodule ServiceRadar.Edge.DirectLeafScope do
  @moduledoc """
  Builds the least-privilege subject contract for a direct OTEL leaf output.

  The scope is deliberately derived from the add-on configuration rather than
  accepting a broad `events.>` permission. The leaf authorization renderer and
  identity issuer use this value to authorize one assignment's publish,
  JetStream stream-management, and request/ack subjects.
  """

  @default_subject "events.otlp"
  @default_stream "events"

  @type scope :: %{
          required(String.t()) => String.t() | [String.t()]
        }

  @spec build(map()) :: {:ok, scope()} | {:error, atom()}
  def build(params) when is_map(params) do
    with nats when is_map(nats) <- map_value(params, :nats),
         {:ok, subject} <- valid_subject(nats, :subject, @default_subject),
         {:ok, logs_subject} <-
           valid_subject(nats, :logs_subject, "#{subject}.logs"),
         {:ok, stream} <- valid_stream(nats) do
      {:ok,
       %{
         "version" => "serviceradar.edge_direct_leaf_scope.v1",
         "stream" => stream,
         "publish" => [
           "#{subject}.traces.>",
           "#{subject}.metrics.>",
           logs_subject,
           "$JS.API.STREAM.INFO.#{stream}",
           "$JS.API.STREAM.CREATE.#{stream}",
           "$JS.API.STREAM.UPDATE.#{stream}"
         ],
         "subscribe" => [
           "_INBOX.>",
           "$JS.ACK.#{stream}.>"
         ]
       }}
    else
      _ -> {:error, :invalid_subject_scope}
    end
  end

  def build(_params), do: {:error, :invalid_subject_scope}

  @doc "Returns true when a concrete subject is covered by a scoped pattern."
  @spec subject_within_scope?(String.t(), String.t()) :: boolean()
  def subject_within_scope?(subject, pattern) when is_binary(subject) and is_binary(pattern) do
    subject_tokens = String.split(subject, ".")
    pattern_tokens = String.split(pattern, ".")
    match_tokens?(subject_tokens, pattern_tokens)
  end

  def subject_within_scope?(_subject, _pattern), do: false

  defp match_tokens?([], []), do: true
  defp match_tokens?([], [">"]), do: true
  defp match_tokens?([_ | _], []), do: false
  defp match_tokens?([], [_ | _]), do: false
  defp match_tokens?(_subject, [">"]), do: true

  defp match_tokens?([_subject | subject_rest], ["*" | pattern_rest]),
    do: match_tokens?(subject_rest, pattern_rest)

  defp match_tokens?([subject | subject_rest], [subject | pattern_rest]),
    do: match_tokens?(subject_rest, pattern_rest)

  defp match_tokens?(_subject, _pattern), do: false

  defp valid_subject(nats, key, default) do
    value = map_value(nats, key) || default

    if valid_subject_name?(value) do
      {:ok, value}
    else
      {:error, :invalid_subject_scope}
    end
  end

  defp valid_stream(nats) do
    stream = map_value(nats, :stream) || @default_stream

    if is_binary(stream) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, stream) do
      {:ok, stream}
    else
      {:error, :invalid_subject_scope}
    end
  end

  defp valid_subject_name?(value) when is_binary(value) do
    value != "" and
      not String.contains?(value, ["*", ">", "$", " ", "\n", "\r"]) and
      Enum.all?(String.split(value, "."), &valid_subject_token?/1)
  end

  defp valid_subject_name?(_value), do: false

  defp valid_subject_token?(token), do: Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, token)

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil
end
