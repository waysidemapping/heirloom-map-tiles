CREATE OR REPLACE FUNCTION function_get_area_features(z integer, env_geom geometry, min_area real, simplify_tolerance real)
  RETURNS TABLE(id int8, tags jsonb, geom geometry, area_3857 real, osm_type text)
  LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
  AS $$
  BEGIN
  IF z < 10 THEN
  RETURN QUERY EXECUTE format($fmt$
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
          AND NOT tags @> 'natural => coastline'
      UNION ALL
        SELECT * FROM areas
        WHERE tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
          AND is_explicit_area
      UNION ALL
        SELECT * FROM areas
        WHERE tags @> 'boundary => protected_area'
          OR tags @> 'boundary => aboriginal_lands'
    ),
    deduped_areas AS (
      -- This will fail if a way and relation in the same tile have the same ID
      SELECT DISTINCT ON (id) * FROM filtered_areas
    )
    SELECT
      NULL::int8 AS id,
      jsonb_build_object({{LOW_ZOOM_AREA_JSONB_KEY_MAPPINGS}}) AS tags,
      ST_Simplify(ST_Multi(ST_Collect(geom)), %4$L, true) AS geom,
      NULL::real AS area_3857,
      NULL::text AS osm_type
    FROM deduped_areas
    GROUP BY tags
  ;
  $fmt$, z, env_geom, min_area, simplify_tolerance);
  ELSE
  RETURN QUERY EXECUTE format($fmt$
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
        AND NOT tags @> 'natural => coastline'
    UNION ALL
      SELECT * FROM areas
      WHERE tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
        AND is_explicit_area
    UNION ALL
      SELECT * FROM areas
      WHERE tags ?| ARRAY['area:highway', 'building:part', 'indoor', 'playground']
        AND %1$L >= 18
    UNION ALL
      SELECT * FROM areas
      WHERE tags @> 'boundary => protected_area'
        OR tags @> 'boundary => aboriginal_lands'
    UNION ALL
        SELECT * FROM areas
        WHERE tags ? 'building'
          -- only show really big buildings at low zooms
          AND (%1$L >= 14 OR area_3857 > %3$L::real * 50)
    ),
    simplifed_areas AS (
      SELECT id, tags::jsonb, ST_Simplify(geom, %4$L, true) AS geom, area_3857, osm_type FROM filtered_areas
    )
    SELECT
      id,
      (
        SELECT jsonb_object_agg(key, value)
        FROM jsonb_each(tags)
        WHERE key IN ({{JSONB_KEYS}}) {{JSONB_PREFIXES}} OR key LIKE 'm.%%'
      ) AS tags,
      geom,
      area_3857,
      osm_type
    FROM simplifed_areas
  ;
  $fmt$, z, env_geom, min_area, simplify_tolerance);
END IF;
END;
$$;

