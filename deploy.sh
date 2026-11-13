#!/usr/bin/env bash
# Deploy FOSSBilling to a self-managed server (host settings in deploy.env).
#
# Ships a BUILD, not the working tree:
#   1. Local:  git archive HEAD → clean temp tree → npm ci + build:production
#              → release = src/ + built assets (+ flat-layout composer.json/lock), minus install/
#   2. Server: rsync release → $BUILD_DIR; composer install --no-dev there
#              as $APP_USER (vendor must be built for the flat layout, on the server)
#   3. Server: verify build → show exactly what would change on live
#   --dry-run stops here. Live is never touched.
#   4. Server: backup live code + DB → rsync build → live (--delete, runtime excluded)
#              → perms → clear cache → reload php-fpm → patcher as $APP_USER
#   5. Local:  HTTP checks, including asset URLs and their content types
#
# Usage:
#   ./deploy.sh --dry-run    full build + diff against live, no live changes
#   ./deploy.sh              same, then asks for confirmation and deploys
#
# Requires locally: git, Node >= 24 / npm >= 11, python3, rsync, and deploy.env
# (copy deploy.env.example; it holds the SSH key, host, paths, users and PHP binaries).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Host-specific settings live in deploy.env (gitignored). Template: deploy.env.example.
ENV_FILE="${DEPLOY_ENV:-$REPO/deploy.env}"
[[ -f "$ENV_FILE" ]] || { echo "✗ $ENV_FILE not found. Copy deploy.env.example to deploy.env and fill it in." >&2; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"
for v in SSH_KEY VPS SITE LIVE_DIR BUILD_DIR APP_USER DB_NAME PHP_BIN PHP_FPM_SERVICE COMPOSER_BIN BACKUP_DIR; do
  [[ -n "${!v:-}" ]] || { echo "✗ $v is not set in $ENV_FILE" >&2; exit 1; }
done
DIFF_FILE="$BUILD_DIR.last-diff.txt"   # full itemized diff of the last run, on the server (outside the build dir)

# Never synced to live (runtime state / build-only files).
LIVE_EXCLUDES=(
  /config.php
  /data/
  /composer.json
  /composer.lock
  /.composer-home/
  /library/FOSSBilling/GeoIP/Databases/*.mmdb   # refreshed at runtime by FOSSBilling's cron; git copies are older
)
# Exist on live but not in git. Protected from --delete until decided:
#   commit them, keep protecting them, or delete this line and let the deploy remove them.
PROTECT=(
  /seed_udp.php                 # DB seed script (untracked)
  /themes/udp/assets/build/     # UDP client theme build (Apr 2026; theme is broken on 0.8.9 anyway)
)

# Files that must exist in the build before it may go live (the 2026-11-13 failure).
REQUIRED_FILES=(
  vendor/autoload.php
  public/assets/js/api.js
  public/assets/js/fossbilling.js
  themes/admin_default/assets/build/css/fossbilling.css
  themes/admin_default/assets/build/css/vendor.css
  themes/admin_default/assets/build/js/fossbilling.js
  themes/huraga/assets/build/manifest.json
)

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes)
step() { echo; echo "▸ $*"; }
ok()   { echo "  ✓ $*"; }
die()  { echo "  ✗ $*" >&2; exit 1; }

rsync_excl() { local a=(); for e in "${LIVE_EXCLUDES[@]}" "${PROTECT[@]}"; do a+=(--exclude="$e"); done; printf '%s\n' "${a[@]}"; }
mapfile -t EXCL_ARGS < <(rsync_excl)

# ── 0. Preflight ───────────────────────────────────────────────────────────────
step "Preflight"
cd "$REPO"
node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[[ "$node_major" -ge 24 ]] || die "Node >= 24 required (have $(node --version 2>/dev/null || echo none)). Try: nvm install 24 && nvm use 24"
dirty=$(git status --porcelain -- src frontend package.json package-lock.json composer.json composer.lock)
[[ -z "$dirty" ]] || { echo "$dirty"; die "uncommitted changes in deployable paths. Commit or stash first."; }
SHA=$(git rev-parse --short HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if git rev-parse --verify -q "origin/$BRANCH" >/dev/null && ! git merge-base --is-ancestor HEAD "origin/$BRANCH"; then
  echo "  ! HEAD $SHA is not pushed to origin/$BRANCH (deploying anyway; push afterwards)"
fi
ok "deploying $BRANCH @ $SHA ($(git log -1 --format=%s))"

# ── 1. Local release build ─────────────────────────────────────────────────────
step "Building release locally"
TMP=$(mktemp -d -t fossbilling-release.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
git archive HEAD | tar -x -C "$TMP"

# Stamp the version, as upstream's release build does (Dockerfile). Unstamped source reports
# 0.0.1, which FOSSBilling treats as "older than 0.8.0" (security alert + update banner).
# Format <tag>+<commits since tag>.<sha>: valid semver, and PHP version_compare() ranks it
# at or above the tag (a letter right after the "+" would rank it BELOW the tag).
BASE_TAG=$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*') || die "no release tag found (git fetch --tags original-origin?)"
AHEAD=$(git rev-list --count "$BASE_TAG..HEAD")
FB_VERSION="$BASE_TAG+$AHEAD.$SHA"
VFILE="$TMP/src/library/FOSSBilling/Version.php"
grep -q "public const string VERSION = '0.0.1';" "$VFILE" || die "Version.php placeholder not found; upstream changed the format"
sed -i "s/public const string VERSION = '0.0.1';/public const string VERSION = '$FB_VERSION';/" "$VFILE"
grep -q "VERSION = '$FB_VERSION';" "$VFILE" || die "version stamp failed"
ok "version stamped: $FB_VERSION"

(
  cd "$TMP"
  npm ci --no-audit --no-fund --loglevel=error
  npm run build:production
) > "$TMP.build.log" 2>&1 || { tail -30 "$TMP.build.log"; die "asset build failed (full log kept: $TMP.build.log)"; }
rm -f "$TMP.build.log"
ok "assets built"

REL="$TMP/src"
rm -rf "$REL/install" "$REL/vendor"
# Flat-layout composer.json for the server (live has no src/ prefix)
python3 - "$TMP/composer.json" "$REL/composer.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
strip = lambda s: s.replace("src/", "", 1) if isinstance(s, str) and s.startswith("src/") else s
d["config"]["vendor-dir"] = "vendor"
for kind in ("psr-0", "psr-4"):
    for k, v in d.get("autoload", {}).get(kind, {}).items():
        d["autoload"][kind][k] = [strip(x) for x in v] if isinstance(v, list) else strip(v)
if "classmap" in d.get("autoload", {}):
    d["autoload"]["classmap"] = [strip(x) for x in d["autoload"]["classmap"]]
d.pop("autoload-dev", None)
d.get("scripts", {})["post-install-cmd"] = [s.replace("php src/vendor/", "php vendor/") for s in d.get("scripts", {}).get("post-install-cmd", [])]
json.dump(d, open(sys.argv[2], "w"), indent=4)
PY
cp "$TMP/composer.lock" "$REL/composer.lock"
grep -q '"src/' "$REL/composer.json" && die "flat composer.json still references src/"
printf 'version=%s\nsha=%s\nbranch=%s\nbuilt=%s\n' "$FB_VERSION" "$SHA" "$BRANCH" "$(date -u +%FT%TZ)" > "$REL/.udp-release"
for f in "${REQUIRED_FILES[@]}"; do
  [[ "$f" == vendor/* ]] && continue
  [[ -s "$REL/$f" ]] || die "release is missing $f"
done
ok "release ready ($(du -sh "$REL" | cut -f1), $(find "$REL" -type f | wc -l) files)"

# ── 2. Upload + vendor build on server ─────────────────────────────────────────
step "Uploading release to $BUILD_DIR"
"${SSH[@]}" -n "$VPS" "install -d -o $APP_USER -g www-data $BUILD_DIR"   # -n: don't eat stdin (confirm prompt)
rsync -rlpt --checksum --delete --chown="$APP_USER:www-data" \
  --exclude='/vendor/' --exclude='/.composer-home/' \
  -e "ssh -i $SSH_KEY -o BatchMode=yes" "$REL/" "$VPS:$BUILD_DIR/"
ok "uploaded"

step "Building vendor/ on server (composer --no-dev)"
"${SSH[@]}" "$VPS" bash -s -- "$BUILD_DIR" "$APP_USER" "$PHP_BIN" "$COMPOSER_BIN" <<'REMOTE'
set -euo pipefail
B=$1; U=$2; PHP=$3; COMPOSER=$4
cd "$B"
sudo -u "$U" env HOME="$B/.composer-home" COMPOSER_HOME="$B/.composer-home" \
  "$PHP" "$COMPOSER" install --no-dev --optimize-autoloader --no-interaction --no-progress 2>&1 \
  | grep -vE '^\s*-\s(Installing|Downloading|Removing|Upgrading)' | tail -8
# Autoload must use flat paths (the 11-04 failure)
if grep -q "/src/library" vendor/composer/autoload_classmap.php; then echo "  ✗ classmap references src/library"; exit 1; fi
sudo -u "$U" "$PHP" -r 'require "vendor/autoload.php"; exit(class_exists("FOSSBilling\\UpdateReadinessCheck") ? 0 : 1);' \
  || { echo "  ✗ autoload smoke test failed"; exit 1; }
echo "  ✓ vendor built, classmap flat, autoload OK"
REMOTE

step "Verifying build"
"${SSH[@]}" "$VPS" bash -s -- "$BUILD_DIR" "${REQUIRED_FILES[@]}" <<'REMOTE'
set -euo pipefail
B=$1; shift
miss=0; for f in "$@"; do [ -s "$B/$f" ] || { echo "  ✗ missing $f"; miss=1; }; done
[ $miss = 0 ] && echo "  ✓ all required files present"
exit $miss
REMOTE

# ── 3. Diff against live ───────────────────────────────────────────────────────
step "Changes that would be applied to $LIVE_DIR"
"${SSH[@]}" "$VPS" bash -s -- "$BUILD_DIR" "$LIVE_DIR" "$DIFF_FILE" "${EXCL_ARGS[@]}" <<'REMOTE'
set -eu
B=$1; L=$2; OUT=$3; shift 3
rsync -rlpt --checksum --delete --dry-run --itemize-changes "$@" "$B/" "$L/" > "$OUT"
# Classify each itemized line: deleted / new / content changed / attributes only.
# Group by the first 3 path components (vendor/ by 2) so thousands of files fit on a screen.
awk '
  { code=$1; path=$2 }
  code ~ /^\*deleting/ { kind="deleted" }
  code ~ /^[<>c]f\+\+\+/ || code ~ /^cd\+\+\+/ { kind="new" }
  code ~ /^[<>]f/ && code !~ /\+\+\+/ { kind=(substr(code,3,1)=="c" ? "changed" : "attrs-only") }
  code ~ /^\.[fd]/ { kind="attrs-only" }
  { n=split(path, p, "/"); depth=(p[1]=="vendor") ? 2 : 3
    g=p[1]; for (i=2; i<=depth && i<n; i++) g=g "/" p[i]
    if (path ~ /\/$/ && n-1 <= depth) { g=path; sub(/\/$/, "", g) }
    cnt[kind" "g]++; tot[kind]++ }
  END {
    printf "  totals:  new=%d  changed=%d  deleted=%d  attrs-only=%d\n", tot["new"], tot["changed"], tot["deleted"], tot["attrs-only"]
    for (k in cnt) { split(k, a, " "); if (a[1] != "attrs-only") printf "  %-8s %6d  %s\n", a[1], cnt[k], a[2] }
  }' "$OUT" | sort -k1,1 -k2,2nr | awk 'NR==1 || $1!=prev {seen=0} {prev=$1; if (++seen<=25) print}'
echo "  (full itemized list on server: $OUT)"
REMOTE

if $DRY_RUN; then
  echo; echo "(dry run — build is staged in $BUILD_DIR; live was not touched)"
  exit 0
fi

echo
read -r -p "Deploy $SHA to $SITE? Type 'deploy' to continue: " answer
[[ "$answer" == "deploy" ]] || die "aborted"

# ── 4. Backup + swap + post-deploy ─────────────────────────────────────────────
step "Backup, sync to live, post-deploy"
TS=$(date -u +%Y%m%d-%H%M%S)
"${SSH[@]}" "$VPS" bash -s -- "$BUILD_DIR" "$LIVE_DIR" "$APP_USER" "$DB_NAME" "$TS" "$PHP_BIN" "$PHP_FPM_SERVICE" "$BACKUP_DIR" "${EXCL_ARGS[@]}" <<'REMOTE'
set -euo pipefail
B=$1; L=$2; U=$3; DB=$4; TS=$5; PHP=$6; FPM=$7; BK=$8; shift 8
CODE_BAK=$BK/$U-code-$TS.tgz
DB_BAK=$BK/$U-db-$TS.sql.gz
mkdir -p "$BK"
tar czf "$CODE_BAK" -C "$L" --exclude=./data .
mysqldump --single-transaction "$DB" | gzip > "$DB_BAK"
echo "  ✓ backups: $CODE_BAK, $DB_BAK"

rsync -rlpt --checksum --delete "$@" "$B/" "$L/"
chown -R "$U:www-data" "$L"
chown "$U:$U" "$L/config.php" "$L/data/cache"
chmod 600 "$L/config.php"
echo "  ✓ synced + ownership"

find "$L/data/cache" -mindepth 1 -maxdepth 1 ! -name .gitkeep -exec rm -rf {} +
systemctl reload "$FPM"
echo "  ✓ cache cleared (incl. classMap.php), $FPM reloaded (opcache)"

cd "$L"
if ! sudo -u "$U" "$PHP" console.php system:run-patcher; then
  echo "  ✗ patcher failed"
  echo "  Rollback: mkdir /tmp/rb && tar xzf $CODE_BAK -C /tmp/rb && rsync -rlpt --delete --exclude=/config.php --exclude=/data/ /tmp/rb/ $L/ && chown -R $U:www-data $L"
  echo "  DB:       zcat $DB_BAK | mysql $DB"
  exit 1
fi
echo "  ✓ patcher done"
echo "  ✓ live reports: $(sudo -u "$U" "$PHP" console.php --version 2>/dev/null | head -1)"
echo "  Rollback if needed: code $CODE_BAK, DB $DB_BAK"
REMOTE

# ── 5. HTTP checks ─────────────────────────────────────────────────────────────
step "HTTP checks"
fail=0
check() { # path expected_code [content_type_substring]
  local r code ctype
  r=$(curl -s -o /dev/null -w '%{http_code} %{content_type}' --max-time 20 "$SITE$1") || r="000 -"
  code=${r%% *}; ctype=${r#* }
  if [[ "$code" == "$2" && ( -z "${3:-}" || "$ctype" == *"$3"* ) ]]; then ok "$1 → $code ${3:+($ctype)}"
  else echo "  ✗ $1 → $code $ctype (expected $2${3:+ $3})"; fail=1; fi
}
check /                                                         200
check /admin                                                    302
check /config.php                                               403
check /vendor/autoload.php                                      403
check /public/assets/js/api.js                                  200 javascript
check /public/assets/js/fossbilling.js                          200 javascript
check /themes/admin_default/assets/build/css/fossbilling.css    200 text/css
check /themes/admin_default/assets/build/js/fossbilling.js      200 javascript
[[ $fail == 0 ]] || die "HTTP checks failed. See rollback commands above."

echo; echo "Done — $SITE is at $SHA"
