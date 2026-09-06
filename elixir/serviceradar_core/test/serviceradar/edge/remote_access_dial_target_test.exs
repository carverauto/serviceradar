defmodule ServiceRadar.Edge.RemoteAccessDialTargetTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessDialTarget

  describe "resolve/2" do
    test "dials the device address rather than its hostname" do
      device = %{uid: "sr:device-01", hostname: "host01", ip: "192.0.2.10"}

      assert {:ok, "192.0.2.10"} = RemoteAccessDialTarget.resolve(device, nil)
    end

    test "an operator-supplied host overrides the device address" do
      device = %{uid: "sr:device-01", hostname: "host01", ip: "192.0.2.10"}

      assert {:ok, "jump01.example.com"} =
               RemoteAccessDialTarget.resolve(device, "jump01.example.com")
    end

    test "falls back to the hostname when the device has no address" do
      device = %{uid: "sr:device-01", hostname: "host01.example.com", ip: nil}

      assert {:ok, "host01.example.com"} = RemoteAccessDialTarget.resolve(device, nil)
    end

    test "reads string-keyed device maps" do
      device = %{"uid" => "sr:device-01", "hostname" => "host01", "ip" => "192.0.2.10"}

      assert {:ok, "192.0.2.10"} = RemoteAccessDialTarget.resolve(device, nil)
    end

    test "ignores a blank address and a blank override" do
      device = %{uid: "sr:device-01", hostname: "host01.example.com", ip: "   "}

      assert {:ok, "host01.example.com"} = RemoteAccessDialTarget.resolve(device, "  ")
    end

    test "prefers an IPv6 address over the hostname" do
      device = %{uid: "sr:device-01", hostname: "host01", ip: "2001:db8::10"}

      assert {:ok, "2001:db8::10"} = RemoteAccessDialTarget.resolve(device, nil)
    end

    test "uses the device name when no hostname is recorded" do
      device = %{uid: "sr:device-01", name: "host01.example.com"}

      assert {:ok, "host01.example.com"} = RemoteAccessDialTarget.resolve(device, nil)
    end

    test "falls back to the uid when the device carries no address or name" do
      device = %{uid: "sr:device-01"}

      assert {:ok, "sr:device-01"} = RemoteAccessDialTarget.resolve(device, nil)
    end

    test "reports a missing target when nothing identifies the device" do
      assert {:error, :missing_remote_access_target} = RemoteAccessDialTarget.resolve(%{}, nil)
    end
  end
end
