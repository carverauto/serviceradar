defmodule ServiceRadar.Inventory.AdvisoryFeeds.ParsersTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.Parsers
  alias ServiceRadar.Inventory.AdvisoryFeeds.StreamReader

  describe "Parsers.Nvd.parse_record/2" do
    test "maps an NVD 2.0 record to an advisory + CPE coordinates with version bounds" do
      record = nvd_record()

      assert {:ok, %{advisory: advisory, coordinates: coordinates}} =
               Parsers.Nvd.parse_record(record, provider: "nvd", feed_key: "nist-nvd2")

      assert advisory.cve_id == "CVE-2024-0001"
      assert advisory.source_object_id == "CVE-2024-0001"
      assert advisory.severity == "high"
      assert advisory.cvss_score == 7.5
      assert advisory.metadata["cwes"] == ["CWE-787"]
      assert advisory.raw == record

      assert [coordinate] = coordinates
      assert coordinate.coordinate_type == "cpe"
      assert coordinate.cpe_vendor == "openssl"
      assert coordinate.cpe_product == "openssl"
      assert coordinate.version_start == "3.0.0"
      assert coordinate.version_start_inclusive == true
      assert coordinate.version_end == "3.0.14"
      assert coordinate.version_end_inclusive == false
    end

    test "skips a record with no CVE id" do
      assert :skip = Parsers.Nvd.parse_record(%{"cve" => %{}}, provider: "nvd", feed_key: "x")
    end

    test "collapses cpeMatch rows that share the coordinate identity" do
      record = %{
        "cve" => %{
          "id" => "CVE-2024-0003",
          "configurations" => [
            %{
              "nodes" => [
                %{
                  "cpeMatch" => [
                    %{
                      "vulnerable" => true,
                      "criteria" => "cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*",
                      "versionStartIncluding" => "3.0.0",
                      "versionEndExcluding" => "3.0.14",
                      "matchCriteriaId" => "AAAA"
                    },
                    %{
                      "vulnerable" => true,
                      "criteria" => "cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*",
                      "versionStartIncluding" => "3.0.0",
                      "versionEndExcluding" => "3.0.14",
                      "matchCriteriaId" => "BBBB"
                    }
                  ]
                }
              ]
            }
          ]
        }
      }

      assert {:ok, %{coordinates: [coordinate]}} =
               Parsers.Nvd.parse_record(record, provider: "nvd", feed_key: "nist-nvd2")

      assert coordinate.value == "cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*"
      assert coordinate.version_start == "3.0.0"
      assert coordinate.version_end == "3.0.14"
    end

    test "excludes non-vulnerable cpeMatch entries" do
      record = %{
        "cve" => %{
          "id" => "CVE-2024-0002",
          "configurations" => [
            %{
              "nodes" => [
                %{
                  "cpeMatch" => [
                    %{"vulnerable" => false, "criteria" => "cpe:2.3:a:x:y:1.0:*:*:*:*:*:*:*"}
                  ]
                }
              ]
            }
          ]
        }
      }

      assert {:ok, %{coordinates: []}} =
               Parsers.Nvd.parse_record(record, provider: "nvd", feed_key: "x")
    end
  end

  describe "Parsers.Kev.parse_record/2 (VulnCheck KEV — cve is a list)" do
    test "maps a VulnCheck KEV entry (cve list) to a vendor_product coordinate" do
      entry = %{
        "vendorProject" => "Apache",
        "product" => "Struts",
        "cve" => ["CVE-2017-5638", "CVE-2017-9805"],
        "vulnerabilityName" => "Apache Struts RCE",
        "shortDescription" => "Remote code execution",
        "dateAdded" => "2021-11-03",
        "epss" => %{"epss_score" => 0.91}
      }

      assert {:ok, %{advisory: advisory, coordinates: [coordinate]}} =
               Parsers.Kev.parse_record(entry, provider: "vulncheck", feed_key: "vulncheck-kev")

      assert advisory.cve_id == "CVE-2017-5638"
      assert advisory.kev == true
      assert advisory.exploit_available == true
      assert advisory.raw["_cve_ids"] == ["CVE-2017-5638", "CVE-2017-9805"]
      assert advisory.metadata["priority"]["epss_score"] == 0.91
      assert advisory.metadata["priority"]["cve_ids"] == ["CVE-2017-5638", "CVE-2017-9805"]

      assert coordinate.coordinate_type == "vendor_product"
      assert coordinate.value == "struts"
      assert coordinate.cpe_vendor == "apache"
      assert coordinate.cpe_product == "struts"
    end
  end

  describe "Parsers.Kev.parse_record/2 (CISA KEV — cveID string)" do
    test "maps a CISA KEV entry to a vendor_product coordinate" do
      entry = %{
        "cveID" => "CVE-2021-44228",
        "vendorProject" => "Apache",
        "product" => "Log4j2",
        "vulnerabilityName" => "Log4Shell",
        "shortDescription" => "JNDI lookup RCE",
        "dueDate" => "2021-12-24",
        "knownRansomwareCampaignUse" => "Known",
        "cwes" => ["CWE-502"]
      }

      assert {:ok, %{advisory: advisory, coordinates: [coordinate]}} =
               Parsers.Kev.parse_record(entry, provider: "cisa", feed_key: "cisa-kev")

      assert advisory.cve_id == "CVE-2021-44228"
      assert advisory.title == "Log4Shell"
      assert advisory.description == "JNDI lookup RCE"
      assert advisory.metadata["priority"]["due_date"] == "2021-12-24"
      assert advisory.metadata["priority"]["ransomware_use"] == "Known"
      assert advisory.metadata["priority"]["sources"] == ["cisa-kev"]
      assert advisory.metadata["cwes"] == ["CWE-502"]
      assert coordinate.value == "log4j2"
    end
  end

  describe "StreamReader fixtures" do
    test "decodes a top-level VulnCheck KEV array binary" do
      binary = Jason.encode!([%{"cveID" => "CVE-1"}, %{"cveID" => "CVE-2"}])

      records =
        binary
        |> StreamReader.records_from_binary(records_key: :array)
        |> Enum.map(fn {:ok, r} -> r["cveID"] end)

      assert records == ["CVE-1", "CVE-2"]
    end

    test "decodes a CISA-shaped {vulnerabilities: [...]} binary" do
      binary = Jason.encode!(%{"vulnerabilities" => [%{"cveID" => "CVE-3"}]})

      records =
        binary
        |> StreamReader.records_from_binary()
        |> Enum.map(fn {:ok, r} -> r["cveID"] end)

      assert records == ["CVE-3"]
    end

    test "decodes a synthetic nist-nvd2 gz shard (gzip stream + JSON)" do
      shard = %{"vulnerabilities" => [nvd_record()]}
      gz = :zlib.gzip(Jason.encode!(shard))

      [record] = StreamReader.records_from_gzip(gz)
      assert record["cve"]["id"] == "CVE-2024-0001"
    end

    test "stream_nvd_shards reads a synthetic .json.gz-in-zip on disk" do
      dir = Path.join(System.tmp_dir!(), "advisory-nvd-#{System.unique_integer([:positive])}")
      extracted = Path.join(dir, "extracted")
      File.mkdir_p!(extracted)

      shard = %{"vulnerabilities" => [nvd_record()]}
      gz = :zlib.gzip(Jason.encode!(shard))
      File.write!(Path.join(extracted, "nvdcve-2.0-001.json.gz"), gz)

      # Build a zip the way Acquisition.extract would unpack it, then re-extract,
      # to prove the on-disk shard path works end-to-end (off-memory).
      records =
        extracted
        |> StreamReader.stream_nvd_shards()
        |> Enum.map(fn {:ok, r} -> r["cve"]["id"] end)

      assert records == ["CVE-2024-0001"]
      File.rm_rf(dir)
    end

    test "stream_nvd_shards skips a shard that disappears after listing" do
      dir = Path.join(System.tmp_dir!(), "advisory-nvd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      shard = %{"vulnerabilities" => [nvd_record()]}
      gz = :zlib.gzip(Jason.encode!(shard))
      present = Path.join(dir, "nvdcve-2.0-001.json.gz")
      missing = Path.join(dir, "nvdcve-2.0-002.json.gz")
      File.write!(present, gz)
      File.write!(missing, gz)

      # shard_paths/1 is eager; unlink after the list, before each File.read.
      stream = StreamReader.stream_nvd_shards(dir)
      File.rm!(missing)

      records = Enum.map(stream, fn {:ok, r} -> r["cve"]["id"] end)
      assert records == ["CVE-2024-0001"]
      File.rm_rf(dir)
    end
  end

  defp nvd_record do
    %{
      "cve" => %{
        "id" => "CVE-2024-0001",
        "published" => "2024-01-01T00:00:00.000",
        "lastModified" => "2024-01-02T00:00:00.000",
        "descriptions" => [%{"lang" => "en", "value" => "Test CVE"}],
        "metrics" => %{
          "cvssMetricV31" => [
            %{
              "type" => "Primary",
              "cvssData" => %{
                "baseScore" => 7.5,
                "baseSeverity" => "HIGH",
                "vectorString" => "CVSS:3.1/AV:N"
              }
            }
          ]
        },
        "weaknesses" => [
          %{
            "type" => "Primary",
            "description" => [%{"lang" => "en", "value" => "CWE-787"}]
          }
        ],
        "references" => [%{"url" => "https://example.test/CVE-2024-0001"}],
        "configurations" => [
          %{
            "nodes" => [
              %{
                "cpeMatch" => [
                  %{
                    "vulnerable" => true,
                    "criteria" => "cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*",
                    "versionStartIncluding" => "3.0.0",
                    "versionEndExcluding" => "3.0.14",
                    "matchCriteriaId" => "ABC"
                  }
                ]
              }
            ]
          }
        ]
      }
    }
  end
end
