defmodule ServiceRadarWebNGWeb.DeviceLive.RunTaskVariablesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.VariableSchema.Var
  alias ServiceRadarWebNGWeb.DeviceLive.RunTaskVariables

  @moduletag :db_free

  describe "playbook_id/1 + ansible?/1" do
    test "extracts the backing playbook id from action metadata" do
      action = %{metadata: %{"playbook_id" => "pb-123", "source_type" => "awx"}}
      assert RunTaskVariables.playbook_id(action) == "pb-123"
      assert RunTaskVariables.ansible?(action)
    end

    test "non-ansible actions have no playbook id" do
      assert RunTaskVariables.playbook_id(%{metadata: %{}}) == nil
      assert RunTaskVariables.playbook_id(%{}) == nil
      refute RunTaskVariables.ansible?(%{metadata: %{"other" => 1}})
    end
  end

  describe "extra_vars/3" do
    test "collects typed form values, coercing per declared type" do
      vars = [%Var{name: "hostname", type: :text}, %Var{name: "count", type: :integer}]

      assert {:ok, %{"hostname" => "web01", "count" => 3}} =
               RunTaskVariables.extra_vars(vars, %{"hostname" => "web01", "count" => "3"}, nil)
    end

    test "raw JSON overrides typed values (raw keys win)" do
      vars = [%Var{name: "hostname", type: :text}]

      assert {:ok, %{"hostname" => "override", "extra" => true}} =
               RunTaskVariables.extra_vars(
                 vars,
                 %{"hostname" => "web01"},
                 ~s({"hostname": "override", "extra": true})
               )
    end

    test "blank / empty-object raw JSON keeps only the typed values" do
      vars = [%Var{name: "hostname", type: :text}]

      assert {:ok, %{"hostname" => "web01"}} =
               RunTaskVariables.extra_vars(vars, %{"hostname" => "web01"}, "")

      assert {:ok, %{"hostname" => "web01"}} =
               RunTaskVariables.extra_vars(vars, %{"hostname" => "web01"}, "{}")
    end

    test "invalid or non-object raw JSON is rejected" do
      assert {:error, _} = RunTaskVariables.extra_vars([], %{}, "{not valid")
      assert {:error, message} = RunTaskVariables.extra_vars([], %{}, ~s(["a", "b"]))
      assert message =~ "JSON object"
    end
  end

  describe "default_values/1 + values_from_params/2" do
    test "seeds declared defaults and pulls only declared vars from params" do
      vars = [%Var{name: "hostname", type: :text, default: "localhost"}, %Var{name: "count", type: :integer, default: 5}]

      assert RunTaskVariables.default_values(vars) == %{"hostname" => "localhost", "count" => "5"}

      assert RunTaskVariables.values_from_params(vars, %{"hostname" => "web01", "ignored" => "x"}) ==
               %{"hostname" => "web01"}
    end
  end
end
