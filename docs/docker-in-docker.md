# Running Docker inside the agent box: which approaches are safe?

## Purpose

The `ai-agent-box` images ship the `docker` **client** only and document
Docker-outside-of-Docker (mounting the host socket) as a last resort, because
that mount is equivalent to root on the Docker host (see README, "Never mount /
never pass"). This document researches the alternatives: how an agent running
in one of these images can build and run containers **without** being handed
the host daemon.

It compares seven approaches, states what each one actually costs in
privileges, and records which ones were verified on this workstation and how.
It does not change any image; it is input for that decision.

## Test environment for every "verified" claim below

| Property              | Value                                                                                                  |
|-----------------------|--------------------------------------------------------------------------------------------------------|
| Host                  | macOS + Docker Desktop (containers run inside Desktop's Linux VM)                                      |
| Engine                | `29.7.2`, `linux/arm64`                                                                                |
| Host security options | `seccomp` (builtin profile), `cgroupns`; **no AppArmor, no SELinux**                                   |
| Images probed         | `docker:29-dind`, `docker:29-dind-rootless` (Docker 29.8.0), `docker:29-cli`, `moby/buildkit:rootless` |

Two consequences for reading the results:

- `--security-opt apparmor=unconfined` is a **no-op here**. On a native-Linux
  host with AppArmor (Ubuntu/Debian default) it is not, and the rootless
  results below must be re-verified there before being relied on.
- An escape from any of these containers lands in Docker Desktop's VM, not on
  macOS. On native Linux it lands on the host kernel.

## Terms

- **DooD (Docker-outside-of-Docker)** — bind-mount the host's
  `/var/run/docker.sock` into the container and use the host daemon. No nested
  daemon exists; "sibling" containers are created on the host.
- **DinD (Docker-in-Docker)** — run a second `dockerd` inside a container.
  Rootful DinD = that daemon runs as root and needs `--privileged`.
- **Rootless DinD** — the nested `dockerd` runs as an unprivileged user inside
  the container, using `rootlesskit` + a user namespace + `slirp4netns` +
  `fuse-overlayfs`.
- **Sidecar DinD** — the nested daemon lives in its own container; the agent
  container only holds the CLI and points `DOCKER_HOST` at it.
- **Sysbox** — a `runc` replacement (`--runtime=sysbox-runc`) that makes a
  container VM-like so an *unmodified* rootful `dockerd` runs inside it without
  `--privileged`. Requires installing a runtime **on the host**.
- **Daemonless builders** — BuildKit rootless, Buildah, Kaniko: they build OCI
  images without any Docker daemon. They cannot *run* containers.

## The seven options at a glance

| # | Approach                                     | Host daemon exposed? | `--privileged`?         | Can run containers? | Status here                                                             |
|---|----------------------------------------------|----------------------|-------------------------|---------------------|-------------------------------------------------------------------------|
| 1 | DooD: mount `/var/run/docker.sock`           | **Yes — full root**  | no                      | yes                 | works; already documented, discouraged                                  |
| 2 | DooD through a filtering socket proxy        | partially            | no (proxy needs socket) | yes                 | not a boundary against a hostile agent                                  |
| 3 | Rootful DinD (`docker:dind`, `--privileged`) | no                   | **yes**                 | yes                 | **verified working**                                                    |
| 4 | Rootless DinD **with** `--privileged`        | no                   | **yes**                 | yes                 | **verified working**                                                    |
| 5 | Rootless DinD **without** `--privileged`     | no                   | **no**                  | yes                 | **verified working** (needs 3 `--security-opt` relaxations + 2 devices) |
| 6 | Sysbox runtime on the host                   | no                   | no                      | yes                 | not testable on macOS/Docker Desktop                                    |
| 7 | Rootless BuildKit / Buildah / Kaniko         | no                   | no                      | **no — build only** | **verified working** (BuildKit)                                         |

## Option 1 — DooD (mount the host socket)

This is what the images support today: `docker-cli` is installed, and
`ensure_docker_access`/`advise_docker_socket_nonroot` in both entrypoints wire
up group access to a mounted socket.

It is the *least* safe option and the only one that cannot be made safe: any
process that can talk to the host daemon can run
`docker run -v /:/host --privileged`, i.e. own the host. Container hardening on
the agent container (`--cap-drop=ALL`, `--read-only`, seccomp) is irrelevant —
the privilege is exercised through the socket, not through the agent
container's own kernel interface.

Keep it only for the documented case: a disposable VM where the agent is
already trusted with the host.

## Option 2 — DooD through a filtering socket proxy

[`Tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy)
is HAProxy in front of the socket; environment variables (`POST`, `CONTAINERS`,
`IMAGES`, `EXEC`, …) allow or deny API prefixes, returning `403` otherwise.

It is a genuine improvement for *read-mostly* consumers (Traefik, Watchtower,
Dozzle). It is **not** a boundary for an agent that must build and run
containers, because that requires `POST` + `CONTAINERS` + `IMAGES` + `BUILD` —
and `POST /containers/create` with a bind mount of `/` is game over. The filter
is coarse (path prefixes, not request bodies), so it cannot express "create
containers, but never mount the host filesystem". The proxy has also had its own
access-control CVE (CVE-2026-78122), which is the expected failure mode for a
prefix-matching filter in front of a root-equivalent API.

Verdict: useful for narrow read-only integrations, wrong tool for this repo.

## Option 3 — Rootful DinD with `--privileged`

The classic `docker:dind` recipe: a nested root `dockerd` in a privileged
container. Verified working here:

```bash
docker run -d --name dind --privileged -e DOCKER_TLS_CERTDIR= docker:29-dind
docker exec dind docker info --format '{{.ServerVersion}}'   # -> 29.8.0
```

The host daemon is untouched — a real improvement over Option 1 — but
`--privileged` gives the container all capabilities, an unmasked `/proc`, all
devices, and no seccomp/AppArmor confinement. On a shared-kernel host that is
one kernel bug away from host root, and it directly contradicts this repo's
"never pass `--privileged`" rule. Use it only if Option 5 is unavailable and
the host is disposable.

## Option 4 — Rootless DinD with `--privileged`

`docker:29-dind-rootless` runs `dockerd` as uid 1000 under `rootlesskit`.
Verified working here:

```bash
docker run -d --name dindr --privileged -e DOCKER_TLS_CERTDIR= docker:29-dind-rootless
docker exec -e DOCKER_HOST=unix:///run/user/1000/docker.sock dindr \
  docker run --rm alpine:3 echo INNER-RUN-OK      # -> INNER-RUN-OK
```

Note the socket path: the rootless daemon listens on
`unix:///run/user/1000/docker.sock`, **not** `/var/run/docker.sock`. A probe
that checks the wrong path reports a healthy daemon as dead.

This is strictly better than Option 3 (the nested daemon is unprivileged inside
the container), but from the host's point of view the container is still
`--privileged`. It is a stepping stone to Option 5, not a destination.

## Option 5 — Rootless DinD **without** `--privileged` (recommended)

### The exact working invocation

Verified working here — daemon starts, pulls images, runs and builds inner
containers:

```bash
docker run -d --name dind-rootless \
  --network agentbox-net --network-alias docker \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  --security-opt systempaths=unconfined \
  --device /dev/net/tun --device /dev/fuse \
  -e DOCKER_TLS_CERTDIR= \
  -v "$PWD:/workspace" \
  docker:29-dind-rootless
```

Four of those five flags are load-bearing here; each was established by
bisection, not copied:

| Flag                                    | Removing it produces                                                                                                                                                                                                                                                                                                             |
|-----------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--security-opt seccomp=unconfined`     | `[rootlesskit:parent] error: failed to start the child: fork/exec /proc/self/exe: operation not permitted` — the default profile blocks `clone(CLONE_NEWUSER)`                                                                                                                                                                   |
| `--device /dev/net/tun`                 | `setting up tap tap0: … ip tuntap add name tap0 mode tap: exit status 1` — `slirp4netns` cannot create its tap device                                                                                                                                                                                                            |
| `--security-opt systempaths=unconfined` | daemon starts and pulls images, but every inner container fails with `error mounting "proc" to rootfs at "/proc": operation not permitted` (Docker's masked `/proc` paths are not remountable from the nested userns)                                                                                                            |
| `--device /dev/fuse`                    | **nothing, on this kernel**: without it the nested daemon still came up with `storage-driver=overlayfs` (containerd snapshotter), because the kernel supports unprivileged overlayfs. Keep it anyway for older kernels, where it is what lets the daemon fall back to `fuse-overlayfs` instead of the layer-copying `vfs` driver |
| `--security-opt apparmor=unconfined`    | no effect **on this host** (no AppArmor); required on AppArmor hosts, where the default `docker-default` profile denies the nested mounts                                                                                                                                                                                        |

### What it is worth

The container runs with the host's default capability set (no `--privileged`,
no `--cap-add`), and the nested `dockerd` plus everything it starts live inside
a user namespace: root in an inner container is uid ≥ 100000 inside the
sidecar, which is an unprivileged uid on the host. What is given up is the
seccomp filter and (on Linux) the AppArmor profile for **the sidecar
container** — a real cost, but a much smaller one than `--privileged`, which
surrenders capabilities, devices, and `/proc` masking as well.

### The recommended shape for this repo: a sidecar, not a fatter image

Do **not** add `dockerd` to `ai-agent-box-*`. Keep the agent image as it is
(client only) and run the daemon in its own container:

```bash
docker network create agentbox-net

# 1. the daemon (flags exactly as above)
docker run -d --name dind-rootless --network agentbox-net --network-alias docker \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  --security-opt systempaths=unconfined \
  --device /dev/net/tun --device /dev/fuse \
  -e DOCKER_TLS_CERTDIR= \
  -v agentbox-docker-data:/home/rootless/.local/share/docker \
  -v "$PWD:/workspace" \
  docker:29-dind-rootless

# 2. the agent — no new privileges of any kind
docker run -it --rm --network agentbox-net \
  --cap-drop=ALL --security-opt=no-new-privileges \
  -e DOCKER_HOST=tcp://docker:2375 \
  -v "$PWD:/workspace" \
  ai-agent-box-opencode:local
```

Verified with `docker:29-cli` standing in for the agent image (same
`docker-cli` version the images pin, `29.8.0-r0`), under
`--cap-drop=ALL --security-opt=no-new-privileges --read-only`:

- `docker info` → `server=29.8.0`
- `docker run --rm alpine:3 echo INNER-RUN-OK` → `INNER-RUN-OK`
- `docker build` of a two-line Dockerfile → `naming to docker.io/library/p5:latest done`

The agent container keeps every hardening flag the README recommends. All the
relaxations are confined to the sidecar, which contains no agent code, no
credentials, and no `/workspace` write access it does not need.

### Caveats that will bite, all observed

- **Workspace paths must be mirrored.** `docker run -v /workspace:/w` issued by
  the agent is resolved by the **daemon**, i.e. against the sidecar's
  filesystem. It only worked in the probe because `$PWD` was bind-mounted at
  `/workspace` in *both* containers. Mount the workspace at the same path in
  the sidecar, or inner bind mounts silently see an empty directory.
  `docker build` is unaffected: the build context travels over the API.
- **`--read-only` needs `DOCKER_CONFIG`.** With a read-only rootfs and no
  writable `$HOME`, `docker build` fails with `ERROR: mkdir /root/.docker:
  read-only file system`. Setting `-e DOCKER_CONFIG=/tmp/.docker` (tmpfs) fixes
  it. The agent images have a writable `$HOME`, so this only affects
  `--read-only` invocations without a home tmpfs.
- **Plain TCP (`DOCKER_TLS_CERTDIR=`) is only acceptable on a dedicated
  network.** Anything that joins `agentbox-net` gets an unauthenticated root
  daemon. Either keep that network exclusive to the pair, or use the image's
  TLS mode (`-e DOCKER_TLS_CERTDIR=/certs` + shared `client` volume, port
  2376) — verified working through a `--internal` network in a separate probe.
- **`--internal` networks block egress.** An `--internal` network isolates the
  pair nicely, but the agent also needs to reach its model provider: attach the
  agent container to a second, normal network, or don't use `--internal`.
- **Image cache.** `/home/rootless/.local/share/docker` is a `VOLUME` in the
  image; give it a named volume or every restart re-pulls. It must not be
  shared between two running daemons.
- **Resources.** The sidecar pulls and unpacks images; apply `--memory`,
  `--cpus`, `--pids-limit` there too, and remember the volume can fill the
  host disk.
- **Kernel requirements** (native Linux): unprivileged user namespaces enabled
  (`user.max_user_namespaces` > 0, `kernel.unprivileged_userns_clone=1` on
  older Debian/Ubuntu), `/dev/net/tun` and `/dev/fuse` present. The
  `dockerd-entrypoint.sh` in the image checks all of these and fails with an
  explicit message.
- **Multi-arch builds** inside the sidecar need `binfmt_misc`, which is not
  namespaced before kernel 6.7.

## Option 6 — Sysbox (`--runtime=sysbox-runc`)

Sysbox (Nestybox, acquired by Docker in 2022; Apache-2.0, community-supported,
*not* covered by Docker subscriptions) is the cleanest answer on paper: install
it on the host, then `docker run --runtime=sysbox-runc` yields a container with
a user namespace, virtualized `procfs`/`sysfs`, and locked initial mounts, in
which a stock rootful `dockerd` runs unmodified — no `--privileged`, no socket
mount, no seccomp relaxation, and inner containers may even be privileged
without gaining host privilege.

Why it is not the recommendation here:

- It requires **installing a runtime on every host** (a `systemd` service +
  `/etc/docker/daemon.json` change). That is a heavier ask than `docker run`
  flags and is impossible on **macOS/Windows Docker Desktop**, which is this
  repo's documented primary environment — so it could not be verified here.
- Documented limitations that matter for a build/test agent: `mknod` fails,
  nested user namespaces fail (so no rootless Docker *inside* it),
  `--privileged`/`--net=host`/`--pid=host`/`--userns=host` are refused, the
  inner daemon must use the default `/var/lib/docker` data-root and must not
  use `userns-remap`.

If the target is a Linux CI fleet you control, Sysbox is worth the install and
gives a better isolation/usability trade-off than Option 5. For a laptop-first
image, Option 5 travels everywhere.

## Option 7 — Daemonless builders (BuildKit rootless, Buildah, Kaniko)

If the agent only needs to **build** images, no daemon is needed at all.
Verified here with `moby/buildkit:rootless`:

```bash
docker run -d --name bk \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  moby/buildkit:rootless --oci-worker-no-process-sandbox
docker exec bk sh -c 'mkdir -p /tmp/c && printf "FROM alpine:3\nRUN echo BUILD-STEP-OK > /x\n" > /tmp/c/Dockerfile \
  && buildctl build --frontend dockerfile.v0 --local context=/tmp/c --local dockerfile=/tmp/c'
# -> #5 [2/2] RUN echo BUILD-STEP-OK > /x   #5 DONE 0.0s
```

Notes from the probe:

- With the **default seccomp profile** it fails identically to rootless DinD
  (`fork/exec /proc/self/exe: operation not permitted`), so `seccomp=unconfined`
  is still needed; `/dev/net/tun` and `/dev/fuse` are not.
- `--oci-worker-no-process-sandbox` is what allows it to run rootless in a
  container, and it weakens the builder's own isolation: build steps can signal
  (and possibly `ptrace`) processes in the buildkitd container. Acceptable when
  the builder container is single-tenant and disposable, which is the case here.
- Buildah needs `--device /dev/fuse` and (rootful-in-container)
  `--cap-add=sys_admin,mknod`; the rootless-user variant avoids those
  capabilities. Kaniko needs no special flags but only builds, has no cache
  semantics comparable to BuildKit, and is effectively in maintenance mode.

This is the **smallest-privilege** option by a wide margin and should be
preferred whenever "run this container" is not part of the requirement — e.g.
an agent that only has to prove a Dockerfile builds.

## Recommendation

1. **Default (no change to the images):** the agent needs no container runtime
   at all. Neither image ships `dockerd` today, which is correct.
2. **If the agent must build images:** Option 7 — a rootless BuildKit sidecar.
   One relaxation (`seccomp=unconfined`) on a container that holds nothing.
3. **If the agent must build *and run* containers:** Option 5 — a rootless DinD
   sidecar with the five flags listed above, agent container unchanged and
   fully hardened, `DOCKER_HOST=tcp://docker:2375` on a dedicated network.
4. **On a Linux fleet you administer:** Option 6 (Sysbox) is a better
   engineering answer than 3/4/5 and removes the seccomp relaxation entirely.
5. **Never:** Options 1 and 2 as a security boundary. Keep the existing README
   wording — mounted socket = host root — and do not let a filtering proxy
   soften it.

## Applying Option 5 to a real invocation (`ai-agent-box-omp-java`)

Everything below was verified with the actual image (`ai-agent-box-omp-java:21`,
`docker-cli 29.8.0`) against a rootless sidecar, with the agent container
keeping `--cap-drop=ALL --security-opt=no-new-privileges --pids-limit=512`.

### 1. One-time: a user-defined network

```bash
docker network create agentbox-net
```

A user-defined bridge is required for DNS (`docker` resolves to the sidecar)
and still has normal egress — verified: `curl https://api.anthropic.com/`
from the agent container returns an HTTP status, so model traffic is
unaffected. Do **not** use `--internal`, which would cut that off.

### 2. Start the daemon sidecar (per session)

```bash
docker run -d --name agentbox-dockerd \
  --network agentbox-net --network-alias docker \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  --security-opt systempaths=unconfined \
  --device /dev/net/tun --device /dev/fuse \
  --memory=6g --cpus=4 --pids-limit=2048 \
  -e DOCKER_TLS_CERTDIR=/certs -v agentbox-certs:/certs/client \
  -v "$HOME/.ca-certificates/combined-ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro" \
  -v "$PWD:$PWD" \
  docker:29-dind-rootless
```

Three details are not optional:

- **`--network-alias docker`** (not `dockerd`): the image's auto-generated
  server certificate carries SANs `docker`, `<container-id>`, `localhost`
  only. With any other alias the client fails with
  `x509: certificate is valid for docker, …, not dockerd`. (Or set
  `-e DOCKER_TLS_SAN=DNS:yourname`.)
- **The corporate CA bundle** must be mounted into the sidecar too. The agent
  container's bundle does not help the nested daemon: registry pulls and
  `docker build`'s `FROM` are performed by the **daemon**.
- **`-v "$PWD:$PWD"`** — mounting the project at its *host path* inside the
  sidecar is what makes `docker run -v "$PWD:/x"` issued by the agent work,
  because inner bind mounts are resolved by the daemon. Verified: the inner
  container sees the real project files. Restart the sidecar when you switch
  projects, or mount a stable parent (`-v "$HOME/DEV:$HOME/DEV"`) once.

### 3. The agent command — three additions

```bash
docker run -it --rm \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --pids-limit=512 \
    --network agentbox-net \
    -e DOCKER_HOST=tcp://docker:2376 \
    -e DOCKER_TLS_VERIFY=1 \
    -e DOCKER_CERT_PATH=/certs/client \
    -v agentbox-certs:/certs/client:ro \
    -v "$HOME/.omp/agent:/home/ai-agent-box/.omp/agent" \
    -v "$PWD:/workspace" \
    -v "$HOME/.ca-certificates/combined-ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro" \
    -v "$HOME/.m2:/home/ai-agent-box/.m2" \
    -e SONARQUBE_TOKEN -e ATLASSIAN_PERSONAL_TOKEN -e ATLASSIAN_EMAIL \
    -e JENKINS_API_TOKEN -e JENKINS_USER -e BITBUCKET_TOKEN \
    ai-agent-box-omp-java:21 --no-title "$@"
```

The additions are: `--network agentbox-net`, the three `DOCKER_*` variables,
and the read-only certificate volume. Nothing is removed; no capability, no
device, and no `--security-opt` relaxation is added to the agent container.

Plain TCP (`-e DOCKER_TLS_CERTDIR=` on the sidecar, `DOCKER_HOST=tcp://docker:2375`,
no cert volume) also works and is simpler, but the daemon now logs
`[DEPRECATION NOTICE] … In future versions this will be a hard failure`, and
anything else that joins `agentbox-net` gets an unauthenticated root daemon.
Prefer the TLS form above.

### 4. Teardown

```bash
docker rm -f agentbox-dockerd          # add -v to drop the image cache too
docker network rm agentbox-net
```

### 5. Known gap: no BuildKit in the agent image

Verified in the actual image: `docker buildx version` fails and
`DOCKER_BUILDKIT=1 docker build` errors with "Install the buildx component".
`docker build` therefore falls back to the **legacy builder**, which works
(`Successfully built …`, `Using cache` on rebuild) but has no BuildKit
features: no `--mount=type=cache`, no parallel stages, no `docker buildx`
cache export.

To get BuildKit, add the Wolfi package to `omp/omp.Dockerfile` next to
`docker-cli` (`ARG DOCKER_CLI_BUILDX_VERSION=0.37.1-r0`,
`docker-cli-buildx=${DOCKER_CLI_BUILDX_VERSION}`); it is a CLI plugin only, so
it adds no daemon and no privileges. Alternatively, keep the agent image as-is
and point it at a rootless BuildKit sidecar (Option 7) for builds.

## Build cache: where it lives, and how to bound or disable it

With the sidecar, **no build cache exists inside the agent container**. Images,
layers and build cache all live in the sidecar's data-root,
`/home/rootless/.local/share/docker` (declared `VOLUME` in the image). The
Maven cache (`~/.m2`) is a separate, agent-side mount and is unaffected by
anything in this section.

| Strategy                     | How                                                                                                                     | Consequence                                                                                                                                                                                                         |
|------------------------------|-------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Persistent (default-ish)** | `-v agentbox-docker-data:/home/rootless/.local/share/docker`                                                            | Fastest: base images pulled once, layers reused across sessions. Grows without bound; you must prune.                                                                                                               |
| **Ephemeral per session**    | omit the volume flag **and** remove the sidecar with `docker rm -fv` (or run it with `--rm`)                            | Every session re-pulls `FROM` images and rebuilds every layer. Nothing stale, nothing leaks between projects, no disk creep. On a TLS-intercepted corporate link, re-pulls are the dominant cost.                   |
| **Ephemeral and bounded**    | `--tmpfs /home/rootless/.local/share/docker:rw,size=2g,mode=0700,uid=1000,gid=1000`                                     | Verified working (`driver=overlayfs`, inner `docker run` OK). Data-root is RAM-backed: it counts against the sidecar's `--memory`/VM RAM, and a build larger than `size=` fails with ENOSPC. Only for small images. |
| **Per build**                | `docker build --no-cache --pull`                                                                                        | Forces a fresh build and a fresh base image for that one build; the resulting layers are still stored in the data-root.                                                                                             |
| **Prune on a schedule**      | `docker image prune -af`, `docker container prune -f`, `docker builder prune -af` (BuildKit only) against `DOCKER_HOST` | Keeps the persistent volume from growing forever; run it from the host or between sessions.                                                                                                                         |

Notes worth knowing before choosing:

- **There is no "disable the cache" switch for the daemon.** The image layer
  store *is* the cache; the only true "off" is an ephemeral data-root
  (rows 2–3). `--no-cache` disables *reuse*, not *storage*.
- **`docker system df` reports `Build Cache=0B` with the legacy builder** —
  that counter only tracks BuildKit records. Legacy cache is the image layers
  under `Images`, so prune images, not the builder, unless you added buildx.
- **Anonymous volumes leak.** Without `-v` on the sidecar, Docker creates an
  anonymous volume for the data-root; `docker rm` without `-v` leaves it
  behind as a dangling volume. Use `docker rm -fv` or `docker run --rm`.
- **Recommendation for this workflow:** persistent named volume plus a
  periodic `docker image prune -af`. Java/Maven images are large and the
  re-pull cost per session is much higher than the disk cost; switch to the
  ephemeral form only when a build must be proven reproducible from scratch,
  or when the agent is working on untrusted code whose layers you do not want
  to keep.

## If Option 5 is ever adopted in-repo

A `dind/dind.Dockerfile` built the same way as the other images is feasible
without any upstream Alpine image: the pinned Wolfi index already carries
every piece (latest values at the time of writing, `aarch64` index):

| Package              | Version     | Role                                                                                         |
|----------------------|-------------|----------------------------------------------------------------------------------------------|
| `dockerd-29`         | `29.8.0-r1` | the nested daemon (pulls in `containerd`, `iptables-nft`, `fuse-overlayfs`, `shadow-subids`) |
| `docker-rootless-29` | `29.8.0-r1` | `dockerd-rootless.sh` wrapper                                                                |
| `rootlesskit`        | `3.1.0-r6`  | user-namespace + network setup                                                               |
| `slirp4netns`        | `1.3.5-r1`  | rootless networking                                                                          |
| `fuse-overlayfs`     | `1.18-r0`   | rootless storage driver                                                                      |
| `docker-cli`         | `29.8.0-r0` | already pinned by both agent images                                                          |
| `docker-cli-buildx`  | `0.37.1-r0` | optional, for `docker buildx`                                                                |

Alternatives also present in Wolfi if the direction changes: `buildkitd`
(`0.30.0-r4`) + `buildctl`, `buildah` (`1.44.0-r1`), `podman` (`6.0.0-r4`),
`crun`, `runc`. (Verified by parsing
`https://packages.wolfi.dev/os/aarch64/APKINDEX.tar.gz`; `apk search` from
inside a container fails on this workstation's TLS-intercepting network, see
README "Building behind a TLS-intercepting proxy".)

Such an image would need: a `rootless` user with `/etc/subuid` + `/etc/subgid`
ranges, `/run/user/<uid>` mode 1777, a `VOLUME` for the data-root, and the same
digest-pinned base, `ARG`-pinned versions, and `tests/run-tests.sh` coverage as
the existing variants. The agent images themselves would need **no change**
beyond documenting `DOCKER_HOST`.

## Reproducing these results

The probes were throwaway scripts; the essential commands are inline above.
To re-verify on a native-Linux host (where AppArmor is live and the kernel is
the host's, both of which change the answer), run, in order:

1. Option 5's `docker run` exactly as printed, then
   `docker exec -e DOCKER_HOST=unix:///run/user/1000/docker.sock dind-rootless docker run --rm alpine:3 echo ok`.
2. The same with one flag removed at a time, to confirm the failure table.
3. The hardened-client step (`--cap-drop=ALL --security-opt=no-new-privileges`)
   against `DOCKER_HOST=tcp://docker:2375`, including one `docker build`.

## Sources

- Docker docs — [Rootless mode](https://docs.docker.com/engine/security/rootless/),
  [Isolate containers with a user namespace](https://docs.docker.com/engine/security/userns-remap/)
- Docker Official Image `docker` — [Docker Hub readme](https://hub.docker.com/_/docker)
  and [`29/dind-rootless/Dockerfile`](https://github.com/docker-library/docker/blob/master/29/dind-rootless/Dockerfile),
  [`dockerd-entrypoint.sh`](https://github.com/docker-library/docker/blob/master/29/dind/dockerd-entrypoint.sh)
- Sysbox — [repository](https://github.com/nestybox/sysbox),
  [Docker-in-Docker guide](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/dind.md),
  [security](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/security.md),
  [limitations](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/limitations.md)
- GitLab docs — [Use Docker to build Docker images](https://docs.gitlab.com/ci/docker/using_docker_build/),
  [Use Docker-in-Docker](https://docs.gitlab.com/ci/docker/docker_in_docker/)
- Red Hat — [How to use Podman inside of a container](https://www.redhat.com/en/blog/podman-inside-container)
- [Tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)
- BuildKit — [rootless mode](https://github.com/moby/buildkit/blob/master/docs/rootless.md)
