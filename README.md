# 🍅 Heirloom Map Tiles

_Server-farm-to-table OpenStreetMap tiles_

Heirloom is a special cultivar of [OpenStreetMap](https://www.openstreetmap.org/about/)-based vector tiles developed for artisan mapmakers. While mass-market solutions like [OpenMapTiles](https://openmaptiles.org/) are great for building simple basemaps, they trade off data fidelity for ease-of-use. Heirloom instead contains the full palette of flavors found in OSM data. Heirloom even supports live updates from OSM to ensure the freshest maps possible. Sure it's easier to pop open a can of pasta sauce, but these are map tiles for people who prefer to whip up their own (and love to throw in a parmesan rind).

### 🍝 Features

- 🤌 **Pure OpenStreetMap**: OSM has all the vector data you need to make a great map. Patching in external datasets such as Natural Earth or Wikidata makes the map harder to deploy and more difficult to edit, so Heirloom doesn't bother.
- 🦆 **Tags are tags**: OSM mappers love the richness of OSM tagging and typically prefer to work with it directly. Heirloom does not make opinionated tag transforms or filter tag values, so new and niche values are supported automatically.
- 🔂 **Minutely updates**: Seeing your edits appear on the map right away makes mapping more fun. It also surfaces potential issues quickly before they are propagated elsewhere. Heirloom is able to pull in minutely diffs from the mainline OSM servers to keep the tiles as fresh as possible.
- 🌾 **High-zoom tiles**: Other tilesets render only low- and mid-zoom tiles, relying on "overzoom" to show detailed areas. Heirloom instead renders high-zoom tiles so that indoor floorplans, building parts, highway areas, and other micromapped features can be included without ballooning individual tile sizes.
- 🔌 **Hot-swappable schema**: OSM tagging standards are always changing and growing. Heirloom is future-proofed by handling most data logic at render time. This way, updates can be applied immediately without a planet-wide rebuild.

### ⚠️ Caveats

- 🏓 **Server required**: Heirloom requires a traditional tileserver to deliver features like minutely-updated tiles. This model generally has greater cost and complexity compared to static map tile solutions like [Planetiler](https://github.com/onthegomap/planetiler) + [Protomaps](https://protomaps.com/).
- 🍋 **No sugarcoating**: Heirloom presents the data as-is without trying to hide issues or assume too much knowledge about OSM tagging. This gives cartographers more power, but also increases styling complexity. And where OSM data is inconsistent or broken, Heirloom will be too.
- 🏋️ **Heavy tile sizes**: To support richer map styles, Heirloom includes a lot more data than found in traditional "production" map tiles. This can cause Heirloom-based maps to be less responsive over slower connections. Even so, these are not QA tiles and do not include all OSM features or tags.
- 🧐 **Built for a single renderer**: Heirloom tiles are tuned to look visually correct rendered as Web Mercator in [MapLibre](https://maplibre.org). They are not tested for other use cases. Data may not always be topologically correct.
- 🏝️ **No planet-level processing**: Database-wide functions, such as network analysis or coastline aggregation, are not performant for minutely-updated tiles. All processing in Heirloom is done per-feature at import or per-tile at render.

### 🥫 Alternatives

Heirloom map tiles aren't for everyone. If you don't need Heirloom's power and complexity, consider working with something simpler.

- [Sourdough](https://sourdough.osm.fyi/): If you don't need minutely updates, high-zoom tiles, or a hot-swappable schema, then you don't need to run a traditional tileserver. If you still want to work with raw OSM tags, definitely check out Sourdough by [@jake-low](https://github.com/jake-low/). Heirloom and Sourdough are cousins of sorts.
- [OSM Spyglass](https://codeberg.org/jot/osm-spyglass): If you want to work with ALL tagged OSM features in vector tiles, Spyglass is a great solution.
- [OpenMapTiles](https://openmaptiles.org/): If you just want an out-of-the-box basemap solution with broad support, you probably want OpenMapTiles. There are a few free tileservers providing tiles in this format, mainly the [OSM US Tileservice](https://tiles.openstreetmap.us/) and [OpenFreeMap](https://openfreemap.org/).
- [Shortbread](https://shortbread-tiles.org/): If you're looking for a lean, general-purpose tile schema supported on openstreetmap.org, try Shortbread. Shortbread also supports minutely updates.

## 🍴 Using Heirloom tiles

### Schema

The Heirloom tile schema is tuned to be as close to OpenStreetMap as possible while maintaining reasonable tile sizes and render speeds. The basics are very simple:

- There are only three geometry layers: `point`, `line`, and `area`. Features may appear in multiple layers.
- All features with specific top-level OSM keys are included (no matter what values).
- All tags for certain keys and key prefixes are included as attributes (no matter what values).
- Features may be filtered or aggregated depending on zoom level.
- Coastlines and boundaries get special treatment.

For detailed info, see [SCHEMA.md](SCHEMA.md).

### MapLibre styling

Heirloom tiles are intended to be displayed with [MapLibre](https://maplibre.org) and are well supported by the [style spec](https://maplibre.org/maplibre-style-spec/).

To get started, add your Heirloom server endpoint as a vector source in your map style:

```
"sources": {
    "heirloom": {
        "type": "vector",
        "url": "https://heirloom.example.com"
    }
}
```

To add a display layer, select the source layer based on geometry, and then filter using OpenStreetMap tags:

```
"layers": [
    {
        "id": "waterway",
        "source": "heirloom",
        "source-layer": "line",
        "type": "line",
        "filter": ["has", "waterway"],
        "paint": {
            "line-color": "blue"
        }
    }
]
```

Note that any quirks in OSM tagging will be reflected in the tiles. For example, the above code block will color dams blue since they are tagged under `waterway`. To account for this, change the filter to exclude them:

```
"filter": [
    "all",
    ["has", "waterway"],
    ["!", ["in", ["get", "waterway"], ["literal", ["dam", "weir"]]]]
]
```

Alternatively, you can style by attribute within the property itself: 

```
"line-color": [
    "case",
    ["in", ["get", "waterway"], ["literal", ["dam", "weir"]]], "grey",
    "blue"
]
```

Using these techniques, you can create expressive, detailed maps with the many OSM tags included in Heirloom tiles.

## 🧑‍🍳 Developing Heirloom

### Stack

Heirloom strives to have minimal dependencies. It is built atop the following open source projects:

- [Martin](https://github.com/maplibre/martin): vector maptile server
- [osm2pgsql](https://github.com/osm2pgsql-dev/osm2pgsql): OSM data importer for Postgres
- [PostGIS](https://postgis.net): geospatial extension for Postgres
- [OpenStreetMap](https://www.openstreetmap.org/about/) (OSM): free, collaborative, global geospatial database 

### Running locally

For convenience, a Dockerfile is provided that will run the server in an Ubuntu environment. Deploying the stack via Docker is intended for development only and has not been tested in production.

To build the reusable Docker image, run:

```
docker build -t heirloom-tileserver:latest -f Dockerfile .
```

To create and start a container using the Docker image, run: 

```
docker run --name heirloom-dev-container -p 3000:3000 --mount type=bind,src=./server,dst=/usr/src/app --mount type=bind,src=./tmp,dst=/var/lib/app heirloom-tileserver:latest
```

The first `--mount` is required to copy over the `/server` directory to the container. Any changes to these files will be immediately synced between the host and the container. The second `--mount` is optional but is convenient for managing intermediate files (which may be quite large) on the host system.

To restart the container once it's stopped, run:

```
docker start heirloom-dev-container -i
```

To apply changes to `functions.sql` while the container (and Postgres) are running, run:

```
docker exec -i heirloom-dev-container /usr/src/app/update_sql_functions.sh
```

To run a custom SQL query in the database (useful for debugging), run:

```
docker exec -i heirloom-dev-container sudo -u postgres psql -U postgres -d osm -c "yourquery"
```

### SQL guidelines

Minutely tiles can't be cached for very long, so lightning-fast renders are critical. Heirloom has a highly optimized SQL query that goes without luxuries like recursion, `UNION`, `ST_SimplifyPreserveTopology`, and `ST_Union`.

## ℹ️ FAQ

### What's with the name?

An [heirloom](https://en.wikipedia.org/wiki/Heirloom_plant) (pronounced *AIR-loom* in the US) is a rare varietal of fruit, vegetable, etc. that is typically homegrown rather than produced for agribusiness. Likewise, Heirloom tiles are homegrown map tiles meant for specialty use rather than mass-market deployment.
