#!/bin/bash

set -x # echo on
set -e # Exit if any command fails

ARCHITECTURE=$(uname -m)
SCRATCH_DIR="/var/tmp/app"

PLANET_FILE="$SCRATCH_DIR/planet-latest.osm.pbf"
PLANET_URL="https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf"
# "https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf"

PG_VERSION="17"
DB_NAME="osm"
DB_USER="osmuser"
TABLE_PREFIX="planet_osm"
OSM2PGSQL_VERSION="2.2.0"
OSM2PGSQL_DIR="/usr/local/osm2pgsql"
LUA_STYLE_FILE="osm2pgsql_style_config.lua"

FLAT_NODES_FILE="$SCRATCH_DIR/flatnodes"

MARTIN_CONFIG_FILE="martin_config.yaml"
MARTIN_VERSION="0.19.2"

[[ "$ARCHITECTURE" == "x86_64" || "$ARCHITECTURE" == "aarch64" ]] && echo "Architecture: $ARCHITECTURE" || { echo "Unsupported architecture: $ARCHITECTURE"; exit 1; }

# Create helper directory
if [ ! -d "$SCRATCH_DIR" ]; then
    mkdir -p "$SCRATCH_DIR"
fi

# Create linux user matching PG role: needed for pgsql peer authentication 
if id "$DB_USER" &>/dev/null; then
    echo "User '$DB_USER' already exists."
else
    echo "Creating user '$DB_USER'..."
    sudo useradd -m "$DB_USER"
    echo "User '$DB_USER' created."
fi

# We need to install needed commands here instead of in the Docker image since
# we may not always deploy via the Docker image

# Install wget: needed to fetch planetfile
if command -v wget &> /dev/null; then
    echo "wget is already installed."
else
    echo "wget not found, installing..."
    sudo apt update && sudo apt install -y wget
    command -v wget &> /dev/null && echo "wget successfully installed." || { echo "Failed to install wget."; exit 1; }
fi

# Install git: needed to clone repos
if command -v git &> /dev/null; then
    echo "git is already installed."
else
    echo "git not found, installing..."
    sudo apt update && sudo apt install -y git
    command -v git &> /dev/null && echo "git successfully installed." || { echo "Failed to install git."; exit 1; }
fi

# Need to do this every time unfortunately
export PATH="${OSM2PGSQL_DIR}/bin:$PATH"

is_osm2pgsql_not_installed() {
    if command -v osm2pgsql >/dev/null 2>&1; then
        INSTALLED_VERSION=$(osm2pgsql --version | grep -oP '\d+\.\d+\.\d+')
        if [ "$INSTALLED_VERSION" == "$OSM2PGSQL_VERSION" ]; then
            echo "osm2pgsql $OSM2PGSQL_VERSION is already installed."
        else
            echo "osm2pgsql is installed but version $INSTALLED_VERSION != $OSM2PGSQL_VERSION"
        fi
        return 1
    else
        echo "osm2pgsql is not installed."
    fi
    return 0
}

if is_osm2pgsql_not_installed; then
    # We need to build osm2pgsql from source since the bundled version is too old
    echo "Cloning and building osm2pgsql $OSM2PGSQL_VERSION..."
    
    echo "Installing dependencies..."
    sudo apt update
    sudo apt install -y \
        make cmake g++ libboost-dev \
        libexpat1-dev zlib1g-dev libpotrace-dev \
        libopencv-dev libbz2-dev libpq-dev libproj-dev lua5.3 liblua5.3-dev \
        pandoc nlohmann-json3-dev pyosmium

    git clone https://github.com/openstreetmap/osm2pgsql.git
    cd osm2pgsql
    git fetch --tags
    git checkout "tags/$OSM2PGSQL_VERSION" -b "build-$OSM2PGSQL_VERSION"
    mkdir build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX="$OSM2PGSQL_DIR" ..
    make -j$(nproc)
    make install

    cd ..
    cd ..
    rm -rf "osm2pgsql"

    osm2pgsql --version

    echo "osm2pgsql $OSM2PGSQL_VERSION installed at $OSM2PGSQL_DIR."
fi

