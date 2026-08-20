defmodule ServiceradarSecret.SecretTest do
  @moduledoc """
  A secret cannot be inspected.

  This is the single most important property in the library. Every other check guards a mistake;
  this one guards the mistake that ends up in a log aggregator, where it outlives the process that
  leaked it.
  """

  use ExUnit.Case, async: true

  alias ServiceradarSecret.Secret

  @value "hunter2-correct-horse-battery-staple"

  defp secret do
    {:ok, secret} = Secret.new(@value)
    secret
  end

  # inspect/1 is reached by Logger metadata, an IO.inspect left in a pipeline, and every
  # FunctionClauseError -- none of which look like printing a password at the call site.
  test "inspect never contains the value" do
    rendered = inspect(secret())
    refute rendered =~ @value
    assert rendered =~ Secret.redacted()
  end

  test "interpolation never contains the value" do
    assert "#{secret()}" == Secret.redacted()
  end

  # Nesting is where a container printing itself would defeat redaction on the value.
  test "a secret nested in a container is still redacted" do
    s = secret()

    for rendered <- [
          inspect([s]),
          inspect(%{"database.password" => s}),
          inspect({:ok, s})
        ] do
      refute rendered =~ @value, "leaked through a container: #{rendered}"
    end
  end

  # The case a custom Inspect implementation does NOT cover, and the reason the value lives in a
  # closure rather than a field: a struct IS a map on the BEAM, so `structs: false` renders it as
  # one and prints every field, bypassing the protocol entirely. Anything that walks the term
  # rather than calling Inspect sees the same thing.
  test "the value survives inspection that bypasses the Inspect protocol" do
    s = secret()

    for rendered <- [
          inspect(s, structs: false),
          inspect(%{secret: s}, structs: false),
          inspect([s], structs: false)
        ] do
      refute rendered =~ @value, "leaked past the protocol: #{rendered}"
    end
  end

  # The same reasoning for a term dumped rather than inspected, which is what a crash report does.
  test "the value is not reachable by walking the term" do
    s = secret()
    refute inspect(Map.from_struct(s)) =~ @value
    refute :erlang.term_to_binary(s) |> Base.encode64() |> Base.decode64!() |> inspect() =~ @value
  end

  # The value is reachable only through a function whose name says so, which makes every read
  # visible in review and greppable in audit.
  test "the value is reachable only by exposing it" do
    assert Secret.expose(secret()) == @value
  end

  # Empty is not a secret. A provider returning an empty string has failed to resolve one, and
  # treating it as a value is how a component connects with a blank password.
  test "an empty value is not a secret" do
    assert :error = Secret.new("")
  end

  # Whitespace is not empty: a secret may legitimately be or contain spaces, and trimming here
  # would silently change a credential.
  test "whitespace is a value, not an absence" do
    assert {:ok, s} = Secret.new(" ")
    assert Secret.expose(s) == " "
    assert Secret.length(s) == 1
  end
end
