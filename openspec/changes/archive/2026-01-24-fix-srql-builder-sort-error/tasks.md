## 1. Implementation
- [x] 1.1 Fix SRQL.Builder filter pipeline to preserve list tokens before appending sort/limit.
- [x] 1.2 Add unit tests covering default SRQL builder output for devices and logs (sort + limit present).
- [x] 1.3 Add regression test ensuring filters do not break sort token assembly.
- [x] 1.4 Run `openspec validate fix-srql-builder-sort-error --strict`.
