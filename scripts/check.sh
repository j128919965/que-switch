#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
swift run --disable-sandbox --cache-path .build/cache --config-path .build/config \
  --security-path .build/security -Xswiftc -module-cache-path -Xswiftc .build/module-cache CoreChecks
