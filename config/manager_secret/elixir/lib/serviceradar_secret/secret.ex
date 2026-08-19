defmodule ServiceradarSecret.Secret do
  @moduledoc """
  A resolved secret value, which cannot be inspected.

  **The value is held in a closure, not in a field.** A custom `Inspect` implementation is not
  enough on the BEAM: a struct IS a map, so `inspect(term, structs: false)` renders it as one and
  prints every field, bypassing the protocol. Anything that walks the term rather than calling
  `Inspect` sees the same thing. A closure's environment is not rendered, so the value survives
  `structs: false`, a Logger formatter that flattens metadata, and a crash report that dumps the
  term.

  `Inspect` and `String.Chars` still redact, for the ordinary paths.

  The value is reachable only through `expose/1`. That name is the point: every call site that
  reads the value says so, and a grep for `expose` is the complete list of places a secret can
  leave this struct.
  """

  @redacted "[REDACTED]"
  def redacted, do: @redacted

  @enforce_keys [:reveal]
  defstruct [:reveal]

  @opaque t :: %__MODULE__{reveal: (-> String.t())}

  @doc """
  Wraps a resolved value.

  Empty is not a secret: a provider that returns an empty string has failed to resolve one, and
  treating it as a value is how a component connects with a blank password.
  """
  @spec new(String.t()) :: {:ok, t()} | :error
  def new(""), do: :error
  def new(value) when is_binary(value), do: {:ok, %__MODULE__{reveal: fn -> value end}}

  @doc "The value. Named so that reading it is visible in review and greppable in audit."
  @spec expose(t()) :: String.t()
  def expose(%__MODULE__{reveal: reveal}), do: reveal.()

  @spec length(t()) :: non_neg_integer()
  def length(%__MODULE__{} = secret), do: secret |> expose() |> byte_size()
end

defimpl Inspect, for: ServiceradarSecret.Secret do
  import Inspect.Algebra

  def inspect(_secret, _opts) do
    concat(["#Secret<", ServiceradarSecret.Secret.redacted(), ">"])
  end
end

defimpl String.Chars, for: ServiceradarSecret.Secret do
  def to_string(_secret), do: ServiceradarSecret.Secret.redacted()
end
