#!/bin/bash

set -euo pipefail

BASE_URL="http://127.0.0.1/beefsteak"

max_zoom_level=5

max_concurrent_jobs=10
jobs_running=0

script_start_ms=$(date +%s%3N)

echo "Warming tiles for zoom levels 0 through $max_zoom_level"
for (( z=0; z<=max_zoom_level; z++ )); do
  max=$((2**z))
  for x in $(seq 0 $((max-1))); do
    for y in $(seq 0 $((max-1))); do
      url="$BASE_URL/$z/$x/$y"
      (
        # Use curl to download tile and measure size in bytes and time in seconds
        read tile_size tile_time http_code <<< \
          $(curl -s -L \
          -w "%{size_download} %{time_total} %{http_code}" \
          -o /dev/null \
          "$url")

        if [[ "$http_code" != 2* ]]; then
          echo "Unexpected response for $url (HTTP $http_code)"
          exit 1
        fi

        # convert to milliseconds
        tile_time_ms=$(echo "$tile_time" | awk -F. '{printf "%d", ($1 * 1000) + substr($2"000",1,3)}')

        echo "$z/$x/$y: HTTP ${http_code}, $tile_size bytes, $tile_time_ms ms"
        # write stats to file to aggregate synchronously later
        echo "$url $tile_size $tile_time_ms" >> /tmp/tile_stats.txt
      ) & # run in the background

      jobs_running=$((jobs_running + 1))
      if ((jobs_running >= max_concurrent_jobs)); then
        wait -n   # wait for ANY background job to finish
        jobs_running=$((jobs_running - 1))
      fi

    done
  done
done

# wait for any remaining jobs
wait

script_end_ms=$(date +%s%3N)
script_duration_ms=$((script_end_ms - script_start_ms))

# compile stats
total_size=0
total_time_ms=0
largest_tile_size=0
largest_tile_url=""
slowest_tile_time=0
slowest_tile_url=""
while read url size time_ms; do
  if (( size > largest_tile_size )); then
      largest_tile_size=$size
      largest_tile_url="$url"
  fi
  if (( time_ms > slowest_tile_time )); then
      slowest_tile_time=$time_ms
      slowest_tile_url="$url"
  fi
  total_size=$((total_size + size))
  total_time_ms=$((total_time_ms + time_ms))
done < /tmp/tile_stats.txt

rm /tmp/tile_stats.txt

echo "Total size of all tiles: $total_size bytes"
echo "Largest tile: $largest_tile_url at $largest_tile_size bytes"
echo "Slowest tile: $slowest_tile_url at $slowest_tile_time ms"
echo "Aggregate download time: $total_time_ms ms"
echo "Total script time: $script_duration_ms ms"
