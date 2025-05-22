#!/bin/bash

# set -x # echo on
set -e # Exit if any command fails

APP_DIR="/usr/src/app"
SCRATCH_DIR="/var/tmp/app"
SQL_FUNCTIONS_FILE="functions.sql"
DB_NAME="osm"

# Use the latest lists instead of the lists at import since all tags are present in the db, we're just filtering 
JSONB_KEYS=$(cat $APP_DIR/helper_data/jsonb_field_keys.txt | sed "s/.*/'&'/" | paste -sd, -)
JSONB_PREFIXES=$(awk '{print "OR key LIKE \x27" $0 "%\x27"}' "$APP_DIR/helper_data/jsonb_field_prefixes.txt" | paste -sd' ' -)

# Generate COLUMN_NAMES from the keys listed in the two text files used when creating the database
COLS=$(cat $SCRATCH_DIR/import_helper_data/sql_column_keys.txt | sed 's/.*/"&"/' | paste -sd, -)
COLS="$COLS,$(cat $SCRATCH_DIR/import_helper_data/sql_table_keys.txt | sed 's/.*/"&"/' | paste -sd, -)"

# For aggregate features we want to set all the attributes to NULL
NULL_COLS=$(cat $SCRATCH_DIR/import_helper_data/sql_column_keys.txt | sed 's/.*/NULL AS "&"/' | paste -sd, -)
NULL_COLS="$NULL_COLS,$(cat $SCRATCH_DIR/import_helper_data/sql_table_keys.txt | sed 's/.*/NULL AS "&"/' | paste -sd, -)"
# Except for specific columns
COLS_COASTLINE=$(echo "$NULL_COLS" | sed 's/NULL AS "natural"/'\''coastline'\'' AS "natural"/')

COLS_LOW_Z_HIGHWAY=$(echo "$NULL_COLS" | sed 's/NULL AS "highway"/"highway"/')

COLS_LOW_Z_RAILWAY=$(echo "$NULL_COLS" | sed 's/NULL AS "railway"/"railway"/')
COLS_LOW_Z_RAILWAY=$(echo "$COLS_LOW_Z_RAILWAY" | sed 's/NULL AS "usage"/"usage"/')

COLS_LOW_Z_WATERWAY=$(echo "$NULL_COLS" | sed 's/NULL AS "waterway"/"waterway"/')

FIELD_DEFS="$(cat $SCRATCH_DIR/import_helper_data/sql_column_keys.txt | sed 's/.*/"&":"String"/' | paste -sd, -)"
FIELD_DEFS="$FIELD_DEFS,$(cat $SCRATCH_DIR/import_helper_data/sql_table_keys.txt | sed 's/.*/"&":"String"/' | paste -sd, -)"

SQL_CONTENT=$(<"$SQL_FUNCTIONS_FILE")
SQL_CONTENT=${SQL_CONTENT//\{\{JSONB_KEYS\}\}/$JSONB_KEYS}
SQL_CONTENT=${SQL_CONTENT//\{\{JSONB_PREFIXES\}\}/$JSONB_PREFIXES}
SQL_CONTENT=${SQL_CONTENT//\{\{COLS\}\}/$COLS}
SQL_CONTENT=${SQL_CONTENT//\{\{COLS_COASTLINE\}\}/$COLS_COASTLINE}
SQL_CONTENT=${SQL_CONTENT//\{\{COLS_LOW_Z_HIGHWAY\}\}/$COLS_LOW_Z_HIGHWAY}
SQL_CONTENT=${SQL_CONTENT//\{\{COLS_LOW_Z_RAILWAY\}\}/$COLS_LOW_Z_RAILWAY}
SQL_CONTENT=${SQL_CONTENT//\{\{COLS_LOW_Z_WATERWAY\}\}/$COLS_LOW_Z_WATERWAY}
SQL_CONTENT=${SQL_CONTENT//\{\{FIELD_DEFS\}\}/$FIELD_DEFS}

sudo -u postgres psql "$DB_NAME" -v ON_ERROR_STOP=1 <<< "$SQL_CONTENT"
