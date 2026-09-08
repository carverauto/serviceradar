defmodule ServiceRadar.Automation.CallbackGrants.CanonicalJSONTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  test "sorts object keys recursively and preserves array order" do
    left = %{"z" => 1, "a" => [%{"b" => true, "a" => "x"}, nil]}
    right = %{z: 1, a: [%{a: "x", b: true}, nil]}

    assert {:ok, bytes} = CanonicalJSON.encode(left)
    assert bytes == ~s({"a":[{"a":"x","b":true},null],"z":1})
    assert CanonicalJSON.encode(right) == {:ok, bytes}
    assert CanonicalJSON.digest(left) == CanonicalJSON.digest(right)
  end

  test "rejects floats, invalid values, and duplicate normalized keys" do
    assert {:error, :floats_not_supported} = CanonicalJSON.encode(%{"value" => 1.0})
    assert {:error, :unsupported_json_value} = CanonicalJSON.encode(%{"value" => self()})

    assert {:error, {:duplicate_object_key, "key"}} =
             CanonicalJSON.encode(%{:key => 1, "key" => 2})
  end
end
