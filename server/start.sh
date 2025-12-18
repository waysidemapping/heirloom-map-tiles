#!/bin/bash

set -x # echo on
set -euo pipefail

# Directory of this script
APP_DIR="$(dirname "$0")"

ARCHITECTURE=$(uname -m)
PERSISTENT_DIR="/var/lib/app"

PLANET_FILE="$PERSISTENT_DIR/planet-latest.osm.pbf"
PLANET_URL="https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf"
# to load an extract, replace the above URL with something like "https://download.geofabrik.de/north-america/us/rhode-island-latest.osm.pbf"

PG_VERSION="18"
POSTGIS_MAJOR_VERSION="3"
PG_CONF_PATH="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
PG_DATA_DIR="$PERSISTENT_DIR/pg_data"
DB_NAME="osm"
DB_USER="osmuser"
TABLE_PREFIX="planet_osm"

OSM2PGSQL_VERSION="2.2.0"
OSM2PGSQL_DIR="/usr/local/osm2pgsql"
OSM2PGSQL_BUILD_DIR="/usr/local/src/osm2pgsql"
FLAT_NODES_FILE="$PERSISTENT_DIR/flatnodes"
LUA_STYLE_FILE="$APP_DIR/lua/osm2pgsql_style_config.lua"

MARTIN_VERSION="0.19.3"
MARTIN_CONFIG_FILE="$APP_DIR/martin_config.yaml"

VARNISH_VERSION="8.0.0"
VARNISH_DIR="/usr/local/varnish"
VARNISH_BUILD_DIR="/usr/local/src/varnish"
VARNISH_CONFIG_FILE="$APP_DIR/varnish_config.vcl"
VARNISH_CACHE_RAM_GB="2"

[[ "$ARCHITECTURE" == "x86_64" || "$ARCHITECTURE" == "aarch64" ]] && echo "Architecture: $ARCHITECTURE" || { echo "Unsupported architecture: $ARCHITECTURE"; exit 1; }

NUM_CORES=$(nproc)
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')

# Create linux user matching PG role: needed for pgsql peer authentication 
if id "$DB_USER" &>/dev/null; then
    echo "User '$DB_USER' already exists."
else
    echo "Creating user '$DB_USER'..."
    sudo useradd -m "$DB_USER"
    echo "User '$DB_USER' created."
fi

# Create helper directory
if [ ! -d "$PERSISTENT_DIR" ]; then
    mkdir -p "$PERSISTENT_DIR"
fi

# Make our user the owner of the helper directory
if [ "$(stat -c %U "$PERSISTENT_DIR")" != "$DB_USER" ]; then
    sudo chown "$DB_USER":"$DB_USER" "$PERSISTENT_DIR"
fi

# We need to install all of our prerequisite commands here instead of in the Docker image since
# we may not always deploy via the Docker image

# Install wget: needed to fetch planetfile
if ! command -v wget >/dev/null 2>&1; then
    echo "wget not found, installing..."
    sudo apt update && sudo apt install -y wget
    command -v wget &> /dev/null && echo "wget successfully installed." || { echo "Failed to install wget."; exit 1; }
fi

# Install git: needed to clone repos
if ! command -v git >/dev/null 2>&1; then
    echo "git not found, installing..."
    sudo apt update && sudo apt install -y git
    command -v git &> /dev/null && echo "git successfully installed." || { echo "Failed to install git."; exit 1; }
fi

# Install Martin: the tileserver
if ! command -v martin >/dev/null 2>&1; then
    echo "Martin not found. Downloading binary..."
    MARTIN_BINARY_NAME="martin-${ARCHITECTURE}-unknown-linux-gnu"
    wget -O "${MARTIN_BINARY_NAME}.tar.gz" "https://github.com/maplibre/martin/releases/download/martin-v${MARTIN_VERSION}/${MARTIN_BINARY_NAME}.tar.gz" || { echo "Download failed"; exit 1; }
    mkdir "${MARTIN_BINARY_NAME}"
    tar -xvzf "${MARTIN_BINARY_NAME}.tar.gz" -C "${MARTIN_BINARY_NAME}" || { echo "Extraction failed"; exit 1; }
    sudo mv -f "${MARTIN_BINARY_NAME}/martin" /usr/local/bin/ || { echo "Move failed"; exit 1; }
    rm -rf "${MARTIN_BINARY_NAME}.tar.gz" "${MARTIN_BINARY_NAME}" 
    martin --version
