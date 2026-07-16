"""Spec for scripts/make_appcast.py — the Sparkle appcast generator.

The appcast is the update feed committed at the repo root and served from
raw.githubusercontent.com. Items must be newest-first, carry an EdDSA
signature, and point at GitHub release assets that already exist.
"""
import base64
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import make_appcast as m

EMPTY = (Path(__file__).resolve().parent.parent / "appcast.xml").read_text()


def make_item(build=9, short="0.1.11", sig="c2ln"):
    return m.appcast_item(short_version=short, build=build, tag=f"v{short}",
                          length=12345, ed_signature=sig,
                          pub_date=datetime(2026, 7, 15, tzinfo=timezone.utc))


def test_enclosure_url():
    assert m.enclosure_url("v0.1.11") == \
        "https://github.com/abhiram304/pomvox/releases/download/v0.1.11/Pomvox.zip"


def test_item_carries_versions_signature_and_min_system():
    item = make_item()
    assert "<sparkle:version>9</sparkle:version>" in item
    assert "<sparkle:shortVersionString>0.1.11</sparkle:shortVersionString>" in item
    assert "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>" in item
    assert 'sparkle:edSignature="c2ln"' in item
    assert 'length="12345"' in item
    assert "releases/tag/v0.1.11" in item        # release-notes link


def test_insert_into_empty_feed_validates():
    out = m.insert_item(EMPTY, make_item())
    assert m.validate(out) == []
    assert out.count("<item>") == 1


def test_insert_is_newest_first():
    one = m.insert_item(EMPTY, make_item(build=9, short="0.1.11"))
    two = m.insert_item(one, make_item(build=10, short="0.1.12"))
    assert m.validate(two) == []
    assert two.index("0.1.12") < two.index("0.1.11")


def test_duplicate_build_rejected():
    one = m.insert_item(EMPTY, make_item(build=9))
    with pytest.raises(ValueError):
        m.insert_item(one, make_item(build=9, short="0.1.11b"))


def test_inserting_older_build_rejected():
    # Downgrade trap: a new item must be strictly newer than everything shipped.
    one = m.insert_item(EMPTY, make_item(build=10, short="0.1.12"))
    with pytest.raises(ValueError):
        m.insert_item(one, make_item(build=9, short="0.1.11"))


def test_out_of_order_feed_fails_validation():
    # Simulate a hand-edited feed whose order went bad after the fact.
    one = m.insert_item(EMPTY, make_item(build=9, short="0.1.11"))
    two = m.insert_item(one, make_item(build=10, short="0.1.12"))
    broken = two.replace("<sparkle:version>10</sparkle:version>",
                         "<sparkle:version>8</sparkle:version>")
    assert m.validate(broken) != []


def test_validate_rejects_malformed_xml_and_missing_signature():
    assert m.validate("<rss>not closed") != []
    unsigned = m.insert_item(EMPTY, make_item()).replace(' sparkle:edSignature="c2ln"', "")
    assert m.validate(unsigned) != []


def test_first_item_indentation_matches_later_items():
    # The empty-feed splice must indent the first item exactly like the ones
    # insert_item later prepends — the feed is committed and served as-is.
    one = m.insert_item(EMPTY, make_item(build=9, short="0.1.11"))
    two = m.insert_item(one, make_item(build=10, short="0.1.12"))
    assert two.count("\n    <item>") == 2


def test_cli_rejects_duplicate_build_cleanly(tmp_path):
    # A duplicate build must exit 1 with the "appcast INVALID" message, not a
    # raw Python traceback.
    import subprocess
    script = Path(__file__).resolve().parent.parent / "scripts" / "make_appcast.py"
    appcast = tmp_path / "appcast.xml"
    appcast.write_text(EMPTY)
    payload = tmp_path / "Pomvox.zip"
    payload.write_bytes(b"bytes")
    cmd = [sys.executable, str(script), "--appcast", str(appcast),
           "--zip", str(payload), "--tag", "v0.1.11", "--short-version", "0.1.11",
           "--build", "9", "--signature", "c2ln", "--write"]
    first = subprocess.run(cmd, capture_output=True, text=True)
    assert first.returncode == 0
    second = subprocess.run(cmd, capture_output=True, text=True)
    assert second.returncode == 1
    assert "appcast INVALID" in second.stderr
    assert "Traceback" not in second.stderr


def test_verify_signature_roundtrip(tmp_path):
    nacl = pytest.importorskip("nacl.signing")
    payload = tmp_path / "Pomvox.zip"
    payload.write_bytes(b"not really a zip but bytes are bytes")
    key = nacl.SigningKey.generate()
    sig = key.sign(payload.read_bytes()).signature
    pub = key.verify_key.encode()
    assert m.verify_signature(str(payload), base64.b64encode(sig).decode(),
                              base64.b64encode(pub).decode())
    assert not m.verify_signature(str(payload), base64.b64encode(b"x" * 64).decode(),
                                  base64.b64encode(pub).decode())
