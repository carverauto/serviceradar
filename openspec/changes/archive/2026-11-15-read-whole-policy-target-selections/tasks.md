## 1. Implementation
- [x] 1.1 `SRQLInputResolver.resolve/2` reads every page of each input through `reduce_pages/4`.
- [x] 1.2 Move the paged `in:agents` uid tie-break into `reduce_pages/4`.

## 2. Verification
- [x] 2.1 Resolver: a selection larger than one SRQL page is returned whole; agent selections page in uid order.
- [x] 2.2 Credential rule reconcile: every target of a selection larger than one page is assigned.
- [x] 2.3 Target policy: an inputs edit keeps every agent the query still selects; the preview counts every device and agent.
- [x] 2.4 Producer schedules: target-query dispatch reaches agents past the first page; `target_input` reports the whole total.
- [x] 2.5 Credential rule preview and dry run report the whole selection's total beside a bounded sample.
