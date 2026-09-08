defmodule ServiceRadar.Notifications.Callbacks.Primitives do
  @moduledoc """
  The parts of the northbound callback stack that genuinely transfer to provider
  callbacks (task 4.3.4, design D7).

  This is the "reuse" half of the amended 4.3.4. The northbound *scheme* does not
  transfer - `"<timestamp>.<raw_body>"` and the `sha256=` prefix are
  northbound-only and must not be copied - but its primitives do, and restating
  them per provider is how three verifiers end up with three subtly different
  notions of "equal" and "recent".

  `ServiceRadar.Automation.Northbound.CommandResultHandler` is deliberately left
  untouched: it is a working, security-critical path with its own tests, and
  refactoring it to share code with a new caller would put that path at risk to
  save duplication that is measured in a few dozen lines.

  ## The default that must not be inherited

  `CommandResultHandler.raw_body/1` defaults a missing raw body to `""`. That is
  safe there because its routes are registered with `RawBodyReader`. Copy it into
  a new route whose prefix is *not* registered and the verifier computes an HMAC
  over the empty string and reports an ordinary bad signature - identical to a
  wrong secret, and for Discord identical to the failure that gets an endpoint
  automatically deregistered. Every unit test that passes the body explicitly
  still passes forever.

  `require_raw_body/2` is the guard: an empty body with a non-zero declared
  content length is `{:error, :raw_body_unavailable}`, which a controller can log
  as a deployment fault rather than an authentication one.
  """

  import Bitwise

  @typedoc "Request headers, in either shape a caller may hold them."
  @type headers :: [{String.t(), String.t()}] | %{String.t() => String.t()}

  @doc """
  Returns the raw body, or a distinct error when it is absent but should not be.

  An empty body is legitimate only when the request genuinely carried none. The
  declared content length is how those two cases are told apart.
  """
  @spec require_raw_body(binary() | nil, non_neg_integer() | nil) ::
          {:ok, binary()} | {:error, :raw_body_unavailable}
  def require_raw_body(raw_body, content_length \\ nil)

  def require_raw_body(raw_body, _content_length) when is_binary(raw_body) and raw_body != "",
    do: {:ok, raw_body}

  def require_raw_body("", content_length) when is_integer(content_length) and content_length > 0,
    do: {:error, :raw_body_unavailable}

  def require_raw_body("", _content_length), do: {:ok, ""}
  def require_raw_body(_raw_body, _content_length), do: {:error, :raw_body_unavailable}

  @doc """
  Constant-time comparison with a length pre-check.

  `Plug.Crypto.secure_compare/2` requires equal-length inputs, so the `byte_size`
  guard is not an optimisation - without it a length mismatch raises instead of
  returning false. Mirrors `CommandResultHandler`'s use exactly.
  """
  @spec secure_equal?(binary(), binary()) :: boolean()
  def secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  def secure_equal?(_left, _right), do: false

  @doc "HMAC-SHA256, lower-case hex. The encoding Slack and PagerDuty both use."
  @spec hmac_sha256_hex(binary(), binary()) :: String.t()
  def hmac_sha256_hex(key, message) do
    :hmac
    |> :crypto.mac(:sha256, key, message)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Parses a Unix-epoch-seconds timestamp presented as a string.

  Deliberately narrower than `CommandResultHandler.parse_callback_timestamp/1`,
  which also accepts ISO 8601. Slack and PagerDuty send epoch seconds; accepting
  a second format on a route that never receives one is a second thing to get
  wrong, and a lenient parser is how a garbage timestamp becomes a `0` that sits
  outside every tolerance and reports the wrong reason.
  """
  @spec parse_unix_timestamp(term()) :: {:ok, DateTime.t()} | {:error, :invalid_timestamp}
  def parse_unix_timestamp(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} ->
        case DateTime.from_unix(seconds) do
          {:ok, datetime} -> {:ok, datetime}
          _error -> {:error, :invalid_timestamp}
        end

      _other ->
        {:error, :invalid_timestamp}
    end
  end

  def parse_unix_timestamp(_value), do: {:error, :invalid_timestamp}

  @doc """
  Rejects a timestamp outside the tolerance, in either direction.

  The comparison is on the absolute skew, as northbound's is. A future-dated
  timestamp is as suspect as an old one and clock drift runs both ways, so a
  one-sided check would silently accept a replay from a fast clock.
  """
  @spec within_tolerance?(DateTime.t(), DateTime.t(), pos_integer()) :: boolean()
  def within_tolerance?(%DateTime{} = timestamp, %DateTime{} = now, tolerance_seconds) do
    abs(DateTime.diff(now, timestamp, :second)) <= tolerance_seconds
  end

  @doc """
  Fetches a header value, case-insensitively, from either shape.

  Header names are case-insensitive by specification and providers document them
  inconsistently (Slack shows both `X-Slack-Signature` and `x-slack-signature`).
  Plug downcases, but a fixture or a test helper may not, and a verifier that
  only matched one casing would pass its tests and reject production traffic.
  """
  @spec header(headers(), String.t()) :: String.t() | nil
  def header(headers, name) when is_map(headers) do
    headers
    |> Enum.find(fn {key, _value} -> downcase(key) == downcase(name) end)
    |> case do
      {_key, value} -> value
      nil -> nil
    end
  end

  def header(headers, name) when is_list(headers) do
    wanted = downcase(name)

    Enum.find_value(headers, fn
      {key, value} -> if downcase(key) == wanted, do: value
      _other -> nil
    end)
  end

  def header(_headers, _name), do: nil

  @doc """
  Compares two hex digests without leaking length or content through timing.

  Normalises case first, because a provider may send either and a case-sensitive
  compare would reject a valid signature.
  """
  @spec hex_equal?(binary(), binary()) :: boolean()
  def hex_equal?(left, right) when is_binary(left) and is_binary(right) do
    secure_equal?(downcase(String.trim(left)), downcase(String.trim(right)))
  end

  def hex_equal?(_left, _right), do: false

  @doc """
  True when any element matches, evaluated without short-circuiting.

  PagerDuty sends a comma-separated list of signatures so a secret can be rotated
  without dropping deliveries, and the obvious `Enum.any?/2` returns on the first
  match - leaking, through timing, which position matched. This folds over every
  element regardless.
  """
  @spec any_equal?([binary()], binary()) :: boolean()
  def any_equal?(candidates, expected) when is_list(candidates) do
    candidates
    |> Enum.reduce(0, fn candidate, acc ->
      bor(acc, if(hex_equal?(candidate, expected), do: 1, else: 0))
    end)
    |> Kernel.==(1)
  end

  def any_equal?(_candidates, _expected), do: false

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(value), do: value |> to_string() |> String.downcase()
end
