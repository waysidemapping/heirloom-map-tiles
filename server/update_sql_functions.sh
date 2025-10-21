#!/bin/bash

# set -x # echo on

APP_DIR="/usr/src/app"
SQL_FUNCTIONS_FILE="sql/functions.sql"
DB_NAME="osm"

# Use the latest lists instead of the lists at import since all tags are present in the db, we're just filtering 
JSONB_KEYS=$(grep -v '^$' "$APP_DIR/schema_data/key.txt" | sed "s/.*/'&'/" | paste -sd, -)
JSONB_PREFIXES=$(grep -v '^$' "$APP_DIR/schema_data/key_prefix.txt" | awk '{print "OR key LIKE \x27" $0 "%%\x27"}' | paste -sd' ' -)

RELATION_JSONB_KEYS=$(grep -v '^$' "$APP_DIR/schema_data/relation_key.txt" | sed "s/.*/'&'/" | paste -sd, -)

FIELD_DEFS="$(grep -v '^$' "$APP_DIR/schema_data/key.txt" | sed 's/.*/"&":"String"/' | paste -sd, -)"
FIELD_DEFS="$FIELD_DEFS,$(grep -v '^$' "$APP_DIR/schema_data/key_prefix.txt" | sed 's/.*/"&\*":"String"/' | paste -sd, -)"

LOW_ZOOM_LINE_JSONB_KEYS=$(grep -v '^$' "$APP_DIR/schema_data/low_zoom_line_key.txt" | sed "s/.*/'&'/" | paste -sd, -)
LOW_ZOOM_LINE_JSONB_PREFIXES=$(grep -v '^$' "$APP_DIR/schema_data/low_zoom_line_key_prefix.txt" | awk '{print "OR key LIKE \x27" $0 "%%\x27"}' | paste -sd' ' -)

LOW_ZOOM_AREA_JSONB_KEY_MAPPINGS="$(grep -v '^$' "$APP_DIR/schema_data/low_zoom_area_key.txt" | sed "s/.*/'&', tags->'&'/" | paste -sd, -)"

SQL_CONTENT=$(<"$SQL_FUNCTIONS_FILE")
SQL_CONTENT=${SQL_CONTENT//\{\{JSONB_KEYS\}\}/$JSONB_KEYS}
SQL_CONTENT=${SQL_CONTENT//\{\{JSONB_PREFIXES\}\}/$JSONB_PREFIXES}
SQL_CONTENT=${SQL_CONTENT//\{\{RELATION_JSONB_KEYS\}\}/$RELATION_JSONB_KEYS}
SQL_CONTENT=${SQL_CONTENT//\{\{FIELD_DEFS\}\}/$FIELD_DEFS}
SQL_CONTENT=${SQL_CONTENT//\{\{LOW_ZOOM_LINE_JSONB_KEYS\}\}/$LOW_ZOOM_LINE_JSONB_KEYS}
SQL_CONTENT=${SQL_CONTENT//\{\{LOW_ZOOM_LINE_JSONB_PREFIXES\}\}/$LOW_ZOOM_LINE_JSONB_PREFIXES}
SQL_CONTENT=${SQL_CONTENT//\{\{LOW_ZOOM_AREA_JSONB_KEY_MAPPINGS\}\}/$LOW_ZOOM_AREA_JSONB_KEY_MAPPINGS}

sudo -u postgres psql "$DB_NAME" -v ON_ERROR_STOP=1 -f "sql/function_get_ocean_for_tile.sql"
sudo -u postgres psql "$DB_NAME" -v ON_ERROR_STOP=1 <<< "$SQL_CONTENT"
