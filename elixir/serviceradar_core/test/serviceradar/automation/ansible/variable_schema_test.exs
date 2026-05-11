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
            %{"question_name" => "Target version", "variable" => "version", "type" => "text", "default" => "1.0.0", "required" => true},
            %{"question_name" => "Replicas", "variable" => "replicas", "type" => "integer", "default" => 3, "min" => 1, "max" => 10},
            %{"question_name" => "Secret", "variable" => "secret", "type" => "password", "required" => true},
            %{"question_name" => "Env", "variable" => "env", "type" => "multiplechoice", "choices" => "prod\nstage\ndev", "default" => "stage"}
          ]
        }
      }

      vars = VariableSchema.from_playbook(playbook)
      assert length(vars) == 4

      [v1, v2, v3, v4] = vars

      assert %Var{name: "version", type: :text, default: "1.0.0", required: true, label: "Target version"} = v1
      assert %Var{name: "replicas", type: :integer, default: 3, min: 1, max: 10} = v2
      assert %Var{name: "secret", type: :password, private: true, required: true} = v3
      assert %Var{name: "env", type: :select, choices: ["prod", "stage", "dev"], default: "stage"} = v4
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

    test "AWX multiplechoice with comma-separated choices also parses" do
      playbook = %{
        source_type: :awx,
        survey_spec: %{
          "spec" => [
            %{"variable" => "env", "type" => "multiplechoice", "choices" => "prod, stage, dev"}
          ]
        }
      }

      assert [%Var{type: :select, choices: ["prod", "stage", "dev"]}] = VariableSchema.from_playbook(playbook)
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

      assert [%Var{type: :multiselect, choices: ["us-east", "us-west"]}] = VariableSchema.from_playbook(playbook)
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
end
