# Changelog

## 1.2.0

- A plugin service reads the history, the Do Not Disturb flag and the plugin's own marks once for every monitor's bar, instead of each bar watching and rereading them on its own; the bells and panels on every monitor bind to it.
- The bell and panel reach the service under Omarchy's built-in bar and under replacement bars, whose shell offers no services: the service also registers itself in the plugin's `ServiceLink.js`, and the widget follows it when it starts later, is reloaded or stops.
- The IPC target belongs to the service: `open`, `show` and `toggle` act on the focused monitor's panel and `close` and `hide` on the open one, `state` reports whether any panel is open, and `readAll` acts as the button in an open panel, so its undo is offered there. The second bar no longer logs that its IPC handler will not be used.

## 1.1.1

- The bell widens to fit its missed count, so the number no longer covers the bar icons beside it; counts above 99 read **99+**, and a vertical bar shows the bell alone (the tooltip keeps the count).

## 1.1.0

- **Read all** (the panel button, `a`, or a right-click on the bell) marks every notification as read: the bell's count, the missed tags and the new dots clear until another notification closes; `u` undoes it.
- The replay button is labelled **Replay**, and the Replay, Read all and Clear all buttons stay in view below the list.
- The bell's tooltip names its middle- and right-click actions, and `readAll` is an IPC method for scripts and key bindings.

## 1.0.1

- Typing in the open panel runs its shortcuts (`x`, `u`, `d`, `r`, the filter digits) instead of searching; the search field takes the keyboard only after `/` or a click on it.

## 1.0.0

- Bell on the bar with the number of missed notifications (timed out or silenced while you were away) and a crossed bell during Do Not Disturb; a middle click toggles Do Not Disturb.
- Panel listing the notifications Omarchy keeps (24 hours, 100 rows) by day, with search, app filters, expandable text and a dot on what is new.
- A click opens a notification the way Omarchy opens one put back from history: its `--exec` command, the sender's window, the source's window or site, or the app.
- Remove notifications one by one or all at once, with undo; Omarchy's own history is never written.
- Replays the last six notifications on screen through Omarchy's notification service.
