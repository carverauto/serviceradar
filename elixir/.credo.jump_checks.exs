[
  {Jump.CredoChecks.AssertElementSelectorCanNeverFail, []},
  {Jump.CredoChecks.AvoidFunctionLevelElse, []},
  {Jump.CredoChecks.AvoidLoggerConfigureInTest, []},
  {Jump.CredoChecks.AvoidSocketAssignsInTest, []},
  {Jump.CredoChecks.DoctestIExExamples,
   [
     derive_test_path: fn filename ->
       filename
       |> String.replace_leading("lib/", "test/")
       |> String.replace_trailing(".ex", "_test.exs")
     end
   ]},
  {Jump.CredoChecks.LiveViewFormCanBeRehydrated, []},
  {Jump.CredoChecks.PreferTextColumns, []},
  {Jump.CredoChecks.TestHasNoAssertions, []},
  {Jump.CredoChecks.TooManyAssertions, []},
  {Jump.CredoChecks.TopLevelAliasImportRequire, []},
  {Jump.CredoChecks.UseObanProWorker, []},
  {Jump.CredoChecks.VacuousTest,
   [
     library_modules: [
       Ash,
       Ecto,
       Jason,
       Oban,
       Phoenix,
       Plug
     ]
   ]},
  {Jump.CredoChecks.WeakAssertion, []}
]
