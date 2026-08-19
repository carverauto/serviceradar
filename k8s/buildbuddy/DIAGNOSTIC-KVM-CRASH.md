# BuildBuddy: a missing `docker` binary reports as a kernel panic

> Dormant as of 2026-08-19: no executor fleet sets `enable_firecracker`, so nothing
> here can be hit today. Kept because it is the record of why the image is pinned to
> `enterprise-v2.290.0`, which still applies, and it is what to read first if
> firecracker is ever restored (see the note in `values.yaml`).

Verified against `buildbuddy-io/buildbuddy` at `57ab95e5` (2026-07-28) and against the tag
we deployed when this was diagnosed, `enterprise-v2.206.0` (= `fc4d95d19`, 2025-10-01) -
since replaced, see "Action for this repository". Every file:line below
was read from those trees.

## Symptom

An action with `test.workload-isolation-type: firecracker` and `test.init-dockerd: true`,
run on an action image that does not ship Docker CE, fails as:

```
ERROR ... failed to connect to VM: context deadline exceeded
```

accompanied by a kernel panic in the VM log. Nothing in the surfaced error mentions Docker.
Diagnosing it took two days. The actual reason is one sentence the guest had already
computed:

```
exec: "docker": executable file not found in $PATH
```

## The premise to correct first

The natural assumption is that `dockerd` is started without checking whether it exists. That
is not what happens - the check is there and it is correct:

```go
// enterprise/server/cmd/goinit/main.go:174-181
func startDockerd(ctx context.Context) error {
	// Make sure we can locate both docker and dockerd.
	if _, err := exec.LookPath("docker"); err != nil {
		return err
	}
	if _, err := exec.LookPath("dockerd"); err != nil {
		return err
	}
```

This is not a missing-validation bug. It is a reporting bug: a correctly detected,
perfectly actionable configuration error is routed through a channel that can destroy it.

## Why the message disappeared, on the version we run

1. `startDockerd` returns `exec: "docker": executable file not found in $PATH`.

2. The caller hands it to `die`:

   ```go
   // main.go:452-454
   if *initDockerd {
   	die(startDockerd(ctx))
   }
   ```

3. `die` is `log.Fatalf`, and its comment already flags how fragile the next step is:

   ```go
   // main.go:70-76
   func die(err error) {
   	if err != nil {
   		// NOTE: do not change this "die: " prefix. We rely on it to parse the fatal
   		// error from the firecracker machine logs and return it back to the user.
   		log.Fatalf("die: %s", err)
   	}
   }
   ```

4. `log.Fatalf` ends in `os.Exit(1)` (`server/util/log/log.go:580-587`). `goinit` is **PID 1**
   in the microVM, so PID 1 exiting is a kernel panic (`Attempted to kill init!`), and the
   guest boots with `panic=1` (`firecracker.go:1684`) so the kernel then reboots. A missing
   package has become a crashed virtual machine.

5. The host recovers the message by scanning the VM log tail for the `die: ` marker
   (`firecracker.go:3492-3505`), and that tail is a circular buffer - the same buffer the
   panic is writing into.

**On `enterprise-v2.206.0`, the buffer we ran with was 12 KB:**

```go
// v2.206.0 firecracker.go:156
vmLogTailBufSize = 1024 * 12 // 12 KB
```

A kernel panic dump plus the reboot that follows comfortably exceeds that, so the one line
that explains the failure is evicted by the noise the failure produces, and the operator is
left with `context deadline exceeded`.

## Most of this is already fixed upstream - we are just behind

This is the main finding, and it changes the action from "write a patch" to "upgrade":

