{build_config, _binding} = Code.eval_file(Path.expand("../.credo.base.exs", __DIR__))

build_config.(
  included: ["lib/", "test/"],
  disabled: [
    {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
    {Credo.Check.Readability.PreferImplicitTry, []},
    {Credo.Check.Refactor.CyclomaticComplexity, []},
    {Credo.Check.Refactor.Nesting, []}
  ]
)
