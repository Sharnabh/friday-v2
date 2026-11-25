"""Capture one manual or wake-triggered turn on the selected Core Audio input."""
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import re
import subprocess
import tempfile
import select
import sys
import wave

import numpy as np
import sounddevice as sd
from tools.wake_word import _build_engine, _resample_audio_frame, load_wake_word_config


def emit(key, value):
    print(json.dumps({key: value}), flush=True)


def transcribe_wake(frames):
    directory = Path(__file__).with_name("Whisper")
    if not (directory/"whisper-cli").exists():
        directory = Path.home() / ".hermes/tools/friday-whisper"
    audio = np.concatenate(frames).astype(float)
    peak = max(1, np.max(np.abs(audio)))
    audio = (audio * min(12, 24000 / peak)).astype(np.int16)
    with tempfile.NamedTemporaryFile(suffix=".wav") as sample:
        with wave.open(sample.name, "wb") as wav:
            wav.setparams((1, 2, 16000, 0, "NONE", ""))
            wav.writeframes(audio.tobytes())
        result = subprocess.run(
            [directory / "whisper-cli", "-m", directory / "ggml-base.bin",
             "-f", sample.name, "-nt", "-np", "-ng", "-l", "en"],
            capture_output=True, text=True, timeout=12, check=True)
    words = re.findall(r"[a-z]+", result.stdout.lower())
    return words in (["hey", "friday"], ["hi", "friday"], ["hey", "fri", "day"])


class WakeFallback:
    def __init__(self):
        self.worker = ThreadPoolExecutor(max_workers=1)
        self.pending = None
        self.lead = deque(maxlen=3)
        self.segment = []
        self.quiet = 0
        self.noise = 10

    def process(self, frame, rms):
        if self.pending and self.pending.done():
            matched = self.pending.result()
            self.pending = None
            if matched:
                return True
            emit("state", "Try Hey Friday again")
        active = rms > max(25, self.noise * 2.8)
        if not self.segment and not active:
            self.noise = 0.95 * self.noise + 0.05 * rms
        if active and not self.segment:
            self.segment = list(self.lead)
        self.lead.append(frame)
        if active or self.segment:
            self.segment.append(frame)
            self.quiet = 0 if active else self.quiet + 1
            if self.quiet >= 5 or len(self.segment) >= 45:
                if self.pending is None and len(self.segment) >= 9:
                    self.pending = self.worker.submit(transcribe_wake, self.segment)
                    emit("state", "Checking wake phrase…")
                self.segment = []
        return False


def main():
    devices = [d for d in sd.query_devices() if d["max_input_channels"]]
    if sys.argv[1] == "devices":
        print(json.dumps([d["name"] for d in devices]))
        return
    mode, name, destination = sys.argv[1:4]
    device = next((d for d in devices if d["name"] == name), None) if name else sd.query_devices(kind="input")
    if device is None:
        raise ValueError("Selected microphone disconnected")
    rate = int(device["default_samplerate"])
    block = round(rate * 0.08)
    engine = None
    if mode == "wake":
        engine = _build_engine(dict(load_wake_word_config(), provider="sherpa", phrase="hey friday", sensitivity=0.20, profile_routing=False))
    fallback = WakeFallback() if engine else None
    silent_blocks = 0
    frames = []
    heard = False
    quiet = 0
    with sd.InputStream(device=device["index"], samplerate=rate, channels=1, dtype="int16", blocksize=block) as stream:
        emit("state", "Say Hey Friday" if engine else "Listening")
        while True:
            if select.select([sys.stdin], [], [], 0)[0]:
                if not sys.stdin.readline() or not frames:
                    return
                break
            raw, overflow = stream.read(block)
            frame = _resample_audio_frame(np, raw, 1280)
            rms = float(np.sqrt(np.mean(frame.astype(float) ** 2)))
            emit("level", min(1, rms / 4000))
            if engine:
                if rms < 3:
                    silent_blocks += 1
                    if silent_blocks == 38:
                        emit("state", "No mic signal: " + device["name"])
                else:
                    if silent_blocks >= 38:
                        emit("state", "Say Hey Friday")
                    silent_blocks = 0
                gain = min(6.0, max(1.0, 1200 / max(1, rms))) if rms >= 20 else 1.0
                normalized = np.clip(frame.astype(float) * gain, -32768, 32767).astype(np.int16)
                if engine.process(normalized) or fallback.process(frame, rms):
                    engine.close()
                    engine = None
                    emit("state", "Listening")
                continue
            frames.append(frame.tobytes())
            if rms > 150:
                heard = True
                quiet = 0
            else:
                quiet += 1
            if mode == "wake" and (heard and quiet >= 14 or not heard and quiet >= 100):
                break
            if len(frames) >= 750:
                break
    if not heard:
        raise ValueError("No speech detected. Check the microphone and its input level.")
    with wave.open(destination, "wb") as wav:
        wav.setparams((1, 2, 16000, 0, "NONE", ""))
        wav.writeframes(b"".join(frames))
    emit("complete", True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit("error", str(error))
        sys.exit(1)
