from pathlib import Path

from murmur import config


def write(tmp_path: Path, text: str) -> Path:
    p = tmp_path / "config.toml"
    p.write_text(text)
    return p


def test_defaults_when_file_absent(tmp_path):
    cfg = config.load(tmp_path / "missing.toml")
    assert cfg == config.Config()
    assert cfg.hotkey.ptt == "fn"
    assert cfg.hotkey.toggle == "fn+space"
    assert cfg.hotkey.stop == "esc"
    assert cfg.stt.model == "mlx-community/parakeet-tdt-0.6b-v3"
    assert cfg.cleanup.enabled is True
    assert cfg.cleanup.model == "mlx-community/Qwen3-4B-4bit"
    assert cfg.cleanup.style == "polish"
    assert cfg.cleanup.timeout_s == 5.0
    assert cfg.insert.method == "paste"
    assert cfg.log.file is True


def test_full_file(tmp_path):
    cfg = config.load(
        write(
            tmp_path,
            """
            [hotkey]
            ptt = "right_option"
            toggle = "fn+space"
            stop = "esc"

            [stt]
            model = "mlx-community/other-model"

            [cleanup]
            enabled = false
            model = "mlx-community/Qwen3-4B-4bit"
            style = "light"
            timeout_s = 5.0

            [insert]
            method = "paste"

            [log]
            file = false
            """,
        )
    )
    assert cfg.hotkey.ptt == "right_option"
    assert cfg.stt.model == "mlx-community/other-model"
    assert cfg.cleanup.enabled is False
    assert cfg.cleanup.style == "light"
    assert cfg.cleanup.timeout_s == 5.0
    assert cfg.log.file is False


def test_partial_file_keeps_other_defaults(tmp_path):
    cfg = config.load(write(tmp_path, '[hotkey]\nptt = "right_option"\n'))
    assert cfg.hotkey.ptt == "right_option"
    assert cfg.hotkey.toggle == "fn+space"
    assert cfg.stt == config.SttConfig()


def test_unknown_keys_and_sections_ignored(tmp_path, caplog):
    cfg = config.load(
        write(tmp_path, '[hotkey]\nbogus = 1\n\n[nonsense]\nx = "y"\n')
    )
    assert cfg == config.Config()
    assert any("unknown key" in r.message for r in caplog.records)
    assert any("unknown section" in r.message for r in caplog.records)


def test_bad_cleanup_style_falls_back(tmp_path, caplog):
    cfg = config.load(write(tmp_path, '[cleanup]\nstyle = "shouty"\n'))
    assert cfg.cleanup == config.CleanupConfig()
    assert any("bad [cleanup]" in r.message for r in caplog.records)


def test_bad_cleanup_timeout_falls_back(tmp_path, caplog):
    cfg = config.load(write(tmp_path, "[cleanup]\ntimeout_s = 0\n"))
    assert cfg.cleanup == config.CleanupConfig()
    assert any("bad [cleanup]" in r.message for r in caplog.records)


def test_malformed_file_falls_back_to_defaults(tmp_path, caplog):
    cfg = config.load(write(tmp_path, "not [valid toml ===="))
    assert cfg == config.Config()
    assert any("failed to read" in r.message for r in caplog.records)


def test_example_config_matches_defaults():
    example = Path(__file__).resolve().parents[1] / "config.example.toml"
    assert config.load(example) == config.Config()
