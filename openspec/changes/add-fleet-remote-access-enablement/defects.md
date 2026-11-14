# Existing defects found while writing this proposal

These are defects in behaviour or documentation that already ships. They are not the
new capability, and each can be fixed without it. They are listed so they can be filed
and fixed on their own.

`E/` is `elixir/serviceradar_core/lib/serviceradar/edge/`; `C/` is
`elixir/serviceradar_core/lib/serviceradar/credentials/`; `W/` is `elixir/web-ng/`;
`R/` is the public repository `carverauto/serviceradar-ansible` at `origin/main`.
"Verified" means the lines were read for this proposal. "Reported" means a survey found
it and the fixer must re-read before acting. "Inferred" means the cause follows from
the code's shape and needs a reproducing test. No live system was inspected.

## SSH certificate access

| # | Defect | Pointers | Status |
| --- | --- | --- | --- |
| 1 | **A hostname or IP policy key grants every device that shares it.** The per-device policy entry is found by trying the device UID, then its hostname, then its IP, against the same `targets` map. Hostnames and private addresses repeat across sites, so an entry written for one host applies to its namesakes. Fix without the proposal: accept UID keys only and log the ignored keys. | `E/remote_access_sessions.ex:1112-1120` | Verified. |
| 2 | **The console tells operators to do something no surface offers.** The recourse text says an operator must grant the device a certificate-policy account; the policy can only be changed by replacing a Secret and restarting web-ng. | `W/assets/component/src/RemoteAccessSSHConsole.jsx:21-26`; `W/config/runtime.exs:791-805` | Verified. |
| 3 | **The documentation and the console say the ephemeral private key stays in tab memory; it is sent to the control plane and the agent.** The attach credential always includes `private_key`, the generated key is assigned to it in certificate mode, and the agent needs the key to use the certificate. The statement should say the key is generated per session, is never stored, and is transmitted inside the attach credential. | `docs/docs/remote-access.md:71`; `W/assets/component/src/RemoteAccessSSHConsole.jsx:47-51`, `:961`, `:975`, `:1054`, `:1294`; `go/pkg/agent/remoteaccess/ssh.go:61` | Verified. |
| 4 | **Sessions stay in `closing`.** When the browser disconnects, the stream handler asks the broker to close and then calls `request_close`, which moves the session to `closing`. The broker's close handler does the same transition and stops. Nothing afterwards performs `close`, and `expire` is not allowed from `closing`, so the row never reaches a terminal state. | `W/lib/serviceradar_web_ng_web/channels/remote_access_stream_handler.ex:295-306`; `E/remote_access_broker.ex:265-276`, `:484-507`; `E/remote_access_session.ex:63-66` | Fixed: the broker's `close/2` and `terminate/2`, and the stream handler when the broker is already gone, now complete `close`; `expire` is allowed from `closing`; `RemoteAccessSessionReaperWorker` expires stale non-terminal rows every 5 minutes. |
| 5 | **A failed SSH handshake reaches the user as the library's error text.** The agent returns the connection error unclassified, so a host that does not trust the CA shows "unable to authenticate, attempted methods [none publickey]". Host-key failures are already classified in the same package; authentication and dial failures can be classified the same way now. | `go/pkg/agent/remoteaccess/ssh.go:311-315`; `go/pkg/agent/remoteaccess/ssh_host_key.go:65-90` | Verified (return path); the displayed string was reported. |
| 6 | **The public role defaults a personal account name.** `fleet_ssh_user` defaults to one person's login, and the role README repeats it, so anyone who runs the role without overriding it creates that account on their hosts. | `R/roles/fleet_ssh_enroll/defaults/main.yml:22`; `R/roles/fleet_ssh_enroll/README.md:6` | Reported. |
| 7 | **Published documentation uses a personal account name and an address outside the documentation ranges in its examples.** Examples should use an invented account and `192.0.2.0/24`. Whether the address was taken from a running system was not established. | `docs/docs/remote-access.md:260`, `:281`, `:364-365`, `:371`, `:387`, `:436-450`, `:474` | Verified (presence). |
| 8 | **The documentation describes an on-host layout that neither role writes.** It uses the newer role's directory with the older role's drop-in name and an extra directive. A host configured from the documentation is rejected by the newer role's preflight as unmanaged. | `docs/docs/remote-access.md:316-366`; `R/roles/remote_access_ssh_ca/tasks/preflight.yml:274-286` | Verified (documentation); role reported. |
| 9 | **Host-key records are not moved when devices merge.** The merge reassigns many device references; remote-access host keys, which carry `device_uid`, are not among them. | `.../inventory/identity/reassignments.ex:23-306`; `E/remote_access_host_key.ex:164` | Inferred from absence in that module. |
| 10 | **The newer role states that it excludes hypervisors and control-plane hosts, but nothing inspects the host.** The only gate is a constant that the caller does not vary. | `R/roles/remote_access_ssh_ca/tasks/main.yml:9`; `R/roles/remote_access_ssh_ca/defaults/main.yml:42-43` | Reported. |
| 11 | **The public content's declared Ansible version and its execution environment disagree.** | `R/meta/runtime.yml:2`; `R/README.md:110-112` | Reported. |

## Proxmox console

| # | Defect | Pointers | Status |
| --- | --- | --- | --- |
| 12 | **Every reason a rule does not apply is reported as "No scoped console credential rule matched this device".** The four per-rule checks (purpose, integration and controller, actor, target) are combined with `and` inside a search, so the specific error each returns is discarded. | `E/proxmox_console_sessions.ex:297-334`, `:345-350`; `W/lib/serviceradar_web_ng_web/live/proxmox_console_live/show.ex:164` | Fixed: the nearest candidate rule's specific denial is returned and shown, with rule detail for credential managers. |
| 13 | **Installing an agent on a PVE node breaks consoles under a rule scoped to the API-polling agent.** Rules are looked up by the host device's own agent, and the preview used to test the target drops any row whose agent differs from an agent-scoped rule's agent. Once the node runs its own agent, the host device no longer appears in the rule's rows. | `E/proxmox_console_sessions.ex:1045-1067`, `:444-464`; `C/network_credential_rule_preview.ex:106-113` | Verified (code path); the symptom was reported. |
| 14 | **Whether a rule targets a device is decided from a 5,000-row sample.** A host outside the sample is refused although the rule's query matches it. | `E/proxmox_console_sessions.ex:447-449` | Verified. |
| 15 | **`metadata.proxmox_cluster` is read and never written.** The only product reference is a fallback when building a device row's `cluster` field, so a rule query that relies on it matches only where someone set it by hand. | `.../plugins/plugin_input_payload_builder.ex:186-191` | Verified (single reader, no writer found by search); effect on rule matching reported. |
| 16 | **The documentation does not name the PVE privileges a console credential needs.** | `docs/docs/proxmox.md:385` | Verified. |

Items 1, 3, 4, 6, 12 and 13 are the ones named in the request for this proposal.
Items 12 to 14 are removed by the proposal's console requirements but can be fixed
first: return the first failing check of the nearest rule, look rules up by the agent
that holds the controller's assignment, and test one device with a query bounded to
its UID.
