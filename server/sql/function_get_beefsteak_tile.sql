--
-- © 2025 Quincy Morgan
-- Licensed MIT: https://github.com/waysidemapping/beefsteak-map-tiles/blob/main/LICENSE.md
--
CREATE OR REPLACE FUNCTION function_get_beefsteak_tile(z integer, x integer, y integer)
RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $function_body$
    WITH
    area_features_without_ocean AS (
      SELECT
        _id AS id,
        _tags AS tags,
        _geom AS geom,
        _area_3857 AS area_3857,
        _osm_type AS osm_type
      FROM function_get_area_features_for_tile(z, x, y)
    ),
    area_features AS (
        SELECT id, tags, geom, area_3857, osm_type
        FROM area_features_without_ocean
      UNION ALL
        SELECT
          NULL::int8 AS id,
          '{"natural": "coastline"}'::jsonb AS tags,
          _geom AS geom,
          NULL::real AS area_3857,
          NULL::text AS osm_type
          FROM function_get_ocean_for_tile(z, x, y)
    ),
    mvt_area_features AS (
      SELECT
        id * 10 + (CASE WHEN osm_type = 'w' THEN 2 WHEN osm_type = 'r' THEN 3 ELSE 0 END) AS feature_id,
        tags,
        -- area_3857,
        ST_AsMVTGeom(geom, ST_TileEnvelope(z, x, y), 4096, 64, true) AS geom
      FROM area_features
    ),
    line_features AS (
      SELECT
        _id AS id,
        _tags AS tags,
        _geom AS geom,
        _relation_ids AS relation_ids
      FROM function_get_line_features_for_tile(z, x, y)
    ),
    mvt_line_features AS (
      SELECT
        id * 10 + 2 AS feature_id,
        tags,
        ST_AsMVTGeom(geom, ST_TileEnvelope(z, x, y), 4096, 64, true) AS geom
      FROM line_features
    ),
    point_features AS (
      SELECT
        _id AS id,
        _tags AS tags,
        _geom AS geom,
        _area_3857 AS area_3857,
        _osm_type AS osm_type,
        _relation_ids AS relation_ids
      FROM function_get_point_features_for_tile(z, x, y)
    ),
    mvt_point_features AS (
      SELECT
        id * 10 + (CASE WHEN osm_type = 'n' THEN 1 WHEN osm_type = 'w' THEN 2 WHEN osm_type = 'r' THEN 3 ELSE 0 END) AS feature_id,
        tags,
        -- area_3857,
        ST_AsMVTGeom(geom, ST_TileEnvelope(z, x, y), 4096, 64, true) AS geom
      FROM point_features
    ),
    all_relation_ids AS (
        SELECT unnest(relation_ids) AS relation_id
        FROM line_features
        WHERE relation_ids IS NOT NULL
      UNION ALL
        SELECT unnest(relation_ids) AS relation_id
        FROM point_features
        WHERE relation_ids IS NOT NULL
    ),
    unique_relation_ids AS (
      SELECT DISTINCT relation_id
      FROM all_relation_ids
    ),
    relation_features AS (
      SELECT r.id, r.tags
      FROM planet_osm_rels r
      JOIN unique_relation_ids linked ON r.id = linked.relation_id
    ),
    tagged_relation_features AS (
      SELECT
        id,
        (
          SELECT jsonb_object_agg(key, value)
          FROM jsonb_each(tags)
          WHERE key IN ({{RELATION_KEY_LIST}}) {{RELATION_KEY_PREFIX_LIKE_STATEMENTS}}
        ) AS tags
      FROM relation_features
    ),
    mvt_relation_features AS (
      SELECT
        id * 10 + 3 AS feature_id,
        tags,
        -- we need to pass in a a non-null geometry for relations so just use the tile centerpoint
        ST_Centroid(ST_TileEnvelope(z, x, y)) AS geom
      FROM tagged_relation_features
    ),
    tiles AS (
        SELECT ST_AsMVT(mvt_relation_features, 'relation', 4096, 'geom', 'feature_id') AS mvt FROM mvt_relation_features
      UNION ALL
        SELECT ST_AsMVT(mvt_area_features, 'area', 4096, 'geom', 'feature_id') AS mvt FROM mvt_area_features
      UNION ALL
        SELECT ST_AsMVT(mvt_line_features, 'line', 4096, 'geom', 'feature_id') AS mvt FROM mvt_line_features
      UNION ALL
        SELECT ST_AsMVT(mvt_point_features, 'point', 4096, 'geom', 'feature_id') AS mvt FROM mvt_point_features
    )
    SELECT string_agg(mvt, ''::bytea) FROM tiles;
$function_body$
SET plan_cache_mode = force_custom_plan;

COMMENT ON FUNCTION function_get_beefsteak_tile IS
$tilejson$
{
  "description": "Server-farm-to-table OpenStreetMap tiles",
  "attribution": "OpenStreetMap"
}
$tilejson$;
