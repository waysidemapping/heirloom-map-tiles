#!/bin/bash

# set -x # echo on
set -euo pipefail

# Directory of this current script
APP_DIR="$(dirname "$0")"
DB_NAME="osm"
DB_USER="osmuser"

# We're going to fetch the OSM key information from text files and insert it into the SQL functions

# area layer

AREA_SQL_FUNCTION=$(<"$APP_DIR/sql/function_get_area_features_for_tile.sql")

AREA_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/area_key.txt" | sed "s/.*/'&'/" | paste -sd, -)
AREA_SQL_FUNCTION=${AREA_SQL_FUNCTION//\{\{AREA_KEY_LIST\}\}/$AREA_KEY_LIST}

AREA_KEY_PREFIX_LIKE_STATEMENTS=$(grep -v '^$' "$APP_DIR/schema_data/area_key_prefix.txt" | awk '{print "OR key LIKE \x27" $0 "%%\x27"}' | paste -sd' ' -)
AREA_SQL_FUNCTION=${AREA_SQL_FUNCTION//\{\{AREA_KEY_PREFIX_LIKE_STATEMENTS\}\}/$AREA_KEY_PREFIX_LIKE_STATEMENTS}

LOW_ZOOM_AREA_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/area_key_low_zoom.txt" | sed "s/.*/'&'/" | paste -sd, -)
AREA_SQL_FUNCTION=${AREA_SQL_FUNCTION//\{\{LOW_ZOOM_AREA_KEY_LIST\}\}/$LOW_ZOOM_AREA_KEY_LIST}

# line layer

LINE_SQL_FUNCTION=$(<"$APP_DIR/sql/function_get_line_features_for_tile.sql")

LINE_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/line_key.txt" | sed "s/.*/'&'/" | paste -sd, -)
LINE_SQL_FUNCTION=${LINE_SQL_FUNCTION//\{\{LINE_KEY_LIST\}\}/$LINE_KEY_LIST}

LINE_KEY_PREFIX_LIKE_STATEMENTS=$(grep -v '^$' "$APP_DIR/schema_data/line_key_prefix.txt" | awk '{print "OR key LIKE \x27" $0 "%%\x27"}' | paste -sd' ' -)
LINE_SQL_FUNCTION=${LINE_SQL_FUNCTION//\{\{LINE_KEY_PREFIX_LIKE_STATEMENTS\}\}/$LINE_KEY_PREFIX_LIKE_STATEMENTS}

LOW_ZOOM_LINE_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/line_key_low_zoom.txt" | sed "s/.*/'&'/" | paste -sd, -)
LINE_SQL_FUNCTION=${LINE_SQL_FUNCTION//\{\{LOW_ZOOM_LINE_KEY_LIST\}\}/$LOW_ZOOM_LINE_KEY_LIST}

# point layer

POINT_SQL_FUNCTION=$(<"$APP_DIR/sql/function_get_point_features_for_tile.sql")

POINT_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/point_key.txt" | sed "s/.*/'&'/" | paste -sd, -)
POINT_SQL_FUNCTION=${POINT_SQL_FUNCTION//\{\{POINT_KEY_LIST\}\}/$POINT_KEY_LIST}

POINT_KEY_PREFIX_LIKE_STATEMENTS=$(grep -v '^$' "$APP_DIR/schema_data/point_key_prefix.txt" | awk '{print "OR key LIKE \x27" $0 "%%\x27"}' | paste -sd' ' -)
POINT_SQL_FUNCTION=${POINT_SQL_FUNCTION//\{\{POINT_KEY_PREFIX_LIKE_STATEMENTS\}\}/$POINT_KEY_PREFIX_LIKE_STATEMENTS}

# relation layer

ROOT_SQL_FUNCTION=$(<"$APP_DIR/sql/function_get_beefsteak_tile.sql")

RELATION_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/relation_key.txt" | sed "s/.*/'&'/" | paste -sd, -)
ROOT_SQL_FUNCTION=${ROOT_SQL_FUNCTION//\{\{RELATION_KEY_LIST\}\}/$RELATION_KEY_LIST}

RELATION_KEY_PREFIX_LIKE_STATEMENTS=$(grep -v '^$' "$APP_DIR/schema_data/relation_key_prefix.txt" | awk '{print "OR key LIKE \x27" $0 "%\x27"}' | paste -sd' ' -)
ROOT_SQL_FUNCTION=${ROOT_SQL_FUNCTION//\{\{RELATION_KEY_PREFIX_LIKE_STATEMENTS\}\}/$RELATION_KEY_PREFIX_LIKE_STATEMENTS}


sudo -u "$DB_USER" psql "$DB_NAME" -v ON_ERROR_STOP=1 -f "$APP_DIR/sql/function_get_ocean_for_tile.sql"
sudo -u "$DB_USER" psql "$DB_NAME" -v ON_ERROR_STOP=1 <<< "$AREA_SQL_FUNCTION"
sudo -u "$DB_USER" psql "$DB_NAME" -v ON_ERROR_STOP=1 <<< "$LINE_SQL_FUNCTION"
sudo -u "$DB_USER" psql "$DB_NAME" -v ON_ERROR_STOP=1 <<< "$POINT_SQL_FUNCTION"
sudo -u "$DB_USER" psql "$DB_NAME" -v ON_ERROR_STOP=1 <<< "$ROOT_SQL_FUNCTION"
