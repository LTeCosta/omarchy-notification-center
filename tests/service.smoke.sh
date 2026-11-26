#!/usr/bin/env bash
# Smoke test of Service.qml and Panel.qml in a headless Quickshell: one
# service and two bar widgets (two monitors) built on the installed Omarchy
# shell kit, with a stand-in KeyboardPanel and stand-in bars. It checks that
# both bells bind to the one service, that only it registers the IPC target,
# the per-panel seen mark and undo, the `state` and `readAll` IPC answers, the
# routing of open, close and toggle through the shell, Do Not Disturb and its
# failure, the state file, a rebuilt bar, a widget under a replacement bar
# (whose shell has no services) reaching the service through ServiceLink.js,
# a service reload, and that widget once no service is left.
#
# Everything runs in a temporary home with a fake omarchy-shell first on PATH;
# the live shell, the real state directory and Hyprland are never touched.
# Skips itself when qs or the shell kit is missing.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin=$(dirname "$here")
kit=${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}

if ! command -v qs >/dev/null; then
  echo "service.smoke.sh: skipped: qs not installed"
  exit 0
fi
if [[ ! -d $kit/Ui || ! -d $kit/Commons ]]; then
  echo "service.smoke.sh: skipped: no Omarchy shell kit at $kit"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
config="$tmp/config"
mkdir -p "$config/Ui" "$tmp/bin" "$tmp/fake" "$tmp/home" "$tmp/run"
chmod 700 "$tmp/run"
cp "$plugin"/*.qml "$plugin"/*.js "$plugin/manifest.json" "$config/"
cp -r "$plugin/i18n" "$config/"
cp "$here/smoke/shell.qml" "$config/shell.qml"
ln -s "$kit/Commons" "$config/Commons"
for file in "$kit"/Ui/*; do
  [[ ${file##*/} == KeyboardPanel.qml ]] || ln -s "$file" "$config/Ui/"
done
cp "$here/smoke/KeyboardPanel.qml" "$config/Ui/KeyboardPanel.qml"

# omarchy-shell logs its arguments; `notifications toggleDnd` turns Do Not
# Disturb on as Omarchy does, in quiet.json, or fails once the driver has
# created fake/fail.
cat > "$tmp/bin/omarchy-shell" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_DIR:?}/calls"
[[ -e $FAKE_DIR/fail ]] && exit 1
if [[ $1 == notifications && $2 == toggleDnd ]]; then
  printf '%s\n' '{"dnd":true}' > "${FAKE_QUIET:?}"
  echo on
fi
exit 0
SCRIPT
chmod 755 "$tmp/bin/omarchy-shell"
: > "$tmp/fake/calls"

# Omarchy's history: a timed-out row after the seen mark, a dismissed one and
# a silenced one before it, from three apps.
now=$(date +%s)
service_dir="$tmp/home/.local/state/omarchy/notifications"
mkdir -p "$service_dir"
row() { printf '{"key":"%s","app":"%s","summary":"%s","body":"Body","closed_ts":%s,"ts":%s,"closed_reason":"%s","urgency":1}' "$@"; }
printf '[%s,%s,%s]\n' \
  "$(row a Alpha One $((now - 100)) $((now - 110)) expired)" \
  "$(row b Beta Two $((now - 200)) $((now - 210)) dismissed)" \
  "$(row c Gamma Three $((now - 300)) $((now - 310)) silenced)" > "$service_dir/history.json"
printf '%s\n' '{"dnd":false}' > "$service_dir/quiet.json"
state="$tmp/home/.local/state/omarchy/io.github.ltecosta.notification-center"
mkdir -p "$state"
printf '{"schema":1,"seen_ts":%s,"cleared_ts":0,"read_ts":0,"hidden":[]}\n' $((now - 250)) > "$state/state.json"

output=$(cd "$tmp" && env -u HYPRLAND_INSTANCE_SIGNATURE -u WAYLAND_DISPLAY -u DISPLAY -u QT_QPA_PLATFORMTHEME -u QT_IM_MODULE \
  HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" XDG_STATE_HOME="$tmp/home/.local/state" XDG_CONFIG_HOME="$tmp/home/.config" \
  XDG_CACHE_HOME="$tmp/home/.cache" XDG_DATA_HOME="$tmp/home/.local/share" \
  PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp/fake" FAKE_QUIET="$service_dir/quiet.json" SMOKE_NOW="$now" \
  QT_QPA_PLATFORM=offscreen NO_COLOR=1 \
  timeout 150 qs -p "$config/shell.qml" 2>&1)
status=$?

results=$(printf '%s\n' "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'SMOKE .*' | sed 's/^SMOKE //')
printf '%s\n' "$results" | grep -v '^done ' | sed 's/^/service.smoke.sh: /'
done_line=$(printf '%s\n' "$results" | grep '^done ' | tail -n 1)
checks=$(printf '%s\n' "$results" | grep -c '^ok')
if [[ $done_line != "done 0" ]] || printf '%s\n' "$results" | grep -q '^not ok'; then
  echo "service.smoke.sh: FAILED (qs exit $status${done_line:+, $done_line})" >&2
  [[ -z $done_line ]] && printf '%s\n' "$output" | tail -n 40 >&2
  exit 1
fi
# The plugin's own QML must run without warnings. The theme's colours do not
# resolve in the headless run (the live shell assigns them), so those are not
# counted.
warnings=$(printf '%s\n' "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'WARN|ERROR' \
  | grep -E '@(Service|Panel|EntryRow)\.qml\[' | grep -v 'Unable to assign \[undefined\] to QColor' || true)
if [[ -n $warnings ]]; then
  printf '%s\n' "$warnings" | sed 's/^/service.smoke.sh: /' >&2
  echo "service.smoke.sh: FAILED (warnings from the plugin's QML)" >&2
  exit 1
fi
echo "service.smoke.sh: passed ($checks checks)"
