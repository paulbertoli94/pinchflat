# Pinchflat REST API

Pinchflat exposes a small authenticated API for external clients that add videos to a YouTube playlist already configured as a Pinchflat Source.

The playlist remains the source of truth. `/sync` does not add videos to YouTube playlists and does not download arbitrary YouTube IDs. A client should first update the YouTube playlist, then call `/sync`, then poll media status.

If Google is connected in Pinchflat settings, clients can instead call `/import`. Pinchflat will add the videos to the YouTube playlist for that Source, then run the same source sync pipeline.

## Configuration

Set `PINCHFLAT_API_TOKEN` in the Pinchflat environment:

```yaml
services:
  pinchflat:
    image: ghcr.io/kieraneglin/pinchflat:latest
    environment:
      PINCHFLAT_API_TOKEN: 'change-me'
```

Requests must include:

```text
Authorization: Bearer <token>
```

If `PINCHFLAT_API_TOKEN` is not set, API endpoints return `503`.

## Google YouTube Connection

`/import` requires a Google OAuth connection in Pinchflat:

1. Create an OAuth client in Google Cloud for a web application.
2. Add Pinchflat's redirect URI shown in Settings -> Advanced -> Google YouTube Connection.
3. Save the Google OAuth Client ID and Client Secret in Pinchflat settings.
4. Click Connect Google and authorize the YouTube account that owns the playlists.

Pinchflat stores the Google refresh token server-side. The refresh token is never included in the Tempus QR payload or REST API responses.

## Endpoints

### Sync Source

```http
POST /api/v1/sources/:source_id/sync
```

Body:

```json
{
  "youtube_ids": ["LdQU46djcAA"],
  "force_full_index": false
}
```

Example:

```bash
curl -X POST \
  http://localhost:8945/api/v1/sources/2/sync \
  -H "Authorization: Bearer $PINCHFLAT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "youtube_ids": ["LdQU46djcAA"],
    "force_full_index": false
  }'
```

Response:

```json
{
  "source_id": 2,
  "status": "queued",
  "expected_youtube_ids": ["LdQU46djcAA"]
}
```

This enqueues Pinchflat's existing source indexing worker with `force: true`. New media creation and downloads are handled by the existing indexing and download pipeline, including media profile settings, cookies, yt-dlp options, naming, metadata, thumbnails, retry behavior, and post-processing.

### Import To Source Playlist

```http
POST /api/v1/sources/:source_id/import
```

Body:

```json
{
  "youtube_ids": ["LdQU46djcAA"]
}
```

Example:

```bash
curl -X POST \
  http://localhost:8945/api/v1/sources/2/import \
  -H "Authorization: Bearer $PINCHFLAT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "youtube_ids": ["LdQU46djcAA"]
  }'
```

Response:

```json
{
  "source_id": 2,
  "status": "queued",
  "imported_youtube_ids": ["LdQU46djcAA"],
  "expected_youtube_ids": ["LdQU46djcAA"]
}
```

This endpoint uses Google OAuth to call YouTube `playlistItems.insert` for the playlist configured on the Pinchflat Source. Videos already present in the playlist are treated as successfully imported. After the playlist write, Pinchflat enqueues the same forced source indexing used by `/sync`.

If Google authorization expires or is revoked, `/import` returns:

```json
{
  "error": {
    "code": "google_reauthorization_required",
    "message": "Google authorization expired or was revoked. Reconnect Google in Pinchflat settings.",
    "details": {}
  }
}
```

Tempus should show a reconnect-Google message and ask the user to reconnect Google in Pinchflat settings.

### Search YouTube

```http
GET /api/v1/youtube/search?q=daft%20punk&max_results=10&source_id=2
```

This endpoint requires YouTube API Key(s) in Pinchflat settings. Tempus can use it to search YouTube without receiving the raw API key in the QR code.

`source_id` is optional. When provided, Pinchflat enriches each search result with status for that Source.

Response:

```json
{
  "items": [
    {
      "youtube_id": "LdQU46djcAA",
      "title": "Song title",
      "channel_id": "UC123",
      "channel_title": "Artist",
      "published_at": "2024-01-01T00:00:00Z",
      "thumbnail_url": "https://example.com/thumb.jpg",
      "pinchflat_status": {
        "source_id": 2,
        "status": "completed",
        "in_source": true,
        "already_downloaded": true,
        "media_id": 123,
        "media_uuid": "...",
        "downloaded_at": "2026-07-10T15:00:00Z",
        "filepath": "/downloads/...",
        "last_error": null
      }
    }
  ]
}
```

`max_results` defaults to `10` and must be between `1` and `25`.

`pinchflat_status.in_source` means Pinchflat already knows that media item for the requested Source. It is derived from Pinchflat's database, not from a live YouTube playlist lookup. If the playlist was changed recently but has not been indexed yet, a video can still return `unknown`.

### Media Status By YouTube ID

```http
GET /api/v1/sources/:source_id/media/by-youtube-id/:youtube_id
```

Returns `404` if the media item is not yet known to Pinchflat.

### Batch Media Status

```http
POST /api/v1/sources/:source_id/media/status
```

Body:

```json
{
  "youtube_ids": ["AAA00000000", "BBB00000000"]
}
```

Response:

```json
{
  "items": [
    { "youtube_id": "AAA00000000", "status": "completed", "media_id": 1 },
    { "youtube_id": "BBB00000000", "status": "unknown", "media_id": null }
  ]
}
```

## Limits And Idempotency

`youtube_ids` accepts only YouTube video IDs: 11 characters using letters, digits, `_`, or `-`. Full URLs and empty strings are rejected. A batch may contain at most 500 IDs. Duplicate IDs are removed before processing.

`/sync` is idempotent for the same source and IDs. `/import` is also idempotent for videos that are already in the YouTube playlist. Both endpoints use Pinchflat's existing Oban job uniqueness and source indexing helper. Existing downloaded media is not downloaded again, pending or queued media is not duplicated, and failed media is not retried unless the normal Pinchflat indexing flow would do so.

## Status Values

Media status is derived from existing `MediaItem` records and Oban task state:

- `unknown`: no media item exists for that YouTube ID in the source
- `discovered`: media exists but is not currently pending, queued, downloading, completed, prevented, or failed
- `pending`: media matches Pinchflat's pending-download rules
- `queued`: a download job is queued, scheduled, or retryable
- `downloading`: a download job is executing
- `completed`: a media filepath is present
- `prevented`: download has been prevented
- `failed`: media has a recorded last error

## Errors

Errors use a uniform JSON shape:

```json
{
  "error": {
    "code": "source_not_found",
    "message": "Source not found",
    "details": {}
  }
}
```
