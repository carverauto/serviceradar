defmodule ServiceRadarWebNG.Mcp.SrqlBindTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Mcp.SrqlBind

  @moduletag :db_free

  describe "literal/2" do
    test "quotes an ordinary device uid" do
      assert {:ok, ~s("sr:0189f8c0-1d2e-7a3b-9c4d-5e6f70819a2b")} =
               SrqlBind.literal("sr:0189f8c0-1d2e-7a3b-9c4d-5e6f70819a2b", :device_uid)
    end

    test "refuses a value carrying SRQL quote characters" do
      # The token boundary would hold, but SRQL's tokenizer strips every
      # trailing quote when it unwraps a token, so a value like this cannot
      # round-trip. Refusing beats silently searching for something else.
      for payload <- [
            ~s(sr:aaa" OR "1"="1),
            "sr:aaa' OR '1'='1",
            "sr:aaa`whoami`",
            "sr:aaa\\",
            ~s(sr:aaa")
          ] do
        assert {:error, message} = SrqlBind.literal(payload, :device_uid)
        assert message =~ "is not a device uid"
      end
    end

    test "refuses whitespace that would split the token" do
      assert {:error, _} = SrqlBind.literal("sr:aaa limit:9999", :device_uid)
      assert {:error, _} = SrqlBind.literal("sr:aaa in:devices", :device_uid)
    end

    test "refuses a uuid that is not one" do
      assert {:error, _} = SrqlBind.literal("not-a-uuid", :uuid)
      assert {:error, _} = SrqlBind.literal("' OR 1=1 --", :uuid)

      assert {:ok, ~s("0189f8c0-1d2e-7a3b-9c4d-5e6f70819a2b")} =
               SrqlBind.literal("0189f8c0-1d2e-7a3b-9c4d-5e6f70819a2b", :uuid)
    end

    test "accepts IPv4, IPv6, and CIDR but not an injected filter" do
      assert {:ok, ~s("192.168.2.1")} = SrqlBind.literal("192.168.2.1", :ip)
      assert {:ok, ~s("fe80::1")} = SrqlBind.literal("fe80::1", :ip)
      assert {:ok, ~s("10.0.0.0/8")} = SrqlBind.literal("10.0.0.0/8", :ip)
      assert {:error, _} = SrqlBind.literal("192.168.2.1 OR deleted:true", :ip)
    end

    test "accepts a hostname but not one carrying operators" do
      assert {:ok, ~s("farm01.example.com")} = SrqlBind.literal("farm01.example.com", :hostname)
      assert {:error, _} = SrqlBind.literal("farm01 stats:count()", :hostname)
      assert {:error, _} = SrqlBind.literal(~s(farm01" OR uid:%), :hostname)
    end

    test "rejects non-scalars and unknown kinds" do
      assert {:error, _} = SrqlBind.literal(%{a: 1}, :device_uid)
      assert {:error, _} = SrqlBind.literal(["sr:aaa"], :device_uid)
      assert {:error, message} = SrqlBind.literal("sr:aaa", :not_a_kind)
      assert message =~ "unknown scalar kind"
    end

    test "trims surrounding whitespace rather than refusing it" do
      assert {:ok, ~s("sr:aaa")} = SrqlBind.literal("  sr:aaa  ", :device_uid)
    end
  end

  describe "classify/1" do
    test "recognises uids, IPs, and hostnames" do
      assert SrqlBind.classify("sr:0189f8c0-1d2e-7a3b-9c4d-5e6f70819a2b") == :device_uid
      assert SrqlBind.classify("192.168.2.1") == :ip
      assert SrqlBind.classify("fe80::1") == :ip
      assert SrqlBind.classify("farm01") == :hostname
      assert SrqlBind.classify("farm01.example.com") == :hostname
    end

    test "an injection payload is not classified as anything usable" do
      assert SrqlBind.classify(~s(sr:aaa" OR "1"="1)) == :unknown
      assert SrqlBind.classify("sr:aaa limit:9999") == :unknown
      assert SrqlBind.classify(nil) == :unknown
    end
  end

  describe "clamp/3" do
    test "uses the default for anything that is not a positive integer" do
      assert SrqlBind.clamp(nil, 50, 200) == 50
      assert SrqlBind.clamp(0, 50, 200) == 50
      assert SrqlBind.clamp(-1, 50, 200) == 50
      assert SrqlBind.clamp("100", 50, 200) == 50
    end

    test "caps a large request rather than honouring it" do
      assert SrqlBind.clamp(10_000, 50, 200) == 200
      assert SrqlBind.clamp(25, 50, 200) == 25
    end
  end
end
