defmodule ServiceRadar.Inventory.DeviceVisibilityPayloadTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Device

  @passive_os %{
    "family" => "Linux",
    "version" => "5.x",
    "confidence" => 0.92,
    "source" => "serviceradar-license-clean",
    "observed_at" => "2026-05-27T12:00:00Z"
  }

  @passive_metadata %{
    "tcp" => %{
      "p0f_signature" => "4:64:0:1460:mss,nop,ws,nop,nop,sok:df,id+:0",
      "observed_at" => "2026-05-27T12:00:00Z"
    },
    "tls" => %{
      "ja4" => "t13d1516h2_8daaf6152771_b0da82dd1658",
      "observed_at" => "2026-05-27T12:00:01Z"
    },
    "http" => %{
      "user_agent" => "curl/8.7.1",
      "observed_at" => "2026-05-27T12:00:02Z"
    },
    "future_protocol" => %{
      "signature" => "forward-compatible",
      "observed_at" => "2026-05-27T12:00:03Z"
    }
  }

  @tag :visibility
  test "create changeset accepts passive fingerprint maps on os and metadata" do
    changeset =
      Ash.Changeset.for_create(Device, :create, %{
        uid: "sr:11111111-1111-1111-1111-111111111111",
        hostname: "passive-fingerprint-host",
        os: %{"passive_fingerprint" => @passive_os},
        metadata: %{"passive_fingerprint" => @passive_metadata}
      })

    assert changeset.valid?
    assert Ash.Changeset.get_attribute(changeset, :os)["passive_fingerprint"] == @passive_os

    assert Ash.Changeset.get_attribute(changeset, :metadata)["passive_fingerprint"] ==
             @passive_metadata
  end

  @tag :visibility
  test "update changeset accepts passive fingerprint maps on existing devices" do
    device = %Device{
      uid: "sr:22222222-2222-2222-2222-222222222222",
      is_managed: true,
      os: %{},
      metadata: %{}
    }

    changeset =
      Ash.Changeset.for_update(device, :update, %{
        os: %{"passive_fingerprint" => @passive_os},
        metadata: %{"passive_fingerprint" => @passive_metadata}
      })

    assert changeset.valid?
    assert Ash.Changeset.get_attribute(changeset, :os)["passive_fingerprint"] == @passive_os

    assert Ash.Changeset.get_attribute(changeset, :metadata)["passive_fingerprint"] ==
             @passive_metadata
  end
end
