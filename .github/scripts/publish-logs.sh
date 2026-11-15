#!/usr/bin/env bash
# Publish everything in the CI log directory as one gzipped tarball stored in a
# Git blob, and print the blob SHA as a notice annotation on the job.
#
# Why: the regular Actions log and artifact downloads are served from a
# separate storage host. Tools that can only reach api.github.com cannot read
# them, but they can read annotations and blobs:
#
#   gh api repos/<owner>/<repo>/check-runs/<job-id>/annotations
#   gh api repos/<owner>/<repo>/git/blobs/<sha> --jq .content | base64 -d | tar xz
#
# The blob is not referenced by any branch, so it never shows up in history.
# Publishing is best-effort: it needs `contents: write`, which pull requests
# from forks do not get, and it must never fail the job.
#
# Usage: .github/scripts/publish-logs.sh <label>
set -uo pipefail

label="${1:-job}"
log_dir="${CI_LOG_DIR:-${RUNNER_TEMP:-/tmp}/ci-logs}"
# On Windows runners RUNNER_TEMP uses backslashes; bash needs forward slashes.
log_dir="${log_dir//\\//}"

if [ ! -d "$log_dir" ] || [ -z "$(ls -A "$log_dir" 2>/dev/null)" ]; then
    echo "No logs to publish in $log_dir"
    exit 0
fi

work="$(mktemp -d)"
# Keep each file to its last 4 MB so one runaway log cannot break the upload.
mkdir -p "$work/logs"
for f in "$log_dir"/*; do
    [ -f "$f" ] || continue
    tail -c 4194304 "$f" >"$work/logs/$(basename "$f")"
done
tar -C "$work" -czf "$work/logs.tgz" logs
# `base64 -w0` is GNU-only; strip the line breaks instead so macOS works too.
base64 <"$work/logs.tgz" | tr -d '\r\n' >"$work/logs.b64"
jq -n --rawfile content "$work/logs.b64" '{content: $content, encoding: "base64"}' >"$work/payload.json"

if sha="$(gh api "repos/${GITHUB_REPOSITORY}/git/blobs" --input "$work/payload.json" --jq .sha 2>"$work/err")"; then
    echo "::notice title=ci-logs::${label} ${sha}"
else
    echo "Could not publish logs (this is expected on pull requests from forks):"
    cat "$work/err"
fi
exit 0
