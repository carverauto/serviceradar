defmodule ServiceRadar.Inventory.AdvisoryFeeds.ParsersTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.Parsers
  alias ServiceRadar.Inventory.AdvisoryFeeds.StreamReader

  describe "Parsers.Nvd.parse_record/2" do
    test "maps an NVD 2.0 record to an advisory + CPE coordinates with version bounds" do
      record = nvd_record()

      assert {:ok, %{advisory: advisory, coordinates: coordinates, assertions: []}} =
               Parsers.Nvd.parse_record(record, provider: "nvd", feed_key: "nist-nvd2")

      assert advisory.cve_id == "CVE-2099-0001"
      assert advisory.source_object_id == "CVE-2099-0001"
      assert advisory.severity == "high"
      assert advisory.cvss_score == 7.5
      assert advisory.metadata["cwes"] == ["CWE-787"]
      assert advisory.metadata["normalization_version"] == 2
      assert advisory.raw == record

      assert [coordinate] = coordinates
      assert coordinate.coordinate_type == "cpe"
      assert coordinate.cpe_vendor == "example"
      assert coordinate.cpe_product == "quartz_tls"
      assert coordinate.version_start == "6.4.0"
      assert coordinate.version_start_inclusive == true
      assert coordinate.version_end == "6.4.8"
      assert coordinate.version_end_inclusive == false
    end

    test "skips a record with no CVE id" do
      assert :skip = Parsers.Nvd.parse_record(%{"cve" => %{}}, provider: "nvd", feed_key: "x")
    end

    test "does not promote a cpeMatch with omitted vulnerable semantics" do
      malformed = %{
        "cve" => %{
          "id" => "CVE-2099-0002",
          "configurations" => [
            %{
              "nodes" => [
                %{
                  "cpeMatch" => [
                    %{"criteria" => "cpe:2.3:a:example:starling_fetch:*:*:*:*:*:*:*:*"}
                  ]
                }
              ]
            }
          ]
        }
      }

      assert {:ok, %{coordinates: [], assertions: []}} =
               Parsers.Nvd.parse_record(malformed,
                 provider: "nvd",
                 feed_key: "nist-nvd2"
               )
    end

    test "collapses cpeMatch rows that share the coordinate identity" do
      record = %{
        "cve" => %{
          "id" => "CVE-2099-0003",
          "configurations" => [
            %{
              "nodes" => [
                %{
                  "cpeMatch" => [
                    %{
                      "vulnerable" => true,
                      "criteria" => "cpe:2.3:a:example:quartz_tls:*:*:*:*:*:*:*:*",
                      "versionStartIncluding" => "6.4.0",
                      "versionEndExcluding" => "6.4.8",
                      "matchCriteriaId" => "AAAA"
                    },
                    %{
                      "vulnerable" => true,
                      "criteria" => "cpe:2.3:a:example:quartz_tls:*:*:*:*:*:*:*:*",
                      "versionStartIncluding" => "6.4.0",
                      "versionEndExcluding" => "6.4.8",
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

      assert coordinate.value == "cpe:2.3:a:example:quartz_tls:*:*:*:*:*:*:*:*"
      assert coordinate.version_start == "6.4.0"
      assert coordinate.version_end == "6.4.8"
    end

    test "retains a complete synthetic application and OS environment expression" do
      record = synthetic_environment_record()

      assert {:ok, %{advisory: advisory, coordinates: [coordinate], assertions: []}} =
               Parsers.Nvd.parse_record(record, provider: "nvd", feed_key: "nist-nvd2")

      assert advisory.metadata["normalization_version"] == Parsers.Nvd.normalization_version()
      assert coordinate.value == "cpe:2.3:a:example:starling_fetch:3.2.1:*:*:*:*:*:*:*"

      assert %{
               "expression_version" => 2,
               "affected_term_ids" => ["starling-fetch-term"],
               "expression" => expression
             } = coordinate.metadata["nvd_applicability"]

      assert expression["op"] == "and"
      assert expression["negate"] == false

      terms = expression_terms(expression)

      assert [affected] = Enum.filter(terms, &(&1["role"] == "affected"))
      assert affected["term_id"] == "starling-fetch-term"

      assert environment_terms = Enum.filter(terms, &(&1["role"] == "environment"))

      assert Enum.map(environment_terms, & &1["term_id"]) == [
               "atlas-9",
               "atlas-9-server",
               "atlas-9-workstation"
             ]

      assert Enum.all?(environment_terms, &(&1["vulnerable"] == false))
    end

    test "merges duplicate coordinate alternatives with OR" do
      record = %{
        "cve" => %{
          "id" => "CVE-2099-0004",
          "configurations" => [
            nvd_configuration(
              "starling-one",
              "cpe:2.3:o:exampleos:atlas_linux:9:*:*:*:*:*:*:*"
            ),
            nvd_configuration(
              "starling-two",
              "cpe:2.3:o:exampleos:atlas_linux:10:*:*:*:*:*:*:*"
            )
          ]
        }
      }

      assert {:ok, %{coordinates: [coordinate]}} =
               Parsers.Nvd.parse_record(record, provider: "nvd", feed_key: "nist-nvd2")

      assert %{
               "affected_term_ids" => ["starling-one", "starling-two"],
               "expression" => %{"op" => "or", "children" => [first, second]}
             } = coordinate.metadata["nvd_applicability"]

      assert Enum.map(
               [first, second],
               &MapSet.new(Enum.map(expression_terms(&1), fn term -> term["term_id"] end))
             ) ==
               [
                 MapSet.new(["starling-one", "env-starling-one"]),
                 MapSet.new(["starling-two", "env-starling-two"])
               ]
    end

    test "keeps each affected coordinate isolated from another product's alternative" do
      record = %{
        "cve" => %{
          "id" => "CVE-2099-0005",
          "configurations" => [
            nvd_configuration(
              "starling-fetch",
              "cpe:2.3:o:exampleos:atlas_linux:9:*:*:*:*:*:*:*"
            ),
            %{
              "operator" => "AND",
              "nodes" => [
                %{
                  "operator" => "OR",
                  "cpeMatch" => [
                    %{
                      "vulnerable" => true,
                      "criteria" => "cpe:2.3:a:example:quartz_tls:2.5.1:*:*:*:*:*:*:*",
                      "matchCriteriaId" => "quartz-tls"
                    }
                  ]
                },
                %{
                  "operator" => "OR",
                  "cpeMatch" => [
                    %{
                      "vulnerable" => false,
                      "criteria" => "cpe:2.3:o:exampleos:aurora_linux:42.04:*:*:*:*:*:*:*"
                    }
                  ]
                }
              ]
            }
          ]
        }
      }

      assert {:ok, %{coordinates: coordinates}} =
               Parsers.Nvd.parse_record(record, provider: "nvd", feed_key: "nist-nvd2")

      by_product = Map.new(coordinates, &{&1.cpe_product, &1})

      starling_criteria =
        expression_criteria(
          by_product["starling_fetch"].metadata["nvd_applicability"]["expression"]
        )

      quartz_criteria =
        expression_criteria(by_product["quartz_tls"].metadata["nvd_applicability"]["expression"])

      assert Enum.any?(starling_criteria, &String.contains?(&1, ":starling_fetch:"))
      refute Enum.any?(starling_criteria, &String.contains?(&1, ":quartz_tls:"))
      assert Enum.any?(quartz_criteria, &String.contains?(&1, ":quartz_tls:"))
      refute Enum.any?(quartz_criteria, &String.contains?(&1, ":starling_fetch:"))

      assert Enum.any?(
               expression_terms(
                 by_product["quartz_tls"].metadata["nvd_applicability"]["expression"]
               ),
               fn term ->
                 term["role"] == "environment" and
                   String.starts_with?(term["term_id"], "configurations/")
               end
             )
    end

    test "excludes non-vulnerable cpeMatch entries" do
      record = %{
        "cve" => %{
          "id" => "CVE-2099-0006",
          "configurations" => [
            %{
              "nodes" => [
                %{
                  "cpeMatch" => [
                    %{
                      "vulnerable" => false,
                      "criteria" => "cpe:2.3:a:example:inactive_widget:1.0:*:*:*:*:*:*:*"
                    }
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
        "vendorProject" => "Example",
        "product" => "Starling",
        "cve" => ["CVE-2099-5638", "CVE-2099-9805"],
        "vulnerabilityName" => "Synthetic Starling advisory",
        "shortDescription" => "Invented parser fixture",
        "dateAdded" => "2099-11-03",
        "epss" => %{"epss_score" => 0.91}
      }

      assert {:ok, %{advisory: advisory, coordinates: [coordinate], assertions: []}} =
               Parsers.Kev.parse_record(entry, provider: "vulncheck", feed_key: "vulncheck-kev")

      assert advisory.cve_id == "CVE-2099-5638"
      assert advisory.kev == true
      assert advisory.exploit_available == true
      assert advisory.raw["_cve_ids"] == ["CVE-2099-5638", "CVE-2099-9805"]
      assert advisory.metadata["priority"]["epss_score"] == 0.91
      assert advisory.metadata["priority"]["cve_ids"] == ["CVE-2099-5638", "CVE-2099-9805"]

      assert coordinate.coordinate_type == "vendor_product"
      assert coordinate.value == "starling"
      assert coordinate.cpe_vendor == "example"
      assert coordinate.cpe_product == "starling"
    end
  end

  describe "Parsers.Kev.parse_record/2 (CISA KEV — cveID string)" do
    test "maps a CISA KEV entry to a vendor_product coordinate" do
      entry = %{
        "cveID" => "CVE-2099-4422",
        "vendorProject" => "Example",
        "product" => "Quartz",
        "vulnerabilityName" => "Synthetic Quartz advisory",
        "shortDescription" => "Invented parser fixture",
        "dueDate" => "2099-12-24",
        "knownRansomwareCampaignUse" => "Known",
        "cwes" => ["CWE-502"]
      }

      assert {:ok, %{advisory: advisory, coordinates: [coordinate], assertions: []}} =
               Parsers.Kev.parse_record(entry, provider: "cisa", feed_key: "cisa-kev")

      assert advisory.cve_id == "CVE-2099-4422"
      assert advisory.title == "Synthetic Quartz advisory"
      assert advisory.description == "Invented parser fixture"
      assert advisory.metadata["priority"]["due_date"] == "2099-12-24"
      assert advisory.metadata["priority"]["ransomware_use"] == "Known"
      assert advisory.metadata["priority"]["sources"] == ["cisa-kev"]
      assert advisory.metadata["cwes"] == ["CWE-502"]
      assert coordinate.value == "quartz"
    end
  end

  describe "StreamReader fixtures" do
    test "decodes a top-level VulnCheck KEV array binary" do
      binary = Jason.encode!([%{"cveID" => "CVE-2099-9001"}, %{"cveID" => "CVE-2099-9002"}])

      records =
        binary
        |> StreamReader.records_from_binary(records_key: :array)
        |> Enum.map(fn {:ok, r} -> r["cveID"] end)

      assert records == ["CVE-2099-9001", "CVE-2099-9002"]
    end

    test "decodes a CISA-shaped {vulnerabilities: [...]} binary" do
      binary = Jason.encode!(%{"vulnerabilities" => [%{"cveID" => "CVE-2099-9003"}]})

      records =
        binary
        |> StreamReader.records_from_binary()
        |> Enum.map(fn {:ok, r} -> r["cveID"] end)

      assert records == ["CVE-2099-9003"]
    end

    test "returns an explicit error when the requested record collection is missing or malformed" do
      assert [{:error, {:invalid_records, "vulnerabilities"}}] =
               %{}
               |> Jason.encode!()
               |> StreamReader.records_from_binary()
               |> Enum.to_list()

      assert [{:error, {:invalid_records, "vulnerabilities"}}] =
               %{"vulnerabilities" => %{}}
               |> Jason.encode!()
               |> StreamReader.records_from_binary()
               |> Enum.to_list()
    end

    test "decodes a synthetic nist-nvd2 gz shard (gzip stream + JSON)" do
      shard = %{"vulnerabilities" => [nvd_record()]}
      gz = :zlib.gzip(Jason.encode!(shard))

      [record] = StreamReader.records_from_gzip(gz)
      assert record["cve"]["id"] == "CVE-2099-0001"
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

      assert records == ["CVE-2099-0001"]
      File.rm_rf(dir)
    end

    test "stream_nvd_shards reports a shard that disappears after listing" do
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

      results = Enum.to_list(stream)

      assert [{:ok, record}, {:error, {:read_error, ^missing, :enoent}}] = results
      assert record["cve"]["id"] == "CVE-2099-0001"
      File.rm_rf(dir)
    end
  end

  defp nvd_record do
    %{
      "cve" => %{
        "id" => "CVE-2099-0001",
        "published" => "2099-01-01T00:00:00.000",
        "lastModified" => "2099-01-02T00:00:00.000",
        "descriptions" => [%{"lang" => "en", "value" => "Synthetic parser advisory"}],
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
        "references" => [%{"url" => "https://advisories.example.invalid/CVE-2099-0001"}],
        "configurations" => [
          %{
            "nodes" => [
              %{
                "cpeMatch" => [
                  %{
                    "vulnerable" => true,
                    "criteria" => "cpe:2.3:a:example:quartz_tls:*:*:*:*:*:*:*:*",
                    "versionStartIncluding" => "6.4.0",
                    "versionEndExcluding" => "6.4.8",
                    "matchCriteriaId" => "synthetic-quartz-range"
                  }
                ]
              }
            ]
          }
        ]
      }
    }
  end

  defp synthetic_environment_record do
    %{
      "cve" => %{
        "id" => "CVE-2099-2601",
        "lastModified" => "2099-03-27T17:59:00.000",
        "configurations" => [
          %{
            "operator" => "AND",
            "nodes" => [
              %{
                "operator" => "OR",
                "negate" => false,
                "cpeMatch" => [
                  %{
                    "vulnerable" => true,
                    "criteria" => "cpe:2.3:a:example:starling_fetch:3.2.1:*:*:*:*:*:*:*",
                    "matchCriteriaId" => "starling-fetch-term"
                  }
                ]
              },
              %{
                "operator" => "OR",
                "negate" => false,
                "cpeMatch" => [
                  %{
                    "vulnerable" => false,
                    "criteria" => "cpe:2.3:o:exampleos:atlas_linux:9:*:*:*:*:*:*:*",
                    "matchCriteriaId" => "atlas-9"
                  },
                  %{
                    "vulnerable" => false,
                    "criteria" => "cpe:2.3:o:exampleos:atlas_linux_server:9:*:*:*:*:*:*:*",
                    "matchCriteriaId" => "atlas-9-server"
                  },
                  %{
                    "vulnerable" => false,
                    "criteria" => "cpe:2.3:o:exampleos:atlas_linux_workstation:9:*:*:*:*:*:*:*",
                    "matchCriteriaId" => "atlas-9-workstation"
                  }
                ]
              }
            ]
          }
        ]
      }
    }
  end

  defp nvd_configuration(term_id, environment_criteria) do
    %{
      "operator" => "AND",
      "nodes" => [
        %{
          "operator" => "OR",
          "cpeMatch" => [
            %{
              "vulnerable" => true,
              "criteria" => "cpe:2.3:a:example:starling_fetch:3.2.1:*:*:*:*:*:*:*",
              "matchCriteriaId" => term_id
            }
          ]
        },
        %{
          "operator" => "OR",
          "cpeMatch" => [
            %{
              "vulnerable" => false,
              "criteria" => environment_criteria,
              "matchCriteriaId" => "env-#{term_id}"
            }
          ]
        }
      ]
    }
  end

  defp expression_terms(%{"kind" => "cpe"} = term), do: [term]

  defp expression_terms(%{"children" => children}) do
    Enum.flat_map(children, &expression_terms/1)
  end

  defp expression_terms(_expression), do: []

  defp expression_criteria(expression) do
    expression
    |> expression_terms()
    |> Enum.map(& &1["criteria"])
  end
end
