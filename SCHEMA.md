# Heirloom map tile schema

*This schema is in active development and is not yet versioned. Users should expect that changes may occur at any time without notice. This schema is never expected to become fully stable since tagging changes are inherent to OpenStreetMap.*

## Concepts

### Top-level tags

OpenStreetMap has the concept of [top-level tags](https://wiki.openstreetmap.org/wiki/Top-level_tag) which define the primary "type" of each feature. Heirloom relies heavily on top-level tags to make blanket assumptions about features without needing to worry too much about specific tag values. For example, only features with specific top-level tags are included in the tiles.

Certain top-level keys such as `emergency` and `indoor` are used as attribute tags by some mappers, like `emergency=designated` or `indoor=yes`. For performance and consistency, features with these tag values are NOT ignored as top-level tags, possibly resulting in unexpected behavior.

### Troll tags

For performance and consistency, tag values like `no` and `unknown` (e.g. `building=no` or `shop=unknown`) are NOT ignored anywhere in Heirloom. These are sometimes called [troll tags](https://wiki.openstreetmap.org/wiki/Trolltag) in OSM since they may be technically accurate but often break apps. As such, these tags can be deleted from OSM if they cause issues in Heirloom tiles.

### Areas as ways

OpenStreetMap does not have distinct "line" and "area" entities, only "ways". Open ways can be assumed to be lines, but closed ways (where the first and last nodes are the same) are ambiguous. Each data consumer, including Heirloom, has to figure out how to deal with closed ways based on tagging. Heirloom takes a very strict approach.

* "Explicit" lines
  * Open ways regardless of tagging
  * Closed ways tagged `area=no`
* "Explicit" areas
  * Closed ways tagged `area=yes`
  * Closed ways with any `building` tag (including `building=no` and `building=unknown`)

### Low zooms vs. high zooms

Zoom level 12 is a magic threshold in Heirloom tiles. At z < 12, most features are aggregated and highly filtered for berevity. At z >= 12, most features correspond directly to OSM entities and contain a large number of attribute tags.

### Aggregation, filtering, and simplification

The features in Heirloom tiles are intended to match the original OpenStreetMap data as closely as possible. However, a certain loss of resolution is required in ordered to limit the size of the tiles. This is tuned toward cartography and is intended to have a limited impact on mapmakers. For example, line and area geometries are simplified with a tolerance matching the resolution of the tile, meaning the results should look nearly invisible to the user. This is done without regard to topology.

### Coastlines

In OpenStreetMap, coastline features model the boundary between land and ocean. They are special since they are mapped simply as connected ways tagged [`natural=coastline`](https://wiki.openstreetmap.org/wiki/Tag:natural%3Dcoastline), but they are included in the tiles as aggregate oceans.

## Layers

Heirloom tiles have just four layers: three geometry layers (`point`, `line`, and `area`) and one meta layer (`relation`). Note that these do not correspond exactly to OSM entity types, and that the same feature may appear in multiple layers. Actual inclusion depends on tagging, zoom level, etc.

### `area`

Features in the `area` layer are polygon and multipolygon geometries thare are intended to be rendered with a fill or extrusion. An outline stroke rendering may be suitable for certain features as well. Labeling is not an expected use case.

Features in the `area` layer correspond to:

* `type=multipolygon` and `type=boundary` relations
* Closed ways with certain tagging. A closed way is one where the first and last nodes are the same. An `area=yes` or `building` tag will always qualify a closed way to be in this layer, while an `area=no` tag will always disqualify. Open ways are never included in the `area` layer regardless of tags.
* Oceans aggregated from coastlines

Features in the `area` layer are filtered as so:

* Areas too small to be seen when rendered in a tile are always discarded.
* At z < 12, area geometries are aggregated together based on the keys listed in [area_key_low_zoom.txt](server/schema_data/area_key_low_zoom.txt).
* At z >= 12, each area geometry corresponds to an OSM feature. Keys are filtered to those listed in [area_key.txt](server/schema_data/area_key.txt) and those beginning with prefixes listed in [area_key_prefix.txt](server/schema_data/area_key_prefix.txt).

### `line`

Features in the `line` layer are linestring and multilinestring geometries that are intended to be rendered with a stroke and/or label.

Features in the `line` layer correspond to:

* Open ways regardless of `area` or `building` tags
* Closed ways with certain tagging. An `area=no` tag will always qualify a closed way to be in this layer, while an `area=yes` or `building` tag will always disqualify.
* Member ways of `type=route`, `type=waterway`, and `boundary=administrative` relations

Features in the `line` layer are filtered as so:

* Lines too small to be seen when rendered in a tile are generally discarded. The threshold is very high to avoid tiny gaps in roads, rivers, etc.
* At z < 12, only lines that are part of long relations are included. Line geometries are aggregated together based on relation membership as well as the keys listed in [line_key_low_zoom.txt](server/schema_data/line_key_low_zoom.txt).
* At z >= 12, each line geometry corresponds to an OSM feature. Keys are filtered to those listed in [line_key.txt](server/schema_data/line_key.txt) and those beginning with prefixes listed in [line_key_prefix.txt](server/schema_data/line_key_prefix.txt).

### `point`

Features in the `point` layer are point geometries that are intended to be rendered with an icon and/or label.

Features in the `point` layer correspond to:

* Nodes
* Closed ways that also appear in the `area` layer, represented at the [`ST_PointOnSurface`](https://postgis.net/docs/ST_PointOnSurface.html)
* `type=multipolygon` and `type=boundary` relations, represented at the node with the [`label`](https://wiki.openstreetmap.org/wiki/Role:label) role if any, otherwise at the `ST_PointOnSurface`
* `type=route` and `type=waterway` relations, represented at the location along the relation closest to the centerpoint of the relations's bounding box

Features in the `point` layer are filtered as so:

* Points representing area features are always included if the area is large enough to be visible in the tile, but not so large that it contains the tile.
* Node features, and points representing areas too small to be visible in the tile, are filtered by zoom:
  * At z < 12, only features with specific notable tags are included.
  * At z >= 12, all features are included unless there are too many in the region around the tile. Features tagged with `name` or `wikidata` tag are considered more notable than those without and are included first.
* For all points features at all zoom levels, keys are filtered to those listed in [point_key.txt](server/schema_data/point_key.txt) and those beginning with prefixes listed in [point_key_prefix.txt](server/schema_data/point_key_prefix.txt).

### `relation`

Features in the `relation` layer are point geometries that are not intended for rendering. They are meant to have their attributes aggregated and added to the corresponding features in the `point` or `line` layers on the client prior to rendering the tile.

Features in the `relation` layer correspond to:
* `type=route`, `type=waterway`, and `boundary=administrative` relations referenced by features in the `point` and `line` layers

## Cheat sheet

This table show top-level tag supportin Heirloom tiles. A checkmark (✔︎) means that if an OSM feature has a tag with the given key, that feature is eligible for inclusion in the given layer. Actual inclusion depends on geometry, zoom level, etc.

| OSM key | `point` layer | `line` layer | `area` layer | `relation` layer | Closed way implies area | Irregularities |
|---|---|---|---|---|---|---|
|`aerialway`          |✔︎|✔︎|✔︎| |No |
|`aeroway`            |✔︎|✔︎|✔︎| |No |
|`advertising`        |✔︎| |✔︎| |Yes|
|`amenity`            |✔︎| |✔︎| |Yes|
|`area:highway`       | | |✔︎| |Yes|
|`barrier`            |✔︎|✔︎|✔︎| |No |
|`boundary`           |✔︎| |✔︎|✔︎|Yes| Only `boundary=protected_area/aboriginal_lands` appear in the `area` layer. Only `boundary=administrative` appears in the `relation` layer.
|`building`           |✔︎| |✔︎| |Yes|
|`building:part`      | | |✔︎| |Yes|
|`club`               |✔︎| |✔︎| |Yes|
|`craft`              |✔︎| |✔︎| |Yes|
|`education`          |✔︎| |✔︎| |Yes|
|`emergency`          |✔︎| |✔︎| |Yes|
|`golf`               |✔︎|✔︎|✔︎| |Yes|
|`healthcare`         |✔︎| |✔︎| |Yes|
|`highway`            |✔︎|✔︎|✔︎| |No |
|`historic`           |✔︎| |✔︎| |Yes|
|`indoor`             |✔︎|✔︎|✔︎| |Yes|
|`information`        |✔︎| |✔︎| |Yes|
|`landuse`            |✔︎| |✔︎| |Yes|
|`leisure`            |✔︎| |✔︎| |Yes|
|`man_made`           |✔︎|✔︎|✔︎| |Yes|
|`military`           |✔︎| |✔︎| |Yes|
|`natural`            |✔︎|✔︎|✔︎| |Yes| `natural=coastline` features are included in the `area` layer as aggregate oceans with no other attributes.
|`office`             |✔︎| |✔︎| |Yes|
|`place`              |✔︎| | | |Yes|
|`playground`         |✔︎| |✔︎| |Yes|
|`power`              |✔︎|✔︎|✔︎| |No |
|`public_transport`   |✔︎| |✔︎| |Yes|
|`railway`            |✔︎|✔︎|✔︎| |No |
|`route`              | |✔︎| | |No |
|`shop`               |✔︎| |✔︎| |Yes|
|`telecom`            |✔︎|✔︎|✔︎| |No |
|`tourism`            |✔︎| |✔︎| |Yes|
|`type`               | | | |✔︎| – | Only `type=route/waterway` appear in the `relation` layer.
|`waterway`           |✔︎|✔︎|✔︎| |No |
