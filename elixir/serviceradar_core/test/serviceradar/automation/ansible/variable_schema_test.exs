defmodule ServiceRadar.Automation.Ansible.VariableSchemaTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.VariableSchema
  alias ServiceRadar.Automation.Ansible.VariableSchema.Var

  describe "from_playbook/1" do
    test "AWX-sourced with survey_spec returns typed vars" do
      playbook = %{
        source_type: :awx,
        survey_spec: %{
          "name" => "Deploy",
          "spec" => [
            %{
              "question_name" => "Target version",
              "variable" => "version",
              "type" => "text",
              "default" => "1.0.0",
              "required" => true
            },
            %{
              "question_name" => "Replicas",
              "variable" => "replicas",
              "type" => "integer",
              "default" => 3,
              "min" => 1,
              "max" => 10
            },
            %{
              "question_name" => "Secret",
              "variable" => "secret",
              "type" => "password",
              "required" => true
            },
            %{
              "question_name" => "Env",
              "variable" => "env",
              "type" => "multiplechoice",
              "choices" => "prod\nstage\ndev",
              "default" => "stage"
            }
          ]
        }
      }

      vars = VariableSchema.from_playbook(playbook)
      assert length(vars) == 4

      [v1, v2, v3, v4] = vars

      assert %Var{
               name: "version",
               type: :text,
               default: "1.0.0",
               required: true,
               label: "Target version"
             } = v1

      assert %Var{name: "replicas", type: :integer, default: 3, min: 1, max: 10} = v2
      assert %Var{name: "secret", type: :password, private: true, required: true} = v3

      assert %Var{name: "env", type: :select, choices: ["prod", "stage", "dev"], default: "stage"} =
               v4
    end

    test "git-sourced with vars_prompt returns text / password vars" do
      playbook = %{
        source_type: :git,
        vars_prompt: [
          %{"name" => "confirm", "prompt" => "Type yes to proceed"},
          %{"name" => "pw", "prompt" => "Password", "private" => true}
        ]
      }

      vars = VariableSchema.from_playbook(playbook)
      assert length(vars) == 2

      [v1, v2] = vars

      assert %Var{name: "confirm", type: :text, private: false} = v1
      assert v1.label == "Type yes to proceed"

      assert %Var{name: "pw", type: :password, private: true} = v2
    end

    test "playbook without source_type / variables returns []" do
      assert VariableSchema.from_playbook(%{}) == []
      assert VariableSchema.from_playbook(%{source_type: :awx}) == []
      assert VariableSchema.from_playbook(%{source_type: :awx, survey_spec: %{}}) == []
      assert VariableSchema.from_playbook(%{source_type: :git, vars_prompt: []}) == []
    end

    test "AWX entries without a variable name are dropped" do
      playbook = %{
        source_type: :awx,
        survey_spec: %{
          "spec" => [
            %{"question_name" => "Anonymous", "type" => "text"},
            %{"variable" => "ok", "type" => "text"}
          ]
        }
      }

      vars = VariableSchema.from_playbook(playbook)
      assert length(vars) == 1
      assert hd(vars).name == "ok"
    end

    test "AWX dispatcher markers never become operator inputs" do
      playbook = %{
        source_type: :awx,
        survey_spec: %{
          "spec" => [
            %{"variable" => "serviceradar_dispatch_id", "type" => "text"},
            %{"variable" => "ServiceRadar_Snapshot_Digest", "type" => "text"},
            %{"variable" => "package_version", "type" => "text"}
          ]
        }
      }

      assert [%Var{name: "package_version"}] = VariableSchema.from_playbook(playbook)
    end

    test "AWX multiplechoice with comma-separated choices also parses" do
      playbook = %{
        source_type: :awx,
        survey_spec: %{
          "spec" => [
            %{"variable" => "env", "type" => "multiplechoice", "choices" => "prod, stage, dev"}
          ]
        }
      }

      assert [%Var{type: :select, choices: ["prod", "stage", "dev"]}] =
               VariableSchema.from_playbook(playbook)
    end

    test "AWX multiselect type produces choices list" do
      playbook = %{
        source_type: :awx,
        survey_spec: %{
          "spec" => [
            %{"variable" => "regions", "type" => "multiselect", "choices" => "us-east\nus-west"}
          ]
        }
      }

      assert [%Var{type: :multiselect, choices: ["us-east", "us-west"]}] =
               VariableSchema.from_playbook(playbook)
    end

    test "AWX unknown type falls back to :text" do
      playbook = %{
        source_type: :awx,
        survey_spec: %{"spec" => [%{"variable" => "x", "type" => "weird"}]}
      }

      assert [%Var{name: "x", type: :text}] = VariableSchema.from_playbook(playbook)
    end

    test "vars_prompt entries without a name are dropped" do
      playbook = %{
        source_type: :git,
        vars_prompt: [
          %{"prompt" => "no name"},
          %{"name" => "good", "prompt" => "fine"}
        ]
      }

      assert [%Var{name: "good"}] = VariableSchema.from_playbook(playbook)
    end

    test "vars_prompt private: 'yes' (Ansible boolean shorthand) becomes password type" do
      playbook = %{
        source_type: :git,
        vars_prompt: [%{"name" => "secret", "prompt" => "?", "private" => "yes"}]
      }

      assert [%Var{type: :password, private: true}] = VariableSchema.from_playbook(playbook)
    end

    test "git declared_vars (plain vars:) render pre-filled, optional, type-inferred inputs" do
      playbook = %{
        source_type: :git,
        vars_prompt: [],
        declared_vars: %{
          "app_version" => "1.4.0",
          "replicas" => 3,
          "ratio" => 0.5,
          "drain" => true
        }
      }

      vars = VariableSchema.from_playbook(playbook)
      # sorted by name: app_version, drain, ratio, replicas
      assert Enum.map(vars, & &1.name) == ["app_version", "drain", "ratio", "replicas"]

      by_name = Map.new(vars, &{&1.name, &1})
      assert %Var{type: :text, default: "1.4.0", required: false} = by_name["app_version"]
      assert %Var{type: :integer, default: 3, required: false} = by_name["replicas"]
      assert %Var{type: :float, default: 0.5} = by_name["ratio"]
      # booleans fall back to text (the pre-filled default carries the value)
      assert %Var{type: :text, default: true} = by_name["drain"]
    end

    test "declared_vars render even when vars_prompt is absent" do
      playbook = %{source_type: :git, declared_vars: %{"region" => "us-east-1"}}

      assert [%Var{name: "region", type: :text, default: "us-east-1", required: false}] =
               VariableSchema.from_playbook(playbook)
    end

    test "vars_prompt wins on a name collision with declared_vars" do
      playbook = %{
        source_type: :git,
        vars_prompt: [%{"name" => "token", "prompt" => "API token", "private" => "yes"}],
        declared_vars: %{"token" => "static-default", "region" => "eu-west-1"}
      }

      vars = VariableSchema.from_playbook(playbook)
      # token appears exactly once, as the vars_prompt (password) definition.
      assert length(vars) == 2

      token_vars = Enum.filter(vars, &(&1.name == "token"))
      assert [%Var{type: :password, private: true, label: "API token"}] = token_vars

      assert %Var{name: "region", type: :text, default: "eu-west-1"} =
               Enum.find(vars, &(&1.name == "region"))
    end

    test "AWX survey_spec is unaffected by declared_vars handling" do
      playbook = %{
        source_type: :awx,
        declared_vars: %{"ignored" => "value"},
        survey_spec: %{"spec" => [%{"variable" => "x", "type" => "text"}]}
      }

      assert [%Var{name: "x", type: :text}] = VariableSchema.from_playbook(playbook)
    end
  end

  describe "extra_vars_from_form/2" do
    defp vars do
      [
        %Var{name: "version", type: :text},
        %Var{name: "replicas", type: :integer},
        %Var{name: "ratio", type: :float},
        %Var{name: "secret", type: :password, private: true},
        %Var{name: "env", type: :select, choices: ["prod", "stage"]},
        %Var{name: "regions", type: :multiselect, choices: ["us", "eu"]}
      ]
    end

    test "happy path: collects values, coerces ints/floats, preserves text" do
      form = %{
        "version" => "1.2.3",
        "replicas" => "3",
        "ratio" => "0.5",
        "secret" => "hunter2",
        "env" => "prod",
        "regions" => ["us", "eu"]
      }

      assert VariableSchema.extra_vars_from_form(vars(), form) == %{
               "version" => "1.2.3",
               "replicas" => 3,
               "ratio" => 0.5,
               "secret" => "hunter2",
               "env" => "prod",
               "regions" => ["us", "eu"]
             }
    end

    test "empty strings drop (use the playbook default)" do
      form = %{
        "version" => "",
        "replicas" => "",
        "ratio" => "",
        "env" => "stage"
      }

      assert VariableSchema.extra_vars_from_form(vars(), form) == %{"env" => "stage"}
    end

    test "non-integer replicas / non-float ratio are dropped" do
      form = %{"replicas" => "not-a-number", "ratio" => "abc"}
      assert VariableSchema.extra_vars_from_form(vars(), form) == %{}
    end

    test "multiselect from comma-separated string works as a fallback" do
      form = %{"regions" => "us, eu"}
      assert VariableSchema.extra_vars_from_form(vars(), form) == %{"regions" => ["us", "eu"]}
    end

    test "missing keys are dropped (operator left them blank)" do
      assert VariableSchema.extra_vars_from_form(vars(), %{}) == %{}
    end
  end

  describe "validated_non_secret_inputs/2" do
    test "canonicalizes declared typed non-secret inputs" do
      vars = [
        %Var{name: "version", type: :text, required: true},
        %Var{name: "replicas", type: :integer, min: 1, max: 10},
        %Var{name: "environment", type: :select, choices: ["stage", "prod"]}
      ]

      assert {:ok, %{"version" => "1.2.3", "replicas" => 3, "environment" => "prod"}} =
               VariableSchema.validated_non_secret_inputs(vars, %{
                 "version" => "1.2.3",
                 "replicas" => "3",
                 "environment" => "prod"
               })
    end

    test "rejects an entire binding that declares a private/password input" do
      vars = [
        %Var{name: "version", type: :text},
        %Var{name: "password", type: :password, private: true}
      ]

      assert {:error, {:sensitive_launch_inputs, ["password"]}} =
               VariableSchema.validated_non_secret_inputs(vars, %{"version" => "1.2.3"})
    end

    test "rejects undeclared fields and invalid typed values" do
      vars = [%Var{name: "replicas", type: :integer, min: 1, max: 10}]

      assert {:error, {:undeclared_launch_inputs, ["password"]}} =
               VariableSchema.validated_non_secret_inputs(vars, %{"password" => "secret"})

      assert {:error, {:invalid_launch_input, "replicas"}} =
               VariableSchema.validated_non_secret_inputs(vars, %{"replicas" => "many"})

      assert {:error, {:launch_input_out_of_bounds, "replicas"}} =
               VariableSchema.validated_non_secret_inputs(vars, %{"replicas" => "11"})
    end

    test "requires mandatory values" do
      vars = [%Var{name: "version", type: :text, required: true}]

      assert {:error, {:required_launch_input, "version"}} =
               VariableSchema.validated_non_secret_inputs(vars, %{})
    end

    test "rejects keys that collide after form-key normalization" do
      vars = [%Var{name: "environment", type: :text}]

      assert {:error, :ambiguous_launch_inputs} =
               VariableSchema.validated_non_secret_inputs(vars, %{
                 :environment => "stage",
                 "environment" => "prod"
               })
    end
  end

  describe "from_binding/1" do
    test "parses the reviewed binding input contract" do
      binding = %{
        input_schema: %{
          "environment" => %{
            "type" => "select",
            "required" => true,
            "choices" => ["stage", "prod"],
            "help" => "Deployment environment"
          },
          "replicas" => %{"type" => "integer", "min" => 1, "max" => 10}
        },
        input_classifications: %{"environment" => "internal", "replicas" => "public"}
      }

      assert {:ok, [environment, replicas]} = VariableSchema.from_binding(binding)
      assert %Var{type: :select, required: true, choices: ["stage", "prod"]} = environment
      assert %Var{type: :integer, min: 1, max: 10, private: false} = replicas
    end

    test "rejects secret-like names, unreviewed keys, and incomplete classifications" do
      assert {:error, {:sensitive_binding_input_forbidden, "api_token"}} =
               VariableSchema.from_binding(%{
                 input_schema: %{"api_token" => %{"type" => "text"}},
                 input_classifications: %{"api_token" => "internal"}
               })

      assert {:error, :binding_input_schema_invalid} =
               VariableSchema.from_binding(%{
                 input_schema: %{"region" => %{"type" => "text", "default" => "farm01"}},
                 input_classifications: %{"region" => "internal"}
               })

      assert {:error, :binding_input_classifications_invalid} =
               VariableSchema.from_binding(%{
                 input_schema: %{"region" => %{"type" => "text"}},
                 input_classifications: %{}
               })
    end

    test "uses canonical token boundaries for sensitive input names" do
      for name <- [
            "apiKey",
            "APIKey",
            "APIKEY",
            "MYAPITOKEN",
            "privateKey",
            "bearerToken",
            "password1",
            "credentialValue"
          ] do
        refute VariableSchema.reviewed_input_name?(name)

        assert {:error, {:sensitive_binding_input_forbidden, ^name}} =
                 VariableSchema.from_binding(%{
                   input_schema: %{name => %{"type" => "text"}},
                   input_classifications: %{name => "internal"}
                 })
      end

      for name <- [
            "environment",
            "qemuGuestAgentState",
            "apiary_zone",
            "key_rotation_days",
            "tokenizer_mode"
          ] do
        assert VariableSchema.reviewed_input_name?(name)
      end
    end

    test "rejects Ansible transport and magic-variable names" do
      for name <- [
            "ansible_host",
            "ansible_connection",
            "ansible_python_interpreter",
            "inventory_hostname",
            "hostvars",
            "groups",
            "play_hosts"
          ] do
        assert {:error, {:sensitive_binding_input_forbidden, ^name}} =
                 VariableSchema.from_binding(%{
                   input_schema: %{name => %{"type" => "text"}},
                   input_classifications: %{name => "internal"}
                 })
      end

      assert VariableSchema.reviewed_input_name?("qemu_guest_agent_state")
      refute VariableSchema.reviewed_input_name?("Ansible_User")
    end

    test "rejects input names that differ only by case" do
      assert {:error, :binding_input_schema_invalid} =
               VariableSchema.from_binding(%{
                 input_schema: %{
                   "Environment" => %{"type" => "text"},
                   "environment" => %{"type" => "text"}
                 },
                 input_classifications: %{
                   "Environment" => "internal",
                   "environment" => "internal"
                 }
               })
    end
  end
end
