import importlib.util
import gzip
import json
import pathlib
import sys
import tempfile
import unittest

from mutagen import File


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "priv" / "scripts" / "normalize_music_tags.py"
spec = importlib.util.spec_from_file_location("normalize_music_tags", SCRIPT)
module = importlib.util.module_from_spec(spec)
sys.modules["normalize_music_tags"] = module
spec.loader.exec_module(module)
backfill_spec = importlib.util.spec_from_file_location("backfill_music_tags", SCRIPT.with_name("backfill_music_tags.py"))
backfill = importlib.util.module_from_spec(backfill_spec)
backfill_spec.loader.exec_module(backfill)


class MusicTagNormalizerTest(unittest.TestCase):
    def test_artist_channel_confirms_collaborators(self):
        self.assertEqual(
            ["Salmo", "Kaos"],
            module.channel_artists({"artist": "Salmo, Kaos", "channel": "Salmo - Topic"}),
        )
        self.assertEqual(
            ["Salmo", "Kaos"],
            module.channel_artists({"artist": "Salmo, Kaos", "channel": "Salmo Official"}),
        )
        self.assertIsNone(module.channel_artists({"artist": "Earth, Wind & Fire", "channel": "Earth, Wind & Fire - Topic"}))

    def test_preserves_artwork_and_display_artist(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "song.opus"
            import subprocess

            subprocess.run(
                ["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", "0.1", "-c:a", "libopus", str(path)],
                check=True,
            )
            audio = File(path)
            audio["ARTIST"] = ["Salmo, Kaos"]
            audio["ALBUM"] = ["RANCH"]
            audio["METADATA_BLOCK_PICTURE"] = ["existing-artwork"]
            audio.save()

            self.assertEqual(
                "updated",
                module.normalize(path, {"artist": "Salmo, Kaos", "artists": ["Salmo", "Kaos"], "album_artists": ["Salmo"]}),
            )
            audio = File(path)
            self.assertEqual(["Salmo, Kaos"], audio["ARTIST"])
            self.assertEqual(["Salmo", "Kaos"], audio["ARTISTS"])
            self.assertEqual(["Salmo"], audio["ALBUMARTIST"])
            self.assertEqual(["Salmo"], audio["ALBUMARTISTS"])
            self.assertEqual(["existing-artwork"], audio["METADATA_BLOCK_PICTURE"])

    def test_ambiguous_comma_is_left_alone(self):
        self.assertIsNone(module.channel_artists({"artist": "Alpha, Beta", "channel": "Other - Topic"}))

    def test_official_channel_supplies_album_artist_when_extractor_omits_it(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "song.opus"
            import subprocess

            subprocess.run(
                ["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", "0.1", "-c:a", "libopus", str(path)],
                check=True,
            )
            metadata = {
                "artist": "Salmo, Kaos",
                "artists": ["Salmo", "Kaos"],
                "album": "RANCH",
                "album_artist": None,
                "album_artists": None,
                "channel": "Salmo Official",
            }
            self.assertEqual("updated", module.normalize(path, metadata))
            audio = File(path)
            self.assertEqual(["Salmo", "Kaos"], audio["ARTISTS"])
            self.assertEqual(["Salmo"], audio["ALBUMARTIST"])

    def test_backfill_only_reads_files_inside_the_selected_media_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            media_dir = root / "downloads"
            metadata_dir = root / "metadata"
            media_dir.mkdir()
            metadata_dir.mkdir()
            inside = media_dir / "song.opus"
            outside = root / "outside.opus"
            inside.touch()
            outside.touch()
            for index, path in enumerate((inside, outside)):
                folder = metadata_dir / str(index)
                folder.mkdir()
                with gzip.open(folder / "metadata.json.gz", "wt", encoding="utf-8") as stream:
                    json.dump({"filepath": str(path), "artists": ["Salmo", "Kaos"]}, stream)

            found = list(backfill.candidates(metadata_dir, media_dir, "Salmo"))
            self.assertEqual([inside], [path for path, _ in found])

    def test_mp3_and_m4a_artist_tags(self):
        import subprocess

        with tempfile.TemporaryDirectory() as directory:
            for extension, codec in (("mp3", "libmp3lame"), ("m4a", "aac")):
                with self.subTest(extension=extension):
                    path = pathlib.Path(directory) / f"song.{extension}"
                    subprocess.run(
                        ["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "0.1", "-c:a", codec, str(path)],
                        check=True,
                    )
                    self.assertEqual("updated", module.normalize(path, {
                        "artist": "Salmo, Kaos", "artists": ["Salmo", "Kaos"],
                        "channel": "Salmo Official",
                    }))
                    audio = File(path)
                    if extension == "mp3":
                        self.assertEqual(["Salmo", "Kaos"], audio.tags["TXXX:ARTISTS"].text)
                        self.assertEqual(["Salmo"], audio.tags["TPE2"].text)
                    else:
                        self.assertEqual([b"Salmo", b"Kaos"], audio["----:com.apple.iTunes:ARTISTS"])
                        self.assertEqual(["Salmo"], audio["aART"])


if __name__ == "__main__":
    unittest.main()