CREATE OR REPLACE FUNCTION function_get_line_features(z integer, env_geom geometry, min_diagonal_length real, simplify_tolerance real)
  RETURNS TABLE(id int8, tags jsonb, geom geometry, relation_ids bigint[])
  LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
  AS $$
    BEGIN
    IF z < 10 THEN
      RETURN QUERY EXECUTE format($fmt$
      WITH
        ways AS (
          SELECT
            w.id,
            -- (
            --   SELECT jsonb_object_agg(e.key, e.value) AS tags
            -- FROM each(w.tags) AS e(key, value)
            -- WHERE
            --   key IN ({{LOW_ZOOM_LINE_JSONB_KEYS}})
            --   {{LOW_ZOOM_LINE_JSONB_PREFIXES}}
            --   )
            (slice(w.tags, ARRAY[{{LOW_ZOOM_LINE_JSONB_KEYS}}])::jsonb)
              || COALESCE(jsonb_object_agg('m.' || rw.relation_id::text, rw.member_role) FILTER (WHERE r.id IS NOT NULL), '{}'::jsonb) AS tags,
            (ARRAY_AGG(w.geom))[1] AS geom,
            ARRAY_AGG(r.id) AS relation_ids
          FROM way_no_explicit_area w
          LEFT JOIN way_relation_member rw ON w.id = rw.member_id
          LEFT JOIN non_area_relation r ON
            rw.relation_id = r.id AND
            r.tags @> 'type => route' AND
            r.bbox_diagonal_length > %3$L * 50.0
          WHERE w.geom && %2$L
            AND (
            (
              w.tags @> 'highway => motorway'
              OR w.tags @> 'highway => trunk'
            ) OR (
              w.tags @> 'highway => primary'
              AND %1$L >= 5
            ) OR (
              w.tags @> 'railway => rail'
              AND (
                w.tags @> 'usage => main'
                OR w.tags @> 'usage => branch'
              )
            ) OR (
              w.tags @> 'route => ferry'
              AND w.bbox_diagonal_length > %3$L * 50.0
            )
          )
          GROUP BY w.id
        ),
        waterways AS (
          SELECT
            w.id,
            slice(w.tags, ARRAY['waterway'])::jsonb
              || jsonb_object_agg('m.' || rw.relation_id::text, rw.member_role) AS tags,
            (ARRAY_AGG(w.geom))[1] AS geom,
            ARRAY_AGG(r.id) AS relation_ids
          FROM way_no_explicit_area w
          JOIN way_relation_member rw ON w.id = rw.member_id
          JOIN non_area_relation r ON rw.relation_id = r.id
          WHERE w.geom && %2$L
            AND w.tags ? 'waterway'
            AND rw.member_role = 'main_stream'
            AND r.tags @> 'type => waterway'
            AND (
              r.bbox_diagonal_length > %3$L * 250.0
              OR w.tags->'order:strahler' IN ('8', '9', '10', '11', '12', '13', '14', '15')
          )
          GROUP BY w.id
        ),
        path_routes AS (
          SELECT
            w.id,
            jsonb_object_agg('m.' || rw.relation_id::text, rw.member_role) AS tags,
            (ARRAY_AGG(w.geom))[1] AS geom,
            ARRAY_AGG(r.id) AS relation_ids
          FROM way_no_explicit_area w
          JOIN way_relation_member rw ON w.id = rw.member_id
          JOIN non_area_relation r ON rw.relation_id = r.id
          WHERE w.geom && %2$L
            AND w.tags ? 'highway'
            AND r.tags @> 'type => route'
            AND r.tags @> 'route => hiking'
            AND r.bbox_diagonal_length > %3$L * 250.0
          GROUP BY w.id
        ),
        admin_boundaries AS (
          SELECT w.id,
            slice(w.tags, ARRAY['name', 'maritime'])::jsonb
              || jsonb_object_agg('m.' || rw.relation_id::text, rw.member_role) AS tags,
            (ARRAY_AGG(w.geom))[1] AS geom,
            ARRAY_AGG(r.id) AS relation_ids
          FROM way w
          JOIN way_relation_member rw ON w.id = rw.member_id
          JOIN area_relation r ON rw.relation_id = r.id AND r.tags @> 'boundary => administrative'
          WHERE w.geom && %2$L
            AND (
              r.tags @> 'admin_level => 1'
              OR r.tags @> 'admin_level => 2'
              OR r.tags @> 'admin_level => 3'
              OR r.tags @> 'admin_level => 4'
              OR r.tags @> 'admin_level => 5'
              OR (
                %1$L >= 6 AND r.tags @> 'admin_level => 6'
              )
            )
          GROUP BY w.id
        ),
        grouped_by_tags AS (
            SELECT tags, ST_Simplify(ST_LineMerge(ST_Multi(ST_Collect(geom))), %4$L, true) AS geom, MIN(relation_ids) AS relation_ids
            FROM ways
            GROUP BY tags
          UNION ALL
            SELECT tags, ST_Simplify(ST_LineMerge(ST_Multi(ST_Collect(geom))), %4$L, true) AS geom, MIN(relation_ids) AS relation_ids
            FROM waterways
            GROUP BY tags
          UNION ALL
            SELECT tags, ST_Simplify(ST_LineMerge(ST_Multi(ST_Collect(geom))), %4$L, true) AS geom, MIN(relation_ids) AS relation_ids
            FROM path_routes
            GROUP BY tags
          UNION ALL
            SELECT tags, ST_Simplify(ST_LineMerge(ST_Multi(ST_Collect(geom))), %4$L, true) AS geom, MIN(relation_ids) AS relation_ids
            FROM admin_boundaries
            GROUP BY tags
        )
        SELECT
            NULL::int8 AS id,
            tags,
            geom,
            relation_ids
          FROM grouped_by_tags
      ;
      $fmt$, z, env_geom, min_diagonal_length, simplify_tolerance);
    ELSE
      RETURN QUERY EXECUTE format($fmt$
      WITH
      ways_in_tile AS (
        SELECT id, tags, geom, is_explicit_line, bbox_diagonal_length FROM way_no_explicit_area
        WHERE geom && %2$L
          AND bbox_diagonal_length > %3$L
      ),
      filtered_lines AS (
        SELECT id, tags, geom FROM ways_in_tile
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
          OR (tags ? 'highway' AND tags @> 'expressway => yes')
        ) OR (
            (
              tags @> 'highway => residential'
              OR tags @> 'highway => unclassified'
            )
            AND %1$L >= 12
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
            AND bbox_diagonal_length > %3$L * 50.0
        ) OR (
          tags ? 'railway'
          AND NOT tags ? 'service'
        ) OR (
          tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'power', 'railway', 'route', 'telecom', 'waterway']
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
      path_routes AS (
        SELECT w.id,
          w.tags,
          w.geom
        FROM way_no_explicit_area w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN non_area_relation r ON rw.relation_id = r.id
        WHERE w.geom && %2$L
          AND w.tags ? 'highway'
          AND r.tags @> 'type => route'
          AND r.tags @> 'route => hiking'
          AND r.bbox_diagonal_length > %3$L * 250.0
          -- all paths are shown by z15 anyway
          AND %1$L < 15
        GROUP BY w.id
      ),
      admin_boundaries AS (
        SELECT w.id,
          w.tags,
          w.geom
        FROM way w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN area_relation r ON rw.relation_id = r.id AND r.tags @> 'boundary => administrative' AND r.tags ? 'admin_level'
        WHERE w.geom && %2$L
        GROUP BY w.id
      ),
      all_filtered_lines AS (
          SELECT * FROM filtered_lines
        UNION ALL
          SELECT * FROM path_routes
        UNION ALL
          SELECT * FROM admin_boundaries
      ),
      all_relations AS (
          SELECT id, tags FROM area_relation
        UNION ALL
          SELECT id, tags FROM non_area_relation
      ),
      filtered_lines_w_relations AS (
        SELECT w.id,
          (ARRAY_AGG(w.tags::jsonb))[1]
            || COALESCE(jsonb_object_agg('m.' || rw.relation_id::text, rw.member_role) FILTER (WHERE r.id IS NOT NULL), '{}'::jsonb) AS tags,
          (ARRAY_AGG(w.geom))[1] AS geom,
          ARRAY_AGG(r.id) AS relation_ids
        FROM all_filtered_lines w
        LEFT JOIN way_relation_member rw ON w.id = rw.member_id
        LEFT JOIN all_relations r ON rw.relation_id = r.id
          AND (
            r.tags @> 'boundary => administrative'
            OR r.tags @> 'type => route'
            OR r.tags @> 'type => waterway'
          )
        GROUP BY w.id
      ),
      simplified_lines AS (
        SELECT id, tags, ST_Simplify(geom, %4$L, true) AS geom, relation_ids
        FROM filtered_lines_w_relations
      )
      SELECT
        id,
        (
          SELECT jsonb_object_agg(key, value)
          FROM jsonb_each(tags)
          WHERE key IN ({{JSONB_KEYS}}) {{JSONB_PREFIXES}} OR key LIKE 'm.%%'
        ) AS tags,
        geom,
        relation_ids
      FROM simplified_lines
    ;
    $fmt$, z, env_geom, min_diagonal_length, simplify_tolerance);
  END IF;
  END;
