#!/bin/bash
set -euo pipefail

trap 'printf "%s\n" "Installation stopped. Read the error above." >&2' ERR

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

REPO='jtrainer-tebra/tebra-saas-design-lab'
TARGET="$HOME/Tebra SaaS Design Lab"
GH_VERSION='2.99.0'
GH_ARCHIVE="gh_${GH_VERSION}_macOS_arm64.zip"
GH_SHA256='94d4bd7e88563a9cb414e651e88acc4f1728a87476752460906d824230748d37'
OWNED_PATHS=(
  'packages/web/src/app/(design)/concepts'
  'packages/web/flows'
  'packages/web/flow-backups'
  'tolaria-vault'
)

[[ $# -le 1 ]] || die 'Use one old Lab folder or find.'

printf '%s\n' 'Checking your Mac.'
[[ "$(uname -m)" == 'arm64' ]] || die 'This Lab needs an Apple Silicon Mac.'

printf '%s\n' 'Checking macOS command line tools.'
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || true
  printf '%s\n' 'macOS is asking to install its command line tools. Click Install and Agree; I will keep going when it finishes.'
  for ((poll = 0; poll < 180; poll += 1)); do
    if xcode-select -p >/dev/null 2>&1; then
      break
    fi
    sleep 10
  done
  xcode-select -p >/dev/null 2>&1 || die 'macOS command line tools did not finish installing within 30 minutes.'
fi

printf '%s\n' 'Finding GitHub CLI.'
if [[ -f "$HOME/.design-lab/bin/gh" ]]; then
  GH="$HOME/.design-lab/bin/gh"
elif command -v gh >/dev/null 2>&1; then
  GH="$(command -v gh)"
else
  GH_HOME="$HOME/.design-lab/bin"
  GH_TMP="$(mktemp -d)"
  trap 'rm -rf "$GH_TMP"' EXIT
  mkdir -p "$GH_HOME"
  curl --fail --location --silent --show-error \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${GH_ARCHIVE}" \
    -o "$GH_TMP/$GH_ARCHIVE"
  printf '%s  %s\n' "$GH_SHA256" "$GH_TMP/$GH_ARCHIVE" | shasum -a 256 -c - >/dev/null || die 'GitHub CLI download did not match its official checksum.'
  unzip -q -j "$GH_TMP/$GH_ARCHIVE" "gh_${GH_VERSION}_macOS_arm64/bin/gh" -d "$GH_HOME"
  chmod 755 "$GH_HOME/gh"
  GH="$GH_HOME/gh"
  xattr -d com.apple.quarantine "$GH" 2>/dev/null || true
fi
"$GH" --version >/dev/null || die 'GitHub CLI could not run.'

printf '%s\n' 'Signing in to GitHub.'
if ! "$GH" auth status -h github.com >/dev/null 2>&1; then
  printf '%s\n' 'Copy the code below, open the link, paste the code, approve.'
  "$GH" auth login -h github.com -p https -w --skip-ssh-key
fi
"$GH" auth setup-git
if ! LOGIN="$("$GH" api user --jq .login)"; then
  die 'GitHub could not identify the signed-in user.'
fi
if ! "$GH" repo view "$REPO" --json name >/dev/null 2>&1; then
  die "GitHub user $LOGIN does not have access to the Lab yet. Send that username to Jay."
fi

printf '%s\n' 'Cloning your Lab.'
[[ ! -e "$TARGET" ]] || die 'There is already a Lab at that path. Open it, or move it aside first.'
"$GH" repo clone "$REPO" "$TARGET"
cd "$TARGET"
git switch -c lab/workspace
git config --local user.name "$LOGIN"
git config --local user.email "$LOGIN@users.noreply.github.com"

printf '%s\n' 'Preparing the bundled runtime.'
gunzip -k runtime/node/bin/node.gz
chmod +x runtime/node/bin/node runtime/node/bin/pnpm
export PATH="$PWD/runtime/node/bin:$PATH"
[[ "$(node --version)" == v24.* ]] || die 'The bundled Node runtime is not version 24.'
[[ "$(pnpm --version)" == '11.6.0' ]] || die 'The bundled pnpm is not version 11.6.0.'

printf '%s\n' 'Installing Lab dependencies.'
CI=true pnpm install --frozen-lockfile

printf '%s\n' 'Checking the Lab.'
pnpm --filter @nitro-alpha/web test:design-mode

OLD="${1:-}"
if [[ "$OLD" == 'find' ]]; then
  printf '%s\n' 'Finding your old Lab.'
  MATCHES=()
  while IFS= read -r RELEASE; do
    if grep -Eq '"channel"[[:space:]]*:[[:space:]]*"tebra-saas"' "$RELEASE"; then
      MATCHES+=("${RELEASE%/lab-release.json}")
    fi
  done < <(find "$HOME" -maxdepth 4 -name lab-release.json -not -path "$TARGET/*" 2>/dev/null)
  if [[ ${#MATCHES[@]} -ne 1 ]]; then
    if [[ ${#MATCHES[@]} -eq 0 ]]; then
      printf '%s\n' 'No Tebra SaaS Lab folder was found.'
    else
      printf '%s\n' "Found these Tebra SaaS Lab folders: ${MATCHES[*]}"
    fi
    die 'tell Jay which folder is your Lab.'
  fi
  OLD="${MATCHES[0]}"
  printf '%s\n' "Using old Lab at $OLD."
elif [[ -n "$OLD" ]]; then
  [[ -d "$OLD" && -f "$OLD/lab-release.json" ]] || die "Old Lab folder is not a Lab: $OLD"
  grep -Eq '"channel"[[:space:]]*:[[:space:]]*"tebra-saas"' "$OLD/lab-release.json" || die "Old Lab folder is not a Tebra SaaS Lab: $OLD"
fi

if [[ -n "$OLD" ]]; then
  printf '%s\n' 'Copying your designer work into the new Lab.'
  if lsof -ti :3001 >/dev/null 2>&1; then
    die "Close the old Lab's Terminal window first, then run this again."
  fi
  INVENTORY="$(mktemp)"
  (
    cd "$OLD"
    for OWNED_PATH in "${OWNED_PATHS[@]}"; do
      [[ -e "$OWNED_PATH" ]] && find "$OWNED_PATH" -type f ! -name .DS_Store -exec shasum -a 256 {} +
    done
  ) > "$INVENTORY"
  for OWNED_PATH in "${OWNED_PATHS[@]}"; do
    if [[ -e "$OLD/$OWNED_PATH" ]]; then
      mkdir -p "$TARGET/$(dirname "$OWNED_PATH")"
      ditto "$OLD/$OWNED_PATH" "$TARGET/$OWNED_PATH"
    fi
  done
  if ! (cd "$TARGET" && shasum -a 256 -c "$INVENTORY"); then
    rm -f "$INVENTORY"
    die 'Migration hash check failed for a file named above.'
  fi
  rm -f "$INVENTORY"
  pnpm --filter @nitro-alpha/web flows:build
  printf '%s\n' "Your old Lab folder is untouched at $OLD. Keep it for a week, then it can go in the Trash."
fi

printf '%s\n' 'Checking the installed Lab.'
if ! runtime/node/bin/node scripts/lab/update.mjs --doctor; then
  die 'The Lab doctor could not complete repairs.'
fi

printf '%s\n' 'Opening your Lab.'
open "$TARGET/start-lab.command"
printf '%s\n' 'Your Lab is starting and will open in your browser. The folder is ~/Tebra SaaS Design Lab.'
