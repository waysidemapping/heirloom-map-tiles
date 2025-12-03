--
-- © 2025 Quincy Morgan
-- Licensed MIT: https://github.com/waysidemapping/heirloom-map-tiles/blob/main/LICENSE.md
--
CREATE OR REPLACE FUNCTION function_get_point_features_for_tile(z integer, x integer, y integer)
RETURNS TABLE(_id int8, _tags jsonb, _geom geometry, _area_3857 real, _osm_type text, _relation_ids int8[])
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  DECLARE
    env_geom geometry;
    wide_env_geom geometry;
    env_width real;
    min_extent real;
    min_area real;
    max_area real;
    min_rel_extent real;
    max_rel_extent real;
    z26_x_min integer;
    z26_x_max integer;
    z26_y_min integer;
    z26_y_max integer;
    wide_z26_x_min integer;
    wide_z26_x_max integer;
    wide_z26_y_min integer;
    wide_z26_y_max integer;
  BEGIN
    env_geom := ST_TileEnvelope(z, x, y);
    env_width := ST_XMax(env_geom) - ST_XMin(env_geom);
    wide_env_geom := ST_Expand(env_geom, env_width);
    min_extent := env_width / 1024.0;
    min_area := power(min_extent * 32, 2);
    max_area := power(min_extent * 4096, 2);
    min_rel_extent := min_extent * 192;
    max_rel_extent := min_extent * 192 * 16;

    z26_x_min := x * (1 << (26 - z));
    z26_x_max := ((x + 1) * (1 << (26 - z))) - 1;
    z26_y_min := y * (1 << (26 - z));
    z26_y_max := ((y + 1) * (1 << (26 - z))) - 1;

    wide_z26_x_min := (x - 1) * (1 << (26 - z));
    wide_z26_x_max := ((x + 2) * (1 << (26 - z))) - 1;
    wide_z26_y_min := (y - 1) * (1 << (26 - z));
    wide_z26_y_max := ((y + 2) * (1 << (26 - z))) - 1;

    IF z < 12 THEN
      RETURN QUERY EXECUTE FORMAT($f$
      WITH
      small_points AS (
          SELECT id, tags, geom, NULL::real AS area_3857, true AS is_node_or_explicit_area, 'n' AS osm_type
          FROM node
          WHERE z26_x BETWEEN %8$L AND %9$L
            AND z26_y BETWEEN %10$L AND %11$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, is_explicit_area AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_no_explicit_line
          WHERE label_point_z26_x BETWEEN %8$L AND %9$L
            AND label_point_z26_y BETWEEN %10$L AND %11$L
            AND area_3857 < %4$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type
          FROM area_relation
          WHERE label_point_z26_x BETWEEN %8$L AND %9$L
            AND label_point_z26_y BETWEEN %10$L AND %11$L
            AND area_3857 < %4$L
      ),
      low_zoom_small_points AS (
        SELECT * FROM small_points
        WHERE (
          tags @> 'place => continent'
          OR tags @> 'place => ocean'
          OR tags @> 'place => sea'
          OR tags @> 'place => country'
          OR tags @> 'place => state'
          OR tags @> 'place => province'
        ) OR (
          (
            tags @> 'place => city'
          )
          AND %1$L >= 4
        ) OR (
          (
            tags @> 'place => town'
          )
          AND %1$L >= 6
        ) OR (
          (
            tags @> 'place => village'
          )
          AND %1$L >= 7
        ) OR (
          (
            tags @> 'place => hamlet'
            OR tags @> 'natural => peak'
            OR tags @> 'natural => volcano'
          )
          AND %1$L >= 8
        ) OR (
          (
            tags @> 'place => locality'
            OR tags @> 'public_transport => station'
            OR tags @> 'aeroway => aerodrome'
            OR tags @> 'highway => motorway_junction'
          )
          AND %1$L >= 9
        )
      ),
      large_points AS (
          SELECT id, tags, label_point AS geom, area_3857, is_explicit_area AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_no_explicit_line
          WHERE label_point_z26_x BETWEEN %8$L AND %9$L
            AND label_point_z26_y BETWEEN %10$L AND %11$L
            AND area_3857 BETWEEN %4$L AND %5$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type
          FROM area_relation
          WHERE label_point_z26_x BETWEEN %8$L AND %9$L
            AND label_point_z26_y BETWEEN %10$L AND %11$L
            AND area_3857 BETWEEN %4$L AND %5$L
      ),
      filtered_large_points AS (
        SELECT * FROM large_points
        WHERE (
          tags ?| ARRAY['advertising', 'amenity', 'boundary', 'building', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'indoor', 'information', 'landuse', 'leisure', 'man_made', 'miltary', 'office', 'place', 'playground', 'public_transport', 'shop', 'tourism']
        ) OR (
          tags ? 'natural'
          AND NOT tags @> 'natural => coastline'
        ) OR (
          tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
          AND is_node_or_explicit_area
        )
      ),
      route_centerpoints AS (
        SELECT
          id,
          -- don't include tags since we're going to infill them on the client 
          '{}'::jsonb AS tags,
          label_point AS geom,
          NULL::real AS area_3857,
          'r' AS osm_type,
          ARRAY[id] AS relation_ids
        FROM non_area_relation
        WHERE label_point_z26_x BETWEEN %8$L AND %9$L
            AND label_point_z26_y BETWEEN %10$L AND %11$L
          AND (
            tags @> 'type => route'
            OR tags @> 'type => waterway'
          )
          AND extent > %6$L
          AND extent < %7$L
          AND %1$L >= 4
      ),
      all_points AS (
          SELECT id, tags::jsonb, geom, area_3857, osm_type, NULL::int8[] AS relation_ids FROM low_zoom_small_points
        UNION ALL
          SELECT id, tags::jsonb, geom, area_3857, osm_type, NULL::int8[] AS relation_ids FROM filtered_large_points
        UNION ALL
          SELECT id, tags::jsonb, geom, area_3857, osm_type, relation_ids FROM route_centerpoints
      )
      SELECT
        id,
        (
          SELECT jsonb_object_agg(key, value)
          FROM jsonb_each(tags)
          WHERE key IN ({{POINT_KEY_LIST}}) {{POINT_KEY_PREFIX_LIKE_STATEMENTS}}
        ) AS tags,
        geom,
        area_3857,
        osm_type,
        relation_ids
      FROM all_points
      ;
      $f$, z, env_geom, wide_env_geom, min_area, max_area, min_rel_extent, max_rel_extent, z26_x_min, z26_x_max, z26_y_min, z26_y_max);
    ELSE
      RETURN QUERY EXECUTE FORMAT($f$
      WITH
      small_points AS (
          SELECT id, tags, geom, NULL::real AS area_3857, true AS is_node_or_explicit_area, 'n' AS osm_type
          FROM node
          WHERE z26_x BETWEEN %8$L AND %9$L
            AND z26_y BETWEEN %10$L AND %11$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, is_explicit_area AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_no_explicit_line
          WHERE label_point_z26_x BETWEEN %8$L AND %9$L
            AND label_point_z26_y BETWEEN %10$L AND %11$L
            AND area_3857 < %4$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type
          FROM area_relation
          WHERE label_point_z26_x BETWEEN %8$L AND %9$L
            AND label_point_z26_y BETWEEN %10$L AND %11$L
            AND area_3857 < %4$L
      ),
      low_zoom_small_points AS (
        SELECT * FROM small_points
        WHERE
          tags @> 'place => continent'
          OR tags @> 'place => ocean'
          OR tags @> 'place => sea'
          OR tags @> 'place => country'
          OR tags @> 'place => state'
          OR tags @> 'place => province'
          OR tags @> 'place => city'
          OR tags @> 'place => town'
          OR tags @> 'place => village'
          OR tags @> 'place => hamlet'
          OR tags @> 'natural => peak'
          OR tags @> 'natural => volcano'
          OR tags @> 'place => locality'
          OR tags @> 'public_transport => station'
          OR tags @> 'aeroway => aerodrome'
          OR tags @> 'highway => motorway_junction'
      ),
      ranked_small_points AS (
        SELECT *,
          -- Assume that a feature with a name (e.g. park, business, artwork) is more important than one without
          -- (e.g. crossing, pole, gate). Features linked to Wikidata items are assumed to be notable regardless
          (tags ? 'name' OR tags ? 'wikidata') AS is_notable
        FROM small_points
        WHERE 
          tags ?| ARRAY['advertising', 'amenity', 'boundary', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'indoor', 'information', 'landuse', 'leisure', 'man_made', 'miltary', 'office', 'place', 'playground', 'public_transport', 'shop', 'tourism']
          OR (
            tags ? 'building'
            AND (tags ? 'name' OR tags ? 'wikidata' OR %1$L >= 15)
          ) OR (
            tags ? 'natural'
            AND NOT tags @> 'natural => coastline'
          ) OR (
            tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
            AND is_node_or_explicit_area
          )
      ),
      -- Count the number of point-like features in this region. We use a region larger than the tile itself
      -- in order to try and avoid sharp visual cutoffs at tile bounds. For performance, this is only an estimate
      points_in_region AS (
          SELECT count(*) AS total FROM node
          WHERE z26_x BETWEEN %12$L AND %13$L
            AND z26_y BETWEEN %14$L AND %15$L
        UNION ALL
          SELECT count(*) AS total FROM way_no_explicit_line
          WHERE label_point_z26_x BETWEEN %12$L AND %13$L
            AND label_point_z26_y BETWEEN %14$L AND %15$L
        UNION ALL
          SELECT count(*) AS total FROM area_relation
          WHERE label_point_z26_x BETWEEN %12$L AND %13$L
            AND label_point_z26_y BETWEEN %14$L AND %15$L
      ),
      point_region_stats AS (
        SELECT sum(total) AS regional_point_count FROM points_in_region
      ),
      -- Only include small points if we don't think they will make the tile too big
      reduced_small_points AS (
          SELECT id, tags, geom, area_3857, osm_type
          FROM ranked_small_points, point_region_stats
          WHERE regional_point_count < 150000
            -- Include only notable features unless we have room to spare
            AND (is_notable OR regional_point_count < 75000)
      ),
      large_points AS (
          SELECT id, tags, label_point AS geom, area_3857, is_explicit_area AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_no_explicit_line
          WHERE label_point_z26_x BETWEEN %8$L AND %9$L
            AND label_point_z26_y BETWEEN %10$L AND %11$L
            AND area_3857 BETWEEN %4$L AND %5$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type
          FROM area_relation
          WHERE label_point_z26_x BETWEEN %8$L AND %9$L
            AND label_point_z26_y BETWEEN %10$L AND %11$L
            AND area_3857 BETWEEN %4$L AND %5$L
      ),
      filtered_large_points AS (
        SELECT * FROM large_points
        WHERE (
          tags ?| ARRAY['advertising', 'amenity', 'boundary', 'building', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'indoor', 'information', 'landuse', 'leisure', 'man_made', 'miltary', 'office', 'place', 'playground', 'public_transport', 'shop', 'tourism']
        ) OR (
          tags ? 'natural'
          AND NOT tags @> 'natural => coastline'
        ) OR (
          tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
          AND is_node_or_explicit_area
        )
      ),
      route_centerpoints AS (
        SELECT
          id,
          -- don't include tags since we're going to infill them on the client 
          '{}'::jsonb AS tags,
          label_point AS geom,
          NULL::real AS area_3857,
          'r' AS osm_type,
          ARRAY[id] AS relation_ids
        FROM non_area_relation
        WHERE label_point_z26_x BETWEEN %8$L AND %9$L
          AND label_point_z26_y BETWEEN %10$L AND %11$L
          AND extent BETWEEN %6$L AND %7$L
          AND (
            tags @> 'type => route'
            OR tags @> 'type => waterway'
          )
          AND %1$L >= 4
      ),
      all_points AS (
          SELECT id, tags::jsonb, geom, area_3857, osm_type, NULL::int8[] AS relation_ids FROM low_zoom_small_points
        UNION ALL
          SELECT id, tags::jsonb, geom, area_3857, osm_type, NULL::int8[] AS relation_ids FROM reduced_small_points
        UNION ALL
          SELECT id, tags::jsonb, geom, area_3857, osm_type, NULL::int8[] AS relation_ids FROM filtered_large_points
        UNION ALL
          SELECT id, tags::jsonb, geom, area_3857, osm_type, relation_ids FROM route_centerpoints
      )
      SELECT
        id,
        (
          SELECT jsonb_object_agg(key, value)
          FROM jsonb_each(tags)
          WHERE key IN ({{POINT_KEY_LIST}}) {{POINT_KEY_PREFIX_LIKE_STATEMENTS}}
        ) AS tags,
        geom,
        area_3857,
        osm_type,
        relation_ids
      FROM all_points
      ;
      $f$, z, env_geom, wide_env_geom, min_area, max_area, min_rel_extent, max_rel_extent, z26_x_min, z26_x_max, z26_y_min, z26_y_max, wide_z26_x_min, wide_z26_x_max, wide_z26_y_min, wide_z26_y_max);
    END IF;
  END;
$$
SET plan_cache_mode = force_custom_plan;