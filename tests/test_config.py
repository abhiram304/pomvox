from pathlib import Path

from pomvox import config


def write(tmp_path: Path, text: str) -> Path:
    p = tmp_path / "config.toml"
    p.write_text(text)
    return p


def test_defaults_when_file_absent(tmp_path):
    cfg = config.load(tmp_path / "missing.toml")
    assert cfg == config.Config()
    assert cfg.hotkey.ptt == "fn"
    assert cfg.hotkey.toggle == "fn+space"
    assert cfg.hotkey.stop == ""  # fn tap / fn+space stop hands-free
    assert cfg.hotkey.cancel == "esc"
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


def test_hud_section(tmp_path):
    cfg = config.load(
        write(tmp_path, '[hud]\nenabled = false\nposition = "top-center"\nsounds = false\n')
    )
    assert cfg.hud.enabled is False
    assert cfg.hud.position == "top-center"
    assert cfg.hud.sounds is False
    assert cfg.hud.show_draft is True


def test_vad_section(tmp_path):
    cfg = config.load(write(tmp_path, "[vad]\nenabled = false\nsilence_ms = 800\n"))
    assert cfg.vad.enabled is False
    assert cfg.vad.silence_ms == 800
    assert cfg.vad.aggressiveness == 2


def test_bad_vad_values_fall_back(tmp_path, caplog):
    cfg = config.load(write(tmp_path, "[vad]\naggressiveness = 9\n"))
    assert cfg.vad == config.VadConfig()
    assert any("bad [vad]" in r.message for r in caplog.records)


def test_bad_hud_position_falls_back(tmp_path, caplog):
    cfg = config.load(write(tmp_path, '[hud]\nposition = "under-the-dock"\n'))
    assert cfg.hud == config.HudConfig()
    assert any("bad [hud]" in r.message for r in caplog.records)


def test_malformed_file_falls_back_to_defaults(tmp_path, caplog):
    cfg = config.load(write(tmp_path, "not [valid toml ===="))
    assert cfg == config.Config()
    assert any("failed to read" in r.message for r in caplog.records)


def test_audio_section(tmp_path):
    cfg = config.load(write(tmp_path, '[audio]\ndevice = "MacBook Pro Microphone"\n'))
    assert cfg.audio.device == "MacBook Pro Microphone"


def test_audio_defaults_to_system_device(tmp_path):
    cfg = config.load(tmp_path / "missing.toml")
    assert cfg.audio == config.AudioConfig()
    assert cfg.audio.device == ""  # empty = system default input


def test_restart_required_flags_audio_device_change():
    old = config.Config()
    new = config.Config(audio=config.AudioConfig(device="USB Mic"))
    assert config.restart_required(old, new) == ["audio.device"]


def test_restart_required_flags_model_and_hotkey_changes():
    old = config.Config()
    new = config.Config(
        stt=config.SttConfig(model="mlx-community/other"),
        hotkey=config.HotkeyConfig(ptt="right_option"),
    )
    assert config.restart_required(old, new) == ["hotkey", "stt.model"]


def test_restart_required_empty_for_hot_appliable_changes():
    old = config.Config()
    new = config.Config(
        cleanup=config.CleanupConfig(style="light", timeout_s=3.0),
        hud=config.HudConfig(position="top-center"),
        vad=config.VadConfig(silence_ms=800),
    )
    assert config.restart_required(old, new) == []


def test_dictionary_section(tmp_path):
    cfg = config.load(
        write(
            tmp_path,
            """
            [dictionary]
            enabled = true
            words = ["Salammagari", "parakeet-mlx"]

            [dictionary.replacements]
            "salam mcgarry" = "Salammagari"
            """,
        )
    )
    assert cfg.dictionary.words == ["Salammagari", "parakeet-mlx"]
    assert cfg.dictionary.replacements == {"salam mcgarry": "Salammagari"}


def test_dictionary_defaults_are_empty(tmp_path):
    cfg = config.load(tmp_path / "missing.toml")
    assert cfg.dictionary == config.DictionaryConfig()
    assert cfg.dictionary.words == []
    assert cfg.dictionary.replacements == {}


def test_bad_dictionary_words_fall_back(tmp_path, caplog):
    cfg = config.load(write(tmp_path, '[dictionary]\nwords = "not a list"\n'))
    assert cfg.dictionary == config.DictionaryConfig()
    assert any("bad [dictionary]" in r.message for r in caplog.records)


def test_restart_required_flags_dictionary_words_change():
    old = config.Config()
    new = config.Config(dictionary=config.DictionaryConfig(words=["Pomvox"]))
    assert config.restart_required(old, new) == ["dictionary.words"]


def test_restart_required_ignores_replacements_only_change():
    old = config.Config()
    new = config.Config(dictionary=config.DictionaryConfig(replacements={"a": "b"}))
    assert config.restart_required(old, new) == []


def test_example_config_matches_defaults():
    example = Path(__file__).resolve().parents[1] / "config.example.toml"
    assert config.load(example) == config.Config()
