"""Repair existing music using Pinchflat's saved yt-dlp metadata.

Dry run by default. Example:
  python3 backfill_music_tags.py /config/metadata /downloads --artist Salmo
"""

import argparse
import gzip
import json
from pathlib import Path

from normalize_music_tags import channel_artists, names, normalize


def candidates(metadata_dir, media_dir, artist_filter):
    root = media_dir.resolve()
    for metadata_path in metadata_dir.rglob("metadata.json.gz"):
        try:
            with gzip.open(metadata_path, "rt", encoding="utf-8") as stream:
                metadata = json.load(stream)
            raw_path = metadata.get("filepath")
            if not isinstance(raw_path, str):
                continue
            media_path = Path(raw_path).resolve()
            if not media_path.is_relative_to(root) or not media_path.is_file():
                continue
            artists = names(metadata.get("artists")) or channel_artists(metadata)
            if not artists or (artist_filter and artist_filter.casefold() not in " ".join(artists).casefold()):
                continue
            yield media_path, metadata
        except (OSError, ValueError, json.JSONDecodeError):
            continue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("metadata_dir", type=Path)
    parser.add_argument("media_dir", type=Path)
    parser.add_argument("--artist", help="Only include downloads credited to this artist")
    parser.add_argument("--apply", action="store_true", help="Write tags; otherwise show a dry run")
    args = parser.parse_args()

    counts = {"updated": 0, "unsupported": 0, "no_artists": 0, "candidate": 0, "error": 0}
    for path, metadata in candidates(args.metadata_dir, args.media_dir, args.artist):
        try:
            result = normalize(path, metadata) if args.apply else "candidate"
        except Exception as error:
            result = "error"
            print(f"error: {path}: {error}")
        counts[result] += 1
        if result != "error":
            print(f"{result}: {path}")
    print(counts)


if __name__ == "__main__":
    main()
