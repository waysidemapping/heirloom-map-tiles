# 🍅 Beefsteak Map Tiles

_Server-farm-to-table OpenStreetMap tiles_

Beefsteak is a special cultivar of [OpenStreetMap](https://www.openstreetmap.org/about/)-based vector tiles developed for artisan mapmakers. While mass-market solutions like [OpenMapTiles](https://openmaptiles.org/) are great for building simple basemaps, they trade off data fidelity for ease-of-use. Beefsteak instead contains the full palette of flavors found in OSM data. Beefsteak even supports live updates from OSM to ensure the freshest maps possible. Sure it's easier to pick up tomatoes at the store, but these are map tiles for people who know the best flavor comes straight out of the garden.

### 🍝 Features

- 🤌 **Pure OpenStreetMap**: OSM has all the vector data you need to make a great map. Patching in external datasets makes the map harder to deploy and more difficult to edit, so Beefsteak doesn't bother.
- 🦆 **Tags are tags**: OSM mappers love the richness of OSM tagging and typically prefer to work with it directly. Beefsteak does not make opinionated tag transforms or filter tag values, so new and niche values are supported automatically.
- 🔂 **Minutely updates**: Seeing your edits appear on the map right away makes mapping more fun. It also surfaces potential issues quickly before they are propagated elsewhere. Beefsteak is able to pull in minutely diffs from the mainline OSM servers to keep the tiles farm fresh.
- 🌾 **High-zoom tiles**: Other tilesets render only low- and mid-zoom tiles, relying on "overzoom" to show detailed areas. Beefsteak instead renders high-zoom tiles so that indoor floorplans, building parts, highway areas, and other micromapped features can be included without ballooning individual tile sizes.
- 🔌 **Hot-swappable schema**: OSM tagging standards are always changing and growing. Beefsteak is future-proofed by handling most data logic at render time. This way, updates can be applied immediately without a planet-wide rebuild.

### ⚠️ Caveats

- 🏓 **Server required**: Beefsteak requires a traditional tileserver to deliver features like minutely-updated tiles. This model generally has greater cost and complexity compared to static map tile solutions.
- 🍋 **No sugarcoating**: Beefsteak presents the data as-is without trying to hide issues or assume too much knowledge about OSM tagging. This gives cartographers more power, but also increases styling complexity. And where OSM data is inconsistent or broken, Beefsteak will be too.
- 🐂 **Beefy tile sizes**: To support richer map styles, Beefsteak includes a lot more data than found in traditional "production" map tiles. This can cause Beefsteak-based maps to be less responsive over slower connections.
- 🧐 **Built for a single renderer**: Beefsteak tiles are tuned to look visually correct rendered as Web Mercator in [MapLibre](https://maplibre.org). They are not tested for other use cases. Data may not always be topologically correct.
- 🏝️ **No planet-level processing**: Database-wide functions, such as network analysis or coastline aggregation, are not performant for minutely-updated tiles. All processing in Beefsteak is done per-feature at import or per-tile at render.

### 🥫 Alternatives

Beefsteak map tiles aren't for everyone. If you don't need Beefsteak's power and complexity, consider working with something simpler.

- [Sourdough](https://sourdough.osm.fyi/): If you don't need minutely updates, high-zoom tiles, or a hot-swappable schema, then you don't need to run a traditional tileserver. If you still want to work with raw OSM tags, definitely check out Sourdough by [@jake-low](https://github.com/jake-low/). Beefsteak and Sourdough are cousins of sorts.
- [OSM Spyglass](https://codeberg.org/jot/osm-spyglass): If you want to work with ALL tagged OSM features in vector tiles, Spyglass is a great solution.
- [OpenMapTiles](https://openmaptiles.org/): If you just want an out-of-the-box basemap solution with broad support, you probably want OpenMapTiles. There are a few free tileservers providing tiles in this format, mainly the [OSM US Tileservice](https://tiles.openstreetmap.us/) and [OpenFreeMap](https://openfreemap.org/).
- [Shortbread](https://shortbread-tiles.org/): If you're looking for a lean, general-purpose tile schema supported on openstreetmap.org, try Shortbread. Shortbread also supports minutely updates.
- [Planetiler](https://github.com/onthegomap/planetiler) or [Tippecanoe](https://github.com/felt/tippecanoe): If you want to roll your own static vector tiles.

## 🍔 Stack

Beefsteak strives to have minimal dependencies. It is built atop the following open source projects:

- [Martin](https://github.com/maplibre/martin): vector map tileserver
- [osm2pgsql](https://github.com/osm2pgsql-dev/osm2pgsql): OSM data importer for Postgres
- [PostGIS](https://postgis.net): geospatial extension for Postgres
- [OpenStreetMap](https://www.openstreetmap.org/about/) (OSM): free, collaborative, global geospatial database

That's about it. You won't find shims such as Natural Earth, Wikidata, or Microsoft Buildings.

## 🍴 Using Beefsteak tiles

### Schema

The Beefsteak tile schema is tuned to be as close to OpenStreetMap as possible while maintaining reasonable tile sizes and render speeds. The basics are very simple:

- There are only three geometry layers: `point`, `line`, and `area`. Features may appear in multiple layers.
- All features with specific top-level OSM keys are included (no matter what values).
- All tags for certain keys and key prefixes are included as attributes (no matter what values).
- Features may be filtered or aggregated depending on zoom level.
- Coastlines and boundaries get special treatment.

For detailed info, see [schema.md](/docs/schema.md).

### MapLibre styling

Beefsteak tiles are intended to be displayed with [MapLibre](https://maplibre.org) and are well supported by the [style spec](https://maplibre.org/maplibre-style-spec/).

To get started, add your Beefsteak server endpoint as a vector source in your map style:

```
"sources": {
    "beefsteak": {
        "type": "vector",
        "url": "https://beefsteak.example.com"
    }
}
```

To add a display layer, select the source layer based on geometry, and then filter using OpenStreetMap tags:

```
"layers": [
    {
        "id": "waterway",
        "source": "beefsteak",
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

Using these techniques, you can create expressive, detailed maps with the many OSM tags included in Beefsteak tiles.

## 🧑‍🍳 Developing Beefsteak

### Running locally

For convenience, a Dockerfile is provided that will run the server in an Ubuntu environment. Deploying the stack via Docker is intended for development only and has not been tested in production.

To build the reusable Docker image, run:

```
docker build -t beefsteak-tileserver:latest -f Dockerfile .
```

To create and start a container using the Docker image, run: 

```
docker run --name beefsteak-dev-container -p 3000:3000 --mount type=bind,src=./server,dst=/usr/src/app --mount type=bind,src=./tmp,dst=/var/lib/app beefsteak-tileserver:latest
```

The first `--mount` is required to copy over the `/server` directory to the container. Any changes to these files will be immediately synced between the host and the container. The second `--mount` is optional but is convenient for managing intermediate files (which may be quite large) on the host system.

To restart the container once it's stopped, run:

```
docker start beefsteak-dev-container -i
```

To apply changes to `functions.sql` while the container (and Postgres) are running, run:

```
docker exec -i beefsteak-dev-container /usr/src/app/update_sql_functions.sh
```

To run a custom SQL query in the database (useful for debugging), run:

```
docker exec -i beefsteak-dev-container sudo -u postgres psql -U postgres -d osm -c "yourquery"
```

### SQL guidelines

Minutely tiles can't be cached for very long, so lightning-fast renders are critical. Beefsteak has a highly optimized SQL query that goes without luxuries like recursion, `UNION`, `ST_SimplifyPreserveTopology`, and `ST_Union`.

## 🚴 Deploying Beefsteak

For detailed instructions on how to deploy your own Beefsteak server, see [deploying.md](/docs/deploying.md).

## ℹ️ FAQ

### What's with the name?

A [beefsteak tomato](https://en.wikipedia.org/wiki/Beefsteak_tomato) (beef tomato in the UK) is a large varietal of tomato that is typically homegrown rather than produced commercially. Likewise, Beefsteak tiles are homegrown map tiles that are larger but jucier than tiles meant for mass-market deployment.

## License

This repository is distributed under the [MIT license](/LICENSE). Dependencies are subject to their respective licenses.
