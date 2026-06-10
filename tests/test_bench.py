import json

from murmur.bench import BenchLog, Timings


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def make_timings():
    clock = FakeClock()
    t = Timings(clock=clock)
    t.start()
    clock.now = 0.082
    t.stamp("stt_finalize")
    clock.now = 0.096
    t.stamp("insert")
    return t


def test_stages_are_relative_to_previous_stamp():
    stages = make_timings().stages_ms()
    assert round(stages["stt_finalize"]) == 82
    assert round(stages["insert"]) == 14
    assert round(stages["total"]) == 96


def test_summary_format():
    assert make_timings().summary() == "stt_finalize=82ms insert=14ms total=96ms"


def test_unstarted_timings_are_empty():
    t = Timings()
    assert t.stages_ms() == {}
    assert t.summary() == ""


def test_start_resets_previous_utterance():
    clock = FakeClock()
    t = Timings(clock=clock)
    t.start()
    clock.now = 1.0
    t.stamp("stt_finalize")
    clock.now = 2.0
    t.start()
    clock.now = 2.05
    t.stamp("stt_finalize")
    assert round(t.stages_ms()["total"]) == 50


def test_benchlog_accumulates_json_exportable_records():
    blog = BenchLog()
    blog.add(make_timings())
    blog.add(make_timings())
    records = json.loads(blog.export_json())
    assert len(records) == 2
    assert round(records[0]["total"]) == 96


def test_benchlog_skips_empty_timings():
    blog = BenchLog()
    blog.add(Timings())
    assert blog.records == []
