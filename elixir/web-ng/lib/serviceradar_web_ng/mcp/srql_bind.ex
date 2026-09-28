defmodule ServiceRadarWebNG.Mcp.SrqlBind do
  @moduledoc """
  The single mechanism for turning an MCP scalar argument into an SRQL literal.

  Tools that accept structured scalars (a device uid, an IP, a hostname, a run
  id) must never concatenate them into an SRQL fragment. Everything goes through
  `literal/2`, so there is one place to audit and one place the injection
  regression tests point at.

  ## Why this validates instead of only escaping

  Escaping alone would round-trip: SRQL removes one outer quote pair and one
  level of backslash escapes from every value (see `rust/srql/src/parser/tokens.rs`).
  But a diagnostic tool handed something that is not a device uid, IP or
  hostname was called wrongly, and searching for it anyway answers a question
  nobody asked. Saying no is more useful.

  So each kind declares the characters it can contain, anything else is refused
  with a message naming the argument, and only then is the value quoted and
  escaped. Device uids, IPs, hostnames and uuids are all constrained enough that
  this costs nothing real.
  """

  # Deliberately excludes the quote characters SRQL's tokenizer treats as
  # delimiters (`"`, `'`, backtick) and the backslash that escapes them.
  @device_uid ~r/\A[A-Za-z0-9:._\-]{1,255}\z/
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @ip ~r/\A[0-9a-fA-F:.\/]{1,64}\z/
  @hostname ~r/\A[A-Za-z0-9._\-]{1,253}\z/
  @identifier_value ~r/\A[A-Za-z0-9:._\-]{1,255}\z/

  @kinds %{
    device_uid: {@device_uid, "a device uid"},
    uuid: {@uuid, "a uuid"},
    ip: {@ip, "an IP address"},
    hostname: {@hostname, "a hostname"},
    identifier_value: {@identifier_value, "an identifier value"}
  }

  @doc """
  Validate a scalar for `kind` and return it as a quoted SRQL literal.

  Returns `{:error, message}` rather than a mangled or dangerous literal.
  """
  @spec literal(term(), atom()) :: {:ok, String.t()} | {:error, String.t()}
  def literal(value, kind) when is_binary(value) do
    case Map.fetch(@kinds, kind) do
      {:ok, {pattern, description}} ->
        trimmed = String.trim(value)

        if Regex.match?(pattern, trimmed) do
          {:ok, quote_literal(trimmed)}
        else
          {:error, "#{inspect(value)} is not #{description}"}
        end

      :error ->
        {:error, "unknown scalar kind #{inspect(kind)}"}
    end
  end

  def literal(value, kind) when is_integer(value) or is_atom(value) do
    literal(to_string(value), kind)
  end

  def literal(value, _kind), do: {:error, "expected a scalar, got #{inspect(value)}"}

  @doc """
  Which of the supported kinds this value satisfies, if any.

  Used to decide whether a seed the operator supplied is a uid, an IP, or a
  hostname without asking them to say which.
  """
  @spec classify(String.t()) :: :device_uid | :ip | :hostname | :unknown
  def classify(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      String.starts_with?(trimmed, "sr:") and Regex.match?(@device_uid, trimmed) -> :device_uid
      Regex.match?(~r/\A[0-9]{1,3}(\.[0-9]{1,3}){3}\z/, trimmed) -> :ip
      String.contains?(trimmed, ":") and Regex.match?(@ip, trimmed) -> :ip
      Regex.match?(@hostname, trimmed) -> :hostname
      true -> :unknown
    end
  end

  def classify(_), do: :unknown

  @doc """
  Clamp a caller-supplied limit into a range these diagnostics can serve.
  """
  @spec clamp(term(), pos_integer(), pos_integer()) :: pos_integer()
  def clamp(value, _default, max) when is_integer(value) and value > 0, do: min(value, max)
  def clamp(_value, default, _max), do: default

  defp quote_literal(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end
end
