"""Text insertion into the focused app via pasteboard + synthesized ⌘V."""

from __future__ import annotations

import logging
import threading

log = logging.getLogger(__name__)

KEYCODE_V = 9
RESTORE_DELAY_S = 0.15
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
