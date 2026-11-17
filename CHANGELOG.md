# Changelog

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
