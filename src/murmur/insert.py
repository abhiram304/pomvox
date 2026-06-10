"""Text insertion into the focused app via pasteboard + synthesized ⌘V."""

from __future__ import annotations

import logging
import time

log = logging.getLogger(__name__)

KEYCODE_V = 9
RESTORE_DELAY_S = 0.15


def insert_text(text: str) -> None:
    """Paste *text* at the cursor, then restore the previous clipboard.

    The old pasteboard is restored only if changeCount still matches what we
    set — a user copy that lands during the delay wins and is left alone.
    """
    import Quartz
    from AppKit import NSPasteboard, NSPasteboardTypeString

    pb = NSPasteboard.generalPasteboard()
    saved = pb.stringForType_(NSPasteboardTypeString)
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)
    our_change = pb.changeCount()

    # Flags are set explicitly to ⌘ alone so a still-held Fn (PTT release
    # races the paste) can't contaminate the synthetic chord.
    for is_down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(None, KEYCODE_V, is_down)
        Quartz.CGEventSetFlags(event, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)

    time.sleep(RESTORE_DELAY_S)
    if saved is not None and pb.changeCount() == our_change:
        pb.clearContents()
        pb.setString_forType_(saved, NSPasteboardTypeString)
