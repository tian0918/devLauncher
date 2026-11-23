#!/bin/zsh
set -eu

project_dir=${0:A:h:h}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/devlauncher-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

/usr/bin/swiftc -parse-as-library -module-cache-path "$scratch/cache" \
    "$project_dir"/Sources/{Projects,NVM,ManagedProcess,ProcessSupervisor,RunOutput,LauncherModel,ProjectTerminal,TCPPortStatus,ProjectIDE,ProjectGit}.swift \
    "$project_dir/Tests/Integration.swift" -o "$scratch/integration"
"$scratch/integration"