else
    echo "Martin is already installed: $(martin --version)"
fi

# Install Varnish: the tile cache 
if ! command -v "$VARNISH_DIR/sbin/varnishd" >/dev/null 2>&1; then
    # We need to build osm2pgsql from source since the bundled version is too old
    echo "Cloning and building Varnish $VARNISH_VERSION..."
    
    echo "Installing dependencies..."
    sudo apt update
    sudo apt install -y \
        make \
        automake \
        autotools-dev \
        libedit-dev \
        libjemalloc-dev \
        libncurses-dev \
        libpcre2-dev \
        libtool \
        pkg-config \
        python3-docutils \
        python3-sphinx \
        cpio

    mkdir -p "$VARNISH_BUILD_DIR"
    cd "$VARNISH_BUILD_DIR"
    wget "https://vinyl-cache.org/downloads/varnish-$VARNISH_VERSION.tgz"
    tar xzf "varnish-$VARNISH_VERSION.tgz"
    cd "varnish-$VARNISH_VERSION"
    ./configure --prefix="$VARNISH_DIR"
    make -j$(nproc)
    sudo make install

    # return to script dir and clean up
    cd "$APP_DIR"
    rm -rf "$VARNISH_BUILD_DIR"

    "$VARNISH_DIR/sbin/varnishd" -V

    echo "Varnish $VARNISH_VERSION installed at $VARNISH_DIR"
fi

# Install osm2pgsql
if ! command -v "$OSM2PGSQL_DIR/bin/osm2pgsql" >/dev/null 2>&1; then
    # We need to build osm2pgsql from source since the bundled version is too old
    echo "Cloning and building osm2pgsql $OSM2PGSQL_VERSION..."
    
    echo "Installing dependencies..."
    sudo apt update
    sudo apt install -y \
        make cmake g++ libboost-dev \
        libexpat1-dev zlib1g-dev libpotrace-dev \
        libopencv-dev libbz2-dev libpq-dev libproj-dev lua5.3 liblua5.3-dev \
        pandoc nlohmann-json3-dev pyosmium

    mkdir "$OSM2PGSQL_BUILD_DIR"
    cd "$OSM2PGSQL_BUILD_DIR"
    git clone https://github.com/openstreetmap/osm2pgsql.git .
    git fetch --tags
    git checkout "tags/$OSM2PGSQL_VERSION" -b "build-$OSM2PGSQL_VERSION"
    mkdir build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX="$OSM2PGSQL_DIR" ..
    make -j$(nproc)
    make install

    # return to script dir and clean up
    cd "$APP_DIR"
    rm -rf "$OSM2PGSQL_BUILD_DIR"

    "$OSM2PGSQL_DIR/bin/osm2pgsql" --version

    echo "osm2pgsql $OSM2PGSQL_VERSION installed at $OSM2PGSQL_DIR"
fi

# Install PostgreSQL
if command -v psql > /dev/null; then
    echo "PostgreSQL is already installed: $(psql -V)"
else
    echo "PostgreSQL is not installed. Proceeding with installation..."

    # delete any possible stale postgres data
    rm -rf "$PG_DATA_DIR"

    sudo apt update
    sudo apt install -y postgresql-common

    # Add PGDG repo
    if ! grep -q apt.postgresql.org /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        echo "Adding PostgreSQL APT repo..."
        sudo apt install -y wget gnupg lsb-release
        wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
        echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
        sudo apt update
    fi

    # Explicitly install only the version we want
    sudo apt install -y \
        postgresql-$PG_VERSION \
        postgresql-contrib-$PG_VERSION \
        postgresql-$PG_VERSION-postgis-$POSTGIS_MAJOR_VERSION \
        postgresql-$PG_VERSION-postgis-$POSTGIS_MAJOR_VERSION-scripts
fi

# Ensure dir exists
if [ ! -d "$PG_DATA_DIR" ]; then
    mkdir -p "$PG_DATA_DIR"
