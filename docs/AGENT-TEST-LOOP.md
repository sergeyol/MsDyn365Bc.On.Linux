# Adding a BC test loop to a repo — agent playbook

You have been pointed at this file because someone wants an AL repo to gain a
**test gate**: one command an agent can run after a change, whose exit code says
whether the change works. This describes how to build it, and — more usefully —
the failure modes that make a naive version worse than nothing.

Read the whole file before writing anything. Most of the mistakes below produce
a test loop that reports success while proving nothing, which is worse than
having no loop at all, because it launders an unverified change into a verified
one.

---

## 1. What you are building

A single executable at the repo root — `./test.sh` by convention — that:

1. compiles the repo's apps,
2. publishes them to a Business Central instance **in dependency order**,
3. runs the test codeunits,
4. writes JUnit XML,
5. exits with a code that distinguishes *your code is broken* from *there is no
   environment to test against*.

A compile gate is not a test gate. Compilation says the code is well-formed; it
says nothing about whether it does the right thing, and — see §6 — it does not
even prove the app can be installed.

## 2. The exit-code contract

This is the heart of the design. Get it wrong and everything else is decoration.

| Exit | Meaning | What the agent must do |
|---|---|---|
| `0` | every test passed | proceed |
| `1` | compile error, publish rejected, failing test, **or zero tests ran** | fix the code |
| `3` | no usable BC environment | tell the user, ask them to set one up, **do not build one** |

Two non-obvious requirements:

- **Zero tests must exit non-zero.** A run that finds no test codeunits is the
  single most common way these scripts silently pass forever. Treat an empty
  run as failure, always.
- **"No environment" needs its own code.** If it collapses into `1`, an agent
  will hunt for a bug that does not exist — or, far worse, try to install a
  BC environment unattended. On a shared repo where colleagues run different
  setups, "no environment" is an expected state, not a misconfiguration.

## 3. Two layers, and why they must not mix

