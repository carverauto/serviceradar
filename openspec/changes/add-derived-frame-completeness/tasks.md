## 1. Report declined frames

- [ ] 1.1 In `FrameRunner.run/3`, deliver an error frame for each data frame past `@max_frames` instead of dropping it with `Enum.take/2`. Keep running the frames the host accepts.
- [ ] 1.2 Report the same overflow from dashboard manifest validation, using the same cap the runner enforces.
- [ ] 1.3 Add a regression test that fails while the silent `Enum.take/2` drop is still in place: a manifest with more frames than the cap yields error frames for the overflow and still returns the accepted frames.

## 2. Close-out

- [ ] 2.1 `openspec validate add-derived-frame-completeness --strict` stays green after the spec delta is edited.
- [ ] 2.2 Archive this change only after 1.1-1.3 are implemented.