fi

if [ "$(stat -c %U "$PG_DATA_DIR")" != "postgres" ]; then
    sudo chown postgres:postgres "$PG_DATA_DIR"
fi

if [ ! -f "$PG_DATA_DIR/PG_VERSION" ]; then
    echo "Initializing new PostgreSQL cluster at $PG_DATA_DIR"
    sudo -u postgres "/usr/lib/postgresql/${PG_VERSION}/bin/initdb" -D "$PG_DATA_DIR"
fi

# Ensure the config file exists
if [ ! -f "$PG_CONF_PATH" ]; then
    echo "postgresql.conf not found at $PG_CONF_PATH"
    exit 1
fi

if ! grep -q "^#\?data_directory = '$PG_DATA_DIR'" "$PG_CONF_PATH"; then
    # Set the postgres data storage directory
    sudo sed -i "s|^#\?data_directory =.*|data_directory = '$PG_DATA_DIR'|" "$PG_CONF_PATH"
    echo "data_directory updated to $PG_DATA_DIR"
fi

# Start PostgreSQL
if pg_isready > /dev/null 2>&1 && pgrep -x "postgres" > /dev/null; then
    sudo service postgresql restart
else
    sudo service postgresql start
fi
until pg_isready > /dev/null 2>&1; do sleep 1; done

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER'" | grep -q 1; then
    echo "User '$DB_USER' exists."
else
    echo "Creating user '$DB_USER'..."
    sudo -u postgres createuser "$DB_USER"
    sudo -u postgres psql --command='ALTER ROLE osmuser SET plan_cache_mode = force_custom_plan;'
fi

# Setup database
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
    echo "Database '$DB_NAME' exists."
else
    echo "Creating database '$DB_NAME'..."

    sudo -u postgres createdb --encoding=UTF8 --owner="$DB_USER" "$DB_NAME"
    sudo -u postgres psql "$DB_NAME" --command='CREATE EXTENSION postgis;'
    sudo -u postgres psql "$DB_NAME" --command='CREATE EXTENSION hstore;'
fi

