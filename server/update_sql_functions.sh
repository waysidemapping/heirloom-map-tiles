#!/bin/bash

# set -x # echo on

APP_DIR="/usr/src/app"
SQL_FUNCTIONS_FILE="sql/functions.sql"
DB_NAME="osm"

# We're going to fetch the OSM key information from text files and insert it into the SQL functions

SQL_CONTENT=$(<"$SQL_FUNCTIONS_FILE")

# point layer

POINT_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/point_key.txt" | sed "s/.*/'&'/" | paste -sd, -)
SQL_CONTENT=${SQL_CONTENT//\{\{POINT_KEY_LIST\}\}/$POINT_KEY_LIST}

POINT_KEY_PREFIX_LIKE_STATEMENTS=$(grep -v '^$' "$APP_DIR/schema_data/point_key_prefix.txt" | awk '{print "OR key LIKE \x27" $0 "%\x27"}' | paste -sd' ' -)
SQL_CONTENT=${SQL_CONTENT//\{\{POINT_KEY_PREFIX_LIKE_STATEMENTS\}\}/$POINT_KEY_PREFIX_LIKE_STATEMENTS}

# line layer

LINE_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/line_key.txt" | sed "s/.*/'&'/" | paste -sd, -)
SQL_CONTENT=${SQL_CONTENT//\{\{LINE_KEY_LIST\}\}/$LINE_KEY_LIST}

LINE_KEY_PREFIX_LIKE_STATEMENTS=$(grep -v '^$' "$APP_DIR/schema_data/line_key_prefix.txt" | awk '{print "OR key LIKE \x27" $0 "%\x27"}' | paste -sd' ' -)
SQL_CONTENT=${SQL_CONTENT//\{\{LINE_KEY_PREFIX_LIKE_STATEMENTS\}\}/$LINE_KEY_PREFIX_LIKE_STATEMENTS}

LOW_ZOOM_LINE_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/line_key_low_zoom.txt" | sed "s/.*/'&'/" | paste -sd, -)
SQL_CONTENT=${SQL_CONTENT//\{\{LOW_ZOOM_LINE_KEY_LIST\}\}/$LOW_ZOOM_LINE_KEY_LIST}

# area layer

AREA_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/area_key.txt" | sed "s/.*/'&'/" | paste -sd, -)
SQL_CONTENT=${SQL_CONTENT//\{\{AREA_KEY_LIST\}\}/$AREA_KEY_LIST}

AREA_KEY_PREFIX_LIKE_STATEMENTS=$(grep -v '^$' "$APP_DIR/schema_data/area_key_prefix.txt" | awk '{print "OR key LIKE \x27" $0 "%\x27"}' | paste -sd' ' -)
SQL_CONTENT=${SQL_CONTENT//\{\{AREA_KEY_PREFIX_LIKE_STATEMENTS\}\}/$AREA_KEY_PREFIX_LIKE_STATEMENTS}

LOW_ZOOM_AREA_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/area_key_low_zoom.txt" | sed "s/.*/'&'/" | paste -sd, -)
SQL_CONTENT=${SQL_CONTENT//\{\{LOW_ZOOM_AREA_KEY_LIST\}\}/$LOW_ZOOM_AREA_KEY_LIST}

# relation layer

RELATION_KEY_LIST=$(grep -v '^$' "$APP_DIR/schema_data/relation_key.txt" | sed "s/.*/'&'/" | paste -sd, -)
SQL_CONTENT=${SQL_CONTENT//\{\{RELATION_KEY_LIST\}\}/$RELATION_KEY_LIST}

RELATION_KEY_PREFIX_LIKE_STATEMENTS=$(grep -v '^$' "$APP_DIR/schema_data/relation_key_prefix.txt" | awk '{print "OR key LIKE \x27" $0 "%\x27"}' | paste -sd' ' -)
SQL_CONTENT=${SQL_CONTENT//\{\{RELATION_KEY_PREFIX_LIKE_STATEMENTS\}\}/$RELATION_KEY_PREFIX_LIKE_STATEMENTS}


sudo -u postgres psql "$DB_NAME" -v ON_ERROR_STOP=1 -f "sql/function_get_ocean_for_tile.sql"
sudo -u postgres psql "$DB_NAME" -v ON_ERROR_STOP=1 <<< "$SQL_CONTENT"
