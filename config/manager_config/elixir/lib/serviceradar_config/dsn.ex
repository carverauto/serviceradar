defmodule ServiceradarConfig.Dsn do
  @moduledoc """
  An assembled connection string, which cannot be printed.

  The DSN is NOT a schema field precisely because it embeds a password (see config.proto). That
  reasoning does not stop at the schema: an assembled DSN is as sensitive as the secret inside it,
  so returning a bare string here would undo the redaction SecretManager provides and put the
  credential into the first `inspect/1` that touches it.

  **The value is held in a closure, not in a field**, for the same reason as
  `ServiceradarSecret.Secret`: a struct IS a map on the BEAM, so `inspect(term, structs: false)`
  renders it as one and prints every field, bypassing the `Inspect` protocol. A closure's
  environment is not rendered, so the value survives `structs: false`, a Logger formatter that
  flattens metadata, and a crash report that dumps the term.

  Mirrors `Dsn` in //config/manager_config/rust.
  """

  @redacted "[REDACTED DSN]"
  def redacted, do: @redacted

  @enforce_keys [:reveal]
  defstruct [:reveal]

  @opaque t :: %__MODULE__{reveal: (-> String.t())}

  @spec new(String.t()) :: t()
  def new(value) when is_binary(value), do: %__MODULE__{reveal: fn -> value end}

  @doc "The connection string. Named so that reading it is visible in review and greppable."
  @spec expose(t()) :: String.t()
  def expose(%__MODULE__{reveal: reveal}), do: reveal.()
end

defimpl Inspect, for: ServiceradarConfig.Dsn do
  import Inspect.Algebra

  def inspect(_dsn, _opts), do: concat(["#Dsn<", ServiceradarConfig.Dsn.redacted(), ">"])
end

defimpl String.Chars, for: ServiceradarConfig.Dsn do
  def to_string(_dsn), do: ServiceradarConfig.Dsn.redacted()
end
