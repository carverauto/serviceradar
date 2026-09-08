defmodule ServiceRadar.EventWriter.OtlpAttributesTest do
  use ExUnit.Case, async: true

  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias ServiceRadar.EventWriter.OtlpAttributes

  describe "canonical_bytes/1 (recipe v2 cross-language vectors)" do
    test "empty map" do
      assert OtlpAttributes.canonical_bytes(%{}) == "{}"
    end

    test "sorts map keys bytewise at every nesting level" do
      assert OtlpAttributes.canonical_bytes(%{"b" => "2", "a" => "1"}) ==
               ~s({"a":"1","b":"2"})

      assert OtlpAttributes.canonical_bytes(%{"outer" => %{"z" => 1, "a" => 2}}) ==
               ~s({"outer":{"a":2,"z":1}})
    end

    test "escapes only backslash and double-quote in strings" do
      assert OtlpAttributes.canonical_bytes("va\"l\\ue") == ~s("va\\"l\\\\ue")
      # Other control/whitespace characters pass through as raw bytes
      assert OtlpAttributes.canonical_bytes("a\nb\tc") == "\"a\nb\tc\""
    end

    test "scalars" do
      assert OtlpAttributes.canonical_bytes(true) == "true"
      assert OtlpAttributes.canonical_bytes(false) == "false"
      assert OtlpAttributes.canonical_bytes(nil) == "null"
      assert OtlpAttributes.canonical_bytes(42) == "42"
      assert OtlpAttributes.canonical_bytes(-7) == "-7"
    end

    test "floats encode as f + 16-char lowercase hex of IEEE-754 big-endian bits" do
      assert OtlpAttributes.canonical_bytes(0.5) == "f3fe0000000000000"
      assert OtlpAttributes.canonical_bytes(2.5) == "f4004000000000000"
      assert OtlpAttributes.canonical_bytes(-1.5) == "fbff8000000000000"
      assert OtlpAttributes.canonical_bytes(0.0) == "f0000000000000000"
      assert OtlpAttributes.canonical_bytes(1.0) == "f3ff0000000000000"
    end

    test "tagged bytes always encode as b + Base64, even valid UTF-8 payloads" do
      assert OtlpAttributes.canonical_bytes({:bytes, <<255, 0, 1>>}) == "b/wAB"
      # Matches the Go []byte case: bytes values keep their type
      assert OtlpAttributes.canonical_bytes({:bytes, "hello"}) == "baGVsbG8="
    end

    test "untagged non-UTF8 binaries fall back to b + Base64" do
      assert OtlpAttributes.canonical_bytes(<<255, 0, 1>>) == "b/wAB"
    end

    test "arrays join encoded items with commas" do
      assert OtlpAttributes.canonical_bytes(["x", 1, 2.5, false, nil]) ==
               ~s(["x",1,f4004000000000000,false,null])
    end
  end

  describe "attributes_hash/3 (recipe v2 literals shared with the Go gateway)" do
    test "empty attributes, empty identity" do
      # md5("{}\n\n")
      assert OtlpAttributes.attributes_hash(%{}, "", "") ==
               "5ad5cc4d26869082efd29c436b57384a"
    end

    test "single string attribute, empty identity" do
      # md5("{\"destination\":\"slack\"}\n\n")
      assert OtlpAttributes.attributes_hash(%{"destination" => "slack"}, "", "") ==
               "0a400c7afa11f7cb8f6b057bfc2ced04"
    end

    test "two string attributes, empty identity" do
      # md5("{\"a\":\"1\",\"b\":\"2\"}\n\n")
      assert OtlpAttributes.attributes_hash(%{"a" => "1", "b" => "2"}, "", "") ==
               "08d15b1d3dba45bfb72b5ba30c440f5c"
    end

    test "rich attributes with service_instance_id and scope_name" do
      attributes = %{
        "arr" => ["x", 1, 2.5, false],
        "bool" => true,
        "bytes" => {:bytes, <<255, 0, 1>>},
        "float" => 0.5,
        "int" => 42,
        "neg" => -1.5,
        "nested" => %{"z" => "last", "a" => %{"deep" => [1, 2]}},
        "none" => nil,
        "str" => "va\"l\\ue"
      }

      assert OtlpAttributes.attributes_hash(attributes, "instance-7", "sr.scope") ==
               "94d9dd949b532a243809a41937972918"
    end

    test "identity inputs change the hash" do
      base = OtlpAttributes.attributes_hash(%{}, "", "")
      assert OtlpAttributes.attributes_hash(%{}, "instance-1", "") != base
      assert OtlpAttributes.attributes_hash(%{}, "", "scope-1") != base
      assert OtlpAttributes.attributes_hash(%{}, "instance-1", "scope-1") != base
    end

    test "nil identity inputs hash like empty strings" do
      assert OtlpAttributes.attributes_hash(%{}, nil, nil) ==
               OtlpAttributes.attributes_hash(%{}, "", "")
    end
  end

  describe "key_values_to_canonical_map/1" do
    test "tags bytes values while the display map Base64-encodes them" do
      values = [
        %KeyValue{key: "payload", value: %AnyValue{value: {:bytes_value, <<255, 0, 1>>}}}
      ]

      assert OtlpAttributes.key_values_to_canonical_map(values) == %{
               "payload" => {:bytes, <<255, 0, 1>>}
             }

      assert OtlpAttributes.key_values_to_map(values) == %{"payload" => "/wAB"}
    end
  end

  describe "stable_json/1" do
    test "sorts keys at every nesting level" do
      term = %{"b" => %{"y" => 1, "x" => 2}, "a" => [%{"k2" => 1, "k1" => 2}]}

      assert OtlpAttributes.stable_json(term) ==
               ~s({"a":[{"k1":2,"k2":1}],"b":{"x":2,"y":1}})
    end

    test "stays stable for maps with more than 32 keys" do
      term = Map.new(1..40, fn i -> {"key_#{String.pad_leading("#{i}", 2, "0")}", i} end)

      encoded = OtlpAttributes.stable_json(term)
      assert encoded == OtlpAttributes.stable_json(Map.new(Enum.shuffle(Map.to_list(term))))

      keys = ~r/"(key_\d+)":/ |> Regex.scan(encoded) |> Enum.map(fn [_, k] -> k end)
      assert keys == Enum.sort(keys)
    end

    test "renders tagged bytes and non-UTF8 binaries as Base64 strings" do
      assert OtlpAttributes.stable_json(%{"bytes" => {:bytes, <<255, 0, 1>>}}) ==
               ~s({"bytes":"/wAB"})

      assert OtlpAttributes.stable_json(%{"bytes" => <<255, 0, 1>>}) ==
               ~s({"bytes":"/wAB"})
    end

    test "uses standard JSON escapes for strings" do
      assert OtlpAttributes.stable_json(%{"str" => "va\"l\\ue"}) ==
               ~s({"str":"va\\"l\\\\ue"})
    end
  end
end
