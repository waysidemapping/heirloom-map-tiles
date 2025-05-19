#!/bin/bash

# set -x # echo on
set -e # Exit if any command fails

APP_DIR="/usr/src/app"
SCRATCH_DIR="/var/tmp/app"
SQL_FUNCTIONS_FILE="functions.sql"
DB_NAME="osm"

# Use the latest list instead of the list at import since all tags are present in the db, we're just filtering 
JSONB_KEYS=$(cat $APP_DIR/helper_data/jsonb_field_keys.txt | sed "s/.*/'&'/" | paste -sd, -)

# Generate COLUMN_NAMES from the keys listed in the two text files used when creating the database
COLUMN_NAMES=$(cat $SCRATCH_DIR/import_helper_data/column_keys.txt | sed 's/.*/"&"/' | paste -sd, -)
COLUMN_NAMES="$COLUMN_NAMES,$(cat $SCRATCH_DIR/import_helper_data/table_keys.txt | sed 's/.*/"&"/' | paste -sd, -)"

# Coastlines are derived so we want to set all the attributes to NULL
COLUMN_NAMES_FOR_COASTLINE=$(cat $SCRATCH_DIR/import_helper_data/column_keys.txt | sed 's/.*/NULL AS "&"/' | paste -sd, -)
COLUMN_NAMES_FOR_COASTLINE="$COLUMN_NAMES_FOR_COASTLINE,$(cat $SCRATCH_DIR/import_helper_data/table_keys.txt | sed 's/.*/NULL AS "&"/' | paste -sd, -)"
# Except for the attribute `natural=coastline` which we'll replace inline while keeping the column order
COLUMN_NAMES_FOR_COASTLINE=$(echo "$COLUMN_NAMES_FOR_COASTLINE" | sed 's/NULL AS "natural"/'\''coastline'\'' AS "natural"/')

FIELD_DEFS="$(cat $SCRATCH_DIR/import_helper_data/column_keys.txt | sed 's/.*/"&":"String"/' | paste -sd, -)"
FIELD_DEFS="$FIELD_DEFS,$(cat $SCRATCH_DIR/import_helper_data/table_keys.txt | sed 's/.*/"&":"String"/' | paste -sd, -)"

SQL_CONTENT=$(<"$SQL_FUNCTIONS_FILE")
SQL_CONTENT=${SQL_CONTENT//\{\{JSONB_KEYS\}\}/$JSONB_KEYS}
SQL_CONTENT=${SQL_CONTENT//\{\{COLUMN_NAMES\}\}/$COLUMN_NAMES}
SQL_CONTENT=${SQL_CONTENT//\{\{COLUMN_NAMES_FOR_COASTLINE\}\}/$COLUMN_NAMES_FOR_COASTLINE}
SQL_CONTENT=${SQL_CONTENT//\{\{FIELD_DEFS\}\}/$FIELD_DEFS}

sudo -u postgres psql "$DB_NAME" -v ON_ERROR_STOP=1 <<< "$SQL_CONTENT"
