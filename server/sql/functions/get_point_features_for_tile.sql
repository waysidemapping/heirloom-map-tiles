--
-- © 2025 Quincy Morgan
-- Licensed MIT: https://github.com/waysidemapping/beefsteak-map-tiles/blob/main/LICENSE
--
CREATE OR REPLACE FUNCTION function_get_point_features_for_tile(z integer, x integer, y integer)
RETURNS TABLE(_id int8, _tags jsonb, _geom geometry, _area_3857 real, _osm_type text, _relation_ids int8[])
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  DECLARE
    env_geom geometry;
    env_width real;
    min_extent real;
    min_area real;
    max_area real;
    z26_x_min integer;
    z26_x_max integer;
    z26_y_min integer;
    z26_y_max integer;
  BEGIN
    env_geom := ST_TileEnvelope(z, x, y);
    env_width := ST_XMax(env_geom) - ST_XMin(env_geom);
    min_extent := env_width / 1024.0;
    min_area := power(min_extent * 32, 2);
    max_area := power(min_extent * 4096, 2);

    z26_x_min := x * (1 << (26 - z));
    z26_x_max := ((x + 1) * (1 << (26 - z))) - 1;
    z26_y_min := y * (1 << (26 - z));
    z26_y_max := ((y + 1) * (1 << (26 - z))) - 1;
    
    IF z < 12 THEN
      RETURN QUERY EXECUTE FORMAT($f$
      WITH
      small_points AS (
          SELECT id, tags, geom, NULL::real AS area_3857, true AS is_node_or_explicit_area, 'n' AS osm_type
          FROM node
          WHERE z26_x BETWEEN %5$L AND %6$L
            AND z26_y BETWEEN %7$L AND %8$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_explicit_area
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 < %3$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, false AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_no_explicit_geometry_type
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 < %3$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type
          FROM area_relation
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 < %3$L
      ),
      low_zoom_small_points AS (
        SELECT * FROM small_points
        WHERE (
          tags @> 'place => continent'
          OR tags @> 'place => ocean'
          OR tags @> 'place => sea'
          OR tags @> 'place => country'
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
          )
          AND %1$L >= 9
        ) OR (
          (
            tags @> 'aeroway => aerodrome'
            OR tags @> 'highway => motorway_junction'
          )
          AND %1$L >= 9
          AND is_node_or_explicit_area
        )
      ),
      large_points AS (
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_explicit_area
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 BETWEEN %3$L AND %4$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, false AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_no_explicit_geometry_type
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 BETWEEN %3$L AND %4$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type
          FROM area_relation
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 BETWEEN %3$L AND %4$L
      ),
      filtered_large_points AS (
          SELECT * FROM large_points
          WHERE tags ?| ARRAY['advertising', 'amenity', 'building', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'indoor', 'information', 'landuse', 'leisure', 'man_made', 'miltary', 'office', 'place', 'playground', 'public_transport', 'shop', 'tourism']
        UNION ALL
          SELECT * FROM large_points
          WHERE tags @> 'boundary => aboriginal_lands'
            OR tags @> 'boundary => administrative'
            OR tags @> 'boundary => protected_area'
        UNION ALL
          SELECT * FROM large_points
          WHERE tags ? 'natural'
            AND NOT tags @> 'natural => coastline'
        UNION ALL
          SELECT * FROM large_points
          WHERE tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
            AND is_node_or_explicit_area
      ),
      all_points AS (
          SELECT id, tags::jsonb, geom, area_3857, osm_type, NULL::int8[] AS relation_ids FROM low_zoom_small_points
        UNION ALL
          SELECT id, tags::jsonb, geom, area_3857, osm_type, NULL::int8[] AS relation_ids FROM filtered_large_points
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
      $f$, z, env_geom, min_area, max_area, z26_x_min, z26_x_max, z26_y_min, z26_y_max);
    ELSE
      RETURN QUERY EXECUTE FORMAT($f$
      WITH
      small_points AS (
          SELECT id, tags, geom, NULL::real AS area_3857, true AS is_node_or_explicit_area, 'n' AS osm_type
          FROM node
          WHERE z26_x BETWEEN %5$L AND %6$L
            AND z26_y BETWEEN %7$L AND %8$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_explicit_area
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 < %3$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, false AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_no_explicit_geometry_type
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 < %3$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type
          FROM area_relation
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 < %3$L
      ),
      filtered_small_points AS (
          SELECT * FROM small_points
          WHERE tags ?| ARRAY['advertising', 'amenity', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'indoor', 'information', 'landuse', 'leisure', 'man_made', 'miltary', 'office', 'place', 'playground', 'public_transport', 'shop', 'tourism']
        UNION ALL
          SELECT * FROM small_points
          WHERE tags @> 'boundary => aboriginal_lands'
            OR tags @> 'boundary => administrative'
            OR tags @> 'boundary => protected_area'
        UNION ALL
          SELECT * FROM small_points
          WHERE tags ? 'building'
            AND (tags ? 'name' OR tags ? 'wikidata' OR %1$L >= 15)
        UNION ALL
          SELECT * FROM small_points
          WHERE tags ? 'natural'
            AND NOT tags @> 'natural => coastline'
        UNION ALL
          SELECT * FROM small_points
          WHERE tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
            AND is_node_or_explicit_area
      ),
      low_zoom_small_points AS (
        SELECT * FROM small_points
        WHERE
          tags @> 'place => continent'
          OR tags @> 'place => ocean'
          OR tags @> 'place => sea'
          OR tags @> 'place => country'
          OR tags @> 'place => city'
          OR tags @> 'place => town'
          OR tags @> 'place => village'
          OR tags @> 'place => hamlet'
          OR tags @> 'natural => peak'
          OR tags @> 'natural => volcano'
          OR tags @> 'place => locality'
          OR tags @> 'public_transport => station'
          OR (
            (
              tags @> 'aeroway => aerodrome'
              OR tags @> 'highway => motorway_junction'
            )
            AND is_node_or_explicit_area
          )
      ),
      point_region_stats AS (
        SELECT count(*) AS filtered_small_point_count FROM filtered_small_points
      ),
      -- Only include small points if we don't think they will make the tile too big
      reduced_small_points AS (
        SELECT id, tags, geom, area_3857, osm_type
        FROM filtered_small_points, point_region_stats
        WHERE filtered_small_point_count < 20000
          -- Include only notable features unless we have room to spare.
          -- Assume that a feature with a name (e.g. park, business, artwork) is more important than one without
          -- (e.g. crossing, pole, gate). Features linked to Wikidata items are assumed to be notable regardless.
          AND (filtered_small_point_count < 5000 OR tags ? 'name' OR tags ? 'wikidata' OR %1$L >= 18)
      ),
      large_points AS (
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_explicit_area
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 BETWEEN %3$L AND %4$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, false AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_no_explicit_geometry_type
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 BETWEEN %3$L AND %4$L
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type
          FROM area_relation
          WHERE label_point_z26_x BETWEEN %5$L AND %6$L
            AND label_point_z26_y BETWEEN %7$L AND %8$L
            AND area_3857 BETWEEN %3$L AND %4$L
      ),
      filtered_large_points AS (
          SELECT * FROM large_points
          WHERE tags ?| ARRAY['advertising', 'amenity', 'building', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'indoor', 'information', 'landuse', 'leisure', 'man_made', 'miltary', 'office', 'place', 'playground', 'public_transport', 'shop', 'tourism']
        UNION ALL
          SELECT * FROM large_points
          WHERE tags @> 'boundary => aboriginal_lands'
            OR tags @> 'boundary => administrative'
            OR tags @> 'boundary => protected_area'
        UNION ALL
          SELECT * FROM large_points
          WHERE tags ? 'natural'
            AND NOT tags @> 'natural => coastline'
        UNION ALL
          SELECT * FROM large_points
          WHERE tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
            AND is_node_or_explicit_area
      ),
      all_points AS (
          SELECT id, tags::jsonb, geom, area_3857, osm_type, NULL::int8[] AS relation_ids FROM low_zoom_small_points
        UNION ALL
          SELECT id, tags::jsonb, geom, area_3857, osm_type, NULL::int8[] AS relation_ids FROM reduced_small_points
        UNION ALL
          SELECT id, tags::jsonb, geom, area_3857, osm_type, NULL::int8[] AS relation_ids FROM filtered_large_points
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
      $f$, z, env_geom, min_area, max_area, z26_x_min, z26_x_max, z26_y_min, z26_y_max);
    END IF;
  END;
$$
;