# Install PostgreSQL
if command -v psql > /dev/null; then
    echo "PostgreSQL is already installed: $(psql -V)"
else
    echo "PostgreSQL is not installed. Proceeding with installation..."

    sudo apt update

    sudo apt install -y postgresql-common
    yes "" | sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh

    sudo apt update

    echo "Installing PostgreSQL $PG_VERSION and PostGIS..."
    sudo apt install -y postgresql-$PG_VERSION postgresql-contrib-$PG_VERSION postgis

    # Path to postgresql.conf based on version
    PG_CONF_PATH="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"

    # Ensure the file exists
    if [ ! -f "$PG_CONF_PATH" ]; then
        echo "postgresql.conf not found at $PG_CONF_PATH"
        exit 1
    fi

    # Tune postgres config based on osm2pgsql recommendations: https://osm2pgsql.org/doc/manual.html#tuning-the-postgresql-server
    sudo sed -i "s/^#*shared_buffers.*/shared_buffers = 1GB/" "$PG_CONF_PATH" || echo "shared_buffers = 1GB" | sudo tee -a "$PG_CONF_PATH"
    sudo sed -i "s/^#*work_mem.*/work_mem = 50MB/" "$PG_CONF_PATH" || echo "work_mem = 50MB" | sudo tee -a "$PG_CONF_PATH"
    sudo sed -i "s/^#*maintenance_work_mem.*/maintenance_work_mem = 10GB/" "$PG_CONF_PATH" || echo "maintenance_work_mem = 10GB" | sudo tee -a "$PG_CONF_PATH"
    sudo sed -i "s/^#*autovacuum_work_mem.*/autovacuum_work_mem = 2GB/" "$PG_CONF_PATH" || echo "autovacuum_work_mem = 2GB" | sudo tee -a "$PG_CONF_PATH"
    sudo sed -i "s/^#*wal_level.*/wal_level = minimal/" "$PG_CONF_PATH" || echo "wal_level = minimal" | sudo tee -a "$PG_CONF_PATH"
    sudo sed -i "s/^#*checkpoint_timeout.*/checkpoint_timeout = 60min/" "$PG_CONF_PATH" || echo "checkpoint_timeout = 60min" | sudo tee -a "$PG_CONF_PATH"
    sudo sed -i "s/^#*max_wal_size.*/max_wal_size = 10GB/" "$PG_CONF_PATH" || echo "max_wal_size = 10GB" | sudo tee -a "$PG_CONF_PATH"
    sudo sed -i "s/^#*checkpoint_completion_target.*/checkpoint_completion_target = 0.9/" "$PG_CONF_PATH" || echo "checkpoint_completion_target = 0.9" | sudo tee -a "$PG_CONF_PATH"
    sudo sed -i "s/^#*max_wal_senders.*/max_wal_senders = 0/" "$PG_CONF_PATH" || echo "max_wal_senders = 0" | sudo tee -a "$PG_CONF_PATH"
    sudo sed -i "s/^#*random_page_cost.*/random_page_cost = 1.0/" "$PG_CONF_PATH" || echo "random_page_cost = 1.0" | sudo tee -a "$PG_CONF_PATH"

    echo "Verifying PostgreSQL config parameters in $PG_CONF_PATH..."

    if grep -Eq "^\s*shared_buffers\s*=\s*1GB" "$PG_CONF_PATH" && \
        grep -Eq "^\s*work_mem\s*=\s*50MB" "$PG_CONF_PATH" && \
        grep -Eq "^\s*maintenance_work_mem\s*=\s*10GB" "$PG_CONF_PATH" && \
        grep -Eq "^\s*autovacuum_work_mem\s*=\s*2GB" "$PG_CONF_PATH" && \
        grep -Eq "^\s*wal_level\s*=\s*minimal" "$PG_CONF_PATH" && \
        grep -Eq "^\s*checkpoint_timeout\s*=\s*60min" "$PG_CONF_PATH" && \
        grep -Eq "^\s*max_wal_size\s*=\s*10GB" "$PG_CONF_PATH" && \
        grep -Eq "^\s*checkpoint_completion_target\s*=\s*0.9" "$PG_CONF_PATH" && \
        grep -Eq "^\s*max_wal_senders\s*=\s*0" "$PG_CONF_PATH" && \
        grep -Eq "^\s*random_page_cost\s*=\s*1.0" "$PG_CONF_PATH"; then
        echo "All parameters are set correctly."
    else
        echo "One or more parameters are missing or incorrect in $PG_CONF_PATH."
        exit 1
    fi

