# Pinchflat REST API

Pinchflat exposes a small authenticated API for external clients that add videos to a YouTube playlist already configured as a Pinchflat Source.

The playlist remains the source of truth. The API does not add videos to YouTube playlists and does not download arbitrary YouTube IDs. A client should first update the YouTube playlist, then call `/sync`, then poll media status.

## Configuration

Set `PINCHFLAT_API_TOKEN` in the Pinchflat environment:

```yaml
services:
  pinchflat:
    image: ghcr.io/kieraneglin/pinchflat:latest
    environment:
      PINCHFLAT_API_TOKEN: "change-me"
```

Requests must include:

```text
Authorization: Bearer <token>
```

If `PINCHFLAT_API_TOKEN` is not set, API endpoints return `503`.

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
    {"youtube_id": "AAA00000000", "status": "completed", "media_id": 1},
    {"youtube_id": "BBB00000000", "status": "unknown", "media_id": null}
  ]
}
```

## Limits And Idempotency

`youtube_ids` accepts only YouTube video IDs: 11 characters using letters, digits, `_`, or `-`. Full URLs and empty strings are rejected. A batch may contain at most 500 IDs. Duplicate IDs are removed before processing.

`/sync` is idempotent for the same source and IDs. It uses Pinchflat's existing Oban job uniqueness and source indexing helper. Existing downloaded media is not downloaded again, pending or queued media is not duplicated, and failed media is not retried unless the normal Pinchflat indexing flow would do so.

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
