defmodule ServiceRadar.SRQLAstTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SRQLAst

  test "entity extracts the declared target and falls back to devices" do
    assert SRQLAst.entity("in:interfaces type:ethernet") == "interfaces"
    assert SRQLAst.entity("hostname:router-1") == "devices"
    assert SRQLAst.entity("hostname:router-1", "interfaces") == "interfaces"
  end

  test "validate passes through SRQL parser success" do
    parse_fn = fn "in:devices hostname:router-1" -> {:ok, ~s({"filters":[]})} end

    assert :ok = SRQLAst.validate("in:devices hostname:router-1", parse_fn: parse_fn)
  end

  test "parse decodes the SRQL ast payload" do
    parse_fn = fn "in:devices hostname:router-1" ->
      {:ok, Jason.encode!(%{"filters" => [%{"field" => "hostname", "value" => "router-1"}]})}
    end

    assert {:ok, %{"filters" => [%{"field" => "hostname", "value" => "router-1"}]}} =
             SRQLAst.parse("in:devices hostname:router-1", parse_fn: parse_fn)
  end

  test "parse returns a decode error tuple for invalid json" do
    parse_fn = fn "in:devices hostname:router-1" -> {:ok, "{"} end

    assert {:error, {:json_decode_error, %Jason.DecodeError{}}} =
             SRQLAst.parse("in:devices hostname:router-1", parse_fn: parse_fn)
  end
end
