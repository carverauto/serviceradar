## 1. Implementation
- [ ] 1.1 Fix SRQL.Builder filter pipeline to preserve list tokens before appending sort/limit.
- [ ] 1.2 Add unit tests covering default SRQL builder output for devices and logs (sort + limit present).
- [ ] 1.3 Add regression test ensuring filters do not break sort token assembly.
- [ ] 1.4 Run `openspec validate fix-srql-builder-sort-error --strict`.
