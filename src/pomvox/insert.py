"""Text insertion into the focused app via pasteboard + synthesized ⌘V."""

from __future__ import annotations

import logging
import threading

log = logging.getLogger(__name__)

KEYCODE_V = 9
# How long to leave the staged transcript on the clipboard before restoring the
# user's prior contents. The synthesized ⌘V is asynchronous — the target app
# reads the clipboard only when it processes the keystroke on its own main
# thread — so this delay must comfortably outlast that handling. At the old
# 0.15 s a busy or slow-to-focus app (launching, Electron, system under load)
# could still be mid-paste when the restore fired, so it read the *restored*
# prior clipboard and pasted the previously-copied text instead of the
# transcript. Restoring off-thread keeps this off the paste latency path, and
# the changeCount guard still lets a real user copy win, so a longer wait is
# safe and only widens the recovery window.
RESTORE_DELAY_S = 0.5
# Community convention (nspasteboard.org): clipboard managers that honor it
# (Maccy, Paste, Alfred, …) skip items carrying this type, so dictations
# don't pile up in clipboard history regardless of Pomvox's own settings.
CONCEALED_TYPE = "org.nspasteboard.ConcealedType"


def insert_text(text: str) -> None:
    """Paste *text* at the cursor, then restore the previous clipboard.

    The old pasteboard is restored only if changeCount still matches what we
    set — a user copy that lands during the delay wins and is left alone.
    """
    import Quartz
    from AppKit import NSPasteboard, NSPasteboardTypeString

    pb = NSPasteboard.generalPasteboard()
    saved = pb.stringForType_(NSPasteboardTypeString)
    our_change = stage_transcript(pb, text)

    # Flags are set explicitly to ⌘ alone so a still-held Fn (PTT release
    # races the paste) can't contaminate the synthetic chord.
    for is_down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(None, KEYCODE_V, is_down)
        Quartz.CGEventSetFlags(event, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)

    def restore() -> None:
        if saved is not None and pb.changeCount() == our_change:
            pb.clearContents()
            pb.setString_forType_(saved, NSPasteboardTypeString)

    # Restore off-thread so insert_text returns as soon as the paste is posted.
    threading.Timer(RESTORE_DELAY_S, restore).start()


def stage_transcript(pb, text: str) -> int:
    """Put *text* on *pb* marked concealed; return the resulting changeCount.

    The restore path deliberately does not re-mark the user's original
    clipboard — it wasn't ours to conceal.
    """
    from AppKit import NSPasteboardTypeString

    pb.declareTypes_owner_([NSPasteboardTypeString, CONCEALED_TYPE], None)
    pb.setString_forType_(text, NSPasteboardTypeString)
    pb.setString_forType_("1", CONCEALED_TYPE)
    return pb.changeCount()
