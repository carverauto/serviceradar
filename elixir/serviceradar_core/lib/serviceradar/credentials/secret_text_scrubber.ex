defmodule ServiceRadar.Credentials.SecretTextScrubber do
  @moduledoc """
  Removes the credential-bearing parts of URLs from text and JSON values that
  Core persists, logs or shows.

  A URL is the usual way a secret reaches a free-text field: an RTSP stream URL
  carries a username and password in its userinfo, a UniFi Protect RTSPS alias
  is a token in its path, and a signed download URL carries its signature in
  the query. Key-based redaction (`ServiceRadar.Credentials.CredentialRedactor`)
  cannot see any of them, because they sit inside an ordinary string.

  There are two strengths:

    * `scrub_text/1` is for free text an agent or library produced, such as a
      command result message or failure reason. Every URL is reduced to its
      origin (`scheme://host[:port]`), because its path can be the secret. A
      scheme-less `user:password@` before a host and any `?query` are removed
      as well; an address such as `ops@example.com` is left alone.
    * `scrub_value/1` is for structured JSON values. A URL inside a string
      loses its userinfo, query and fragment but keeps its path, which is data
      that consumers of a structured payload read. A string with nothing to
      remove is returned unchanged.

  Both are idempotent, so a value can be scrubbed again at every boundary and a
  one-time cleanup can be re-run safely.
  """

  @unparseable_url "[url]"
  @redacted_path "/[redacted]"

  @url_pattern ~r/[a-zA-Z][a-zA-Z0-9+.\-]*:\/\/[^\s"'<>]*/
  @query_pattern ~r/\?[^\s"'<>]*/
  # Characters of a host-name label, shared by every host pattern below.
  @host_label_chars "A-Za-z0-9\\-_"
  @safe_host_pattern Regex.compile!("\\A[#{@host_label_chars}.\\[\\]:%]+\\z")
  @trailing_punctuation_pattern ~r/\A(.*?)([.,;:!)\]]+)\z/s

  # A credential-bearing authority without a scheme: `user:password@host`,
  # optionally followed by a port and path. The host must be an IPv4 literal, a
  # bracketed IPv6 literal or a dotted host name, so an email address, a bare
  # `user@host` and a time such as `12:30@noon` are not matched.
  @credential_userinfo "[^\\s/:@\"'<>=]+:[^\\s/@\"'<>]+@"
  @credential_host "(?:\\[[0-9A-Fa-f:.%]+\\]|[#{@host_label_chars}]+(?:\\.[#{@host_label_chars}]+)+)" <>
                     "(?![#{@host_label_chars}@])"
  @credential_authority_pattern Regex.compile!(@credential_userinfo <> @credential_host)
  # The same authority, matching only its `user:password@` so the host is kept.
  @credential_userinfo_pattern Regex.compile!(
                                 @credential_userinfo <> "(?=" <> @credential_host <> ")"
                               )

  @doc "Reduces every URL in free text to its origin and drops credentials and query strings."
  @spec scrub_text(term()) :: term()
  def scrub_text(text) when is_binary(text) do
    text
    |> String.replace(@url_pattern, &keep_trailing_punctuation(&1, fn url -> url_origin(url) end))
    |> String.replace(@credential_userinfo_pattern, "")
    |> String.replace(@query_pattern, "")
  end

  def scrub_text(other), do: other

  @doc "Strips userinfo, query and fragment from every URL inside a JSON value."
  @spec scrub_value(term()) :: term()
  def scrub_value(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, nested} -> {key, scrub_value(nested)} end)

  def scrub_value(value) when is_list(value), do: Enum.map(value, &scrub_value/1)

  def scrub_value(value) when is_binary(value),
    do:
      String.replace(
        value,
        @url_pattern,
        &keep_trailing_punctuation(&1, fn url -> without_url_credentials(url) end)
      )

  def scrub_value(value), do: value

  @doc """
  The name of the first `{name, value}` entry whose value holds, in any string
  at any depth of lists and maps, a URL with userinfo (`user@` or
  `user:password@` before the host) or a scheme-less `user:password@host`;
  `nil` when there is none.
  """
  @spec userinfo_url_input(Enumerable.t()) :: term() | nil
  def userinfo_url_input(entries),
    do: Enum.find_value(entries, fn {name, value} -> if url_with_userinfo?(value), do: name end)

  defp url_with_userinfo?(value) when is_map(value) and not is_struct(value),
    do: Enum.any?(value, fn {_key, nested} -> url_with_userinfo?(nested) end)

  defp url_with_userinfo?(value) when is_list(value), do: Enum.any?(value, &url_with_userinfo?/1)

  defp url_with_userinfo?(value) when is_binary(value) do
    Regex.match?(@credential_authority_pattern, value) or
      @url_pattern
      |> Regex.scan(value)
      |> Enum.any?(fn [match] ->
        case parse(match) do
          %URI{userinfo: userinfo} -> userinfo != nil
          nil -> match |> String.split("/", parts: 4) |> Enum.at(2, "") |> String.contains?("@")
        end
      end)
  end

  defp url_with_userinfo?(_value), do: false

  @doc """
  The origin of a URL followed by a redaction marker, for a field whose whole
  URL is secret but whose host is useful to an operator, for example
  `rtsps://camera01.example.com:7441/[redacted]`.
  """
  @spec redacted_url(String.t()) :: String.t()
  def redacted_url(url) when is_binary(url) do
    # The marker itself is not a valid path, so an already-redacted URL is
    # parsed without it; this keeps the function idempotent.
    url
    |> String.trim()
    |> String.replace_suffix(@redacted_path, "")
    |> url_origin()
    |> case do
      @unparseable_url -> "[redacted]"
      origin -> origin <> @redacted_path
    end
  end

  # Sentence punctuation after a URL is not part of it.
  defp keep_trailing_punctuation(match, fun) do
    case Regex.run(@trailing_punctuation_pattern, match) do
      [_whole, url, suffix] -> fun.(url) <> suffix
      nil -> fun.(match)
    end
  end

  defp url_origin(url) do
    case parse(url) do
      %URI{scheme: scheme, host: host, port: port} ->
        URI.to_string(%URI{scheme: String.downcase(scheme), host: host, port: port})

      nil ->
        @unparseable_url
    end
  end

  defp without_url_credentials(url) do
    case parse(url) do
      %URI{userinfo: nil, query: nil, fragment: nil} ->
        url

      %URI{} = uri ->
        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})

      # Nothing that can carry a credential: leave the text as it was.
      nil ->
        if String.contains?(url, ["@", "?", "#"]), do: @unparseable_url, else: url
    end
  end

  # A host that still holds an "@" means the userinfo itself contained one; such
  # a URL cannot be split safely, so it is replaced as a whole.
  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        if Regex.match?(@safe_host_pattern, host), do: uri

      _other ->
        nil
    end
  end
end
