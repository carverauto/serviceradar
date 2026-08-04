"""Remote-execution task sizing for targets whose link step needs a large worker.

Why this is not written inline at each target
---------------------------------------------
These are scheduling hints. They tell the BuildBuddy executor how much CPU and
memory to reserve; they are not inputs to the compile or link action, so changing
one cannot change a single byte of the produced binary.

`scripts/check-native-addon-version-bumps.sh` cannot know that. It decides an
add-on's payload changed by matching changed paths against that add-on's source
directories, which include its `BUILD.bazel`. So tuning a memory hint inline made
the gate demand a version bump for five add-ons whose artifacts were identical --
and the only ways out were to publish five byte-identical versions or to weaken
the gate into something that could miss a real change.

Keeping the values here means the next tuning pass edits one file that belongs to
no add-on, and the gate stays quiet without being made less strict.

When a target needs this
------------------------
Add it when a link step OOMs on a default-sized worker, not pre-emptively. A
larger task reserves more of the executor pool, so over-applying it serialises
the build. Current users are the Rust add-ons whose final link pulls in aws-lc /
ring / zstd, and the Go agent, whose pure-Go GoLink is large.
"""

# ~2.5Gi default microVM memory OOMs these links (observed as `signal: killed`).
NATIVE_ADDON_EXEC_PROPERTIES = {
    "EstimatedCPU": "4",
    "EstimatedMemory": "8Gi",
}
