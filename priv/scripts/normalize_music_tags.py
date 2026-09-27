"""Preserve yt-dlp's display artist while giving Navidrome individual artists.

Writes each container's equivalent of Navidrome's ARTISTS tag without guessing
where an artist name should be split.
"""

import json
import re
import sys

from mutagen import File
from mutagen.flac import FLAC
from mutagen.id3 import TPE2, TXXX
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4, MP4FreeForm
from mutagen.oggopus import OggOpus
from mutagen.oggvorbis import OggVorbis


def names(value):
    if not isinstance(value, list):
        return []
    return list(dict.fromkeys(name.strip() for name in value if isinstance(name, str) and name.strip()))


def channel_artists(metadata):
    """Use an artist channel only when it confirms the first credited artist."""
    display = metadata.get("artist")
    channel = metadata.get("channel") or metadata.get("uploader")
    if not isinstance(display, str) or not isinstance(channel, str):
        return None
    parts = [part.strip() for part in display.split(",")]
    if len(parts) < 2 or not all(parts):
        return None
    primary = re.sub(r"(?:\s+-\s+Topic|\s+Official)$", "", channel, flags=re.IGNORECASE)
    if primary.casefold() != parts[0].casefold() or primary == channel:
        return None
    return parts


def normalize(path, metadata):
    audio = File(path)
    if not isinstance(audio, (OggOpus, OggVorbis, FLAC, MP3, MP4)):
        return "unsupported"

    artists = names(metadata.get("artists"))
    verified_channel_artists = channel_artists(metadata)
    if not artists or artists == [metadata.get("artist")]:
        artists = verified_channel_artists or artists
    if not artists:
        return "no_artists"

    album_artists = names(metadata.get("album_artists"))
    if not album_artists:
        album_artist = metadata.get("album_artist")
        if isinstance(album_artist, str) and album_artist.strip():
            album_artists = [album_artist.strip()]
        elif verified_channel_artists:
            album_artists = [artists[0]]
        elif len(artists) == 1:
            album_artists = artists

    if isinstance(audio, MP3):
        if audio.tags is None:
            audio.add_tags()
        audio.tags.delall("TXXX:ARTISTS")
        audio.tags.add(TXXX(encoding=3, desc="ARTISTS", text=artists))
        if album_artists:
            audio.tags.delall("TXXX:ALBUM ARTISTS")
            audio.tags.add(TXXX(encoding=3, desc="ALBUM ARTISTS", text=album_artists))
            audio.tags.delall("TPE2")
            audio.tags.add(TPE2(encoding=3, text=[", ".join(album_artists)]))
    elif isinstance(audio, MP4):
        audio["----:com.apple.iTunes:ARTISTS"] = [MP4FreeForm(name.encode("utf-8")) for name in artists]
        if album_artists:
            audio["aART"] = [", ".join(album_artists)]
    else:
        audio["ARTISTS"] = artists
        if album_artists:
            audio["ALBUMARTISTS"] = album_artists
            audio["ALBUMARTIST"] = [", ".join(album_artists)]
    audio.save()
    return "updated"


if __name__ == "__main__":
    result = normalize(sys.argv[1], json.loads(sys.argv[2]))
    print(result)