| Fix | Commit | Date | In `v2.206.0`? |
|---|---|---|---|
| VM log tail buffer 12 KB -> 128 KB | `ecf5e118` (#11901) | 2026-04-16 | **NO** |
| Include the VM log in the dial error | `9f01f4ed` (#8559) | 2025-03-06 | YES |

```go
// firecracker.go:160 at HEAD
vmLogTailBufSize = 1024 * 128 // 128 KB
```

So our executor already appends `. vmlog: %s` to the dial failure - it just truncates to the
last 12 KB, which is precisely the window the panic floods. Upstream widened that window by
10x three months ago.

**Action for this repository: DONE.** `values.yaml` now pins
`enterprise-v2.290.0` (`983eb596b`, 2026-07-28), verified to contain `ecf5e118`:

```
$ git show v2.290.0:enterprise/.../firecracker.go | grep vmLogTailBufSize
160:  vmLogTailBufSize = 1024 * 128 // 128 KB

$ crane ls gcr.io/flame-public/buildbuddy-executor-enterprise | grep enterprise-v2.290.0
enterprise-v2.290.0
```

No patch of ours is required for the buffer problem; do not write one.

That is a jump of 84 releases and roughly ten months (2025-10-01 -> 2026-07-28), so treat
the first deploy as a change worth watching rather than a routine tag bump: apply it,
confirm the executors register with the scheduler, and run the dgraph acceptance suite
before assuming it is clean. The chart is pulled fresh from `https://helm.buildbuddy.io` by
`deploy.sh` and is not pinned, so chart-side schema changes over that range
land at the same time as the image.

Note also that `parseFatalInitError` was refactored from a method into a free function
taking the tail (`firecracker.go:3492`), so any patch written against the older shape will
not apply.

## What is still worth upstreaming at HEAD

Three items survive the version bump. The first is a plain bug.

### Patch 1 - an unchecked write, and it is the only one in the file

```go
// main.go:183-190
dockerdDaemonJSON, err := firecrackerutil.FetchMMDSKey("dockerd_daemon_json")
if err != nil {
	return err
}
if err := mkdirp("/etc/docker", 0755); err != nil {
	return err
}
os.WriteFile("/etc/docker/daemon.json", dockerdDaemonJSON, 0644)   // <- error discarded
```

Every other `os.WriteFile` in this file is checked - `die(...)`-wrapped at lines 361, 368 and
390, and `if err := ...` at 401. Line 190 is the only one that is not, which makes it an
oversight rather than a convention.

The consequence is quiet: if the write fails, `dockerd` starts anyway with a stale or absent
`daemon.json`, so the daemon silently runs with different configuration than the executor
asked for. That surfaces later as inexplicable behaviour differences - the registry mirror
is ignored, say - with nothing anywhere connecting it to a failed write.

```go
if err := os.WriteFile("/etc/docker/daemon.json", dockerdDaemonJSON, 0644); err != nil {
	return status.InternalErrorf("write /etc/docker/daemon.json: %s", err)
}
```

### Patch 2 - say what the operator has to change

`exec: "docker": executable file not found in $PATH` is accurate and nearly useless to
someone who has never heard of `goinit`. It does not say that a platform property asked for
Docker, and it does not say that the missing binary belongs to the **action's container
image** rather than to the executor - which is the single most important fact, because it
tells you which Dockerfile to edit.

```go
// main.go:174-181
func startDockerd(ctx context.Context) error {
	// Make sure we can locate both docker and dockerd. Both come from the action's
	// container image, not from the executor, so a missing binary means the image is
	// not equipped for the isolation type the action asked for.
	for _, bin := range []string{"docker", "dockerd"} {
		if _, err := exec.LookPath(bin); err != nil {
			return status.FailedPreconditionErrorf(
				"init-dockerd was requested but %q was not found in the VM image (PATH=%s). "+
					"Install Docker in the action's container-image, or remove the "+
					"init-dockerd platform property: %s",
				bin, os.Getenv("PATH"), err)
		}
	}
	...
}
```

Including `PATH` is deliberate: `goinit` sets it explicitly rather than inheriting it, so an
operator whose image does ship Docker somewhere unusual can see at once why it was not found.

This patch is worth more than it looks. It is the one change that would have ended the
two-day search on the first run, because it makes the message self-explanatory even when it
arrives buried in a kernel panic dump.

### Patch 3 - a tightening, while in the area

```go
// firecracker.go:3500
if m := fatalErrPattern.FindStringSubmatch(line); len(m) >= 1 {
	return status.UnavailableErrorf("Firecracker VM crashed: %s", m[1])
}
```

`fatalErrPattern` has one capture group, so `FindStringSubmatch` returns either `nil` or a
slice of length 2. `len(m) >= 1` therefore happens to be correct, but it reads as though
`m[1]` might not exist and is indexed unconditionally on the very next line. `len(m) >= 2`
states the actual requirement.

### Design note - a preflight failure should not be a kernel panic

Not a patch, but the reason this class of bug keeps costing days.

`startDockerd` failing is knowable before any workload runs, and the answer is a fixed
string. Routing it through "kill PID 1 -> panic the kernel -> hope the marker survives a
circular buffer that the panic is flooding -> hope the host's dial fails in the one way that
reaches the parser" gives four independent places to lose a message that never had to leave
userspace.

Worth noting the *other* dockerd failure has the same weakness by a different route:
`waitForDockerd` returning `docker init timed out after 30s` makes `runVMExecServer` return
before `server.Serve(listener)` is ever reached, so that message does not get to the host
either - the guest simply stops answering.

Serving the error would be strictly better than dying with it: the guest already has a
working channel to the host in the vmexec gRPC server, and a typed `FailedPrecondition`
needs no log scraping at all. That is a larger change and is listed separately so patches
1-3 are not blocked on it.

## Tests

Patch 1 is the one that needs a regression test, and it does not need a VM:

```go
func TestStartDockerdReportsUnwritableDaemonJSON(t *testing.T) {
	// /etc/docker exists as a *file*, so the daemon.json write cannot succeed.
	// Before the fix this returned nil and dockerd started misconfigured.
	...
	err := startDockerd(ctx)
	require.Error(t, err)
	require.Contains(t, err.Error(), "daemon.json")
}
```

Patch 2 is assertable on the message contract, which is the part that matters:

```go
func TestStartDockerdNamesTheMissingBinaryAndTheProperty(t *testing.T) {
	t.Setenv("PATH", t.TempDir()) // no docker, no dockerd

	err := startDockerd(context.Background())

	require.Error(t, err)
	assert.True(t, status.IsFailedPreconditionError(err))
	assert.Contains(t, err.Error(), "docker")
	// The operator has to know WHICH image to fix; without this the message sends
	// people to the executor image, which is not where the binary belongs.
	assert.Contains(t, err.Error(), "container-image")
	assert.Contains(t, err.Error(), "init-dockerd")
}
```

## Reproducing

1. Build an action image without Docker CE - on a Debian/Ubuntu base, simply omit
   `docker-ce docker-ce-cli containerd.io`.
2. Run any action with:

   ```
   exec_properties = {
       "test.workload-isolation-type": "firecracker",
       "test.init-dockerd": "true",
   }
   ```
3. On an executor at `v2.206.0`, observe `failed to connect to VM: context deadline
   exceeded` with a truncated 12 KB vmlog and no mention of Docker.
4. On an executor containing `ecf5e118`, the same run should surface
   `Firecracker VM crashed: exec: "docker": executable file not found in $PATH`, because the
   128 KB tail now retains the `die: ` line past the panic dump.

Step 4 is the check to run before filing anything upstream about the buffer: if it passes,
the only outstanding items are patches 1-3.
