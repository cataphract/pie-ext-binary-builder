# Local extension build and test

## Building with build-ext-musl.sh

Use `build-ext-musl.sh` to build an extension inside a php-minimal container.
The script mounts the current directory as `/workspace` inside the container.

```bash
sudo rm -rf ext   # ext/ may be owned by root from a previous Docker build
./build-ext-musl.sh \
    --image ghcr.io/cataphract/php-minimal:8.0-release \
    --repo krakjoe/apcu --ref v5.1.28 \
    [--packages "pkg1 pkg2"] \
    [--pre-script .github/workflows/scripts/some-script.sh] \
    [--configure "--enable-foo --enable-bar"] \
    [--ldflags "-lfoo"]
```

The script forwards `GITHUB_WORKSPACE=/workspace` automatically. `--ldflags`
mirrors the matrix `ldflags:` field: it is scoped to the build phase
(phpize + configure + make) and does **not** affect the pre-build script, just
as in CI where `env: LDFLAGS:` is on the action step only.

## Patchelf (remove musl libc dep before glibc testing)

```bash
cp ext/modules/<ext>.so /tmp/<ext>.so
patchelf --remove-needed libc.musl-x86_64.so.1 /tmp/<ext>.so
sudo cp /tmp/<ext>.so ext/modules/<ext>.so
```

## Running glibc tests

Mirror CI exactly: mount `ext/` at `/ext` and use `/ext/modules/<ext>.so`.

```bash
docker run --rm \
    -e DEBIAN_FRONTEND=noninteractive \
    -v "$(pwd)/ext:/ext" \
    -w /ext \
    php:8.0-cli \
    sh -c "php run-tests.php -n -d extension=/ext/modules/<ext>.so --show-diff -q tests/"
```

For extensions that need extra packages or setup before testing (e.g. imagick):

```bash
docker run --rm \
    -e DEBIAN_FRONTEND=noninteractive \
    -v "$(pwd)/ext:/ext" \
    -w /ext \
    php:8.0-cli \
    sh -c "apt-get update -q && apt-get install -y -q <pkgs> && <pre-test-cmd> && \
           php run-tests.php -n -d extension=/ext/modules/<ext>.so --show-diff -q tests/"
```

Imagick-specific: `apt-get install -y ghostscript gsfonts` and
`ln -sf /etc/ImageMagick-6 /etc/ImageMagick-7` before running tests.

# Policy: handling test failures

`allow-test-failures: 'true'` in the matrix is **not acceptable**. It uses
`continue-on-error` on the entire test step, which indiscriminately ignores
all test failures, including ones we don't know about yet.

When tests fail, the required process is:

1. **Identify** the exact failing test files.
2. **Form a hypothesis** for why they fail (e.g. "this is a PHP version bug,
   not a bug in our build").
3. **Validate empirically**: design two kinds of tests —
   - *Confirming tests*: tests that would pass if the hypothesis is true.
   - *Disproving tests*: tests that would pass if the hypothesis is false
     (i.e. would show our build is the actual culprit).
   Run both. Guessing without empirical evidence is not acceptable.
4. **Fix specifically**: if tests must be excluded, remove the specific
   `.phpt` files (like `imagick-force-static.sh` already does for two known
   bad tests), or use `run-tests.php` skip options, with an inline comment
   explaining the validated reason.

# Monitoring CI

When told to monitor CI, spawn a **background** agent with the following prompt:

```
Run this command in the FOREGROUND (do NOT use run_in_background — you must block and
wait for it to exit):

  scripts/monitor-ci.sh [SHA]

Where [SHA] is the commit SHA to monitor (omit to default to HEAD). You may also pass
--workflow <name> to filter to a specific workflow by name (substring match).

Once it exits, use the speak_when_done MCP tool to say:
- Exit 0: "All GitHub Actions jobs passed"
- Exit 1: "Some jobs failed: <names of the failing jobs printed by the script, up to
  three; if more, append 'among others'>. Logs saved to: <list the log file paths
  printed to stderr>"
- Exit 2: "Workflow monitoring timed out"
```

## monitor-ci.sh

`scripts/monitor-ci.sh` monitors GitHub Actions CI for a given commit SHA.

Usage:
```
scripts/monitor-ci.sh [SHA] [--workflow NAME] [--wait-timeout SECONDS] [--timeout SECONDS]
```

- `SHA`: commit SHA to monitor (default: HEAD)
- `--workflow NAME`: filter to workflows whose name contains NAME
- `--wait-timeout SECONDS`: how long to wait for runs to appear (default: 30)
- `--timeout SECONDS`: total monitoring timeout (default: 3600)

Exit codes:
- `0`: all runs completed successfully
- `1`: at least one run failed (failing run names are printed to stdout)
- `2`: timed out waiting for runs to appear, or total timeout exceeded

The `cataphract` remote (`cataphract/pie-ext-binary-builder`) is the fork where CI runs.
The script auto-detects remotes and queries whichever one has runs for the SHA; since
`cataphract` is configured as a remote it will be found automatically.

On failure, logs for failed jobs are downloaded to `/tmp/workflow_<run_id>/<job_name>.log`
and printed to stderr before exit. The subagent should report the log file paths upstream.

Requires `uv` to be installed. Auth is resolved in order:
1. `~/github_pub_pat` — a file containing a GitHub PAT (preferred)

Always use the github API, never gh and avoid direct Fetch() to github pages
where API access is possible.