fi

# Start PostgreSQL
if pg_isready > /dev/null 2>&1; then
    echo "PostgreSQL is running and responsive."
else
    echo "PostgreSQL is not responding. Attempting to start or restart..."

    # Check if the service is running but unresponsive
    if pgrep -x "postgres" > /dev/null; then
        echo "PostgreSQL process is running but not ready. Restarting..."
        sudo service postgresql restart
    else
        echo "PostgreSQL is not running. Starting..."
        sudo service postgresql start
    fi

    # Give it a moment to initialize
    sleep 3

    # Final check
    if pg_isready > /dev/null 2>&1; then
        echo "PostgreSQL is now running and responsive."
    else
        echo "Failed to start or restart PostgreSQL."
        exit 1
    fi
fi

# Setup database
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
    echo "Database '$DB_NAME' exists."
else
    echo "Creating database '$DB_NAME'..."
    # Check if user exists
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER'" | grep -q 1; then
        echo "User '$DB_USER' exists."
    else
        echo "Creating user '$DB_USER'..."
        sudo -u postgres createuser "$DB_USER"
    fi

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
    sudo -u "$DB_USER" env PATH="${OSM2PGSQL_DIR}/bin:$PATH" osm2pgsql \
        -d "$DB_NAME" \
        -U "$DB_USER" \
        --create \
        --slim \
        --extra-attributes \
        "$NODE_CACHE_PARAMS" \
        --prefix="$TABLE_PREFIX" \
        --output=flex \
        --style="$LUA_STYLE_FILE" \
        "$PLANET_FILE"

    echo "Running post-import SQL queries..."
    sudo -u postgres psql "$DB_NAME" --command="UPDATE way SET point_on_surface = ST_PointOnSurface(geom) WHERE is_closed AND point_on_surface IS NULL;" &
    sudo -u postgres psql "$DB_NAME" --command="UPDATE area_relation r SET label_point = n.geom FROM node n WHERE n.id = r.label_node_id AND r.label_point IS NULL; UPDATE area_relation SET label_point = ST_PointOnSurface(geom) WHERE label_point IS NULL;" &
    sudo -u postgres psql "$DB_NAME" --command="UPDATE non_area_relation SET bbox_centerpoint_on_surface = ST_ClosestPoint(geom, ST_Centroid(bbox)) WHERE bbox_centerpoint_on_surface IS NULL;" &
    wait
fi

# Reinstall functions every time in case something changed.
# In order to pass validation, we have to do this after the database has been populated 
/bin/bash update_sql_functions.sh

# Install build-essential: needed to install Martin
if ! dpkg -s build-essential >/dev/null 2>&1; then
    echo "Installing build-essential..."
    apt update && apt install -y build-essential
else
    echo "build-essential already installed."
fi

# Install rust: needed to install Martin
if ! command -v rustc >/dev/null 2>&1; then
    echo "Rust not found. Installing Rust..."
    export RUSTUP_HOME=/usr/local/rustup
    export CARGO_HOME=/usr/local/cargo
    export PATH=/usr/local/cargo/bin:$PATH
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

    # add cargo to path in current shell without needing to restart
    . "/usr/local/cargo/env"
    rustc --version
else
    echo "Rust is already installed: $(rustc --version)"
fi

# Install Martin: the tileserver
if ! command -v martin >/dev/null 2>&1; then
    echo "Martin not found. Installing with cargo..."
    cargo install cargo-binstall
    cargo binstall martin --version "$MARTIN_VERSION" --no-confirm
    martin --version
else
    echo "Martin is already installed: $(martin --version)"
fi

# start tileserver
sudo -u "$DB_USER" -- /usr/local/cargo/bin/martin --config "$MARTIN_CONFIG_FILE"