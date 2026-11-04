# Groups and the managed block

A **group** is a named set of hosts lines you switch together. A **line** is one `IP hostname` pair. Both can be turned on and off from the window or, for existing ones, from the [command](agents.md).

Groups live in `~/Library/Application Support/BorkHosts/groups.json`. What is on is not remembered there: it is read from `/etc/hosts` every time, so the window always shows what the file really says.

## The managed block

The app writes only between two marker lines in `/etc/hosts`:

```text
127.0.0.1 localhost

# BEGIN: bork-hosts
192.0.2.10 example.com
#192.0.2.10 api.example.com
# END: bork-hosts
```

- A line in the block without a leading `#` is **on**. A commented line is **off**. A line that is in a group but not in the block is **missing**, which the window treats as off.
- Everything outside the block, including lines you added by hand, is never read as a group line and never changed. The app checks this on every write and refuses one that would alter anything outside the markers.
- If the file has no block yet, the app adds one the first time you switch something on.

### Repairing the markers

If the `# BEGIN: bork-hosts` and `# END: bork-hosts` lines are missing, duplicated or out of order, the app stops and says which problem it found. Nothing is changed until you fix them by hand: keep exactly one of each, with `BEGIN` first. Markers are matched ignoring trailing blanks only, so retype them exactly if a copy and paste has altered them.

## States

| State   | Meaning                                       |
| ------- | --------------------------------------------- |
| On      | Every line in the group is enabled            |
| Off     | No line in the group is enabled               |
| Mixed   | Some lines are on and some are off            |

Clicking a mixed group turns all of its lines on.

## One IP per hostname

Only one IP can be enabled for a hostname at a time, because a hosts file uses the first match. Turning on a group or line that names a hostname already enabled with a different IP turns the older line off in the same write, and a banner lists what was turned off, for example `Turned off 192.0.2.20 example.com`.

A line whose hostname is enabled elsewhere with a different IP shows a warning icon in the sidebar.

## Adding and editing

- **Add Group** takes a name and pasted hosts lines. Blank lines and `#` comments are skipped. Several hostnames after one IP become several lines. The group is saved, then switched on in one write. If you cancel the dialog, the group stays in the sidebar, off.
- **Add Line…**, **Edit…**, **Rename** and the delete buttons are on each group and line. Editing a line rewrites it in place and keeps its on or off state.
- **Delete Group** and **Delete Line** remove the lines from `/etc/hosts` as well as from the sidebar, after asking you to confirm.
- A group name cannot be blank. An IP and hostname must be valid, and `localhost` and `broadcasthost` are refused. The same IP and hostname pair cannot be in two groups, and one group cannot give a hostname two different IPs (two groups can, which is what the rule above resolves). A rejected entry says why and changes nothing.

Agents and scripts cannot do any of this. See [Agents and scripts](agents.md).

## Backups and safe writes

Before each write the app saves a copy of the current `/etc/hosts` to `~/Library/Application Support/BorkHosts/backups/` as `hosts-YYYYMMDD-HHMMSS-mmm`, and keeps the newest 20. If the backup cannot be written, nothing is written to the hosts file. To undo a change by hand, copy a backup over `/etc/hosts` with `sudo`.

The app also refuses to write a file that has no enabled `localhost` line, or that is not valid UTF-8 text. How each write is verified is in [Safety model](security.md).

## When the file changes under you

The app rereads `/etc/hosts` at launch and whenever it becomes the active app, so an edit made in a terminal shows up as soon as you switch back. A write that finds the file changed since the last read is not applied blindly: the app reads again, reapplies your change to the new content, and tries once more. If the file changes again, the write is refused and nothing is lost.
