#!/bin/sh
# Runs the integration suite (and, in the same binary, the pure one) against real git.
#
# The wrapper exists for one reason: `eliot.build.Git`'s `transportUrl` prepends `https://` to every
# dependency URL, so a cold clone always asks git for `https://github.com/x/foo`. Git's own `insteadOf`
# rewrites that onto the fixture repositories this run builds under `target/it/fixtures`, so the clone path
# is exercised for real, offline, with no change to `src/` and no network.
#
# `GIT_CONFIG_GLOBAL` is set from here rather than from the program because `eliot.system.Process` runs a
# command in a working directory and does not set a child's environment, and `eliot.system.Environment` only
# reads. `GIT_CONFIG_NOSYSTEM` keeps a system-wide config from leaking in.
#
# Usage: it/run.sh [path-to-IntegrationRunner.jar]      (run from the repository root)
set -e

jar="${1:-target/IntegrationRunner.jar}"
root="$(pwd)"
config="$root/target/it-gitconfig"

mkdir -p "$root/target"
cat > "$config" <<EOF
[url "$root/target/it/fixtures/foo"]
	insteadOf = https://github.com/x/foo
[url "$root/target/it/fixtures/bar"]
	insteadOf = https://github.com/x/bar
EOF

GIT_CONFIG_GLOBAL="$config" GIT_CONFIG_NOSYSTEM=1 java -jar "$jar"
