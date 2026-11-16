defmodule ServiceRadar.Logging.SecretRedaction do
  @moduledoc """
  Removes credential values from log records before they are exported, stored
  or displayed.

  Log records carry secrets in three shapes, and each needs its own pass:

    * **Terms.** A crash report's `crash_reason`, `reason`, `state` and
      `last_message` hold the crashing process's data as Erlang terms. A
      third-party struct such as `ExTURN.Client` keeps a TURN password and its
      derived HMAC key, and its `Inspect` implementation cannot be changed from
      here. `redact_term/1` walks maps, structs, tuples and lists and replaces
      the value of every sensitive key, so the exporter never renders it.
    * **Rendered text.** The same terms arrive pre-rendered: Elixir's crash
      translation (`password: "..."`, `key: <<1, 2, ...>>`), Erlang `~p`
      output (`password => <<"...">>`, `{password,<<"...">>}`), JSON
      (`"password":"..."`) and `key=value` pairs. `redact_text/1` replaces the
      whole value in each rendering, including binaries that span lines.
    * **Decoded attributes.** Stored log attributes are JSON maps.
      `redact_value/1` replaces the value of each sensitive key and redacts
      the text of every other string.

  Every pass is idempotent: a value that already reads `[REDACTED]` is left as
  it is. Text that an earlier version of this redaction mangled, where the
  marker was inserted in front of an Erlang binary instead of replacing it
  (`password =[REDACTED] <<"...">>`), is repaired by dropping that binary.

  `filter/2` is a `:logger` filter that applies the term and text passes to a
  whole log event. `ServiceRadar.Telemetry.OtelSetup` attaches it to the OTLP
  log handler, and `ServiceRadar.Logging.ConsoleFormatter` redacts the text it
  prints.

  ## Sensitive keys

  A key is sensitive when, after lowercasing and folding non-alphanumerics to
  `_`, it is one of `sensitive_keys/0` or ends in `_` followed by one of them
  (`local_pwd`, `client_secret`, `message_integrity`). `integrity` is listed
  because ExSTUN carries the TURN HMAC key in it. `key` is sensitive only by the
  shape of its value: raw bytes, such as that HMAC key, are redacted, and a
  printable `key` (an object key, a cache key) is kept.
  """

  @redacted "[REDACTED]"

  @sensitive_keys ~w(
    api_key apikey authorization bearer cookie credential credentials integrity jwt nkey
    nkey_seed passphrase passwd password private_key pwd secret secret_key seed signing_key
    token
  )

  @sensitive_key_set MapSet.new(@sensitive_keys)
  @sensitive_key_suffixes Enum.map(@sensitive_keys, &("_" <> &1))

  # Terms larger than this are not walked. The OTLP exporter renders any value
  # this large as `<truncated>` (see `otel_exporter_logs_otlp.erl`,
  # MAX_TERM_WORDS), so nothing in it can be exported, and walking a
  # multi-megabyte report in the logging process would stall the caller.
  @max_term_words 4096

  @withheld_message "[log event withheld: secret redaction failed]"

  @doc "The marker that replaces a redacted value."
  @spec redacted() :: String.t()
  def redacted, do: @redacted

  @doc "Key names (and `_`-suffixes) whose values are always redacted."
  @spec sensitive_keys() :: [String.t()]
  def sensitive_keys, do: @sensitive_keys

  @doc """
  Returns true when `key` names a credential. Atoms, strings and charlists are
  accepted; any other key is not sensitive.
  """
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) do
    case normalize_key(key) do
      nil ->
        false

      normalized ->
        MapSet.member?(@sensitive_key_set, normalized) or
          String.ends_with?(normalized, @sensitive_key_suffixes)
    end
  end

  @doc """
  Redacts decoded log data: maps with string or atom keys, lists and strings.
  """
  @spec redact_value(term()) :: term()
  def redact_value(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_entry?(key, nested), do: {key, @redacted}, else: {key, redact_value(nested)}
    end)
  end

  def redact_value(value) when is_list(value) do
    if printable_charlist?(value) do
      text = List.to_string(value)
      redacted = redact_text(text)
      if redacted == text, do: value, else: redacted
    else
      Enum.map(value, &redact_value/1)
    end
  end

  def redact_value(value) when is_binary(value), do: redact_text(value)
  def redact_value(value), do: value

  @doc """
  Redacts an arbitrary Erlang term: maps and structs by key, `{key, value}`
  pairs, nested tuples and lists, and the text of every string. Chardata that
  contains a secret is returned as a redacted binary.
  """
  @spec redact_term(term()) :: term()
  def redact_term(term) when is_binary(term) do
    if String.valid?(term), do: redact_text(term), else: term
  end

  def redact_term(term) when is_map(term) do
    :maps.map(
      fn key, nested ->
        if sensitive_entry?(key, nested), do: @redacted, else: redact_term(nested)
      end,
      term
    )
  end

  def redact_term({key, nested} = pair) when is_atom(key) or is_binary(key) do
    if sensitive_entry?(key, nested), do: {key, @redacted}, else: redact_tuple(pair)
  end

  def redact_term(term) when is_tuple(term), do: redact_tuple(term)
  def redact_term(term) when is_list(term), do: redact_list(term)
  def redact_term(term), do: term

  @doc """
  Redacts chardata, returning it unchanged when it carries no secret and as a
  redacted binary when it does.
  """
  @spec redact_chardata(IO.chardata()) :: IO.chardata()
  def redact_chardata(chardata) when is_binary(chardata), do: redact_term(chardata)

  def redact_chardata(chardata) when is_list(chardata) do
    case chardata_to_binary(chardata) do
      {:ok, text} ->
        redacted = redact_text(text)
        if redacted == text, do: chardata, else: redacted

      :error ->
        redact_list(chardata)
    end
  end

  @doc """
  Replaces the value of every sensitive key in rendered text: Elixir inspect,
  Erlang `~p`, JSON, tuple and `key=value` renderings.
  """
  @spec redact_text(String.t()) :: String.t()
  def redact_text(text) when is_binary(text) do
    %{assignment: assignment, pair: pair, raw_key: raw_key} = patterns()

    text
    |> replace_values(assignment)
    |> replace_values(pair)
    |> replace_values(raw_key)
  end

  def redact_text(text), do: text

  @doc """
  `:logger` filter (arity-2 filter fun contract). Returns the event with its
  message and metadata redacted; never `:stop` or `:ignore`. If redaction
  itself raises, the event is kept but its message and payload metadata are
  withheld, because `:logger` removes a filter that crashes and every later
  event would then pass unredacted.
  """
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()
  def filter(log_event, _arg), do: redact_log_event(log_event)

  @doc "Redacts a `:logger` event's message and metadata."
  @spec redact_log_event(:logger.log_event()) :: :logger.log_event()
  def redact_log_event(%{msg: msg, meta: meta} = log_event) when is_map(meta) do
    %{log_event | msg: redact_message(msg), meta: Map.new(meta, &redact_meta_entry/1)}
  rescue
    _error -> withhold(log_event)
  end

  def redact_log_event(log_event), do: log_event

  defp redact_message({:string, chardata}), do: {:string, redact_chardata(chardata)}

  defp redact_message({:report, report}) when is_map(report) do
    {:report, :maps.map(fn key, value -> redact_report_value(key, value) end, report)}
  end

  defp redact_message({:report, report}) when is_list(report) do
    {:report, Enum.map(report, &redact_report_pair/1)}
  end

  defp redact_message({format, args}) when is_list(args) do
    {format, Enum.map(args, &redact_bounded/1)}
  end

  defp redact_message(msg), do: redact_bounded(msg)

  defp redact_report_pair({key, value}), do: {key, redact_report_value(key, value)}
  defp redact_report_pair(other), do: redact_bounded(other)

  # Elixir's translator stores the rendered crash text here as chardata.
  defp redact_report_value(:elixir_translation, value) when is_list(value) or is_binary(value),
    do: redact_chardata(value)

  defp redact_report_value(key, value) do
    if sensitive_entry?(key, value), do: @redacted, else: redact_bounded(value)
  end

  defp redact_meta_entry({key, value}) do
    if sensitive_entry?(key, value), do: {key, @redacted}, else: {key, redact_bounded(value)}
  end

  defp redact_bounded(value) when is_binary(value), do: redact_term(value)

  defp redact_bounded(value) do
    if :erts_debug.flat_size(value) > @max_term_words, do: value, else: redact_term(value)
  end

  defp withhold(%{meta: meta} = log_event) when is_map(meta) do
    kept = Map.take(meta, [:time, :gl, :pid, :mfa, :file, :line, :domain])
    %{log_event | msg: {:string, @withheld_message}, meta: kept}
  end

  defp redact_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&redact_term/1) |> List.to_tuple()
  end

  defp redact_list(list) do
    case chardata_to_binary(list) do
      {:ok, text} ->
        redacted = redact_text(text)
        if redacted == text, do: list, else: redacted

      :error ->
        redact_elements(list)
    end
  end

  # Walks an improper list without losing its tail.
  defp redact_elements([head | tail]), do: [redact_term(head) | redact_elements(tail)]
  defp redact_elements([]), do: []
  defp redact_elements(tail), do: redact_term(tail)

  defp sensitive_entry?(key, value) do
    sensitive_key?(key) or raw_key_material?(key, value)
  end

  defp raw_key_material?(key, value) when is_binary(value) do
    normalize_key(key) == "key" and not String.printable?(value)
  end

  defp raw_key_material?(_key, _value), do: false

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> fold_key()
  defp normalize_key(key) when is_binary(key), do: fold_key(key)

  defp normalize_key(key) when is_list(key) do
    case chardata_to_binary(key) do
      {:ok, text} -> fold_key(text)
      :error -> nil
    end
  end

  defp normalize_key(_key), do: nil

  defp fold_key(key), do: key |> String.downcase() |> String.replace(~r/[^a-z0-9_]+/, "_")

  defp chardata_to_binary(chardata) do
    case :unicode.characters_to_binary(chardata) do
      text when is_binary(text) -> {:ok, text}
      _invalid_or_incomplete -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp printable_charlist?([_ | _] = value) do
    Enum.all?(value, &is_integer/1) and List.ascii_printable?(value)
  end

  defp printable_charlist?(_value), do: false

  defp replace_values(text, regex) do
    Regex.replace(regex, text, fn _match, prefix, value -> prefix <> replacement(value) end)
  end

  # Keep the rendering's own quoting so JSON stays JSON and an Erlang binary
  # still reads as one.
  defp replacement(~s(<<") <> _rest), do: ~s(<<"#{@redacted}">>)
  defp replacement(~s(") <> _rest), do: ~s("#{@redacted}")
  defp replacement(_value), do: @redacted

  # The patterns are built from the key list, so they are compiled once and
  # cached rather than recompiled for every log line.
  defp patterns do
    case :persistent_term.get({__MODULE__, :patterns}, nil) do
      nil ->
        patterns = compile_patterns()
        :persistent_term.put({__MODULE__, :patterns}, patterns)
        patterns

      patterns ->
        patterns
    end
  end

  defp compile_patterns do
    # Erlang binary string, optionally depth-truncated: <<"abc">>, <<"ab"...>>
    binary_string = ~S/<<"(?:[^"\\]|\\.)*"(?:\.\.\.)?>>/
    # Erlang or Elixir byte list, possibly across lines: <<1,2,...>>, <<1, 2,\n 3>>
    byte_list = ~S/<<[\d\s,.]*>>/
    double_quoted = ~S/"(?:[^"\\]|\\.)*"(?:\.\.\.)?/
    single_quoted = ~S/'(?:[^'\\]|\\.)*'/
    charlist_sigil = ~S/~c"(?:[^"\\]|\\.)*"/
    # A flat tuple or map, possibly across lines: {true, <<1, 2>>}, %{a: 1}
    braced = ~S/%?\{[^{}]*\}/
    # An existing marker, plus the binary that a pre-fix redaction left behind it.
    already_redacted = ~S/\[REDACTED\]\]*(?:\s+(?:/ <> binary_string <> "|" <> byte_list <> "))?"
    bare = ~S/(?:(?:Bearer|Basic|Digest|Token)\s+)?[^\s,;&"'}\])>]+/

    value =
      Enum.join(
        [
          already_redacted,
          binary_string,
          byte_list,
          braced,
          charlist_sigil,
          double_quoted,
          single_quoted,
          bare
        ],
        "|"
      )

    names =
      @sensitive_keys
      |> Enum.sort_by(&byte_size/1, :desc)
      |> Enum.map_join("|", &Regex.escape/1)
      |> then(&(~S/(?:[a-z0-9]+_)*?(?:/ <> &1 <> ")"))

    quoted_name = ~S/["']?/ <> names <> ~S/["']?/
    separator = ~S/\s*(?:=>|:|=)\s*/
    word_start = ~S/(?<![A-Za-z0-9_])/

    %{
      # password: "x" / password => <<"x">> / "password":"x" / password=x
      assignment:
        Regex.compile!("(" <> word_start <> quoted_name <> separator <> ")(" <> value <> ")", "i"),
      # {password,<<"x">>} / {:password, "x"}
      pair: Regex.compile!(~S/(\{\s*:?/ <> quoted_name <> ~S/\s*,\s*)(/ <> value <> ")", "i"),
      # key: <<241, 159, ...>> / key => <<241,159,...>>: raw key material only
      raw_key:
        Regex.compile!(
          "(" <> word_start <> ~S/["']?key["']?/ <> separator <> ")(" <> byte_list <> ")",
          "i"
        )
    }
  end
end
