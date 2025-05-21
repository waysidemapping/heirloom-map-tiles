# Rustic Map Tiles Schema

This schema is in active development and is not yet versioned. Users should expect that changes may occur at any time without notice.

## Layers

Rustic tiles have just three layers, one for each geometry type. Note that these do not correspond exactly to OSM entity types, and that the same feature may appear in multiple layers. Actual inclusion is dependent on tagging and zoom level.

### `area`

Features in the `area` layer correspond to multipolygon relations, boundary relations, or closed ways with certain tagging. (A closed way is one where the first and last nodes are the same.) An `area=yes` tag will always qualify a closed way to be in this layer, while an `area=no` tag will always disqualify. Open ways are never included in the `area` layer regardless of tags.

### `line`

Features in the `line` layer correspond to open ways, or closed ways with certain tagging. An `area=no` tag will always qualify a closed way to be in this layer, while an `area=yes` tag will always disqualify. The `area` tag has no effect on open ways.

### `point`

Features in the `point` layer correspond to tagged nodes, or the [`ST_PointOnSurface`](https://postgis.net/docs/ST_PointOnSurface.html) of any feature included in the `area` layer. Features that would appear in the `line` layer are not represented in the `point` layer.

## Top-level tags

OpenStreetMap has the concept of [top-level tags](https://wiki.openstreetmap.org/wiki/Top-level_tag) which define the main type of each feature. Rustic tiles include only features tagged with a supported top-level tag. Each tag has specific geometry expectations. Negative top-level tags like `building=no` or `highway=no` are ignored and do not qualify features for inclusion.

### Point, line, and area tags

The following keys are supported on any geometry type (point, line, or area features). Closed ways are assumed to be areas unless they have `area=no` or a specific tag value.

* `aeroway`
  * `aeroway=jet_bridge/parking_position/runway/taxiway` imply line geometry on closed ways.
* `golf`
  * `golf=hole` does NOT imply line geometry on closed ways because this tag is always assumed to be used on open ways. Please add `area=no` to any exceptions.
* `indoor`
  * `indoor=yes` is not supported as a top-level tag since it is assumed to be an attribute tag.
  * `indoor=wall` implies line geometry on closed ways.
* `natural`
  * `natural=coastline` features are included only in the `area` layer as aggregate oceans. They do not carry attributes.
  * `natural=bay/peninsula` features are included only in the `point` layer, not `area` or `line`.
* `power`
  * `power=cable/line/minor_line` imply line geometry on closed ways.
* `telecom`
  * `telecom=line` implies line geometry on closed ways.

For the following keys, closed ways are assumed to be lines unless they have `area=yes` or a specific tag value.

* `aerialway`
* `barrier`
* `highway`
* `railway`
* `waterway`

### Point and area only tags

The following keys are supported only on point and area features. Closed ways are assumed to be areas. Open ways, or closed ways with `area=no`, are considered lines and are not included in the tiles.

* `advertising`
* `amenity`
  * `amenity=bench/bicycle_parking` on lines is not supported. Consider mapping as a node or area.
* `club`
* `craft`
* `education`
* `emergency`
* `healthcare`
* `historic`
* `information`
  * `information` is supported with and without `tourism=information`.
* `landuse`
* `leisure`
  * `leisure=slipway` on lines is not supported. Consider mapping as a node.
  * `leisure=track` on lines is not supported. Consider using a `highway` tag or mapping as a node or area.
* `military`
  * `military=trench` on lines is not supported. Consider using a `barrier` tag.
* `office`
* `playground`
* `public_transport`
  * `public_transport=platform` on lines is not supported. Consider using a `highway` tag and/or mapping as an area.
* `shop`
* `tourism`
  * `tourism=artwork` on lines is not supported. Consider mapping as a node or area.

For the following key, features are included only in the `point` layer, not the `area` layer.

* `place`

### Area only tags

The following keys are supported only on area features. Closed ways are assumed to be areas. Open ways, or closed ways with `area=no`, are considered lines and are not included in the tiles.

* `area:highway`
* `building`
  * Buildings are often double-tagged with a POI top-level tag, like `shop` or `amenity`. In this case, the tiles will still include the POI in the `points` layer.
* `building:part`

### Line only tags

The following key is supported only on line features. Closed ways are assumed to be lines unless they have `area=yes`, in which case they are considered areas and are not included in tiles.

* `route`

### Reserved tags

The following keys are collected as top-level tags in the database but are not included in the tiles at this time.

* `boundary`

### Unsupported tags

The following keys are often considered top-level tags in OSM but are not supported as such in the tiles at this time.

* `allotments`
* `attraction`
* `bridge:support`
* `cemetery`
* `entrance`
* `ford`
* `junction`
* `landcover`
* `noexit`
* `piste:type`
* `roller_coaster`
* `traffic_calming`
* `traffic_sign`