$$;

CREATE OR REPLACE FUNCTION function_get_point_features(z integer, env_geom geometry, min_area real, max_area real)
  RETURNS TABLE(id int8, tags jsonb, geom geometry, area_3857 real, osm_type text)
  LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
  AS $$
    BEGIN
    RETURN QUERY EXECUTE format($fmt$
    WITH
    small_points AS (
        SELECT id, tags, geom, NULL::real AS area_3857, true AS is_node_or_explicit_area, 'n' AS osm_type FROM node
        WHERE geom && %2$L
      UNION ALL
        SELECT id, tags, label_point AS geom, area_3857, is_explicit_area AS is_node_or_explicit_area, 'w' AS osm_type FROM way_no_explicit_line
        WHERE label_point && %2$L
          AND area_3857 <= %3$L
      UNION ALL
        SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type FROM area_relation
        WHERE label_point && %2$L
          AND area_3857 <= %3$L
    ),
    filtered_small_points AS (
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
      ) OR (
        tags ?| ARRAY['advertising', 'amenity', 'boundary', 'building', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'indoor', 'information', 'landuse', 'leisure', 'man_made', 'miltary', 'natural', 'office', 'place', 'playground', 'public_transport', 'shop', 'tourism']
        AND %1$L >= 12
        AND (tags ? 'name' OR tags ? 'wikidata' OR %1$L >= 15)
      ) OR (
        tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
        AND is_node_or_explicit_area
        AND %1$L >= 12
        AND (tags ? 'name' OR tags ? 'wikidata' OR %1$L >= 15)
      )
    ),
    large_points AS (
        SELECT id, tags, label_point AS geom, area_3857, is_explicit_area AS is_node_or_explicit_area, 'w' AS osm_type FROM way_no_explicit_line
        WHERE label_point && %2$L
          AND area_3857 > %3$L
          AND area_3857 < %4$L
      UNION ALL
        SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type FROM area_relation
        WHERE label_point && %2$L
          AND area_3857 > %3$L
          AND area_3857 < %4$L
    ),
    filtered_large_points AS (
      SELECT * FROM large_points
      WHERE (
        tags ?| ARRAY['advertising', 'amenity', 'boundary', 'building', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'indoor', 'information', 'landuse', 'leisure', 'man_made', 'miltary', 'natural', 'office', 'place', 'playground', 'public_transport', 'shop', 'tourism']
      ) OR (
        tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
        AND is_node_or_explicit_area
      )
    ),
    route_centerpoints AS (
      SELECT id, tags, bbox_centerpoint_on_surface AS geom, NULL::real AS area_3857, 'r' AS osm_type FROM non_area_relation
      WHERE bbox_centerpoint_on_surface && %2$L
        AND tags ? 'route'
        -- scale area by 4 since we want to be a little more selective about size
        AND bbox_diagonal_length > sqrt(2.0 * %3$L * 4)
        AND bbox_diagonal_length < sqrt(2.0 * %4$L * 4)
        AND %1$L >= 4
    ),
    all_points AS (
      SELECT id, tags::jsonb, geom, area_3857, osm_type FROM filtered_small_points
    UNION ALL
      SELECT id, tags::jsonb, geom, area_3857, osm_type FROM filtered_large_points
    UNION ALL
      SELECT id, tags::jsonb, geom, area_3857, osm_type FROM route_centerpoints
    )
    SELECT
      id,
      (
        SELECT jsonb_object_agg(key, value)
        FROM jsonb_each(tags)
        WHERE key IN ({{JSONB_KEYS}}) {{JSONB_PREFIXES}} OR key LIKE 'm.%%'
      ) AS tags,
      geom,
      area_3857,
      osm_type
    FROM all_points
    ;
    $fmt$, z, env_geom, min_area, max_area);
  END;
