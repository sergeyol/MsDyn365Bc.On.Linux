## MacOS steps

Verified on Apple Silicon (M1 Pro, macOS 15.7.9, podman 6.1, applehv). The
macOS version matters more than usual here — see step 4. BC runs under Rosetta
emulation — the images are `linux/amd64`, so every container logs an
`image platform (linux/amd64) does not match the expected platform (linux/arm64)`
warning. That is expected and harmless.

### 1. Install podman

Either the official installer from podman.io (lands in `/opt/podman/bin` and
adds itself to your PATH via `/etc/paths.d/podman-pkg`) or `brew install podman`.
Confirm it resolves before continuing:

```
podman --version
```

### 2. Configure the machine

Make sure _~/.config/containers/containers.conf_ contains both keys:

```
  [machine]
  provider = "applehv"
  rosetta = true
```

Both are read when the VM is created, so set them before the next step.
`rosetta = true` is not a performance tweak — without it nothing amd64 runs at
all, and SQL Server dies immediately. Step 4 has the details.

### 3. Create the VM

Podman needs to run in "rootful" mode, and BC needs a lot of memory. Both are
properties of the VM, so pass them at creation time:

```
podman machine init --image docker://quay.io/podman/machine-os:5.5 --rootful --cpus 8 --memory 15000 --disk-size 120 --now
```

The `--image` pin is **required**, not cosmetic — the current default machine
image ships a kernel Apple's Rosetta cannot run amd64 binaries under, which
takes SQL Server down with it. See step 4 for the symptom and the reasoning.

`podman machine set --rootful` and `--memory` only edit a machine that already
exists — running them on a fresh install fails with
`Error: podman-machine-default: VM does not exist`. To change either later, stop
the machine first:

```
podman machine stop && podman machine set --memory 15000 && podman machine start
```

**Sizing note.** 15000 MB is what BC comfortably wants, but on a 16 GB Mac that
is 94% of physical RAM and macOS will swap continuously.

The VM allocation is not the only knob, and it is the wrong one to reach for
first. Inside the VM the memory goes to three places:

| consumer | knob | default |
|---|---|---|
| SQL Server | `MSSQL_MEMORY_LIMIT_MB` | 2048 |
| SQL data tmpfs (**guest RAM, not disk**) | `BC_SQL_TMPFS_SIZE` | 4g |
| the NST — spikes while compiling AL | — | — |

Measured steady state at 12000 MB with the web client running: ~6.5 GB used of
11.6 GB, of which ~1.2 GB was the database sitting in tmpfs. So a smaller VM is
viable *if* you shrink the first two first — dropping to 8000 MB without also
lowering them leaves roughly 1 GB of headroom, and boot (DB restore, extension
publish, AL compile) is the peak, not the steady state.

The tmpfs one surprises people: it is a RAM disk, so every byte of database
counts against the VM's memory. Lowering it caps how large the database can
grow — fine for a demo tenant, not for a restored production-sized one.

If BC gets OOM-killed, shrink `BC_SQL_TMPFS_SIZE` and `MSSQL_MEMORY_LIMIT_MB`
before raising the VM allocation.

### 4. Enable Rosetta

**This is not optional and not just a performance tweak.** Without Rosetta the
VM falls back to QEMU user-mode emulation for `linux/amd64` binaries, and SQL
Server segfaults on startup before it logs anything useful:

```
qemu: uncaught target signal 11 (Segmentation fault) - core dumped
```

which surfaces only as `container ..._sql_1 is unhealthy` from `--wait`.

Rosetta is attached to the VM by the `rosetta = true` containers.conf setting
from step 2. If you are repairing an existing machine that was created without
it, add it now, then create the marker file the machine OS looks for and
restart:

```
podman machine ssh 'sudo touch /etc/containers/enable-rosetta'
```

```
podman machine stop && podman machine start
```

The VM's `/etc/containers` is a virtiofs mount of the host's
`~/.config/containers`, so that marker and the config file are the same
directory seen from two sides — you can equally `touch
~/.config/containers/enable-rosetta` on the host.

A restart is enough to flip the setting; you do **not** need to recreate the
machine just for this, even though the `Rosetta` field is baked into the machine
config at init time.

#### Rosetta cannot run amd64 on a current machine image

Enabling Rosetta is necessary but **not sufficient**. Apple's Rosetta aborts on
every amd64 binary — `/bin/true` included — when the podman machine's kernel is
too new, with:

```
rosetta error: unhandled auxillary vector type 29
```

Auxv type 29 is `AT_HWCAP3`, introduced in Linux 6.11. Containers die with exit
`133` and `--wait` reports only `container ..._sql-1 is unhealthy`, which points
nowhere near the cause.

Measured on macOS 15.7.9 (Rosetta dated July 2025), four images tested:

| machine-os image | Fedora CoreOS | kernel | Rosetta (amd64) | host port forwarding |
|---|---|---|---|---|
| `6.1` (current default) | 44 | 7.1.4 | **fails** | — |
| `6.0` | 44 | 7.1.3 | **fails** | works |
| `5.8` | 44 | 7.1.4 | **fails** | fails |
| `5.5` | 41 | 6.12.13 | **works** | fails |
| `5.2` | 40 | 6.11.3 | **works** | fails |

