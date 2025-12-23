--
-- © 2025 Quincy Morgan
-- Licensed MIT: https://github.com/waysidemapping/beefsteak-map-tiles/blob/main/LICENSE
--
CREATE OR REPLACE FUNCTION function_get_line_features_for_tile(z integer, x integer, y integer)
RETURNS TABLE(_id int8, _tags jsonb, _geom geometry, _relation_ids int8[])
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  DECLARE
    env_geom geometry;
    env_width real;
    min_way_extent real;
    min_rel_extent real;
    min_area real;
    simplify_tolerance real;
  BEGIN
    env_geom := ST_TileEnvelope(z, x, y);
    env_width := ST_XMax(env_geom) - ST_XMin(env_geom);
    min_way_extent := env_width / 1024.0;
    min_rel_extent := min_way_extent * 192;
    min_area := power(min_way_extent * 4, 2);
    simplify_tolerance := min_way_extent * 0.75;
    IF z <= 2 THEN
      RETURN;
    ELSIF z < 12 THEN
      RETURN QUERY EXECUTE FORMAT($f$
      WITH
      tagged_lines_in_tile AS (
          SELECT id, tags, geom
          FROM way_explicit_line
          WHERE geom && %2$L
            AND tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'man_made', 'natural', 'power', 'railway', 'route', 'telecom', 'waterway']
        UNION ALL
          SELECT id, tags, geom
          FROM way_no_explicit_geometry_type
          WHERE geom && %2$L
            AND tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'man_made', 'natural', 'power', 'railway', 'route', 'telecom', 'waterway']
      ),
      routes AS (
        SELECT id
        FROM non_area_relation
        WHERE geom && %2$L
          AND tags @> 'type => route'
          AND extent >= %4$L
      ),
      route_members AS (
        SELECT
          w.id AS id,
          w.tags AS tags,
          w.geom AS geom,
          rw.member_role AS member_role,
          r.id AS relation_id
        FROM tagged_lines_in_tile w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN routes r ON rw.relation_id = r.id
      ),
      way_explicit_line_in_tile AS (
          SELECT id, tags, geom
          FROM way_explicit_line
          WHERE geom && %2$L
            AND tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'man_made', 'natural', 'power', 'railway', 'route', 'telecom', 'waterway']
      ),
      waterways AS (
        SELECT id
        FROM non_area_relation
        WHERE geom && %2$L
          AND tags @> 'type => waterway'
          AND extent >= %4$L
      ),
      waterway_members AS (
        SELECT
          w.id AS id,
          w.tags AS tags,
          w.geom AS geom,
          rw.member_role AS member_role,
          r.id AS relation_id
        -- pretty safe to assume that all waterway relation segments are open ways
        FROM way_explicit_line_in_tile w
        JOIN way_relation_member rw ON w.id = rw.member_id AND rw.member_role = 'main_stream'
        JOIN waterways r ON rw.relation_id = r.id
      ),
      way AS (
          SELECT id, ''::hstore AS tags, geom
          FROM untagged_way
          WHERE geom && %2$L
        UNION ALL
          SELECT id, tags, geom
          FROM way_explicit_area
          WHERE geom && %2$L
        UNION ALL
          SELECT id, tags, geom
          FROM way_explicit_line
          WHERE geom && %2$L
        UNION ALL
          SELECT id, tags, geom
          FROM way_no_explicit_geometry_type
          WHERE geom && %2$L
      ),
      boundaries AS (
        SELECT
          id
        FROM area_relation
        WHERE geom && %2$L
          AND tags @> 'boundary => administrative'
          AND (
            tags @> 'admin_level => 2'
            OR tags @> 'admin_level => 3'
            OR tags @> 'admin_level => 4'
            OR tags @> 'admin_level => 5'
            OR (
              %1$L >= 6 AND tags @> 'admin_level => 6'
            )
          )
      ),
      boundary_members AS (
        SELECT
          w.id AS id,
          w.tags AS tags,
          w.geom AS geom,
          rw.member_role AS member_role,
          r.id AS relation_id
        FROM way w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN boundaries r ON rw.relation_id = r.id
      ),
      combined_lines AS (
          SELECT *
          FROM route_members
        UNION ALL
          SELECT *
          FROM waterway_members
        UNION ALL
          SELECT *
          FROM boundary_members
      ),
      collapsed AS (
        SELECT
          ANY_VALUE(tags) AS tags,
          COALESCE(jsonb_object_agg('m.' || relation_id::text, member_role) FILTER (WHERE relation_id IS NOT NULL), '{}'::jsonb) AS membership_attributes,
          ANY_VALUE(geom) AS geom,
          ARRAY_AGG(relation_id) AS relation_ids
        FROM combined_lines
        GROUP BY id
      ),
      tagged AS (
        SELECT
          slice(tags, ARRAY[{{LOW_ZOOM_LINE_KEY_LIST}}])::jsonb || membership_attributes AS tags,
          geom,
          relation_ids
        FROM collapsed
      ),
      grouped_and_simplified AS (
        SELECT
          tags,
          ST_Simplify(ST_LineMerge(ST_Multi(ST_Collect(geom))), %6$L, true) AS geom,
          ANY_VALUE(relation_ids) AS relation_ids
        FROM tagged
        GROUP BY tags
      )
      SELECT
        NULL::int8 AS id,
        tags,
        geom,
        relation_ids
      FROM grouped_and_simplified
      ;
      $f$, z, env_geom, min_way_extent, min_rel_extent,  min_area, simplify_tolerance);
    ELSE
      RETURN QUERY EXECUTE FORMAT($f$
      WITH
      lines_in_tile AS (
          SELECT id, tags, geom, true AS is_explicit_line
          FROM way_explicit_line
          WHERE geom && %2$L
            AND extent >= %3$L
        UNION ALL
          SELECT id, tags, geom, false AS is_explicit_line
          FROM way_no_explicit_geometry_type
          WHERE geom && %2$L
            AND extent >= %3$L
      ),
      filtered_lines AS (
        SELECT id, tags, geom
        FROM lines_in_tile
        WHERE (
          tags @> 'highway => motorway'
          OR tags @> 'highway => motorway_link'
          OR tags @> 'highway => trunk'
          OR tags @> 'highway => trunk_link'
          OR tags @> 'highway => primary'
          OR tags @> 'highway => primary_link'
          OR tags @> 'highway => secondary'
          OR tags @> 'highway => secondary_link'
          OR tags @> 'highway => tertiary'
          OR tags @> 'highway => tertiary_link'
          OR tags @> 'highway => residential'
          OR tags @> 'highway => unclassified'
          OR tags @> 'highway => pedestrian'
        ) OR (
          tags ? 'highway'
          AND NOT (tags @> 'highway => footway' AND tags ? 'footway')
          AND %1$L >= 13
        ) OR (
          tags ? 'highway'
          AND %1$L >= 15
        ) OR (
          tags ?| ARRAY['waterway']
        ) OR (
          tags @> 'route => ferry'
        ) OR (
          tags ? 'railway'
          AND NOT tags ? 'service'
        ) OR (
          tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'power', 'railway', 'route', 'telecom']
          AND %1$L >= 13
        ) OR (
          tags ?| ARRAY['man_made', 'natural']
          AND is_explicit_line
          AND %1$L >= 13
        ) OR (
          tags @> 'natural => coastline'
          AND %1$L >= 13
        ) OR (
          tags ?| ARRAY['golf']
          AND is_explicit_line
          AND %1$L >= 15
        ) OR (
          tags ?| ARRAY['indoor']
          AND is_explicit_line
          AND %1$L >= 18
        )
      ),
      tagged_lines_in_tile AS (
          SELECT id, tags, geom
          FROM lines_in_tile
          WHERE tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'man_made', 'natural', 'power', 'railway', 'route', 'telecom', 'waterway']
      ),
      routes AS (
        SELECT id
        FROM non_area_relation
        WHERE geom && %2$L
          AND tags @> 'type => route'
          AND extent >= %4$L
      ),
      route_members AS (
        SELECT
          w.id AS id,
          w.tags AS tags,
          w.geom AS geom,
          rw.member_role AS member_role,
          r.id AS relation_id
        FROM tagged_lines_in_tile w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN routes r ON rw.relation_id = r.id
      ),
      way_explicit_line_in_tile AS (
          SELECT id, tags, geom
          FROM way_explicit_line
          WHERE geom && %2$L
            AND extent >= %3$L
            AND tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'man_made', 'natural', 'power', 'railway', 'route', 'telecom', 'waterway']
      ),
      waterways AS (
        SELECT id
        FROM non_area_relation
        WHERE geom && %2$L
          AND tags @> 'type => waterway'
          AND extent >= %4$L
      ),
      waterway_members AS (
        SELECT
          w.id AS id,
          w.tags AS tags,
          w.geom AS geom,
          rw.member_role AS member_role,
          r.id AS relation_id
        -- pretty safe to assume that all waterway relation segments are open ways
        FROM way_explicit_line_in_tile w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN waterways r ON rw.relation_id = r.id
      ),
      all_ways_in_tile AS (
          SELECT id, ''::hstore AS tags, geom
          FROM untagged_way
          WHERE geom && %2$L
        UNION ALL
          SELECT id, tags, geom
          FROM way_explicit_area
          WHERE geom && %2$L
            AND extent >= %3$L
        UNION ALL
          SELECT id, tags, geom
          FROM way_explicit_line
          WHERE geom && %2$L
            AND extent >= %3$L
        UNION ALL
          SELECT id, tags, geom
          FROM way_no_explicit_geometry_type
          WHERE geom && %2$L
            AND extent >= %3$L
      ),
      boundaries AS (
        SELECT
          id
        FROM area_relation
        WHERE geom && %2$L
          AND (
            tags @> 'boundary => aboriginal_lands'
            OR tags @> 'boundary => administrative'
            OR tags @> 'boundary => protected_area'
          )
          AND area_3857 > %6$L
      ),
      boundary_members AS (
        SELECT
          w.id AS id,
          w.tags AS tags,
          w.geom AS geom,
          rw.member_role AS member_role,
          r.id AS relation_id
        FROM all_ways_in_tile w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN boundaries r ON rw.relation_id = r.id
      ),
      combined_lines AS (
          SELECT id, tags, geom, NULL::text AS member_role, NULL::int8 AS relation_id
          FROM filtered_lines
        UNION ALL
          SELECT *
          FROM route_members
        UNION ALL
          SELECT *
          FROM waterway_members
        UNION ALL
          SELECT *
          FROM boundary_members
      ),
      collapsed AS (
        SELECT id,
          ANY_VALUE(tags)::jsonb
            || COALESCE(jsonb_object_agg('m.' || relation_id::text, member_role) FILTER (WHERE relation_id IS NOT NULL), '{}'::jsonb) AS tags,
          ANY_VALUE(geom) AS geom,
          ARRAY_AGG(relation_id) AS relation_ids
        FROM combined_lines
        GROUP BY id
      ),
      simplified_lines AS (
        SELECT id, tags, ST_Simplify(geom, %6$L, true) AS geom, relation_ids
        FROM collapsed
      )
      SELECT
        id,
        (
          SELECT jsonb_object_agg(key, value)
          FROM jsonb_each(tags)
          WHERE key IN ({{LINE_KEY_LIST}}) {{LINE_KEY_PREFIX_LIKE_STATEMENTS}} OR key LIKE 'm.%%'
        ) AS tags,
        geom,
        relation_ids
      FROM simplified_lines
      ;
      $f$, z, env_geom, min_way_extent, min_rel_extent, min_area, simplify_tolerance);
    END IF;
  END;
$$
;