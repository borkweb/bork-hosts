import Foundation

/// The compare-and-swap shell script run (as root in production) to replace the hosts file.
/// Arguments: target, newContentFile, expectedCurrentSHA256, expectedNewSHA256, flushFlag (1 or 0).
///
/// Order matters:
/// 1. Copy the content file to a temp path next to the target. The copy, not the user-writable
///    source, is what gets verified and moved, so the source cannot be swapped after the check.
/// 2. Verify the copy's SHA-256 (exit 4), then verify the target still has the expected SHA-256 (exit 3).
/// 3. Give the copy the target's mode and owner, run `sync` so the new data is on disk before the
///    rename can be (a power loss must not leave a short or empty file), then `mv -f` it over the
///    target (one atomic rename).
/// 4. Optionally flush the DNS cache; failures are ignored.
/// Tools use absolute paths because the root shell started by osascript has a minimal PATH.
public enum ApplyScript {
    public static let exitStale: Int32 = 3
    public static let exitContentTampered: Int32 = 4

    public static let source: String = #"""
    set -eu
    target=$1
    newfile=$2
    expected_current=$3
    expected_new=$4
    flush=$5
    tmp="$(/usr/bin/dirname "$target")/.hosts.bork.$$"
    trap '/bin/rm -f "$tmp"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    /bin/cp "$newfile" "$tmp"
    actual_new=$(/usr/bin/shasum -a 256 "$tmp" | /usr/bin/cut -d' ' -f1)
    [ "$actual_new" = "$expected_new" ] || exit 4
    actual_current=$(/usr/bin/shasum -a 256 "$target" | /usr/bin/cut -d' ' -f1)
    [ "$actual_current" = "$expected_current" ] || exit 3
    mode=$(/usr/bin/stat -f %Lp "$target")
    owner=$(/usr/bin/stat -f %Su:%Sg "$target")
    /bin/chmod "$mode" "$tmp"
    /usr/sbin/chown "$owner" "$tmp"
    /bin/sync
    /bin/mv -f "$tmp" "$target"
    if [ "$flush" = 1 ]; then
      /usr/bin/dscacheutil -flushcache || true
      /usr/bin/killall -HUP mDNSResponder || true
    fi
    """#
}
