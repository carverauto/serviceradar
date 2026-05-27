defmodule ServiceRadar.Inventory.IdentityReconcilerPassiveFingerprintTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.IdentityReconciler

  @passive_metadata %{
    "passive_fingerprint" => %{
      "tcp" => %{
        "p0f_signature" => "64240:64:1:60:M1460,S,T,N,W7",
        "os_family" => "linux",
        "os_name" => "Linux 5.x"
      },
      "tls" => %{
        "ja4" => "t13d1516h2_8daaf6152771_b0da82dd1658"
      }
    }
  }

  @tag :visibility
  test "passive fingerprint is extracted as weak evidence, not a strong identifier" do
    ids =
      IdentityReconciler.extract_strong_identifiers(%{
        device_id: nil,
        ip: "",
        mac: nil,
        partition: "default",
        metadata: @passive_metadata
      })

    assert is_binary(ids.passive_fingerprint)
    assert String.starts_with?(ids.passive_fingerprint, "sha256:")
    refute IdentityReconciler.has_strong_identifier?(ids)
    assert {nil, nil} = IdentityReconciler.highest_priority_identifier(ids)
  end

  @tag :visibility
  test "same passive fingerprint alone does not produce a deterministic device id" do
    ids =
      IdentityReconciler.extract_strong_identifiers(%{
        device_id: nil,
        ip: "",
        mac: nil,
        partition: "default",
        metadata: @passive_metadata
      })

    first = IdentityReconciler.generate_deterministic_device_id(ids)
    second = IdentityReconciler.generate_deterministic_device_id(ids)

    assert IdentityReconciler.serviceradar_uuid?(first)
    assert IdentityReconciler.serviceradar_uuid?(second)
    assert first != second
  end

  @tag :visibility
  test "property: matching passive fingerprints cannot collapse distinct strong identifiers" do
    for suffix <- 1..50 do
      ids_a =
        IdentityReconciler.extract_strong_identifiers(%{
          device_id: nil,
          ip: "",
          mac: nil,
          partition: "default",
          metadata: Map.put(@passive_metadata, "armis_device_id", "armis-a-#{suffix}")
        })

      ids_b =
        IdentityReconciler.extract_strong_identifiers(%{
          device_id: nil,
          ip: "",
          mac: nil,
          partition: "default",
          metadata: Map.put(@passive_metadata, "armis_device_id", "armis-b-#{suffix}")
        })

      assert ids_a.passive_fingerprint == ids_b.passive_fingerprint
      assert IdentityReconciler.has_strong_identifier?(ids_a)
      assert IdentityReconciler.has_strong_identifier?(ids_b)

      refute IdentityReconciler.generate_deterministic_device_id(ids_a) ==
               IdentityReconciler.generate_deterministic_device_id(ids_b)
    end
  end

  @tag :visibility
  test "passive fingerprint hash is stable across metadata key shape" do
    flat_ids =
      IdentityReconciler.extract_strong_identifiers(%{
        device_id: nil,
        ip: "",
        mac: nil,
        partition: "default",
        metadata: %{
          "passive_fingerprint.tcp.signature" => "64240:64:1:60:M1460,S,T,N,W7",
          "passive_fingerprint.tcp.os_family" => "linux",
          "passive_fingerprint.tcp.os_name" => "Linux 5.x",
          "passive_fingerprint.tls.ja4" => "t13d1516h2_8daaf6152771_b0da82dd1658"
        }
      })

    nested_ids =
      IdentityReconciler.extract_strong_identifiers(%{
        device_id: nil,
        ip: "",
        mac: nil,
        partition: "default",
        metadata: @passive_metadata
      })

    assert flat_ids.passive_fingerprint == nested_ids.passive_fingerprint
  end

  @tag :visibility
  test "passive fingerprint hash keeps field context for swapped values" do
    ids_a =
      IdentityReconciler.extract_strong_identifiers(%{
        device_id: nil,
        ip: "",
        mac: nil,
        partition: "default",
        metadata: %{
          "passive_fingerprint" => %{
            "tls" => %{"ja4" => "shared-a"},
            "http" => %{"server" => "shared-b"}
          }
        }
      })

    ids_b =
      IdentityReconciler.extract_strong_identifiers(%{
        device_id: nil,
        ip: "",
        mac: nil,
        partition: "default",
        metadata: %{
          "passive_fingerprint" => %{
            "tls" => %{"ja4" => "shared-b"},
            "http" => %{"server" => "shared-a"}
          }
        }
      })

    assert String.starts_with?(ids_a.passive_fingerprint, "sha256:")
    assert String.starts_with?(ids_b.passive_fingerprint, "sha256:")
    refute ids_a.passive_fingerprint == ids_b.passive_fingerprint
  end
end
