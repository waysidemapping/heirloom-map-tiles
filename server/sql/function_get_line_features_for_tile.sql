--
-- © 2025 Quincy Morgan
-- Licensed MIT: https://github.com/waysidemapping/heirloom-map-tiles/blob/main/LICENSE.md
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
    simplify_tolerance real;
  BEGIN
    env_geom := ST_TileEnvelope(z, x, y);
    env_width := ST_XMax(env_geom) - ST_XMin(env_geom);
    min_way_extent := env_width / 1024.0;
    min_rel_extent := min_way_extent * 192;
    simplify_tolerance := min_way_extent * 0.75;
    IF z < 12 THEN
      RETURN QUERY EXECUTE FORMAT($f$
      WITH
      routes AS (
        SELECT
          w.id,
          w.tags,
          w.geom,
          rw.member_role,
          rw.relation_id
        FROM way_no_explicit_area w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN non_area_relation r ON rw.relation_id = r.id
        WHERE w.geom && %2$L
          AND r.geom && %2$L
          AND w.tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'man_made', 'natural', 'power', 'railway', 'route', 'telecom', 'waterway']
          AND r.extent >= %4$L
          AND r.tags @> '{"type": "route"}'
          AND r.tags ? 'route'
      ),
      waterways AS (
        SELECT
          w.id,
          w.tags,
          w.geom,
          rw.member_role,
          rw.relation_id
        FROM way_no_explicit_area w
        JOIN way_relation_member rw ON w.id = rw.member_id AND rw.member_role = 'main_stream'
        JOIN non_area_relation r ON rw.relation_id = r.id
        WHERE w.geom && %2$L
          AND r.geom && %2$L
          AND w.tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'man_made', 'natural', 'power', 'railway', 'route', 'telecom', 'waterway']
          AND r.tags @> '{"type": "waterway"}'
          AND r.extent >= %4$L
      ),
      admin_boundaries AS (
        SELECT w.id,
          w.tags,
          w.geom,
          rw.member_role,
          rw.relation_id
        FROM way w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN area_relation r ON rw.relation_id = r.id
        WHERE w.geom && %2$L
          AND r.geom && %2$L
          AND r.tags @> '{"boundary": "administrative"}'
          AND (
            r.tags @> '{"admin_level": "1"}'
            OR r.tags @> '{"admin_level": "2"}'
            OR r.tags @> '{"admin_level": "3"}'
            OR r.tags @> '{"admin_level": "4"}'
            OR r.tags @> '{"admin_level": "5"}'
            OR (
              %1$L >= 6 AND r.tags @> '{"admin_level": "6"}'
            )
          )
      ),
      combined_lines AS (
          SELECT *
          FROM routes
        UNION ALL
          SELECT *
          FROM waterways
        UNION ALL
          SELECT *
          FROM admin_boundaries
      ),
      collapsed AS (
        SELECT
          COALESCE((
            SELECT jsonb_object_agg(key, value)
            FROM jsonb_each(ANY_VALUE(tags))
            WHERE key IN ({{LOW_ZOOM_LINE_KEY_LIST}})
          ), '{}'::jsonb)
            || COALESCE(jsonb_object_agg('m.' || relation_id::text, member_role) FILTER (WHERE relation_id IS NOT NULL), '{}'::jsonb) AS tags,
          ANY_VALUE(geom) AS geom,
          ARRAY_AGG(relation_id) AS relation_ids
        FROM combined_lines
        GROUP BY id
      ),
      grouped_and_simplified AS (
        SELECT
          tags,
          ST_Simplify(ST_LineMerge(ST_Multi(ST_Collect(geom))), %5$L, true) AS geom,
          ANY_VALUE(relation_ids) AS relation_ids
        FROM collapsed
        GROUP BY tags
      )
      SELECT
        NULL::int8 AS id,
        tags,
        geom,
        relation_ids
      FROM grouped_and_simplified
      ;
      $f$, z, env_geom, min_way_extent, min_rel_extent, simplify_tolerance);
    ELSE
      RETURN QUERY EXECUTE FORMAT($f$
      WITH
      ways_in_tile AS (
        SELECT id, tags, geom, is_explicit_line
        FROM way_no_explicit_area
        WHERE geom && %2$L
          AND extent >= %3$L
      ),
      filtered_lines AS (
        SELECT id, tags, geom
        FROM ways_in_tile
        WHERE (
          tags @> '{"highway": "motorway"}'
          OR tags @> '{"highway": "motorway_link"}'
          OR tags @> '{"highway": "trunk"}'
          OR tags @> '{"highway": "trunk_link"}'
          OR tags @> '{"highway": "primary"}'
          OR tags @> '{"highway": "primary_link"}'
          OR tags @> '{"highway": "secondary"}'
          OR tags @> '{"highway": "secondary_link"}'
          OR tags @> '{"highway": "tertiary"}'
          OR tags @> '{"highway": "tertiary_link"}'
          OR tags @> '{"highway": "residential"}'
          OR tags @> '{"highway": "unclassified"}'
          OR tags @> '{"highway": "pedestrian"}'
        ) OR (
          tags ? 'highway'
          AND NOT (tags @> '{"highway": "footway"}' AND tags ? 'footway')
          AND %1$L >= 13
        ) OR (
          tags ? 'highway'
          AND %1$L >= 15
        ) OR (
          tags ?| ARRAY['waterway']
        ) OR (
          tags @> '{"route": "ferry"}'
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
          tags @> '{"natural": "coastline"}'
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
      routes AS (
        SELECT
          w.id,
          w.tags,
          w.geom,
          rw.member_role,
          rw.relation_id
        FROM way_no_explicit_area w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN non_area_relation r ON rw.relation_id = r.id
        WHERE w.geom && %2$L
          AND r.geom && %2$L
          AND w.tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'man_made', 'natural', 'power', 'railway', 'route', 'telecom', 'waterway']
          AND r.extent >= %4$L
          AND r.tags @> '{"type": "route"}'
          AND r.tags ? 'route'
      ),
      waterways AS (
        SELECT
          w.id,
          w.tags,
          w.geom,
          rw.member_role,
          rw.relation_id
        FROM way_no_explicit_area w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN non_area_relation r ON rw.relation_id = r.id
        WHERE w.geom && %2$L
          AND r.geom && %2$L
          AND w.tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'man_made', 'natural', 'power', 'railway', 'route', 'telecom', 'waterway']
          AND r.tags @> '{"type": "waterway"}'
          AND r.extent >= %4$L
      ),
      admin_boundaries AS (
        SELECT w.id,
          w.tags,
          w.geom,
          rw.member_role,
          rw.relation_id
        FROM way w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN area_relation r ON rw.relation_id = r.id
        WHERE w.geom && %2$L
          AND r.geom && %2$L
          AND r.tags @> '{"boundary": "administrative"}'
      ),
      combined_lines AS (
          SELECT id, tags, geom, NULL::text AS member_role, NULL::int8 AS relation_id
          FROM filtered_lines
        UNION ALL
          SELECT *
          FROM routes
        UNION ALL
          SELECT *
          FROM waterways
        UNION ALL
          SELECT *
          FROM admin_boundaries
      ),
      collapsed AS (
        SELECT id,
          ANY_VALUE(tags)
            || COALESCE(jsonb_object_agg('m.' || relation_id::text, member_role) FILTER (WHERE relation_id IS NOT NULL), '{}'::jsonb) AS tags,
          ANY_VALUE(geom) AS geom,
          ARRAY_AGG(relation_id) AS relation_ids
        FROM combined_lines
        GROUP BY id
      ),
      simplified_lines AS (
        SELECT id, tags, ST_Simplify(geom, %5$L, true) AS geom, relation_ids
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
      $f$, z, env_geom, min_way_extent, min_rel_extent, simplify_tolerance);
    END IF;
  END;
$$
SET plan_cache_mode = force_custom_plan;