# Load data into database
TABLES_EXISTING=$(sudo -u postgres psql -d "$DB_NAME" -tAc \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE '${TABLE_PREFIX}_%';")
if [[ "$TABLES_EXISTING" -gt 0 ]]; then
    echo "osm2pgsql import detected — $TABLES_EXISTING tables found with prefix '${TABLE_PREFIX}_'."
else

    # Set import params dynamically based on available cores and memory
    if [ "$NUM_CORES" -ge 32 ]; then
        MAX_PARALLEL_WORKERS=64
        MAX_PARALLEL_PER_GATHER=16
    elif [ "$NUM_CORES" -ge 16 ]; then
        MAX_PARALLEL_WORKERS=32
        MAX_PARALLEL_PER_GATHER=8
    elif [ "$NUM_CORES" -ge 8 ]; then
        MAX_PARALLEL_WORKERS=16
        MAX_PARALLEL_PER_GATHER=8
    else
        MAX_PARALLEL_WORKERS=$NUM_CORES
        MAX_PARALLEL_PER_GATHER=$(( NUM_CORES / 2 ))
        # Ensure at least 1
        [ "$MAX_PARALLEL_PER_GATHER" -lt 1 ] && MAX_PARALLEL_PER_GATHER=1
    fi
    SHARED_BUFFERS_MB=$(( MEM_KB * 25 / 100 / 1024 ))   # 25% RAM
    MAINTENANCE_MB=$(( MEM_KB * 60 / 100 / 1024 ))      # 60% RAM
    AUTOVAC_MB=$(( MEM_KB * 25 / 100 / 1024 ))          # 25% RAM
    EFFECTIVE_CACHE_MB=$(( MEM_KB * 75 / 100 / 1024 ))  # 75% RAM

    AVAILABLE_BYTES=$(df --output=avail -B1 "$PG_DATA_DIR" | tail -n1)
    AVAILABLE_TB=$((AVAILABLE_BYTES / 1024 / 1024 / 1024 / 1024))

    if [ "$AVAILABLE_TB" -ge 1 ]; then
        MIN_WAL_SIZE_GB=32
        MAX_WAL_SIZE_GB=128
    elif [ "$AVAILABLE_TB" -ge 0.5 ]; then
        MIN_WAL_SIZE_GB=4
        MAX_WAL_SIZE_GB=16
    else
        MIN_WAL_SIZE_GB=1
        MAX_WAL_SIZE_GB=4
    fi

    declare -A PARAMS=(
        ["shared_buffers"]="${SHARED_BUFFERS_MB}MB"
        ["work_mem"]="64MB"
        ["maintenance_work_mem"]="${MAINTENANCE_MB}MB"
        ["autovacuum_work_mem"]="${AUTOVAC_MB}MB"
        ["effective_cache_size"]="${EFFECTIVE_CACHE_MB}MB"
        ["wal_level"]="minimal"
        ["synchronous_commit"]="off"
        ["full_page_writes"]="off"
        ["checkpoint_timeout"]="60min"
        ["min_wal_size"]="${MIN_WAL_SIZE_GB}GB"
        ["max_wal_size"]="${MAX_WAL_SIZE_GB}GB"
        ["checkpoint_completion_target"]="0.9"
        ["max_parallel_workers"]="$MAX_PARALLEL_WORKERS"
        ["max_parallel_workers_per_gather"]="$MAX_PARALLEL_PER_GATHER"
        ["max_wal_senders"]="0"
        ["random_page_cost"]="1.0"
        ["effective_io_concurrency"]="8"
        ["temp_buffers"]="64MB"
        ["autovacuum"]="off"
        ["jit"]="off"
    )
    for key in "${!PARAMS[@]}"; do
        value="${PARAMS[$key]}"
        # Check if value is already as desired
        if grep -Eq "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*${value}\b" "$PG_CONF_PATH"; then
            continue
        fi
        # Remove any existing lines for this parameter (commented or active)
        sudo sed -i "/^[[:space:]]*#\?[[:space:]]*${key}[[:space:]]*=/d" "$PG_CONF_PATH"
        # Append desired parameter
        echo "${key} = ${value}" | sudo tee -a "$PG_CONF_PATH" >/dev/null
    done

    # Restart postgres so our config file changes take effect
    sudo service postgresql restart
    until pg_isready > /dev/null 2>&1; do sleep 1; done

    # Remove stale flat nodes cache file, if any
    rm -f -- "$FLAT_NODES_FILE"

    echo "Downloading the OSM Planet file..."
    if [ ! -f "$PLANET_FILE" ]; then
        wget "$PLANET_URL" -O "$PLANET_FILE"
    else
        echo "Planet file already exists: $PLANET_FILE"
    fi

    # Allow 2 GB of RAM for node cache if not using flat nodes file
    NODE_CACHE_PARAMS="--cache=2000"
    # Cache nodes in a flat file if input is larger than 10 GB, per https://osm2pgsql.org/doc/manual.html#flat-node-store
    if [[ -f "$PLANET_FILE" ]] && [[ $(stat -c%s "$PLANET_FILE") -gt 10737418240 ]]; then
        NODE_CACHE_PARAMS="--flat-nodes=$FLAT_NODES_FILE --cache=0"
    fi

    echo "Running import..."
    # These options are documented but are not needed with flex output: --merc --multi-geometry --keep-coastlines
    sudo -u "$DB_USER" "$OSM2PGSQL_DIR/bin/osm2pgsql" \
        -d "$DB_NAME" \
        -U "$DB_USER" \
        --create \
        --slim \
        --extra-attributes \
        $NODE_CACHE_PARAMS \
        --prefix="$TABLE_PREFIX" \
        --output=flex \
        --style="$LUA_STYLE_FILE" \
        "$PLANET_FILE"

    echo "Running post-import SQL queries..."
    sudo -u "$DB_USER" psql "$DB_NAME" --file="$APP_DIR/sql/post_init_or_update/area_relation.sql" &
    wait

    # We need to manually do this since we turned off autovacuum for the import
    sudo -u "$DB_USER" psql "$DB_NAME" --command="VACUUM;"
fi

# Set tileserving params dynamically based on available cores and memory
if [ "$NUM_CORES" -ge 32 ]; then
    MAX_PARALLEL_WORKERS=16
    MAX_PARALLEL_PER_GATHER=4
elif [ "$NUM_CORES" -ge 16 ]; then
    MAX_PARALLEL_WORKERS=8
    MAX_PARALLEL_PER_GATHER=2
elif [ "$NUM_CORES" -ge 8 ]; then
    MAX_PARALLEL_WORKERS=4
    MAX_PARALLEL_PER_GATHER=2
else
    MAX_PARALLEL_WORKERS=$(( NUM_CORES - 2 ))
    [ "$MAX_PARALLEL_WORKERS" -lt 2 ] && MAX_PARALLEL_WORKERS=2
    MAX_PARALLEL_PER_GATHER=2
fi
SHARED_BUFFERS_MB=$(( MEM_KB * 25 / 100 / 1024 ))   # 25% RAM
MAINTENANCE_MB=$(( MEM_KB * 5 / 100 / 1024 ))       # 5% RAM
AUTOVAC_MB=$(( MEM_KB * 2 / 100 / 1024 ))           # 2% RAM
EFFECTIVE_CACHE_MB=$(( MEM_KB * 75 / 100 / 1024 ))  # 75% RAM

AVAILABLE_BYTES=$(df --output=avail -B1 "$PG_DATA_DIR" | tail -n1)
AVAILABLE_TB=$((AVAILABLE_BYTES / 1024 / 1024 / 1024 / 1024))

MIN_WAL_SIZE_GB=4
MAX_WAL_SIZE_GB=16

declare -A PARAMS=(
    ["shared_buffers"]="${SHARED_BUFFERS_MB}MB"
    ["work_mem"]="64MB"                           
    ["maintenance_work_mem"]="${MAINTENANCE_MB}MB"
    ["autovacuum_work_mem"]="${AUTOVAC_MB}MB"
    ["effective_cache_size"]="${EFFECTIVE_CACHE_MB}MB"
    ["wal_level"]="replica"
    ["synchronous_commit"]="on"
    ["full_page_writes"]="on"
    ["checkpoint_timeout"]="15min"
    ["min_wal_size"]="${MIN_WAL_SIZE_GB}GB"
    ["max_wal_size"]="${MAX_WAL_SIZE_GB}GB"
    ["checkpoint_completion_target"]="0.9"
    ["max_parallel_workers"]="$MAX_PARALLEL_WORKERS"
    ["max_parallel_workers_per_gather"]="$MAX_PARALLEL_PER_GATHER"
    ["max_wal_senders"]="5"
    ["random_page_cost"]="1.0"
    ["effective_io_concurrency"]="128"
    ["temp_buffers"]="32MB"
    ["autovacuum"]="on"
    ["jit"]="off"
)

CONFIG_UPDATED=0
for key in "${!PARAMS[@]}"; do
    value="${PARAMS[$key]}"
    # Check if value is already as desired
    if grep -Eq "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*${value}\b" "$PG_CONF_PATH"; then
        continue
    fi
    # Remove any existing lines for this parameter (commented or active)
    sudo sed -i "/^[[:space:]]*#\?[[:space:]]*${key}[[:space:]]*=/d" "$PG_CONF_PATH"
    # Append desired parameter
    echo "${key} = ${value}" | sudo tee -a "$PG_CONF_PATH" >/dev/null
    CONFIG_UPDATED=1
done

if [ "$CONFIG_UPDATED" -eq 1 ]; then
    # Restart postgres so our config file changes take effect
    sudo service postgresql restart
    until pg_isready > /dev/null 2>&1; do sleep 1; done
fi

# Reinstall functions every time in case something changed.
# In order to pass validation, we have to do this after the database has been populated 
/bin/bash "$APP_DIR/update_sql_functions.sh"

# start Varnish
if ! pgrep -x varnishd >/dev/null 2>&1; then
    echo "Starting Varnish..."
    sudo  "$VARNISH_DIR/sbin/varnishd" -a :80 -f "$VARNISH_CONFIG_FILE" -s "malloc,${VARNISH_CACHE_RAM_GB}G"
    echo "Varnish started."
fi

# start Martin
sudo -u "$DB_USER" -- /usr/local/bin/martin --config "$MARTIN_CONFIG_FILE"