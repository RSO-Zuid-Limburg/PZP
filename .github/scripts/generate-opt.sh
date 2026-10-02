#!/usr/bin/env bash
# Generates ADL 1.4 Operational Templates (OPTs) for every COMPOSITION template in this
# repository, using the Archetype Designer's GitHub-backed repository for this same Git repo.
#
# Read-only towards the Archetype Designer: it exports the repository *at this commit*
# (repositoryVersionId) with opt=true and keeps only the .opt files. Nothing is imported,
# saved or deleted on the server.
#
# Required env:
#   AD_USER                Archetype Designer account with a local (username/password) login
#                          and API access, which has this GitHub repo configured as a repository
#   AD_PASSWORD            optional when run interactively: prompted for (not echoed) if unset
#   AD_REPOSITORY_ID       id of that Archetype Designer repository
# Optional env:
#   AD_URL                 default https://tools.openehr.org/designer
#   OUT_DIR                default opt
#   COMMIT_SHA             default: git rev-parse HEAD
#   HISTORY_RETRIES        default 6 (x 10 s) - wait for the Designer to see the commit
set -euo pipefail

AD_URL="${AD_URL:-https://tools.openehr.org/designer}"
OUT_DIR="${OUT_DIR:-opt}"
COMMIT_SHA="${COMMIT_SHA:-$(git rev-parse HEAD)}"
HISTORY_RETRIES="${HISTORY_RETRIES:-6}"
: "${AD_USER:?AD_USER not set}" "${AD_REPOSITORY_ID:?AD_REPOSITORY_ID not set}"
if [ -z "${AD_PASSWORD:-}" ]; then
  [ -t 0 ] || { echo "AD_PASSWORD not set and no terminal to prompt on" >&2; exit 1; }
  read -r -s -p "Archetype Designer password for $AD_USER: " AD_PASSWORD; echo
fi

API="$AD_URL/api"
WORK="$(mktemp -d)"
JAR="$WORK/cookies"
# The password is only sent once, via stdin (never on a command line); all other calls use
# the session cookie, and the session is logged out on exit.
ad() { curl -sS --fail-with-body -b "$JAR" -c "$JAR" "$@"; }
cleanup() { [ -s "$JAR" ] && ad -X POST "$API/user/logout" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
# q k1 v1 k2 v2 ... -> url-encoded query string
q() { local out=""; while [ $# -ge 2 ]; do out+="&$1=$(jq -rn --arg v "$2" '$v|@uri')"; shift 2; done; echo "${out#&}"; }

# --- 1. Login ---------------------------------------------------------------------------
AD_PASSWORD="$AD_PASSWORD" jq -n --arg u "$AD_USER" '{provider:"local",username:$u,password:env.AD_PASSWORD}' \
  | ad -H 'Content-Type: application/json' --data-binary @- "$API/user/login" >/dev/null
unset AD_PASSWORD
echo "logged in to $AD_URL"

# --- 2. Find the Designer version id for this commit -------------------------------------
# Assumption to verify: for a GitHub-backed repository the versionId is the Git commit SHA.
# If it is not, this step fails and prints what the Designer does return.
version=""
for i in $(seq 1 "$HISTORY_RETRIES"); do
  ad "$API/repository/history/list?$(q repositoryId "$AD_REPOSITORY_ID" count 50)" > "$WORK/history.json"
  version="$(jq -r --arg sha "$COMMIT_SHA" \
    '[.[].versionId // empty | select(length >= 7) | select(. as $v | ($sha | startswith($v)) or ($v | startswith($sha)))] | .[0] // empty' \
    "$WORK/history.json")"
  [ -n "$version" ] && break
  echo "commit $COMMIT_SHA not (yet) in Designer history, attempt $i/$HISTORY_RETRIES"
  sleep 10
done
if [ -z "$version" ]; then
  echo "::error::commit $COMMIT_SHA not found in Archetype Designer history of '$AD_REPOSITORY_ID'"
  echo "latest versions returned by the Designer:"
  jq -r '.[:5][] | "  \(.versionId)  \(.message)"' "$WORK/history.json"
  exit 1
fi
echo "Designer version: $version"

# --- 3. Export the repository at that version, with OPTs ---------------------------------
ad "$API/repository/export/zip?$(q repositoryId "$AD_REPOSITORY_ID" repositoryVersionId "$version" opt true)" \
   -o "$WORK/export.zip"
mkdir -p "$WORK/zip" "$WORK/out"
unzip -q "$WORK/export.zip" -d "$WORK/zip"

# Keep COMPOSITION-rooted OPTs only; name each file after its template_id.
python3 - "$WORK/zip" "$WORK/out" <<'PY'
import sys, pathlib, re, shutil, xml.etree.ElementTree as ET
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
ns = {"o": "http://schemas.openehr.org/v1"}
for f in sorted(src.rglob("*.opt")):
    root = ET.parse(f).getroot()
    tid = (root.findtext("o:template_id/o:value", namespaces=ns) or "").strip()
    rm = (root.findtext("o:definition/o:rm_type_name", namespaces=ns) or "").strip()
    if rm != "COMPOSITION":
        print(f"skip {f.relative_to(src)} ({rm})"); continue
    name = re.sub(r'[/\\:*?"<>|]', "_", tid) + ".opt"
    if (dst / name).exists():
        sys.exit(f"duplicate template_id {tid!r}")
    shutil.copy(f, dst / name)
    print(f"{f.relative_to(src)} -> {name}")
PY

# Sanity check: one OPT per COMPOSITION template in the repo. The Designer exports a
# template's raw content instead of failing when it cannot build the OPT, so a missing
# OPT is the only signal that something went wrong.
expected=0
while IFS= read -r -d '' t; do
  jq -e '.templateId // "" | test("-COMPOSITION\\.")' "$t" >/dev/null && expected=$((expected + 1))
done < <(git ls-files -z -- '*.t.json')
got="$(find "$WORK/out" -name '*.opt' | wc -l)"
if [ "$got" -ne "$expected" ]; then
  echo "::error::expected $expected COMPOSITION OPTs, Designer produced $got; nothing written"
  exit 1
fi

# Replace the output folder, so OPTs of removed/renamed templates disappear too.
mkdir -p "$OUT_DIR"
find "$OUT_DIR" -maxdepth 1 -name '*.opt' -delete
cp "$WORK/out/"*.opt "$OUT_DIR/"
ls -l "$OUT_DIR"
