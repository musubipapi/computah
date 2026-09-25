#!/usr/bin/env python3
"""Opt-in speech-to-app tests. Requires an idle Mac and real provider keys."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
import uuid
import wave
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "outputs/Computah.app/Contents/MacOS/Computah"


class NoteText(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []

    def handle_data(self, data):
        self.parts.append(data)

    def handle_starttag(self, tag, attrs):
        if tag in {"div", "p", "br", "li"}:
            self.parts.append("\n")


def private_json(path, value):
    path.write_text(json.dumps(value, indent=2))


class SpeechToAppTests(unittest.TestCase):
    output: Path
    voice = "Samantha"

    def setUp(self):
        self.folder = self.output / self._testMethodName
        self.folder.mkdir(mode=0o700)

    def run_process(self, args, name, timeout=30, input_text=None):
        """Keep subprocess output private, including failures and timeouts."""
        log = self.folder / (name + ".log")
        try:
            with log.open("w") as stream:
                with subprocess.Popen(args, cwd=ROOT, text=True, stdin=subprocess.PIPE,
                                      stdout=stream, stderr=subprocess.STDOUT) as process:
                    try:
                        process.communicate(input=input_text, timeout=timeout)
                    except (subprocess.TimeoutExpired, KeyboardInterrupt):
                        process.kill()
                        process.wait()
                        raise
        except subprocess.TimeoutExpired:
            self.fail(f"{name} timed out. No retry was sent. See {log.relative_to(ROOT)}")
        self.assertEqual(process.returncode, 0,
                         f"{name} failed. See {log.relative_to(ROOT)}")
        return log.read_text()

    def observe(self, expression, name):
        # Test-only oracle. Production code never uses app-specific scripting.
        script = "JSON.stringify(" + expression + ")"
        raw = self.run_process(["osascript", "-l", "JavaScript", "-"], name,
                               input_text=script)
        try:
            return json.loads(raw)
        except (ValueError, TypeError):
            self.fail(f"{name} did not return valid observation data; see its private log.")

    def speech_command(self, command):
        started = time.monotonic()
        source = self.folder / "command.txt"
        source.write_text(command)
        audio = self.folder / "speech.aiff"
        wav = self.folder / "speech.wav"
        pcm = self.folder / "speech.pcm"
        # Generate a fresh local fixture. No recording or personal speech is committed.
        self.run_process(["say", "-v", self.voice, "-r", "155", "-f", str(source),
                          "-o", str(audio)], "synthesize")
        self.run_process(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                          str(audio), str(wav)], "convert")
        with wave.open(str(wav), "rb") as recording:
            self.assertTrue(recording.getnchannels() == 1 and recording.getsampwidth() == 2
                            and recording.getframerate() == 16000, "Unexpected audio format")
            pcm.write_bytes(recording.readframes(recording.getnframes()))
        report = self.folder / "report.json"
        self.run_process([str(APP), "--root", str(ROOT), "--audio-pcm", str(pcm),
                          "--report", str(report), "--trace-dir", str(self.folder / "trace")], "computah", timeout=105)
        data = json.loads(report.read_text())
        self.assertEqual(data.get("diagnosticOutcome"), "completed", "The command was not confirmed")
        self.assertTrue(any(event.get("payload", {}).get("event") == "EndOfTurn"
                            for event in data.get("speechEvents", [])), "No final Deepgram turn")
        results = data.get("results", [])
        self.assertTrue(results and results[-1].get("complete") is True, "No completed workflow")
        self.assertTrue(any(result.get("usage", {}).get("requests", 0) > 0 for result in results),
                        "No recorded Jev request")
        self.assertTrue(any(event.get("event") == "admittedEffect" for event in data.get("inputAudit", [])),
                        "No recorded app input")
        private_json(self.folder / "timing.json", {"seconds": time.monotonic() - started,
                     "diagnosticSeconds": data.get("elapsed")})

    def snapshot(self, bundle_id, name):
        path = self.folder / (name + ".json")
        self.run_process([str(APP), "--root", str(ROOT), "--inspect-app", bundle_id,
                          "--snapshot-json", str(path)], name, timeout=45)
        return json.loads(path.read_text())

    def test_spotify_play_song(self):
        spotify = 'Application("com.spotify.client")'
        before = self.observe(spotify + '.playerState()', "before")
        self.assertNotEqual(before, "playing", "Pause Spotify before this test to prove playback starts")
        self.speech_command("Open Spotify and play Mary Had a Little Lamb.")
        after = self.observe('({state: ' + spotify + '.playerState(), name: ' + spotify
                             + '.currentTrack.name(), position: ' + spotify + '.playerPosition()})', "after")
        self.assertEqual(after["state"], "playing", "Spotify is not playing")
        self.assertTrue("mary had a little lamb" in after["name"].casefold(),
                        "Spotify is playing a different song; see the private after log")
        # Read again without sending another action. A moving clock proves active playback.
        time.sleep(1)
        later = self.observe('({state: ' + spotify + '.playerState(), name: ' + spotify
                             + '.currentTrack.name(), position: ' + spotify + '.playerPosition()})', "progress")
        self.assertTrue(later["state"] == "playing" and later["name"] == after["name"]
                        and later["position"] > after["position"], "Playback did not advance on the requested song")

    def test_chrome_google_search(self):
        tab = 'Application("com.google.Chrome").windows[0].activeTab'
        before = self.observe(tab + '.url()', "before")
        self.assertTrue(before == "about:blank", "Select an about:blank Chrome tab before this test")
        self.speech_command("Open Chrome, go to google dot com, and search penguins.")
        after = self.observe('({url: ' + tab + '.url(), title: ' + tab + '.title(), loading: '
                             + tab + '.loading()})', "after")
        url = urlparse(after["url"])
        self.assertTrue(url.scheme == "https" and url.hostname in {"google.com", "www.google.com"}
                        and url.path == "/search" and parse_qs(url.query).get("q") == ["penguins"],
                        "Chrome did not reach the expected Google search URL; see the private after log")
        self.assertTrue(not after["loading"] and "penguins" in after["title"].casefold(),
                        "The search page has not finished loading")

    def test_discord_general_channel(self):
        before = self.snapshot("com.hnc.Discord", "before")
        general = [node for node in before if node["role"] == "AXLink"
                   and node["label"].casefold() == "general (text channel)"]
        self.assertEqual(len(general), 1, "Select a Discord server with one visible general text channel")
        target = general[0]["value"]
        self.assertTrue(target and "/channels/" in target, "The general channel has no observable destination")
        def at_target(nodes):
            # A sidebar link alone is not proof of navigation. Match the loaded document too.
            return any(node["role"] == "AXWebArea" and node["value"].removeprefix("https://")
                       == target.removeprefix("https://") for node in nodes)
        self.assertFalse(at_target(before), "Select a different channel in this server before testing")
        self.speech_command("Open Discord and go to the general channel.")
        after = self.snapshot("com.hnc.Discord", "after")
        self.assertTrue(at_target(after), "Discord did not open the observed general channel destination")
        self.assertTrue(any(node["role"] == "AXTextArea" and node["label"] == "Message #general"
                            for node in after), "The general channel message editor is not present")

    def test_notes_create_and_type(self):
        notes = 'Application("com.apple.Notes").notes'
        before = set(self.observe(notes + '.id()', "before"))
        self.speech_command("Open Notes, create a new note, and type hello.")
        after = set(self.observe(notes + '.id()', "after"))
        created = after - before
        self.assertEqual(len(created), 1, "Expected exactly one new note; possible duplicate or outside input")
        body = self.observe(notes + '.byId(' + json.dumps(created.pop()) + ').body()', "content")
        parser = NoteText()
        parser.feed(body)
        matches = " ".join("".join(parser.parts).split()).casefold() == "hello"
        self.assertTrue(matches, "The new note does not contain only the expected text; see the private content log")

    def test_textedit_create_and_type(self):
        windows = 'Application("com.apple.TextEdit").windows'
        before = set(self.observe(windows + '.id()', "before"))
        self.speech_command("Open TextEdit, create a new document, and type quiet mornings.")
        after = set(self.observe(windows + '.id()', "after"))
        created = after - before
        self.assertEqual(len(created), 1, "Expected exactly one new window; possible duplicate or outside input")
        body = self.observe(windows + '.byId(' + str(created.pop()) + ').document().text()', "content")
        matches = " ".join(body.split()).casefold() == "quiet mornings"
        self.assertTrue(matches, "The new document does not contain only the expected text; see the private content log")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true",
                        help="Authorize real Deepgram/Jev requests, app input, and local diagnostic files")
    cases = {"notes": "test_notes_create_and_type", "textedit": "test_textedit_create_and_type",
             "spotify": "test_spotify_play_song", "discord": "test_discord_general_channel",
             "chrome": "test_chrome_google_search"}
    parser.add_argument("--case", action="append", choices=cases,
                        help="Run only this case; repeat to select several. Default: all cases")
    parser.add_argument("--voice", default="Samantha", help="Installed macOS speech voice for the fixture")
    args = parser.parse_args()
    if not args.live:
        parser.error("Pass --live only when the Mac is idle and real app/provider tests are authorized.")
    if sys.platform != "darwin":
        parser.error("These tests require macOS.")
    running = subprocess.run(["pgrep", "-x", "Computah"], capture_output=True)
    if running.returncode != 1:
        parser.error("Quit Computah before testing. The runner must own its app instance.")
    if not (ROOT / ".env").is_file():
        parser.error("Set both provider keys in the ignored root .env file first.")
    os.umask(0o077)
    output = ROOT / "outputs/e2e" / (time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
    output.mkdir(parents=True, mode=0o700)
    with (output / "build.log").open("w") as log:
        result = subprocess.run(["zsh", "scripts/build.sh"], cwd=ROOT,
                                stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        parser.exit(1, f"Build failed. See {output.relative_to(ROOT)}/build.log\n")
    SpeechToAppTests.output = output
    SpeechToAppTests.voice = args.voice
    suite = unittest.TestSuite(SpeechToAppTests(cases[name]) for name in dict.fromkeys(args.case or cases))
    result = unittest.TextTestRunner(verbosity=2, failfast=True).run(suite)
    private_json(output / "summary.json", {"passed": result.wasSuccessful(), "voice": args.voice, "testsRun": result.testsRun,
                 "failures": len(result.failures), "errors": len(result.errors)})
    print(f"Private evidence: {output.relative_to(ROOT)}")
    print("Test documents and final app states remain for inspection.")
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