**Layer 1 — committed, machine-agnostic.** `test.sh`, a config template, a
gitignore entry, and a short section in whatever file the repo's agents read
(`CLAUDE.md`, `AGENTS.md`, `.github/copilot-instructions.md`, or a process doc —
follow the repo's existing convention rather than inventing a new file).

**Layer 2 — per-machine, gitignored.** One file, `.bc-local.env`, holding the
instance URL, credential, and the path to the test runner.

Do **not** commit setup instructions for any particular machine. On a repo
several people share, one committed recipe is wrong for most of them and stale
for the rest. Windows colleagues may use a container helper script; someone else
runs BC on Linux under podman; someone else points at a shared dev instance.
`test.sh` must know about none of it.

The committed instruction says *"run the tests; if there is no environment, ask
the user"*. The uncommitted file says *how this machine reaches an instance*.
Keeping those apart is the entire point.

## 4. Steps

1. **Find the test app.** Its `app.json` `idRanges` gives you the codeunit
   range to run. If there is no test app, stop — say so, and do not invent one
   unless asked.

2. **Work out the dependency order** from each `app.json`'s `dependencies`.
   Publish order is not cosmetic; see §6.

   Dependencies resolve **by id, not by name**. A dependency entry whose `name`
   matches nothing in the workspace is usually just a stale name on a correct
   id — check ids before concluding an app is missing.

3. **Write `test.sh`** (§5 is a reference implementation).

4. **Write `.bc-local.env.example`**, commented, with no real credentials.

5. **Add `.bc-local.env` to `.gitignore`**, then *verify* with
   `git check-ignore -v .bc-local.env` — do not assume the pattern matched.

6. **Add the instruction** to the repo's agent-facing doc. State the exit-code
   contract and the escalation rule verbatim; that is the part agents act on.

7. **Verify** (§7). Do not report the task complete without it.

## 5. Reference implementation

The shape that matters, elided for brevity — copy the real thing from a repo
that already has one rather than retyping it.

```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

no_env() {   # exit 3 — environment, not code
    echo "NO LOCAL BC ENVIRONMENT: $*"
    echo "  If you are an agent: report this and ask the user to set up or"
    echo "  start their environment. Do not attempt to install one yourself."
    exit 3
}
fail() { echo "TEST RED: $*" >&2; exit 1; }   # exit 1 — code

[ -f "$ROOT/.bc-local.env" ] || no_env "no .bc-local.env in the repo root"
. "$ROOT/.bc-local.env"
[ -n "${BC_DEV_URL:-}" ]          || no_env ".bc-local.env does not set BC_DEV_URL"
[ -n "${BC_TEST_RUNNER_DIR:-}" ]  || no_env ".bc-local.env does not set BC_TEST_RUNNER_DIR"

# Reachability, with an optional per-machine hook to make it reachable.
if ! curl -s --max-time 10 -o /dev/null "$BC_DEV_URL/metadata"; then
    [ -n "${BC_LOCAL_UP_CMD:-}" ] && eval "$BC_LOCAL_UP_CMD" >/dev/null 2>&1
    sleep 3
    curl -s --max-time 15 -o /dev/null "$BC_DEV_URL/metadata" \
        || no_env "BC is not answering at $BC_DEV_URL"
fi

# ... compile each app, 0 errors or fail ...

. "$BC_TEST_RUNNER_DIR/scripts/publish-app.sh"
for app in "${APPS_IN_DEPENDENCY_ORDER[@]}"; do
    if ! bc_publish_app "$OUT/$app.app" "$BC_DEV_URL" "$BC_AUTH" >"$log" 2>&1; then
        cat "$log"
        # A dependency the INSTANCE lacks is an environment gap, not a code bug.
        grep -q "AL1024" "$log" && no_env "instance is missing dependency apps"
        fail "publish rejected for $app"
    fi
done

( cd "$BC_TEST_RUNNER_DIR" && ./scripts/run-tests.sh "${args[@]}" )
[ $? -eq 0 ] || fail "tests failed"
echo "TEST GREEN: all tests passed"
```

`BC_TEST_RUNNER_DIR` points at a `MsDyn365Bc.On.Linux` checkout. The only
interfaces depended on are `scripts/publish-app.sh` (exposing `bc_publish_app`)
and `scripts/run-tests.sh`, so any runner offering those works.

Build the `run-tests.sh` arguments as an **array**. `${VAR:+--flag "$VAR"}`
reads tidily but word-splits its expansion, so a credential containing a space
silently becomes two arguments.

## 6. Failure modes that will bite you

Every one of these was hit in practice.

**A green compile does not mean the app publishes.** The dev endpoint
**recompiles server-side against the target platform**, while your local compile
resolved against whatever symbols are in `.alpackages`. An app targeting an
older BC can be `BUILD GREEN` and then rejected at publish — for example
`AL0155` when the platform has since added a field your page extension also
adds. Never report "it compiles" as evidence that a change works.

**Republishing an unchanged version silently does nothing.** BC answers
`422 duplicate package ID`, and publish tooling reasonably treats that as
"already deployed". So a fix published under an unchanged version reports
success while the instance keeps running the old code — the fix is untested and
looks verified. **Bump the version** whenever you need to prove a fix landed,
and confirm against `[Published Application]` that the new version is the
installed one. The `.app` manifest carries no package id, and two builds of
identical source are not byte-identical, so you cannot settle this from files.

**One failed publish produces a wall of fake errors.** BC resolves symbols from
the database, so a dependent published before its dependency reports `AL1024`
plus dozens of `AL0185 "object is missing"` errors for objects that are
perfectly fine. Observed: one real error in a base app generated 40+ bogus ones
across three dependents. **Fix the first app in dependency order and re-run
before reading any other error.**

**`AL1024` means the environment, not your code** — the *instance* lacks a
dependency app. Map it to exit 3.

**Published ≠ installed for tenant.** An app can sit in `[Published
Application]` without being installed. If tests behave as though your code is
absent, check both tables.

**macOS ships bash 3.2.** No `mapfile`, and `set -u` trips on empty arrays. App
folder names contain spaces, so split lists with `IFS` and `set --`, never with
`$(...)` word splitting — `for app in $(echo "$APPS")` turns
`"My App"` into two arguments. This one bites immediately and looks like a
missing file.

**Never read `$?` after a pipe.** `./thing | tail` gives you `tail`'s status.
Capture `${PIPESTATUS[0]}`, or don't pipe.

**`alc` rewrites tracked report layouts** (`*.docx`, `*.rdlc`) during compile in
some repos. Check `git status` after building and restore what you did not mean
to change. Be careful running a build in a repo whose tree is already dirty.

**On macOS + podman, ports may not reach the host.** The container can be
healthy and BC still unreachable, because the healthcheck runs inside the VM. If
the setup needs a tunnel, drive it from `BC_LOCAL_UP_CMD` rather than expecting
anyone to remember it. Likewise `DOCKER_HOST`: agent tool calls each get a fresh
shell, so anything the agent must not forget belongs in the environment
(`~/.zshenv`) or inside the script — never in prose telling it to export things.

## 7. Verify before claiming done

Run and show the output of each:

- **Green path** — `./test.sh` exits `0` and reports a non-zero test count.
- **No-environment path** — move `.bc-local.env` aside; expect exit `3` and a
  message naming what is missing.
- **Empty-run path** — pass a codeunit range with no tests; expect non-zero.
- **Gitignore** — `git check-ignore -v .bc-local.env` matches.

If the repo has no usable instance and the green path cannot run, **say so
plainly**. Report which paths you verified and which you could not, and do not
describe the loop as working end to end. That honesty is the same thing the exit
3 contract is for.

## 8. When not to do this

- **No test app** — say so; do not invent tests unless asked.
- **The dependency closure is impractical.** Some repos need many ISV apps
  published before their own will install. Building that instance is a project
  in itself and is the user's decision, not yours. Ship the gate anyway — it
  will correctly report exit 3 until an instance exists.
- **The repo already has a working gate.** Extend it; do not add a second one.
