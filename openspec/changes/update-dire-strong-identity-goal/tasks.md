# Tasks

## 1. Requirements

- [x] 1.1 ADDED goal requirements in `device-identity-reconciliation`; MODIFIED `device-inventory`
      "Restore Soft-Deleted Devices", with the pending copy in `add-device-delete-guardrails`
      updated to match.
- [ ] 1.2 Archive `refactor-device-identity-reconciliation` so its guarded `IP Alias Resolution`
      and `Merge Stability and Oscillation Protection` replace the unguarded wording in the
      living spec (design D1). Check first that no other pending change repeats those blocks.
- [ ] 1.3 Correct `docs/docs/dire-identity-model.md`: a globally-unique MAC may merge where it
      is the only hardware identifier; randomized MACs never do (design D4, D5).

## 2. Formal model (owned by `add-dire-formal-model`)

- [ ] 2.1 Extend the model with address churn, IP aliases, identifier classes, interface
      identifiers and recorded identity decisions, and add the properties in the design's
      mapping table.
- [ ] 2.2 Check the model against today's code, and record each violated requirement as a
      defect switch with a witness configuration.

## 3. Cleanup

Each confirmed defect is fixed in its own pull request. The pull request removes the defect's
model switch, deletes its witness, and adds its property to the model's must-pass
configuration. The list is filled in from task 2.2.

## 4. Related work

- [ ] 4.1 #4603: expire ephemeral devices on last-seen; never expire a device holding a hardware
      or source-authoritative identifier.
- [ ] 4.2 #4604: de-duplication tasks for every blocked, declined or overridden identity decision.
