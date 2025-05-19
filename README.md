# 🍅 Rustic Map Tiles

_Delightfully unrefined OpenStreetMap tiles_

### Features

- 🤌 **Pure OpenStreetMap**: OSM has all the data needed to make a great map. Patching in external datasets such as Natural Earth or Wikidata makes the map harder to deploy and more complicated to edit, so Rustic doesn't bother.
- 🦆 **No tag transforms**: OSM mappers know OSM tagging and typically want to work with it directly. Rustic does not make opinionated tag transforms, leaving it for the client app to interpret tag values (though tags are filtered for berevity).
- 🔂 **Minutely updates**: Seeing your edits appear on the map right away makes mapping more fun. It also surfaces potential issues quickly, before they are propagated elsewhere. Rustic pulls in minutely diffs from the mainline OSM servers to keep the tiles as fresh as possible.
- 🛤️ **Speedy renders**: Minutely tiles can't be cached for very long, so lightning-fast renders are critical. Rustic has a highly optimized SQL query that avoids conveniences like procedural language, recursion, `UNION`s, and expensive spatial functions like `ST_Union`.
- 🌾 **High-zoom tiles**: Other tilesets render only low- and mid-zoom tiles, relying on "overzoom" to show detailed areas. Rustic instead renders high-zoom tiles so that indoor floorplans, building parts, highway areas, and other micromapped features can be included without ballooning individual tile sizes.

### Caveats

- **Heavy filtering**: Rustic tiles are not QA tiles and do not include all OSM features or tags. 
- **Built for a single client**: Rustic tiles are tuned to look visually correct in MapLibre and is not tested for other use cases. Data may not always be topologically correct.
- **No planet-level processing**: Database-wide functions, such as network analysis or coastline aggregation, are not performant for minutely-updated tiles. All processing in Rustic is done per-feature at import or per-tile at render.

## Development

### Stack

- OpenStreetMap
- PostgreSQL/PostGIS
- osm2pgsql
- Martin

### Schema

Rustic uses a custom tile schema to achieve its design goals. See [SCHEMA.md](SCHEMA.md) for detailed info.

### Running locally

For convenience, a Dockerfile is provided that will run the server in an Ubuntu environment. Deploying the stack via Docker is intended for development only and has not been tested in production.

To build the reusable Docker image, run:

```
docker build -t rustic-tileserver:latest -f Dockerfile .
```

To create and start a container using the Docker image, run: 

```
docker run --name rustic-dev-container -p 3000:3000 --mount type=bind,src=./server,dst=/usr/src/app --mount type=bind,src=./tmp,dst=/var/tmp/app rustic-tileserver:latest
```

The first `--mount` is required to copy over the `/server` directory to the container. Any changes to these files will be immediately synced between the host and the container. The second `--mount` is optional but is convenient for managing intermediate files (which may be quite large) on the host system.

To restart the container once it's stopped, run:

```
docker start rustic-dev-container -i
```

To apply changes to `functions.sql` while the container (and Postgres) are running, run:

```
docker exec -i rustic-dev-container /usr/src/app/update_sql_functions.sh
```