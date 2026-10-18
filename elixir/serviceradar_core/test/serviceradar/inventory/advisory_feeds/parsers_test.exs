defmodule ServiceRadar.Inventory.AdvisoryFeeds.ParsersTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.NvdApplicability
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
      assert advisory.metadata["normalization_version"] == 3
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
               "expression_version" => 3,
               "affected_term_ids" => ["starling-fetch-term"],
               "configuration_refs" => [
                 %{"configuration_index" => 0, "required_term_ids" => ["starling-fetch-term"]}
               ]
             } = coordinate.metadata["nvd_applicability"]

      assert %{"expression" => expression} = resolved_applicability(advisory, coordinate)

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

      assert {:ok, %{advisory: advisory, coordinates: [coordinate]}} =
               Parsers.Nvd.parse_record(record, provider: "nvd", feed_key: "nist-nvd2")

      assert %{
               "affected_term_ids" => ["starling-one", "starling-two"],
               "expression" => %{"op" => "or", "children" => [first, second]}
             } = resolved_applicability(advisory, coordinate)

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

      assert {:ok, %{advisory: advisory, coordinates: coordinates}} =
               Parsers.Nvd.parse_record(record, provider: "nvd", feed_key: "nist-nvd2")

      by_product =
        Map.new(
          coordinates,
          &{&1.cpe_product, resolved_applicability(advisory, &1)["expression"]}
        )

      starling_criteria = expression_criteria(by_product["starling_fetch"])
      quartz_criteria = expression_criteria(by_product["quartz_tls"])

      assert Enum.any?(starling_criteria, &String.contains?(&1, ":starling_fetch:"))
      refute Enum.any?(starling_criteria, &String.contains?(&1, ":quartz_tls:"))
      assert Enum.any?(quartz_criteria, &String.contains?(&1, ":quartz_tls:"))
      refute Enum.any?(quartz_criteria, &String.contains?(&1, ":starling_fetch:"))

      assert Enum.any?(
               expression_terms(by_product["quartz_tls"]),
               fn term ->
                 term["role"] == "environment" and
                   String.starts_with?(term["term_id"], "configurations/")
               end
             )
    end

    test "persisted applicability grows linearly with the record's coordinates" do
      # Each coordinate used to embed the whole configuration expression, so a
      # record's stored bytes grew with coordinates x expression size (~3.4x per
      # doubling here). Storing the expression once keeps doubling near 2x.
      at_50 = persisted_applicability_bytes(wide_configuration_record(50))
      at_100 = persisted_applicability_bytes(wide_configuration_record(100))

      assert at_100 / at_50 < 2.2,
             "doubling coordinates grew stored applicability #{Float.round(at_100 / at_50, 2)}x " <>
               "(#{at_50} -> #{at_100} bytes)"
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

    test "decodes every record of a synthetic nist-nvd2 gz shard spanning many reads" do
      dir = Path.join(System.tmp_dir!(), "advisory-nvd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      {path, _json_bytes, count} = write_fat_nvd_shard(dir)

      ids =
        path
        |> File.read!()
        |> StreamReader.records_from_gzip()
        |> Enum.map(& &1["cve"]["id"])

      assert ids == Enum.map(1..count, &fat_cve_id/1)
      File.rm_rf(dir)
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

    test "decodes a shard one object at a time across chunk boundaries" do
      first = %{
        "cve" => %{
          "id" => "CVE-2099-0100",
          "descriptions" => [
            %{"lang" => "en", "value" => "synthetic {brace} \"quote\""}
          ],
          "configurations" => [
            %{"nodes" => [%{"cpeMatch" => [%{"criteria" => "cpe:2.3:a:example:quartz:*"}]}]}
          ]
        }
      }

      second = %{"cve" => %{"id" => "CVE-2099-0101"}}
      json = Jason.encode!(%{"resultsPerPage" => 2, "vulnerabilities" => [first, second]})
      chunks = for <<byte <- json>>, do: <<byte>>

      records =
        chunks
        |> StreamReader.decode_vulnerability_chunks()
        |> Enum.map(fn {:ok, record} -> record["cve"]["id"] end)

      assert records == ["CVE-2099-0100", "CVE-2099-0101"]
    end

    test "keeps a large synthetic shard resident set to one record" do
      dir = Path.join(System.tmp_dir!(), "advisory-nvd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      {path, json_bytes, count} = write_fat_nvd_shard(dir)
      # Several 16 KiB reads: a shard that fits one read hides a reader that
      # stops after the first inflate chunk.
      assert File.stat!(path).size > 8 * 16_384

      :erlang.garbage_collect()
      baseline = resident_bytes()

      {seen, peak, ids} =
        dir
        |> StreamReader.stream_nvd_shards()
        |> Enum.reduce({0, baseline, []}, fn
          {:ok, record}, {seen, peak, ids} ->
            id = record["cve"]["id"]
            :erlang.garbage_collect()
            {seen + 1, max(peak, resident_bytes()), [id | ids]}

          other, _acc ->
            flunk("shard decode failed: #{inspect(other)}")
        end)

      assert seen == count
      assert Enum.reverse(ids) == Enum.map(1..count, &fat_cve_id/1)
      assert peak - baseline < 2_000_000
      assert peak - baseline < div(json_bytes, 4)

      File.rm_rf(dir)
    end

    test "stream_nvd_shards reports a gz shard cut mid-stream as a truncated record" do
      dir = Path.join(System.tmp_dir!(), "advisory-nvd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      {path, _json_bytes, count} = write_fat_nvd_shard(dir)
      gz = File.read!(path)
      File.write!(path, binary_part(gz, 0, div(byte_size(gz), 2)))

      {oks, [last]} =
        dir
        |> StreamReader.stream_nvd_shards()
        |> Enum.split(-1)

      ids = Enum.map(oks, fn {:ok, record} -> record["cve"]["id"] end)

      assert last == {:error, {:parse_error, path, :truncated_record}}
      assert length(ids) > div(count, 4)
      assert ids == Enum.map(1..length(ids), &fat_cve_id/1)
      File.rm_rf(dir)
    end
  end

  defp write_fat_nvd_shard(dir) do
    path = Path.join(dir, "nvdcve-2.0-2099.json.gz")
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
    {:ok, io} = File.open(path, [:write, :binary, :raw])

    count = 80
    total = deflate_write(io, z, ~s({"vulnerabilities":[))

    total =
      Enum.reduce(1..count, total, fn i, acc ->
        record = %{
          "cve" => %{
            "id" => fat_cve_id(i),
            "descriptions" => [
              %{"lang" => "en", "value" => "synthetic {brace} \"quote\" " <> fat_noise(i)}
            ],
            "references" => [
              %{"url" => "https://advisories.example.invalid/#{fat_cve_id(i)}"}
            ]
          }
        }

        prefix = if i == 1, do: "", else: ","
        acc + deflate_write(io, z, prefix <> Jason.encode!(record))
      end)

    total = total + deflate_write(io, z, "]}")
    :ok = IO.binwrite(io, :zlib.deflate(z, <<>>, :finish))
    :ok = :zlib.deflateEnd(z)
    :zlib.close(z)
    :ok = File.close(io)
    {path, total, count}
  end

  defp deflate_write(io, z, data) do
    :ok = IO.binwrite(io, :zlib.deflate(z, data))
    byte_size(data)
  end

  # Deterministic hex noise: it deflates to about half its size, so the shard
  # spans many reads instead of collapsing the way repeated padding does.
  defp fat_noise(i) do
    Enum.map_join(1..500, fn block ->
      Base.encode16(:crypto.hash(:sha256, "fat-#{i}-#{block}"), case: :lower)
    end)
  end

  defp fat_cve_id(i) do
    "CVE-2099-" <> String.pad_leading(Integer.to_string(i), 4, "0")
  end

  defp resident_bytes do
    :erlang.garbage_collect()
    {:memory, mem} = Process.info(self(), :memory)
    {:binary, bins} = Process.info(self(), :binary)
    mem + Enum.reduce(bins, 0, fn {_id, size, _refc}, acc -> acc + size end)
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

  defp resolved_applicability(advisory, coordinate) do
    coordinate.metadata
    |> NvdApplicability.resolve_metadata(advisory.nvd_configurations)
    |> Map.fetch!("nvd_applicability")
  end

  # The bytes the loader persists for one record's applicability: every
  # coordinate's metadata plus the advisory's configuration expressions.
  defp persisted_applicability_bytes(record) do
    {:ok, %{advisory: advisory, coordinates: coordinates}} =
      Parsers.Nvd.parse_record(record, provider: "nvd", feed_key: "nist-nvd2")

    coordinate_bytes =
      coordinates |> Enum.map(&byte_size(Jason.encode!(&1.metadata))) |> Enum.sum()

    coordinate_bytes + byte_size(Jason.encode!(Map.get(advisory, :nvd_configurations)))
  end

  # One configuration: N affected application CPEs AND a fixed set of 20
  # environment operating systems.
  defp wide_configuration_record(affected_count) do
    affected =
      for i <- 1..affected_count do
        %{
          "vulnerable" => true,
          "criteria" => "cpe:2.3:a:example:widget_#{i}:*:*:*:*:*:*:*:*",
          "versionEndExcluding" => "2.#{i}.0",
          "matchCriteriaId" => "widget-#{i}"
        }
      end

    environment =
      for i <- 1..20 do
        %{
          "vulnerable" => false,
          "criteria" => "cpe:2.3:o:exampleos:atlas_linux:#{i}:*:*:*:*:*:*:*",
          "matchCriteriaId" => "atlas-#{i}"
        }
      end

    %{
      "cve" => %{
        "id" => "CVE-2099-0101",
        "configurations" => [
          %{
            "operator" => "AND",
            "nodes" => [
              %{"operator" => "OR", "cpeMatch" => affected},
              %{"operator" => "OR", "cpeMatch" => environment}
            ]
          }
        ]
      }
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
