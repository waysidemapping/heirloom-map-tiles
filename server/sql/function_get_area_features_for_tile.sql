--
-- © 2025 Quincy Morgan
-- Licensed MIT: https://github.com/waysidemapping/beefsteak-map-tiles/blob/main/LICENSE.md
--
CREATE OR REPLACE FUNCTION function_get_area_features_for_tile(z integer, x integer, y integer)
RETURNS TABLE(_id int8, _tags jsonb, _geom geometry, _area_3857 real, _osm_type text)
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  DECLARE
    env_geom geometry;
    env_width real;
    min_extent real;
    min_area real;
    simplify_tolerance real;
  BEGIN
    env_geom := ST_TileEnvelope(z, x, y);
    env_width := ST_XMax(env_geom) - ST_XMin(env_geom);
    min_extent := env_width / 1024.0;
    min_area := power(min_extent * 4, 2);
    simplify_tolerance := min_extent * 0.75;
  IF z < 12 THEN
    RETURN QUERY EXECUTE FORMAT($f$
    WITH
    closed_ways AS (
      SELECT id, tags, geom, area_3857, 'w' AS osm_type, is_explicit_area FROM way_no_explicit_line
      WHERE geom && %2$L
        AND area_3857 > %3$L
    ),
    relation_areas AS (
      SELECT id, tags, geom, area_3857, 'r' AS osm_type, true AS is_explicit_area FROM area_relation
      WHERE geom && %2$L
        AND area_3857 > %3$L
    ),
    areas AS (
        SELECT * FROM closed_ways
      UNION ALL
        SELECT * FROM relation_areas
    ),
    filtered_areas AS (
        SELECT * FROM areas
        WHERE tags ?| ARRAY['advertising', 'amenity', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'information', 'landuse', 'leisure', 'man_made', 'military', 'office', 'public_transport', 'shop', 'tourism']
      UNION ALL
        SELECT * FROM areas
        WHERE tags ? 'natural'
          -- coastline areas are handled separately
          AND NOT tags @> 'natural => coastline'
      UNION ALL
        SELECT * FROM areas
        -- only certain boundaries are relevant for rendering as areas
        WHERE tags @> 'boundary => protected_area'
          OR tags @> 'boundary => aboriginal_lands'
      UNION ALL
        SELECT * FROM areas
        WHERE tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
          AND is_explicit_area
    ),
    -- dedupe before simplifying/tag processing to reduce cost
    deduped_areas AS (
      SELECT DISTINCT ON (id, osm_type) * FROM filtered_areas
    ),
    -- filter tags to a small number of relevant keys
    tagged_areas AS (
      SELECT
        slice(tags, ARRAY[{{LOW_ZOOM_AREA_KEY_LIST}}])::jsonb AS tags,
        geom
      FROM deduped_areas
    )
    -- aggregate features with the same tags and simplify
    SELECT
      NULL::int8 AS id,
      tags,
      ST_Simplify(ST_Multi(ST_Collect(geom)), %4$L, true) AS geom,
      NULL::real AS area_3857,
      NULL::text AS osm_type
    FROM tagged_areas
    GROUP BY tags
    ;
    $f$, z, env_geom, min_area, simplify_tolerance);
  ELSE
    RETURN QUERY EXECUTE FORMAT($f$
    WITH
    closed_ways AS (
      SELECT id, tags, geom, area_3857, 'w' AS osm_type, is_explicit_area FROM way_no_explicit_line
      WHERE geom && %2$L
        AND area_3857 > %3$L
    ),
    relation_areas AS (
      SELECT id, tags, geom, area_3857, 'r' AS osm_type, true AS is_explicit_area FROM area_relation
      WHERE geom && %2$L
        AND area_3857 > %3$L
    ),
    areas AS (
        SELECT * FROM closed_ways
      UNION ALL
        SELECT * FROM relation_areas
    ),
    filtered_areas AS (
        SELECT * FROM areas
        WHERE tags ?| ARRAY['advertising', 'amenity', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'information', 'landuse', 'leisure', 'man_made', 'military', 'office', 'public_transport', 'shop', 'tourism']
      UNION ALL
        SELECT * FROM areas
        WHERE tags ? 'natural'
          -- coastline areas are handled separately
          AND NOT tags @> 'natural => coastline'
      UNION ALL
        SELECT * FROM areas
        -- only certain boundaries are relevant for rendering as areas
        WHERE tags @> 'boundary => protected_area'
          OR tags @> 'boundary => aboriginal_lands'
      UNION ALL
        SELECT * FROM areas
        WHERE tags ? 'building'
          AND %1$L >= 14
      UNION ALL
        SELECT * FROM areas
        WHERE tags ?| ARRAY['area:highway', 'building:part', 'indoor', 'playground']
          AND %1$L >= 18
      UNION ALL
        SELECT * FROM areas
        WHERE tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
          AND is_explicit_area  
    ),
    -- dedupe before simplifying/tag processing to reduce cost
    deduped_areas AS (
      SELECT DISTINCT ON (id, osm_type) * FROM filtered_areas
    )
    SELECT
      id,
      (
        SELECT jsonb_object_agg(key, value)
        FROM each(tags)
        WHERE key IN ({{AREA_KEY_LIST}}) {{AREA_KEY_PREFIX_LIKE_STATEMENTS}}
      ) AS tags,
      ST_Simplify(geom, %4$L, true) AS geom,
      area_3857,
      osm_type
    FROM deduped_areas
  ;
  $f$, z, env_geom, min_area, simplify_tolerance);
  END IF;
END;
$$
SET plan_cache_mode = force_custom_plan;