Rosetta works up to kernel 6.12.13 and fails from 7.1.3 on. `5.5` is the newest
image that still runs amd64, which is why it is the one pinned above.

The last column is the sting in the tail and is covered under
[Port forwarding](#port-forwarding-does-not-work-on-the-pinned-image) below:
podman's native forwarding needs a podman 6.x guest, every 6.x image ships a
7.1.x kernel, so **no single image gives you both**. Rosetta is the
non-negotiable one — without it nothing runs at all — so pin for Rosetta and
tunnel the ports.

Verify rather than reasoning from a version number:

```
podman machine ssh 'sudo podman run --rm --platform linux/amd64 docker.io/library/alpine:latest uname -m'
```

`x86_64` means Rosetta is working. `rosetta error: unhandled auxillary vector
type 29` means that image's kernel is too new.

A newer macOS ships a newer Rosetta and would likely remove the need for the
pin — and with it the port-forwarding problem, since you could then run a
current image. That was not testable here. Retest before assuming any of this
is still required.

#### Add a policy.json

The VM's `/etc/containers` is the host's `~/.config/containers` seen over
virtiofs, which masks the image's own copy. The pinned image's podman has no
fallback to
`/usr/share/containers/policy.json`, so image pulls inside the VM fail with
`open /etc/containers/policy.json: no such file or directory`. Create it once:

```
cat > ~/.config/containers/policy.json <<'EOF'
{
    "default": [{ "type": "insecureAcceptAnything" }],
    "transports": {
        "docker-daemon": { "": [{ "type": "insecureAcceptAnything" }] }
    }
}
EOF
```

**Verify it took effect** — `podman machine inspect` only reports the requested
setting, so check the guest's actual binfmt handler:

```
podman machine ssh 'cat /proc/sys/fs/binfmt_misc/rosetta'
```

Good output contains `interpreter /mnt/rosetta`. If instead
`/proc/sys/fs/binfmt_misc/qemu-x86_64` exists and lists
`interpreter /usr/bin/qemu-x86_64-static`, Rosetta is still off and SQL will
not start.

### 5. Install docker-compose

`podman compose` does not support `--wait`:

```
brew install docker-compose
```

## Starting BC

First, point compose at podman's socket:

```
export DOCKER_HOST="unix://$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')"
```

This matters most if **Docker Desktop is also installed**. Docker Desktop owns
the `docker` CLI at `/usr/local/bin/docker` and the `docker compose` plugin
bundled with it, so without `DOCKER_HOST` the whole stack quietly starts inside
Docker Desktop instead of podman — with none of the overrides below applying for
the right reasons. For the same reason, invoke the Homebrew binary as
`docker-compose` (with the hyphen) rather than `docker compose`; the plugin
Docker Desktop ships can be several years old.

### Keep BC artifacts outside the VM

Optional, but worth doing on macOS: the ~3 GB of downloaded BC artifacts
normally live in a podman volume, so they are destroyed along with the VM — and
on macOS you may well rebuild the VM (see step 4). Point them at a host
directory instead and they survive:

```
export BC_ARTIFACTS_DIR=~/bc-artifact-cache
```

The entrypoint keys its cache on a `.bc-artifact-cache` stamp recording the
requested type/version/country, so a rebuilt VM reuses the download rather than
re-fetching from Microsoft. Recovering an existing volume before you tear a VM
down works too:

```
podman machine ssh 'sudo cp -a /var/lib/containers/storage/volumes/*_bc-artifacts/_data/. /Users/<you>/bc-artifact-cache/'
```

### Port forwarding does not work on the pinned image

Pinning the machine image for Rosetta costs you podman's host port forwarding.
Published container ports listen correctly **inside** the VM but are
unreachable from macOS — `curl localhost:7049` just hangs, and `docker-compose
up --wait` still reports both containers healthy, because the healthchecks run
inside the VM.

This is not specific to BC and not caused by rootful mode — a plain arm64 test
container publishing a port is equally unreachable, rootless or rootful. It is
the guest/client split in the table above: forwarding needs a podman 6.x guest,
Rosetta needs a ≤ 6.12 kernel, and no image has both.

Bridge it with an SSH tunnel over podman's own machine SSH connection:

```
./scripts/macos-tunnel.sh --daemon
```

`--stop` and `--status` do what they say, and running it without arguments keeps
it in the foreground. Ports are read from your compose config, so a port offset
is picked up automatically; override with `BC_TUNNEL_PORTS="7049 11433"`.

Leave it running for as long as you are using BC. Confirm with:

```
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:7049/BC/dev/metadata
```

### Bring the stack up

Then use the macOS overlay on top of the main compose file:

```
docker-compose -f docker-compose.yml -f docker-compose.macos.yml up -d --wait
```

The overlay handles three Apple Silicon / podman differences:

* **SQL Server is pinned to 2022-CU17.** Later 2022 CUs crash under Rosetta
  emulation (SQL Server 2025 fixes it).
* **The SQL container runs as root.** Rootful podman mounts the data tmpfs
  root-owned, which the image's non-root `mssql` user cannot write to.
* **The tmpfs `uid=`/`gid=` options are dropped.** Docker passes them to the
  kernel; podman validates mount options and hard-fails container create with
  `unknown mount option "uid=10001": invalid mount option`. They were never
  taking effect under rootful podman anyway — see the point above.

Everything else (ports, env vars like `BC_VERSION`/`BC_COUNTRY`, running
tests via `scripts/run-tests.sh`) works the same as on Linux.

## Web client

Opt-in. With `BC_WEBCLIENT=1` set, the entrypoint self-hosts Microsoft's real
web client on Kestrel inside the bc container on port 8080, pointed at the Linux
NST over the 7085 client-services channel:

```
BC_WEBCLIENT=1 docker-compose -f docker-compose.yml -f docker-compose.macos.yml up -d --wait
```

Then browse to **http://localhost:8080** and sign in as **BCRUNNER /
Admin123!** (the credentials the entrypoint prints as `Database ready (...)`).
Port 8080 is in the tunnel's port list, so it works from macOS with no extra
setup — but as with everything else, **the tunnel has to be running**.

Verified working on this setup: sign-in, role center, list pages, cards. It is
a proof of concept, and `docs/WEBCLIENT-POC.md` has the full gap list — the ones
most likely to surprise you day to day:

* **Record images do not render** (customer/item/contact pictures, user
  avatars). The web client decodes them via `System.Drawing.Common`, which
  throws unconditionally on Linux. Static icons and brand assets are fine.
* **F5 debugger launch mode is unreliable** — it usually drops the debug
  parameters and lands on the role center. Attach mode (`breakOnNext`) works.
* **Sessions die on container restart** (DataProtection keys are not
  persisted) — just sign in again.
* Reports/printing, file upload/download, and the designer are untested.

## Daily use

Three environment variables are needed in **every** shell that talks to BC.
Forgetting `DOCKER_HOST` is the dangerous one — compose silently targets Docker
Desktop instead of podman and nothing warns you. Put them in your shell profile:

```
export PATH="/opt/podman/bin:$PATH"
export BC_ARTIFACTS_DIR="$HOME/bc-artifact-cache"
_bc_sock=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null)
[ -n "$_bc_sock" ] && export DOCKER_HOST="unix://$_bc_sock"
unset _bc_sock
```

The guard matters: if the machine does not exist yet, an unguarded command
substitution leaves `DOCKER_HOST=unix://`, which fails far more confusingly than
having it unset. The socket path is stable per user, so you can also just
hardcode it once you know it.

Add `export BC_WEBCLIENT=1` too if you want the web client (see below), and on
a RAM-constrained Mac the two memory knobs from step 3:

```
export BC_SQL_TMPFS_SIZE=2g
export MSSQL_MEMORY_LIMIT_MB=1536
```

Then a normal session is:

```
podman machine start
```

```
docker-compose -f docker-compose.yml -f docker-compose.macos.yml up -d --wait
```

```
./scripts/macos-tunnel.sh --daemon
```

Shutting down is `./scripts/macos-tunnel.sh --stop`, `docker-compose ... down`,
`podman machine stop`.

### Things to remember

* **The tunnel must be running before you use BC.** Without it every port is
  dead from macOS even though `--wait` reports both containers healthy, because
  the healthchecks run inside the VM. `./scripts/macos-tunnel.sh --status`
  tells you. It does not survive a reboot or a `podman machine stop`.
* **The SQL data directory is a tmpfs, so the database is wiped whenever the
  SQL container restarts** — that is true on Linux too, but it bites more here
  because you will stop and start the VM. A restart means another full CRONUS
  restore and extension publish (~4 min with artifacts cached), not a resume.
  Anything you want to keep must be in an app, not in the database.
* **Only one podman VM can run at a time.** `podman machine start <other>`
  fails with `only one VM can be active at a time` — stop the current one first.
* **Do not delete `~/bc-artifact-cache`.** It holds the ~3 GB of extracted BC
  artifacts and is what makes a VM rebuild cheap. It is keyed by the requested
  version, so changing `BC_VERSION` re-downloads on its own.
* **Rebuilding the VM destroys every podman volume**, including the patched
  service tier and the assembly cache. Both regenerate; the artifacts only
  survive because they live on the host (see above).
* **`podman machine set --memory` needs the machine stopped**, and the value is
  RAM taken from macOS — see the sizing note in step 3 before raising it.
* **The memory knobs are environment variables, so they must be set on every
  `up` as well** — same trap as `BC_WEBCLIENT`. A forgotten
  `BC_SQL_TMPFS_SIZE` silently restores the 4 GB default and can OOM a VM you
  had sized to fit 2 GB.
* **`BC_WEBCLIENT=1` must be set on every `up`.** It is a compose environment
  variable, so running `up` without it silently recreates the bc container
  *without* the web client — and recreating means another full DB restore. Put
  it in your profile rather than remembering it per command.
