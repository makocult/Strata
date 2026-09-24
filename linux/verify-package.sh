#!/bin/bash
# Run INSIDE a fresh Ubuntu 24.04 container. Do not run on the build host.
set -euo pipefail
package=${1:?absolute package path required}
results=${2:?isolated results directory required}
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends "$package" xvfb xauth dbus-x11 fonts-noto-cjk
useradd --create-home --uid 12345 strata-test
install -d -o strata-test -g strata-test "$results"
dpkg-query -W -f='${Package} ${Version} ${Architecture} ${Status}\n' strata
/usr/bin/strata --version
runuser -u strata-test -- env HOME=/home/strata-test \
  XDG_DATA_HOME=/home/strata-test/.local/share \
  XDG_CONFIG_HOME=/home/strata-test/.config \
  QT_QPA_PLATFORM=xcb \
  dbus-run-session -- xvfb-run -a -s '-screen 0 1440x1000x24' \
  /usr/bin/strata --smoke-test "$results/installed-smoke.json"
test -s "$results/installed-smoke.json"
# A normal launch (not only the smoke entry point) must survive a live event loop.
set +e
runuser -u strata-test -- env HOME=/home/strata-test QT_QPA_PLATFORM=xcb \
  timeout 5s dbus-run-session -- xvfb-run -a /usr/bin/strata
status=$?
set -e
if [[ "$status" != 124 ]]; then
  printf 'Normal GUI launch exited unexpectedly: %s\n' "$status" >&2
  exit 1
fi
printf 'INSTALLED_GUI_AND_NORMAL_STARTUP_OK\n'
