#!/usr/bin/env bash

# Give the command its own process group, including children such as
# yt-dlp's bundled Python process, Deno and ffmpeg. Killing only $! leaves
# those children running after a job is cancelled.
# Bash assigns the process group before returning from the background launch.
# This also avoids a race between stdin closing and an external setsid starting.
set -m
"$@" &
command_pid=$!
set +m
watcher_pid=

cleanup() {
  kill -KILL -- "-$command_pid" 2>/dev/null || :
  if [[ -n "$watcher_pid" ]]; then
    kill -KILL "$watcher_pid" 2>/dev/null || :
    wait "$watcher_pid" 2>/dev/null || :
  fi
}

trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# Explicitly preserve stdin for the background watcher; otherwise Bash gives
# asynchronous commands /dev/null. System.cmd closes this pipe on cancellation.
(
  while IFS= read -r; do :; done
  kill -KILL -- "-$command_pid" 2>/dev/null || :
) <&0 >/dev/null 2>&1 &
watcher_pid=$!

wait "$command_pid" 2>/dev/null
ret=$?
exit "$ret"
