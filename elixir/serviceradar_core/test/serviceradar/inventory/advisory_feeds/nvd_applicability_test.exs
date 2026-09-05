defmodule ServiceRadar.Inventory.AdvisoryFeeds.NvdApplicabilityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.NvdApplicability
  alias ServiceRadar.Inventory.EndpointNvdFacts

  describe "evaluate/2" do
    test "implements every strong Kleene AND and OR result" do
      expected_and = %{
        {true, true} => true,
        {true, false} => false,
        {true, :unknown} => :unknown,
        {false, true} => false,
        {false, false} => false,
        {false, :unknown} => false,
        {:unknown, true} => :unknown,
        {:unknown, false} => false,
        {:unknown, :unknown} => :unknown
      }

      expected_or = %{
        {true, true} => true,
        {true, false} => true,
        {true, :unknown} => true,
        {false, true} => true,
        {false, false} => false,
        {false, :unknown} => :unknown,
        {:unknown, true} => true,
        {:unknown, false} => :unknown,
        {:unknown, :unknown} => :unknown
      }

      for {op, table} <- [{"and", expected_and}, {"or", expected_or}],
          {{left, right}, expected} <- table do
        expression = node(op, [term("left"), term("right")])
        facts = %{"term_results" => %{"left" => left, "right" => right}}

        assert %{result: ^expected} = NvdApplicability.evaluate(expression, facts)
      end
    end

    test "negation swaps true and false while preserving unknown" do
      for {value, expected} <- [{true, false}, {false, true}, {:unknown, :unknown}] do
        expression = node("and", [term("value")], true)

        assert %{result: ^expected} =
                 NvdApplicability.evaluate(expression, %{"term_results" => %{"value" => value}})
      end
    end

    test "classifies matched, contradicted, and unknown terms" do
      expression = node("and", [term("yes"), term("no"), term("maybe")])

      assert %{
               result: false,
               matched_terms: [%{"term_id" => "yes"}],
               contradicted_terms: [%{"term_id" => "no"}],
               unknown_terms: [%{"term_id" => "maybe"}]
             } =
               NvdApplicability.evaluate(expression, %{
                 "term_results" => %{"yes" => true, "no" => false, "maybe" => :unknown}
               })
    end

    test "treats vulnerable false as a positive environmental requirement" do
      expression =
        node("and", [
          Map.merge(term("environment"), %{
            "role" => "environment",
            "vulnerable" => false
          })
        ])

      assert %{result: true} =
               NvdApplicability.evaluate(expression, %{
                 "term_results" => %{"environment" => true}
               })
    end

    test "returns unknown for malformed and unsupported terms" do
      for expression <- [
            %{"kind" => "cpe", "term_id" => "bad", "criteria" => "not-a-cpe"},
            %{"kind" => "unsupported", "term_id" => "other"},
            %{"op" => "xor", "children" => [term("left"), term("right")]}
          ] do
        assert %{result: :unknown} = NvdApplicability.evaluate(expression, %{})
      end
    end

    test "returns unknown without raising when an arbitrary AST has malformed bounds" do
      expression = Map.put(term("curl", curl_cpe()), "bounds", ["not", "a", "map"])
      facts = EndpointNvdFacts.build(ubuntu_curl(), [ubuntu_curl()])

      assert %{result: :unknown} = NvdApplicability.evaluate(expression, facts)
    end

    test "requires the group kind even when operator and children look valid" do
      for child_truth <- [true, false] do
        expression = %{
          "kind" => "unsupported",
          "op" => "and",
          "negate" => false,
          "children" => [term("child")]
        }

        assert %{result: :unknown} =
                 NvdApplicability.evaluate(expression, %{
                   "term_results" => %{"child" => child_truth}
                 })
      end
    end

    test "returns unknown when a present required-term guard is malformed" do
      for required_term_ids <- ["child", [nil], [""], [1]],
          child_truth <- [true, false] do
        expression =
          "and"
          |> node([term("child")])
          |> Map.put("required_term_ids", required_term_ids)

        assert %{result: :unknown} =
                 NvdApplicability.evaluate(expression, %{
                   "term_results" => %{"child" => child_truth}
                 })
      end
    end

    test "returns unknown for inconsistent bound and inclusivity pairs" do
      facts = EndpointNvdFacts.build(ubuntu_curl(), [ubuntu_curl()])

      true_looking =
        "true-looking"
        |> term("cpe:2.3:a:haxx:curl:*:*:*:*:*:*:*:*")
        |> Map.put("bounds", %{
          "version_start" => "1",
          "version_start_inclusive" => nil,
          "version_end" => nil,
          "version_end_inclusive" => nil
        })

      false_looking =
        "false-looking"
        |> term("cpe:2.3:a:haxx:curl:1:*:*:*:*:*:*:*")
        |> Map.put("bounds", %{
          "version_start" => nil,
          "version_start_inclusive" => true,
          "version_end" => nil,
          "version_end_inclusive" => nil
        })

      assert %{result: :unknown} = NvdApplicability.evaluate(true_looking, facts)
      assert %{result: :unknown} = NvdApplicability.evaluate(false_looking, facts)
    end

    test "does not turn an escaped literal star into a wildcard match" do
      escaped =
        term("escaped", "cpe:2.3:a:haxx:curl:\\*:*:*:*:*:*:*:*")

      assert %{result: :unknown} =
               NvdApplicability.evaluate(escaped, %{
                 "application_cpes" => [parsed_cpe!(curl_cpe())],
                 "application_inventory_complete" => true
               })
    end

    test "NA in a non-version component does not match a concrete value" do
      expression =
        term(
          "na-update",
          "cpe:2.3:a:example:starling_fetch:3.2.1:-:*:*:*:*:*:*"
        )

      concrete_facts = %{
        "application_cpes" => [
          parsed_cpe!("cpe:2.3:a:example:starling_fetch:3.2.1:security:*:*:*:*:*:*")
        ],
        "application_inventory_complete" => true
      }

      na_facts = %{
        "application_cpes" => [
          parsed_cpe!("cpe:2.3:a:example:starling_fetch:3.2.1:-:*:*:*:*:*:*")
        ],
        "application_inventory_complete" => true
      }

      assert %{result: false} = NvdApplicability.evaluate(expression, concrete_facts)
      assert %{result: true} = NvdApplicability.evaluate(expression, na_facts)
    end

    test "NA in the version component matches only an NA installed version" do
      expression = term("na-version", "cpe:2.3:a:example:starling_fetch:-:*:*:*:*:*:*:*")

      concrete_facts = %{
        "application_cpes" => [parsed_cpe!(synthetic_app_cpe())],
        "application_inventory_complete" => true
      }

      na_facts = %{
        "application_cpes" => [
          parsed_cpe!("cpe:2.3:a:example:starling_fetch:-:*:*:*:*:*:*:*")
        ],
        "application_inventory_complete" => true
      }

      assert %{result: false} = NvdApplicability.evaluate(expression, concrete_facts)
      assert %{result: true} = NvdApplicability.evaluate(expression, na_facts)
    end
  end

  describe "normalize/1" do
    test "rejects missing or non-boolean vulnerable and negate values" do
      missing_vulnerable = [
        %{
          "nodes" => [
            %{
              "cpeMatch" => [
                %{"criteria" => synthetic_app_cpe()}
              ]
            }
          ]
        }
      ]

      malformed_vulnerable = [
        %{
          "nodes" => [
            %{
              "cpeMatch" => [
                %{"vulnerable" => "false", "criteria" => curl_cpe()}
              ]
            }
          ]
        }
      ]

      malformed_negate = [
        %{
          "negate" => "false",
          "nodes" => [
            %{"cpeMatch" => [%{"vulnerable" => true, "criteria" => curl_cpe()}]}
          ]
        }
      ]

      assert {:ok, %{coordinates: []}} = NvdApplicability.normalize(missing_vulnerable)
      assert {:ok, %{coordinates: []}} = NvdApplicability.normalize(malformed_vulnerable)
      assert {:ok, %{coordinates: []}} = NvdApplicability.normalize(malformed_negate)
    end

    test "rejects ambiguous and non-string version bounds as unsupported" do
      malformed_bounds = [
        %{
          "versionStartIncluding" => "1.0",
          "versionStartExcluding" => "1.1"
        },
        %{
          "versionEndIncluding" => "2.0",
          "versionEndExcluding" => "2.1"
        },
        %{"versionStartIncluding" => 1},
        %{"versionEndExcluding" => false}
      ]

      for {bounds, index} <- Enum.with_index(malformed_bounds) do
        configurations = [
          %{
            "nodes" => [
              %{
                "cpeMatch" => [
                  Map.merge(bounds, %{
                    "vulnerable" => true,
                    "criteria" => synthetic_app_cpe(),
                    "matchCriteriaId" => "malformed-bound-#{index}"
                  })
                ]
              }
            ]
          }
        ]

        assert {:ok, %{coordinates: []}} = NvdApplicability.normalize(configurations)
      end
    end

    test "retains malformed nested negation as JSON-safe unsupported input" do
      configurations = [
        %{
          "cpeMatch" => [%{"vulnerable" => true, "criteria" => curl_cpe()}],
          "nodes" => [
            %{
              "negate" => "false",
              "cpeMatch" => [
                %{
                  "vulnerable" => false,
                  "criteria" => "cpe:2.3:o:redhat:enterprise_linux:6:*:*:*:*:*:*:*"
                }
              ]
            }
          ]
        }
      ]

      assert {:ok, %{coordinates: [coordinate]}} =
               NvdApplicability.normalize(configurations)

      expression = coordinate.metadata["nvd_applicability"]["expression"]
      assert [_, %{"kind" => "unsupported", "negate" => nil}] = expression["children"]

      assert %{result: false, unknown_terms: [_ | _]} =
               NvdApplicability.evaluate(expression, %{})
    end

    test "merges coordinate inclusivity as an order-independent safe superset" do
      excluding = bounded_configuration("exclude", false)
      including = bounded_configuration("include", true)

      assert {:ok, %{coordinates: [forward]}} =
               NvdApplicability.normalize([excluding, including])

      assert {:ok, %{coordinates: [reverse]}} =
               NvdApplicability.normalize([including, excluding])

      assert forward.version_start_inclusive == true
      assert forward.version_end_inclusive == true
      assert reverse.version_start_inclusive == true
      assert reverse.version_end_inclusive == true

      assert forward.metadata["nvd_applicability"]["expression"]
             |> expression_terms()
             |> MapSet.new(fn term ->
               {term["term_id"], term["bounds"]["version_start_inclusive"],
                term["bounds"]["version_end_inclusive"]}
             end) == MapSet.new([{"exclude", false, false}, {"include", true, true}])
    end

    test "malformed CPE terms remain unknown and emit no coordinate" do
      configurations = [
        %{
          "nodes" => [
            %{
              "cpeMatch" => [
                %{"vulnerable" => true, "criteria" => "cpe:2.3:a"}
              ]
            }
          ]
        }
      ]

      assert {:ok, %{coordinates: []}} = NvdApplicability.normalize(configurations)

      assert %{result: :unknown} =
               NvdApplicability.evaluate(term("short", "cpe:2.3:a"), %{})
    end
  end

  describe "EndpointNvdFacts.build/2" do
    test "uses the package version for every application CPE alias" do
      aliases = [
        "cpe:2.3:a:fixture:alpha_widget:1.2.3:*:*:*:*:*:*:*",
        "cpe:2.3:a:sample:beta_widget:9.8.7:*:*:*:*:*:*:*"
      ]

      facts = EndpointNvdFacts.build(%{version: "1.2.3", cpes: aliases}, [])

      assert %{version: "1.2.3"} =
               Enum.find(
                 facts["current_application_cpes"],
                 &(&1.vendor == "sample" and &1.product == "beta_widget")
               )

      fallback_facts = EndpointNvdFacts.build(%{version: nil, cpes: aliases}, [])

      assert %{version: "9.8.7"} =
               Enum.find(
                 fallback_facts["current_application_cpes"],
                 &(&1.vendor == "sample" and &1.product == "beta_widget")
               )
    end

    test "emits coordinates only for vulnerable application terms" do
      configurations = [
        %{
          "operator" => "OR",
          "nodes" => [
            %{
              "operator" => "OR",
              "cpeMatch" => [
                %{"vulnerable" => true, "criteria" => curl_cpe()},
                %{
                  "vulnerable" => true,
                  "criteria" => "cpe:2.3:o:redhat:enterprise_linux:6:*:*:*:*:*:*:*"
                },
                %{
                  "vulnerable" => true,
                  "criteria" => "cpe:2.3:h:dell:poweredge_r740:*:*:*:*:*:*:*:*"
                }
              ]
            }
          ]
        }
      ]

      assert {:ok, %{coordinates: [coordinate]}} =
               NvdApplicability.normalize(configurations)

      assert coordinate.cpe_part == "a"
      assert coordinate.cpe_product == "curl"
    end

    test "another affected product alternative cannot confirm this coordinate" do
      curl = curl_cpe()
      openssl = "cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*"

      configurations = [
        %{
          "operator" => "OR",
          "nodes" => [
            %{
              "operator" => "OR",
              "cpeMatch" => [
                %{"vulnerable" => true, "criteria" => curl, "matchCriteriaId" => "curl"},
                %{
                  "vulnerable" => true,
                  "criteria" => openssl,
                  "matchCriteriaId" => "openssl"
                }
              ]
            }
          ]
        }
      ]

      assert {:ok, %{coordinates: coordinates}} = NvdApplicability.normalize(configurations)
      by_product = Map.new(coordinates, &{&1.cpe_product, &1})

      current = %{name: "openssl", version: "3.0.13", cpes: [openssl]}
      facts = EndpointNvdFacts.build(current, [current])

      assert %{result: false} =
               NvdApplicability.evaluate(
                 by_product["curl"].metadata["nvd_applicability"]["expression"],
                 facts
               )

      assert %{result: true} =
               NvdApplicability.evaluate(
                 by_product["openssl"].metadata["nvd_applicability"]["expression"],
                 facts
               )
    end

    test "applies source negation before the current-coordinate guard" do
      openssl_cpe = "cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*"

      configurations = [
        %{
          "operator" => "OR",
          "negate" => true,
          "nodes" => [
            %{
              "operator" => "OR",
              "cpeMatch" => [
                %{
                  "vulnerable" => true,
                  "criteria" => curl_cpe(),
                  "matchCriteriaId" => "curl"
                },
                %{
                  "vulnerable" => true,
                  "criteria" => openssl_cpe,
                  "matchCriteriaId" => "openssl"
                }
              ]
            }
          ]
        }
      ]

      assert {:ok, %{coordinates: coordinates}} = NvdApplicability.normalize(configurations)
      curl = Enum.find(coordinates, &(&1.cpe_product == "curl"))
      openssl = %{name: "openssl", version: "3.0.13", cpes: [openssl_cpe]}

      assert %{result: false, contradicted_terms: contradicted} =
               NvdApplicability.evaluate(
                 curl.metadata["nvd_applicability"]["expression"],
                 EndpointNvdFacts.build(openssl, [openssl])
               )

      assert Enum.any?(contradicted, fn term ->
               term["term_id"] == "curl" and
                 term["evaluation_scope"] == "current_application"
             end)
    end

    test "an evidence-backed Ubuntu provider contradicts a RHEL requirement" do
      facts = EndpointNvdFacts.build(ubuntu_curl(), [ubuntu_curl()])

      assert %{result: false} = NvdApplicability.evaluate(rhel_expression(), facts)
    end

    test "a qualified package PURL supplies OS evidence without an explicit OS map" do
      package = Map.delete(ubuntu_curl(), :os)
      facts = EndpointNvdFacts.build(package, [package])

      assert facts["os"] == %{
               "namespace" => "ubuntu",
               "release" => "jammy",
               "releases" => ["jammy"]
             }

      assert %{result: false} = NvdApplicability.evaluate(rhel_expression(), facts)
    end

    test "a conflicting package identity and endpoint OS emits no OS fact" do
      package = Map.put(ubuntu_curl(), :os, %{"provider" => "debian", "release" => "jammy"})

      facts = EndpointNvdFacts.build(package, [package])

      assert facts["os"] == nil
      assert %{result: :unknown} = NvdApplicability.evaluate(rhel_expression(), facts)
    end

    test "reconciles a precomputed package identity with current OS evidence" do
      package = %{
        name: "curl",
        version: "7.19.7",
        cpes: [curl_cpe()],
        package_identity: %{
          authority: :qualified_purl,
          namespace: "ubuntu",
          release: "jammy",
          conflicts: []
        }
      }

      facts =
        EndpointNvdFacts.build(package, [package], %{
          os_evidence: %{provider: "debian", release: "jammy"}
        })

      assert facts["os"] == nil
      assert %{result: :unknown} = NvdApplicability.evaluate(rhel_expression(), facts)
    end

    test "missing operating-system facts remain unknown" do
      package = %{name: "curl", version: "7.19.7", cpes: [curl_cpe()], package_manager: "dpkg"}
      facts = EndpointNvdFacts.build(package, [package])

      assert %{result: :unknown} = NvdApplicability.evaluate(rhel_expression(), facts)
    end

    test "unqualified PURL and package-manager identities do not supply OS evidence" do
      unqualified = %{
        name: "curl",
        version: "7.19.7",
        cpes: [curl_cpe()],
        purl: "pkg:deb/ubuntu/curl@7.19.7"
      }

      manager_only = unqualified |> Map.delete(:purl) |> Map.put(:package_manager, "dpkg")

      assert EndpointNvdFacts.build(unqualified, [unqualified])["os"] == nil
      assert EndpointNvdFacts.build(manager_only, [manager_only])["os"] == nil
    end

    test "matching RHEL provider and release satisfy the environment" do
      package = %{
        name: "curl",
        version: "7.19.7",
        cpes: [curl_cpe()],
        purl: "pkg:rpm/redhat/curl@7.19.7?distro=6",
        os: %{id: "redhat", version_id: "6"}
      }

      facts = EndpointNvdFacts.build(package, [package])
      assert %{result: true} = NvdApplicability.evaluate(rhel_expression(), facts)
    end

    test "operating-system environment terms honor their version bounds" do
      package = %{
        name: "curl",
        version: "7.19.7",
        cpes: [curl_cpe()],
        purl: "pkg:rpm/redhat/curl@7.19.7?distro=8",
        os: %{id: "redhat", version_id: "8"}
      }

      bounded_rhel =
        rhel_expression()
        |> put_in(
          ["children", Access.at(1), "criteria"],
          "cpe:2.3:o:redhat:enterprise_linux:*:*:*:*:*:*:*:*"
        )
        |> put_in(["children", Access.at(1), "bounds"], %{
          "version_start" => "6",
          "version_start_inclusive" => true,
          "version_end" => "7",
          "version_end_inclusive" => false
        })

      assert %{result: false} =
               NvdApplicability.evaluate(
                 bounded_rhel,
                 EndpointNvdFacts.build(package, [package])
               )
    end

    test "same-family releases from incomparable vocabularies remain unknown" do
      package = %{
        name: "curl",
        version: "7.19.7",
        cpes: [curl_cpe()],
        purl: "pkg:deb/ubuntu/curl@7.19.7?distro=jammy",
        os: %{id: "ubuntu", version_id: "22.04"}
      }

      expression =
        node("and", [
          Map.put(term("curl", curl_cpe()), "role", "affected"),
          Map.merge(
            term("ubuntu", "cpe:2.3:o:canonical:ubuntu_linux:jammy:*:*:*:*:*:*:*"),
            %{"role" => "environment", "vulnerable" => false}
          )
        ])

      assert %{result: :unknown} =
               NvdApplicability.evaluate(
                 expression,
                 EndpointNvdFacts.build(package, [package])
               )
    end

    test "same-family releases in the same vocabulary may contradict" do
      package = %{
        name: "curl",
        version: "7.19.7",
        cpes: [curl_cpe()],
        os_evidence: %{"namespace" => "ubuntu", "release" => "22.04"}
      }

      expression =
        node("and", [
          Map.put(term("curl", curl_cpe()), "role", "affected"),
          Map.merge(
            term("ubuntu", "cpe:2.3:o:canonical:ubuntu_linux:20.04:*:*:*:*:*:*:*"),
            %{"role" => "environment", "vulnerable" => false}
          )
        ])

      assert %{result: false} =
               NvdApplicability.evaluate(
                 expression,
                 EndpointNvdFacts.build(package, [package])
               )
    end

    test "codename ranges remain unknown because their ordering is not established" do
      package = %{
        name: "curl",
        version: "7.19.7",
        cpes: [curl_cpe()],
        os_evidence: %{namespace: "ubuntu", release: "jammy"}
      }

      environment =
        "ubuntu"
        |> term("cpe:2.3:o:canonical:ubuntu_linux:*:*:*:*:*:*:*:*")
        |> Map.merge(%{
          "role" => "environment",
          "vulnerable" => false,
          "bounds" => %{
            "version_start" => "focal",
            "version_start_inclusive" => true,
            "version_end" => "noble",
            "version_end_inclusive" => false
          }
        })

      expression =
        node("and", [Map.put(term("curl", curl_cpe()), "role", "affected"), environment])

      assert %{result: :unknown} =
               NvdApplicability.evaluate(
                 expression,
                 EndpointNvdFacts.build(package, [package])
               )
    end

    test "unevidenced constrained OS fields remain unknown" do
      constrained =
        put_in(
          rhel_expression(),
          ["children", Access.at(1), "criteria"],
          "cpe:2.3:o:redhat:enterprise_linux:6:*:*:*:*:*:x86_64:*"
        )

      package = %{
        name: "curl",
        version: "7.19.7",
        cpes: [curl_cpe()],
        os_evidence: %{namespace: "redhat", release: "6"}
      }

      assert %{result: :unknown} =
               NvdApplicability.evaluate(
                 constrained,
                 EndpointNvdFacts.build(package, [package])
               )
    end

    test "structured OS facts cannot prove logical NA fields" do
      criteria = "cpe:2.3:o:exampleos:aurora_linux:42.04:-:*:*:*:*:*:*"
      expression = Map.put(term("aurora-na", criteria), "role", "environment")

      structured_only = %{
        "os" => %{"namespace" => "aurora", "release" => "42.04"},
        "os_cpes" => []
      }

      assert %{result: :unknown} = NvdApplicability.evaluate(expression, structured_only)

      explicit_na =
        Map.put(structured_only, "os_cpes", [parsed_cpe!(criteria)])

      assert %{result: true} = NvdApplicability.evaluate(expression, explicit_na)
    end

    test "structured OS product fallback cannot replace a logical NA vendor" do
      criteria = "cpe:2.3:o:-:aurora_linux:solstice:*:*:*:*:*:*:*"
      expression = Map.put(term("aurora-na-vendor", criteria), "role", "environment")

      structured_only = %{
        "os" => %{"namespace" => "aurora", "release" => "solstice"},
        "os_cpes" => []
      }

      assert %{result: :unknown} = NvdApplicability.evaluate(expression, structured_only)

      explicit_na = Map.put(structured_only, "os_cpes", [parsed_cpe!(criteria)])
      assert %{result: true} = NvdApplicability.evaluate(expression, explicit_na)
    end

    test "a bounded logical-NA version cannot match a concrete installed version" do
      expression =
        "bounded-na"
        |> term("cpe:2.3:a:example:starling_fetch:-:*:*:*:*:*:*:*")
        |> Map.put("bounds", %{
          "version_start" => "1.0",
          "version_start_inclusive" => true,
          "version_end" => "9.0",
          "version_end_inclusive" => false
        })

      facts = %{
        "application_cpes" => [parsed_cpe!(synthetic_app_cpe())],
        "application_inventory_complete" => true
      }

      assert %{result: :unknown} = NvdApplicability.evaluate(expression, facts)
    end

    test "missing hardware facts remain unknown" do
      expression =
        node("and", [
          Map.put(term("curl", curl_cpe()), "role", "affected"),
          Map.put(
            term("hardware", "cpe:2.3:h:dell:poweredge_r740:*:*:*:*:*:*:*:*"),
            "role",
            "environment"
          )
        ])

      assert %{result: :unknown} =
               NvdApplicability.evaluate(
                 expression,
                 EndpointNvdFacts.build(ubuntu_curl(), [ubuntu_curl()])
               )
    end

    test "other current application CPEs may satisfy required applications" do
      openssl = %{
        name: "openssl",
        version: "3.0.13",
        cpes: ["cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*"]
      }

      expression =
        node("and", [
          Map.put(term("curl", curl_cpe()), "role", "affected"),
          Map.put(term("openssl", hd(openssl.cpes)), "role", "environment")
        ])

      assert %{result: true} =
               NvdApplicability.evaluate(
                 expression,
                 EndpointNvdFacts.build(ubuntu_curl(), [ubuntu_curl(), openssl])
               )
    end

    test "other package CPEs may satisfy vulnerable application terms in the expression" do
      openssl_cpe = "cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*"

      configurations = [
        %{
          "operator" => "AND",
          "nodes" => [
            %{
              "operator" => "OR",
              "cpeMatch" => [
                %{
                  "vulnerable" => true,
                  "criteria" => curl_cpe(),
                  "matchCriteriaId" => "curl"
                }
              ]
            },
            %{
              "operator" => "OR",
              "cpeMatch" => [
                %{
                  "vulnerable" => true,
                  "criteria" => openssl_cpe,
                  "matchCriteriaId" => "openssl"
                }
              ]
            }
          ]
        }
      ]

      assert {:ok, %{coordinates: coordinates}} = NvdApplicability.normalize(configurations)
      curl = Enum.find(coordinates, &(&1.cpe_product == "curl"))

      current = ubuntu_curl()
      openssl = %{name: "openssl", version: "3.0.13", cpes: [openssl_cpe]}
      facts = EndpointNvdFacts.build(current, [current, openssl])

      assert %{result: true} =
               NvdApplicability.evaluate(
                 curl.metadata["nvd_applicability"]["expression"],
                 facts
               )
    end

    test "absent extra application facts remain unknown because inventory may be incomplete" do
      expression =
        node("and", [
          Map.put(term("curl", curl_cpe()), "role", "affected"),
          Map.put(
            term("openssl", "cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*"),
            "role",
            "environment"
          )
        ])

      assert %{result: :unknown} =
               NvdApplicability.evaluate(
                 expression,
                 EndpointNvdFacts.build(ubuntu_curl(), [ubuntu_curl()])
               )
    end

    test "explicit scan completeness turns absent applications into false" do
      expression =
        node("and", [
          Map.put(term("curl", curl_cpe()), "role", "affected"),
          Map.put(
            term("openssl", "cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*"),
            "role",
            "environment"
          )
        ])

      partial =
        EndpointNvdFacts.build(ubuntu_curl(), [ubuntu_curl()], %{coverage_state: "partial"})

      complete =
        EndpointNvdFacts.build(ubuntu_curl(), [ubuntu_curl()], %{coverage_state: "complete"})

      assert %{result: :unknown} = NvdApplicability.evaluate(expression, partial)
      assert %{result: false} = NvdApplicability.evaluate(expression, complete)
    end

    test "explicit completeness overrides scan coverage and fact lists come from context" do
      hardware = "cpe:2.3:h:dell:poweredge_r740:*:*:*:*:*:*:*:*"
      runtime = "cpe:2.3:a:erlang:otp:27:*:*:*:*:*:*:*"
      os = "cpe:2.3:o:redhat:enterprise_linux:6:*:*:*:*:*:*:*"

      facts =
        EndpointNvdFacts.build(ubuntu_curl(), [ubuntu_curl()], %{
          application_inventory_complete: false,
          coverage_state: "complete",
          os_cpes: [os],
          hardware_cpes: [hardware],
          hardware_inventory_complete: true,
          runtime_cpes: [runtime],
          runtime_inventory_complete: true
        })

      assert facts["application_inventory_complete"] == false
      assert [%{part: "o", product: "enterprise_linux"}] = facts["os_cpes"]
      assert [%{part: "h", product: "poweredge_r740"}] = facts["hardware_cpes"]
      assert facts["hardware_inventory_complete"] == true
      assert [%{part: "a", product: "otp"}] = facts["runtime_cpes"]
      assert facts["runtime_inventory_complete"] == true
    end
  end

  defp rhel_expression do
    node("and", [
      Map.put(term("curl", curl_cpe()), "role", "affected"),
      Map.merge(term("rhel", "cpe:2.3:o:redhat:enterprise_linux:6:*:*:*:*:*:*:*"), %{
        "role" => "environment",
        "vulnerable" => false
      })
    ])
  end

  defp ubuntu_curl do
    %{
      name: "curl",
      version: "7.19.7",
      cpes: [curl_cpe()],
      purl: "pkg:deb/ubuntu/curl@7.19.7?distro=jammy",
      os: %{"id" => "ubuntu", "version_codename" => "jammy"}
    }
  end

  defp curl_cpe, do: "cpe:2.3:a:haxx:curl:7.19.7:*:*:*:*:*:*:*"

  defp synthetic_app_cpe, do: "cpe:2.3:a:example:starling_fetch:3.2.1:*:*:*:*:*:*:*"

  defp node(op, children, negate \\ false) do
    %{"kind" => "group", "op" => op, "negate" => negate, "children" => children}
  end

  defp term(id), do: term(id, "cpe:2.3:a:test:#{id}:1:*:*:*:*:*:*:*")

  defp term(id, criteria) do
    %{
      "kind" => "cpe",
      "term_id" => id,
      "role" => "affected",
      "criteria" => criteria,
      "bounds" => %{}
    }
  end

  defp bounded_configuration(id, inclusive) do
    %{
      "nodes" => [
        %{
          "cpeMatch" => [
            %{
              "vulnerable" => true,
              "criteria" => "cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*",
              "matchCriteriaId" => id,
              if(inclusive, do: "versionStartIncluding", else: "versionStartExcluding") =>
                "3.0.0",
              if(inclusive, do: "versionEndIncluding", else: "versionEndExcluding") => "3.0.14"
            }
          ]
        }
      ]
    }
  end

  defp parsed_cpe!(value) do
    assert {:ok, parsed} = ServiceRadar.Inventory.AdvisoryFeeds.Cpe.parse(value)
    parsed
  end

  defp expression_terms(%{"kind" => "cpe"} = term), do: [term]

  defp expression_terms(%{"children" => children}) when is_list(children),
    do: Enum.flat_map(children, &expression_terms/1)

  defp expression_terms(_expression), do: []
end
