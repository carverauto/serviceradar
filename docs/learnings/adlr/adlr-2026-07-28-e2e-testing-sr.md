
# [ADLR]: End to End Integration testing with BB     
* Date: July/28 2026
* Author: Marvin Hansen
* Contact: marvin.hansen@gmail.com

## Abstract   
   
-- Short summary here 
   
## Driving Event   
   
On July 27, PR #4738 introduced the first E2E integration test for the Rust source tree as part of the added DGraph Rust client. It as was expected that CI will fail because the underlying MicroVM stack required to run the DGraph container was never configured in BuildBuddy (BB). However, configuring  firecracker required for the MicroVM stack has proven complex and error prone.  

The subsequent investigation reveled multiple complex causes, but was hindered by a perplexing lack of diagnostic. Later, it was identified that the diagnostic was fixed in BB months prior, but the BB image was never updated. 

   
## Process    

Stage 1: Test configuration. 
The Integration test re-used a known-good config for Docker dependent integration tests in combination with the known to be working DockerUtils. This was confirmed with a local execution against OrbStack (Docker alternative on Mac) and, locally, the test executed as expected. 

Stage 2: KVM kernel panic 
CI failed as expected. However, the reported KVM kernel panic implied some potential issue with low storage. That has proven false, but it took some time to identify. The diagnostic from the DockerUtils correctly reported the docker deamon missing. A BB support engineer confirmed that Docker needs to be installed in the executor image. 

Stage 3: Executor image
Upon further investigation, the custom BB executor image exhibited a number of secondary issues e.g. a full CNPG installation that wasn’t used anywhere, a Rust compiler that was unnecessary because Bazel provides toolchains and the absence of Docker. 
Once the unnecessary parts were removed, Docker installed, and verified, the Executor image reduced from ~5GB to ~2.5GB in size. 

Stage 4: Docker failure 
Once the executor was providing Docker and the k8s deployment was configured, the E2E integration test started failing because somehow the Docker Deamon terminated during init. Eventually, it was discovered that the allocated memory wasn’t enough and Docker ran Out of Memory (OOM). Once the memory settings in the BB Helm chart were adjusted to 2GB, Docker started correctly, but the test was failing. 

Stage 5: Docker Networking blocked  
Once docker started, the test failure pointed at the connection ports being unreachable. As it turned out, the Ubuntu 24.04 image has switched to a modern firewall that requires Docker to configure a network bridge during startup, but somehow that caused some errors resulting in Docker ports being blocked. Switching back to the legacy firewall resulted in different errors. 
In the end, DockerUtils were patched to support host mode in Docker that does not require any network bridge or firewall configuration. It is unknown if this is BB issue that was resolved in the updated image or something else. 

Stage 6: Test failure. 
Once Docker was starting correctly, diagnostic ran short and extensive debugging was added to the actual test. That revealed that the required DGraph container ran out of memory too. Once the test requested 4GB of memory, DGraph started and the integration test passed on the CI on July 29. 

Stage 7: Resolution:
1) BB executor image was updated to latest version
2) Test Bazel config was updated to request 4GB of memory
3) Test was updated to use host mode for networking 
4) DockerUtils were updated with host networking 
5) DockerUtils are still updated to add more detailed diagnostic capabilities. New release is pending.  

Claude Opus 5 was instrumental in the identification of the root cause and subsequent resolution. However, Claude was only effective after it found the full BB code repository on disk and matched config flags from the helm chart to the actual code processing those flags. 

Observations: 
- BB’s MicroVM is barely documented and most of the critical settings and flags were retrieved from the BB source code. 
- The KVM Kernel panic obfuscated the real cause, missing docker, because the BB image was 10 months outdated and contained a bug that truncated the error log. The exact bug was a log allocation of 12kb that dropped everything after it, and that is were the docker diagnostic got lost. The patch that landed later increased the log allocation to 128KB. This would have caught both, the missing docker and the docker OOM. 
- The test OOM was actually a known BB issue. However, somehow the diagnostic didn’t show up until detailed debugging was added to the test, the issue remained unidentified for some time. The DockerUtils have debug flags, but lacked docker instrument capabilities to catch OOMs. 

## Identified root cause(s)

1) Outdated BB image that contained a bug that dropped critical diagnostic. The underlying root cause was a failure to continuously update critical container images. 

2) DockerUtils could not instrument docker for detailed diagnostic. The debug facility was too shallow to identify issues with docker itself and could not capture OOM’s of containers. This was never added because prior usage of DockerUtils did not encountered a failing docker or tests running OOM. 

   
## Lesson(s) Learned  

L1: Outdated container images cause tangible damage. Updating to the latest image might be the best option before deeper investigation starts. 
L2: Detailed diagnostic remains paramount 
L3: Increasing memory for E2E with large containers might be the first action before deeper investigation. 

When debugging interaction between multiple systems, clone the repo  of all involved systems and give the Ai agent full access to the code so it can pinpoint the exact code involved in the interaction. 
   
## Recommendation(s)   
   
Continuously update all container images and all dependencies. 

Recommended full repo update schedule: Once per week!

Rationale: Frequent smaller changes result in less severe issued than late major updates that backfill months of updates with potentially breaking changes.  
   
## Related resources:    
   
PR 4738
https://code.carverauto.dev/carverauto/serviceradar/pulls/4738
   
