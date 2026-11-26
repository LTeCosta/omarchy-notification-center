# Notification Center

An [Omarchy](https://omarchy.org) bar widget for the notifications you did not catch in time. A bell on the bar counts the ones that vanished while you were away, and its panel lists everything Omarchy kept from the last 24 hours, ready to search, open again or remove.

It reads what Omarchy's own notification service already stores and adds no daemon and no archive: the history stays Omarchy's, 100 notifications for at most 24 hours.

The plugin is a bar widget and a shell service. The service (`Service.qml`) runs once, however many monitors have a bar: it watches the history, Do Not Disturb and the plugin's own state, keeps the marks and answers IPC. Each monitor's bell and panel (`Panel.qml`) bind to it, so every bell shows the same count, while each panel keeps its own search, filter and new-row dots.

The widget works under Omarchy's built-in bar and under replacement bars. The built-in bar's shell hands a widget its plugin's service; a replacement bar's shell has no services, so the service also registers itself in `ServiceLink.js`, a script every QML file of the plugin shares, and the widget takes it from there. A service that starts later, is reloaded or stops is followed at once; until one runs, the bell shows nothing missed and the panel an empty list.

## Requirements

- Omarchy 4.5 or later, with its built-in notification service (`omarchy.notifications`), which writes `~/.local/state/omarchy/notifications/history.json`.
- Hyprland (`hyprctl`) for focusing windows.

## Install

From a checkout of this repository:

```bash
scripts/install notification-center
omarchy plugin enable io.github.ltecosta.notification-center
```

The widget's default place is the right side of the bar; move it with `omarchy bar move io.github.ltecosta.notification-center --section <section>`.

## The bell

- **󰂚** nothing missed.
- **󱅫** in the accent color, with a count beside it: notifications that timed out on screen, or arrived during Do Not Disturb, since you last opened the panel. The widget widens to fit the count, which stops at **99+**; a vertical bar shows only the bell and the tooltip gives the count.
- **󰂛** Do Not Disturb is on.

A click opens the panel, a middle click toggles Do Not Disturb, and a right click marks everything read.

## The panel

Notifications are listed newest first under Today, Yesterday and Earlier, with the sender's icon, the arrival time, the summary and two lines of the text. Missed ones carry a **missed** or **silenced** tag, and the ones that arrived since you last looked carry a dot.

| | Key | |
|---|---|---|
| Click a notification | Enter | Opens it and closes the panel |
| Expand button | Space | Shows its whole text |
| Remove button | `x`, Delete | Removes it from the list |
| Search field | `/` | Shows the notifications whose app, summary and text hold every word typed. Escape empties it, then leaves it; Down or Enter moves to the list |
| App chips | `h` / `l`, `0`–`4` | All, or one of the four apps with the most notifications |
| **Silence** | `d` | Do Not Disturb |
| **Replay** | `r` | Puts the last six back on screen as cards, with their buttons |
| **Read all** | `a` | Marks every notification read: the bell's count, the missed tags and the new dots clear until another one closes |
| **Clear all** | | Empties the list |
| **Undo** | `u` | Undoes the last removal, Clear all or Read all |

`j` / `k` and the arrow keys move between items; Escape closes the panel.

### Opening a notification

An app's own actions, such as the chat a Teams card opens, end with the notification. A click on a stored one does what Omarchy does for a notification put back from history, in this order:

1. Omarchy's `--exec` command, when the notification carries one: a screenshot opens its file.
2. The window of the process that sent it.
3. A window whose class or web-app host matches the source, or a browser tab whose title names a web source's site.
4. `https://<site>/` for a notification from a web page.
5. `omarchy-hyprland-focus-app` with the app's name.

## Settings

| Setting | Default | |
|---|---|---|
| Bar label | `Missed` | `Missed` shows the count beside the bell, `None` only colors it |

## What it stores

Removing, clearing, reading all and the "last looked" time are kept in `~/.local/state/omarchy/io.github.ltecosta.notification-center/state.json` (directory mode 0700): three timestamps and the ids of removed notifications, never their text. Omarchy's history file is only read, so its replay shortcut (Super + Shift + Alt + ,) still has everything until it ages out.

Do Not Disturb and the replay go through Omarchy's notification service (`omarchy-shell notifications toggleDnd`, `showHistory`). Notification text is shown as plain text: markup is removed, and only theme icon names are looked up.

## IPC

```bash
omarchy-shell io.github.ltecosta.notification-center toggle   # open, close, show, hide
omarchy-shell io.github.ltecosta.notification-center state    # JSON for scripts and checks
omarchy-shell io.github.ltecosta.notification-center readAll  # Read all, from a script or key binding
```

The service answers the target. `open`, `show` and `toggle` act on the panel of the focused monitor and `close` and `hide` on the open one, through `omarchy-shell shell summon|hide|toggle`. `state` reports the shared counts and marks, whether any panel is open, and the search, filter and seen mark of the open panel (or of the first bar's panel when none is open). `readAll` acts as the button in an open panel, which then offers its undo. Bind `toggle` to a key to open the panel from the keyboard.

## Development

The parsing, search, filtering, marking and opening rules are in `Model.js`, a QML JavaScript library that runs in Node as well:

```bash
node --test
bash tests/service.smoke.sh   # the service, two bars' widgets and a replacement bar's in a headless Quickshell
```

The smoke test runs in a temporary home with a fake `omarchy-shell` and skips itself without `qs` or the Omarchy shell kit. QML changes take effect after `omarchy-restart-shell`.

## License

MIT
