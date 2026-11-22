#!/usr/bin/env bash
# Publish the latest stable upstream release with patches/*.patch applied.
#
# Release tags are vX.Y.Z.N: X.Y.Z is the upstream version, N counts the
# builds of it. Home Assistant compares versions with AwesomeVersion, which
# ranks v2.2.1.1 above the upstream v2.2.1 and v2.2.2.1 above v2.2.1.N.
#
# Each build is a commit on main whose parent is the previous main, so pushes
# never contain upstream commits. Upstream commits often change workflow
# files, which GITHUB_TOKEN may not push. The fork's own .github/ and
# patches/ replace upstream's in every build.
#
# Runs from a full clone of the fork with main checked out. Needs GH_TOKEN
# with contents: write.
set -euo pipefail

upstream_repo=steamEngineer/bravia-quad-homeassistant
component=custom_components/bravia_quad
asset=bravia_quad.zip
fork_paths=(.github patches)

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

upstream_release=$(gh api "repos/$upstream_repo/releases/latest")
upstream_tag=$(jq -r .tag_name <<<"$upstream_release")
upstream_version=${upstream_tag#v}
if [[ ! $upstream_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Upstream release $upstream_tag is not X.Y.Z"
  exit 1
fi
echo "Latest upstream release: $upstream_tag"

git fetch --quiet --no-tags "https://github.com/$upstream_repo.git" \
  "+refs/tags/$upstream_tag:refs/upstream/$upstream_tag"

work=$(mktemp -d)
out=$(mktemp -d)
trap 'git worktree remove --force "$work"; rm -rf "$out"' EXIT
git worktree add --quiet --detach "$work" "refs/upstream/$upstream_tag"

applied=()
no_change=()
for patch in patches/*.patch; do
  before=$(git -C "$work" write-tree)
  if ! git -C "$work" apply --3way "$repo_root/$patch"; then
    echo "::error::$patch does not apply to upstream $upstream_tag"
    exit 1
  fi
  if [[ $(git -C "$work" write-tree) == "$before" ]]; then
    echo "::warning::$patch changes nothing on top of upstream $upstream_tag, delete it"
    no_change+=("$patch")
  else
    applied+=("$patch")
  fi
done

set_version() {
  python3 - "$work/$component/manifest.json" "$1" <<'EOF'
import json
import sys

path, version = sys.argv[1:]
with open(path) as file:
    manifest = json.load(file)
manifest["version"] = version
with open(path, "w") as file:
    json.dump(manifest, file, indent=2)
    file.write("\n")
EOF
  git -C "$work" add "$component/manifest.json"
}

last_build=$(git tag --list "v$upstream_version.*" |
  sed -n "s/^v${upstream_version//./\\.}\.\([0-9][0-9]*\)$/\1/p" |
  sort -n | tail -n 1)
if [[ -n $last_build ]]; then
  # What the last build would contain if it were made now
  set_version "$upstream_version.$last_build"
  component_tree=$(git -C "$work" rev-parse "$(git -C "$work" write-tree):$component")
  if [[ $component_tree == $(git rev-parse "v$upstream_version.$last_build:$component") ]]; then
    echo "v$upstream_version.$last_build is up to date"
    exit 0
  fi
fi
version="$upstream_version.$((${last_build:-0} + 1))"
set_version "$version"

# The upstream tree, with the fork's own top-level paths in place of upstream's
upstream_tree=$(git -C "$work" write-tree)
tree=$(
  {
    git ls-tree "$upstream_tree" |
      awk -F '\t' -v fork="${fork_paths[*]}" \
        'BEGIN { split(fork, paths, " "); for (i in paths) skip[paths[i]] } !($2 in skip)'
    git ls-tree HEAD -- "${fork_paths[@]}"
  } | git mktree
)

export GIT_AUTHOR_NAME="github-actions[bot]"
export GIT_AUTHOR_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
commit=$(git commit-tree "$tree" -p HEAD \
  -m "Build v$version from upstream $upstream_tag" \
  -m "$(printf 'Patches applied:\n'; printf -- '- %s\n' "${applied[@]:-none}")")

(cd "$work/$component" && zip -q -r "$out/$asset" .)

notes=$(
  printf 'Upstream [%s](%s) with these patches:\n\n' \
    "$upstream_tag" "$(jq -r .html_url <<<"$upstream_release")"
  for patch in "${applied[@]}"; do
    subject=$(git mailinfo --encoding=UTF-8 /dev/null /dev/null <"$patch" |
      sed -n 's/^Subject: //p')
    printf -- '- %s\n' "${subject:-$patch}"
  done
  if ((${#no_change[@]})); then
    printf '\nNo longer needed, upstream has these changes: %s\n' "${no_change[*]}"
  fi
  printf '\n---\n\n## Upstream release notes\n\n%s\n' "$(jq -r '.body // ""' <<<"$upstream_release")"
)

git push --quiet origin "$commit:refs/heads/main"
gh release create "v$version" "$out/$asset" --target "$commit" --latest \
  --title "v$version" --notes "$notes"
echo "Published v$version"
