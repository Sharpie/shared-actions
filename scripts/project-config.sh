#!/usr/bin/env bash
#
# Compute the acceptance test configuration (including the OS matrix) for one
# OpenVox suite.
#
# The OS matrix is DERIVED from what a given release line actually builds: the
# build platform lists in ../platforms.json are mapped to acceptance OS names
# and intersected with the universe of OSes nested_vms can provision. This keeps
# the acceptance matrix in step with the packages that exist, so 9.0 (main) is
# reduced to its smaller server/db platform set while 8.x still tests the full
# legacy list.
#
# The static, per-suite acceptance config lives in ./project_defaults.json; this
# script merges the derived matrix and the openvox server-fallback information
# into it and prints the combined JSON object on stdout.
#
# Usage:
#   project-config.sh <suite> <collection> [<qemu>]
#
#   suite       openvox | openvox-agent | openvox-server | openvoxdb
#   collection  openvox collection (openvox9 -> main, openvox8 -> 8.x, else main)
#   qemu        "true" when running arm64 guests under qemu (limits the matrix)
#
# Environment:
#   PLATFORMS_JSON  override the path to platforms.json (default ../platforms.json)
#
# Example:
#   scripts/project-config.sh openvox-server openvox9 | jq .
set -euo pipefail

suite=${1:?usage: project-config.sh <suite> <collection> [<qemu>]}
collection=${2:?usage: project-config.sh <suite> <collection> [<qemu>]}
qemu=${3:-false}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
platforms="${PLATFORMS_JSON:-${script_dir}/../platforms.json}"
project_defaults="${script_dir}/project_defaults.json"

# The universe of OSes nested_vms can actually provision. The derived matrix is
# always a subset of this, so build targets we cannot stand up as VMs (e.g. 8.x
# el-7 -> alma/rocky 7 or ubuntu-25.04, and non-VM families like sles, fedora,
# amazon, macos and windows) never leak into the matrix.
universe='[
  ["almalinux","10"]
]'
# Under qemu, the openvox suite (which shards its tests) is limited to this
# subset to stay under the GHA 6 hour job limit; the other suites drop ubuntu.
arm64_sharded='[["rocky","9"],["debian","13"]]'

# Map the openvox collection to a platforms.json release-line key.
case "$collection" in
  openvox8) branch="8.x" ;;
  *)        branch="main" ;;
esac

# jq: turn a list of build-platform strings (e.g. "el-9", "debian-13",
# "ubuntu-24.04-amd64") into acceptance [os, version] pairs. Arch suffixes are
# stripped, "el-N" expands to both almalinux and rocky (which the acceptance
# suite tests separately), and non-VM families are dropped.
map_platforms='
  def strip_arch: sub("-(x86_64|amd64|aarch64|arm64|armhf)$"; "");
  def map_platform:
    strip_arch as $s
    | if   ($s | test("^el-[0-9]+$"))
        then ($s | ltrimstr("el-")) as $v | [["almalinux", $v], ["rocky", $v]]
      elif ($s | test("^debian-[0-9]+$"))
        then [["debian", ($s | ltrimstr("debian-"))]]
      elif ($s | test("^ubuntu-[0-9.]+$"))
        then [["ubuntu", ($s | ltrimstr("ubuntu-"))]]
      else [] end;
  ([ .[] | map_platform ] | add) // [] | unique
'
# jq: keep only the universe entries present in the mapped build set ($set),
# preserving universe ordering.
intersect='. as $uni | $uni | map(select(. as $u | ($set | any(. == $u))))'

# Which build list gates this suite: the agent (vanagon) list for the agent
# suites, or the combined server/db (ezbake) list otherwise.
case "$suite" in
  openvox|openvox-agent)
    build_list=$(jq -c --arg b "$branch" '.[$b].vanagon' "$platforms") ;;
  openvox-server|openvoxdb)
    build_list=$(jq -c --arg b "$branch" '(.[$b]["ezbake-deb"] + .[$b]["ezbake-rpm"])' "$platforms") ;;
  *)
    echo "Unknown suite '$suite'" >&2; exit 1 ;;
esac
# The server/db build list is always needed to decide when a fall back is needed
# to test an agent platform that does not have a corresponding server build.
server_list=$(jq -c --arg b "$branch" '(.[$b]["ezbake-deb"] + .[$b]["ezbake-rpm"])' "$platforms")

# Translate platforms.json OS names to nested_vms tuples.
build_os=$(jq -c "$map_platforms" <<<"$build_list")
server_build_os=$(jq -c "$map_platforms" <<<"$server_list")

os=$(jq -c --argjson set "$build_os" "$intersect" <<<"$universe")
server_capable_os=$(jq -c --argjson set "$server_build_os" "$intersect" <<<"$universe")

# Merge the static per-suite config with the derived matrix and server info.
# acceptance-shard-tags defaults to [] so every suite exposes the key.
config=$(jq -c \
  --arg suite "$suite" \
  --argjson os "$os" \
  --argjson server_capable_os "$server_capable_os" \
  '.[$suite]
    | .os = $os
    | .["server-capable-os"] = $server_capable_os
    | .["server-fallback-os"] = ["debian", "13"]
    | .["acceptance-shard-tags"] //= []' \
  "$project_defaults")

# Under qemu, limit the OS matrix. This operates on the already-derived matrix,
# so an OS with no build is never reintroduced.
if [[ "$qemu" == "true" ]]; then
  shard_count=$(jq '.["acceptance-shard-tags"] | length' <<<"$config")
  if [[ "$shard_count" -gt 0 ]]; then
    limited=$(jq -c --argjson set "$arm64_sharded" "$intersect" <<<"$os")
    config=$(jq -c --argjson os "$limited" '.os = $os' <<<"$config")
  elif [[ "$suite" != "openvox-agent" ]]; then
    limited=$(jq -c 'map(select(.[0] != "ubuntu"))' <<<"$os")
    config=$(jq -c --argjson os "$limited" '.os = $os' <<<"$config")
  fi
fi

echo "$config"
