# RTSP replayer (showcase demo video)

Serves licensed drone clips as looping RTSP paths through the real product
relay. Design: `add-showcase-demo-portfolio` D8 (tasks 9.1-9.2).

## How it works

The `replayer` supervisor (Go, stdlib only) runs MediaMTX plus one ffmpeg
publisher per entry in [paths.json](paths.json):

1. List the bucket and **refuse startup** if any object falls outside
   [clips.lock.json](clips.lock.json), or if a download's SHA-256 mismatches.
2. Generate a random publish password and render the embedded MediaMTX template
   to a mode-0600 file next to the clips directory. Start MediaMTX with that file,
   wait for its RTSP port, then start one authenticated publisher per path:
   `ffmpeg -re -stream_loop -1 -i <clip> -ss <offset> -c copy -f rtsp ...`.
3. If any child exits, stop the rest and exit nonzero (Kubernetes restarts).

Readers need no credentials. Publishing requires the per-boot `replayer`
password and a loopback source address (`127.0.0.1` or `::1`). The supervisor
injects the password into every ffmpeg RTSP URL. Both stdout and stderr from
each child are forwarded to the supervisor log with a child-name prefix.
The generated config is removed when the supervisor returns.

The clip lock, six-path catalog, and MediaMTX template are embedded in the
binary; there are no runtime file overrides or permissive inventory mode.
S3 requests use the configured signing region without region discovery.

Each clip loops on two paths with different initial output offsets. Output-side
seeking preserves the full input timeline across loop wraps, with stream copy
and RTSP over TCP. Because `-re` reads the input in real time, the first frame
arrives roughly the offset in seconds after publisher startup, plus any wait
for a keyframe: up to about 55.5 seconds for `drone-surf-b`. This startup delay
is acceptable for the long-running demo. Once started, paired publishers may
show the same clip position at the same time.

## Clips

All footage is aerial/drone perspective with detectable content (vehicles,
machinery, people, infrastructure), transcoded once to H.264 with no
B-frames because the agent relay is H.264-only. Originals live on
Wikimedia Commons; transcodes live in the Linode bucket
`serviceradar-demo-drone-clips`, never in git.

| clip | content | license | author | source |
| --- | --- | --- | --- | --- |
| highway-401 | Highway 401 overpasses at sunset, traffic | CC BY 2.0 | InOldNews / Katherine KY Cheng | [Commons](https://commons.wikimedia.org/wiki/File:Aerial_view_(zoom_in)_of_overpasses_crossing_over_Highway_401_during_sunset_in_Toronto,_Canada..webm) |
| quarry-excavators | Quarry with excavators and haul trucks | CC0 1.0 | Bellergy | [Commons](https://commons.wikimedia.org/wiki/File:Miejscu-pracy-koparka-budowlanych-3741.webm) |
| tamarama-surf | Drone over body surfers, Tamarama | CC BY 3.0 | Poseidon's Reach | [Commons](https://commons.wikimedia.org/wiki/File:Drone_video_of_people_in_water_-_body_surfing_(East_Sydney_at_Tamarama).webm) |

CC BY clips require attribution: credit author + license wherever demo
footage is shown or described. `clips.lock.json` records key, sha256,
duration, resolution, license and source per clip.

Transcode recipe (ffmpeg 8.x, `-bf 0` is the requirement; GOP 60 keeps
stream joins under ~2 s):

```sh
ffmpeg -i <original> -c:v libx264 -preset slow -crf 20 -bf 0 -g 60 \
  -pix_fmt yuv420p -an -movflags +faststart <clip>.mp4
# quarry only: scale the 4K original down with -vf scale=1920:1080
```

## Build

```sh
bazel test --config=remote //demo/rtsp-replayer:replayer_test
bazel build --config=remote //demo/rtsp-replayer:image   # multiarch index
bazel run //demo/rtsp-replayer:image_push                # :latest, note digest
```

(`image_push` must run without `--config=remote`: the push runner needs a
host jq, and the remote config resolves the Linux one.)

Pinned third-party artifacts (MODULE.bazel `http_file`):

- MediaMTX v1.21.1 (MIT), linux amd64 + arm64
- Static ffmpeg 7.0.2 (GPLv3; `GPLv3.txt` ships in the image layer),
  linux amd64 + arm64

## Deploy (demo namespace)

The Deployment lives in `carverauto/gitops` (demo namespace); the bucket-read
credential is a Kubernetes Secret, which is acceptable here because the
replayer is demo infrastructure, not a monitored device (D8).

Secret (values from the maintainer; never commit):

```yaml
apiVersion: v1
kind: Secret
metadata:
  {name: rtsp-replayer-obj, namespace: demo}
type: Opaque
stringData:
  access-key: <read-only key for serviceradar-demo-drone-clips>
  secret-key: <read-only secret>
```

Container env (Secret mounted at `/etc/replayer-secret`):

| var | value |
| --- | --- |
| REPLAYER_S3_ENDPOINT | https://us-ord-10.linodeobjects.com |
| REPLAYER_S3_BUCKET | serviceradar-demo-drone-clips |
| REPLAYER_S3_REGION | us-ord |
| REPLAYER_S3_ACCESS_KEY_FILE | /etc/replayer-secret/access-key |
| REPLAYER_S3_SECRET_KEY_FILE | /etc/replayer-secret/secret-key |

`REPLAYER_S3_REGION` defaults to `us-ord`. `REPLAYER_CLIPS_DIR` defaults to
`/var/lib/replayer/clips`; its parent must also be writable for the generated
config. Publishers always connect to `rtsp://127.0.0.1:8554`.
`REPLAYER_MEDIAMTX_BIN` and `REPLAYER_FFMPEG_BIN`
default to the corresponding binaries under `/usr/local/bin`.

Port: 8554/tcp (RTSP over TCP only). Use TCP probes on 8554. Mount an
`emptyDir` at `/var/lib/replayer` so container restarts skip the clip
re-download and the supervisor can write its config beside `clips/`.
Deploy the image **by digest** from the push output, not
`:latest`.

## Verify

```sh
# Paths serve H.264 with no B-frames:
for p in drone-highway drone-highway-b drone-quarry drone-quarry-b \
         drone-surf drone-surf-b; do
  ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_name,has_b_frames \
    -of default=noprint_wrappers=1 rtsp://<host>:8554/$p
done
```

Then verify a relay session to one replayer path plays through web-ng
(`/cameras` or the drone multiview once the `drone-fleet` plugin lands).