$$;

CREATE OR REPLACE FUNCTION function_get_heirloom_tile_for_envelope(z integer, x integer, y integer, env_geom geometry, env_area real, env_width real)
  RETURNS bytea
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
  AS $function_body$
  WITH
    area_features_without_ocean AS (
      SELECT id, tags, geom, area_3857, osm_type FROM function_get_area_features(z, env_geom, (env_area * 0.00001)::real, (env_width/4096 * 2)::real)
    ),
    area_features AS (
        SELECT id, tags, geom, area_3857, osm_type FROM area_features_without_ocean
      UNION ALL
        SELECT NULL AS id, '{"natural": "coastline"}'::jsonb AS tags, geom, NULL AS area_3857, NULL AS osm_type FROM function_get_ocean_for_tile(env_geom)
    ),
    mvt_area_features AS (
      SELECT
        id * 10 + (CASE WHEN osm_type = 'w' THEN 2 WHEN osm_type = 'r' THEN 3 ELSE 0 END) AS feature_id,
        tags,
        area_3857,
        ST_AsMVTGeom(geom, env_geom, 4096, 64, true) AS geom
      FROM area_features
    ),
    line_features AS (
      SELECT id, tags, geom, relation_ids
      FROM function_get_line_features(z, env_geom, sqrt(2.0 * (env_area * 0.000000075))::real, (env_width/4096 * 2)::real)
    ),
    mvt_line_features AS (
      SELECT
        id * 10 + 2 AS feature_id,
        tags,
        ST_AsMVTGeom(geom, env_geom, 4096, 64, true) AS geom
      FROM line_features
    ),
    point_features AS (
      SELECT id, tags, geom, area_3857, osm_type FROM function_get_point_features(z, env_geom, (env_area * 0.0005)::real, (env_area * 16)::real)
    ),
    mvt_point_features AS (
      SELECT
        id * 10 + (CASE WHEN osm_type = 'n' THEN 1 WHEN osm_type = 'w' THEN 2 WHEN osm_type = 'r' THEN 3 ELSE 0 END) AS feature_id,
        tags,
        area_3857,
        ST_AsMVTGeom(geom, env_geom, 4096, 64, true) AS geom
      FROM point_features
    ),
    all_relation_ids AS (
      SELECT unnest(relation_ids) AS relation_id
      FROM line_features
    ),
    unique_relation_ids AS (
      SELECT DISTINCT relation_id
      FROM all_relation_ids
    ),
    relation_features AS (
        SELECT r.id, r.tags::jsonb
        FROM non_area_relation r
        JOIN unique_relation_ids linked ON r.id = linked.relation_id
      UNION ALL
        SELECT r.id, r.tags::jsonb
        FROM area_relation r
        JOIN unique_relation_ids linked ON r.id = linked.relation_id
    ),
    tagged_relation_features AS (
      SELECT
        id,
        (
          SELECT jsonb_object_agg(key, value)
          FROM jsonb_each(tags)
          WHERE key IN ({{RELATION_JSONB_KEYS}})
        ) AS tags
      FROM relation_features
    ),
    mvt_relation_features AS (
      SELECT
        id * 10 + 3 AS feature_id,
        tags,
        env_geom AS geom
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
$function_body$;

CREATE OR REPLACE FUNCTION function_get_heirloom_tile(z integer, x integer, y integer)
  RETURNS bytea
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
  AS $function_body$
  SELECT * FROM function_get_heirloom_tile_for_envelope(z, x, y, ST_TileEnvelope(z, x, y), ST_Area(ST_TileEnvelope(z, x, y))::real, (ST_XMax(ST_TileEnvelope(z, x, y)) - ST_XMin(ST_TileEnvelope(z, x, y)))::real)
$function_body$;

COMMENT ON FUNCTION function_get_heirloom_tile IS
$tilejson$
{
  "description => Server-farm-to-table OpenStreetMap tiles",
  "attribution => © OpenStreetMap",
  "vector_layers": [
    {
      "id => relation",
      "fields": {
        {{FIELD_DEFS}}
      }
    },
    {
      "id => area",
      "fields": {
        {{FIELD_DEFS}}
      }
    },
    {
      "id => line",
      "fields": {
        {{FIELD_DEFS}}
      }
    },
    {
      "id => point",
      "fields": {
        {{FIELD_DEFS}}
      }
    }
  ]
}
$tilejson$;
