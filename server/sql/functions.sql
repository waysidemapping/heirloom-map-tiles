CREATE OR REPLACE FUNCTION function_get_area_features(z integer, env_geom geometry, min_area real, simplify_tolerance real)
  RETURNS TABLE(_id int8, _tags jsonb, _geom geometry, _area_3857 real, _osm_type text)
  LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
  AS $$
  BEGIN
  IF z < 12 THEN
    RETURN QUERY
    WITH
    closed_ways AS (
      SELECT id, tags, geom, area_3857, 'w' AS osm_type, is_explicit_area FROM way_no_explicit_line
      WHERE geom && env_geom
        AND area_3857 > min_area
    ),
    relation_areas AS (
      SELECT id, tags, geom, area_3857, 'r' AS osm_type, true AS is_explicit_area FROM area_relation
      WHERE geom && env_geom
        AND area_3857 > min_area
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
      ST_Simplify(ST_Multi(ST_Collect(geom)), simplify_tolerance, true) AS geom,
      NULL::real AS area_3857,
      NULL::text AS osm_type
    FROM tagged_areas
    GROUP BY tags
  ;
  ELSE
  RETURN QUERY
  WITH
    closed_ways AS (
      SELECT id, tags, geom, area_3857, 'w' AS osm_type, is_explicit_area FROM way_no_explicit_line
      WHERE geom && env_geom
        AND area_3857 > min_area
    ),
    relation_areas AS (
      SELECT id, tags, geom, area_3857, 'r' AS osm_type, true AS is_explicit_area FROM area_relation
      WHERE geom && env_geom
        AND area_3857 > min_area
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
          AND z >= 14
      UNION ALL
        SELECT * FROM areas
        WHERE tags ?| ARRAY['area:highway', 'building:part', 'indoor', 'playground']
          AND z >= 18
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
      ST_Simplify(geom, simplify_tolerance, true) AS geom,
      area_3857,
      osm_type
    FROM deduped_areas
  ;
END IF;
END;
$$;

CREATE OR REPLACE FUNCTION function_get_line_features(z integer, env_geom geometry, min_way_extent real, min_rel_extent real, simplify_tolerance real)
  RETURNS TABLE(_id int8, _tags jsonb, _geom geometry, _relation_ids int8[])
  LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
  AS $$
    BEGIN
    IF z < 12 THEN
      RETURN QUERY
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
        WHERE w.geom && env_geom
          AND r.geom && env_geom
          AND w.tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'man_made', 'natural', 'power', 'railway', 'route', 'telecom', 'waterway']
          AND r.bbox_diagonal_length > min_rel_extent
          AND r.tags @> 'type => route'
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
        WHERE w.geom && env_geom
          AND r.geom && env_geom
          AND w.tags ? 'waterway'
          AND r.tags @> 'type => waterway'
          AND r.bbox_diagonal_length > min_rel_extent
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
        WHERE w.geom && env_geom
          AND r.geom && env_geom
          AND r.tags @> 'boundary => administrative'
          AND (
            r.tags @> 'admin_level => 1'
            OR r.tags @> 'admin_level => 2'
            OR r.tags @> 'admin_level => 3'
            OR r.tags @> 'admin_level => 4'
            OR r.tags @> 'admin_level => 5'
            OR (
              z >= 6 AND r.tags @> 'admin_level => 6'
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
          slice(ANY_VALUE(tags), ARRAY[{{LOW_ZOOM_LINE_KEY_LIST}}])::jsonb
            || COALESCE(jsonb_object_agg('m.' || relation_id::text, member_role) FILTER (WHERE relation_id IS NOT NULL), '{}'::jsonb) AS tags,
          ANY_VALUE(geom) AS geom,
          ARRAY_AGG(relation_id) AS relation_ids
        FROM combined_lines
        GROUP BY id
      ),
      grouped_and_simplified AS (
        SELECT
          tags,
          ST_Simplify(ST_LineMerge(ST_Multi(ST_Collect(geom))), simplify_tolerance, true) AS geom,
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
    ELSE
      RETURN QUERY
      WITH
      ways_in_tile AS (
        SELECT id, tags, geom, is_explicit_line
        FROM way_no_explicit_area
        WHERE geom && env_geom
          AND bbox_diagonal_length > min_way_extent
      ),
      filtered_lines AS (
        SELECT id, tags, geom
        FROM ways_in_tile
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
          AND z >= 13
        ) OR (
          tags ? 'highway'
          AND z >= 15
        ) OR (
          tags ?| ARRAY['waterway']
        ) OR (
          tags @> 'route => ferry'
        ) OR (
          tags ? 'railway'
          AND NOT tags ? 'service'
        ) OR (
          tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'power', 'railway', 'route', 'telecom']
          AND z >= 13
        ) OR (
          tags ?| ARRAY['man_made', 'natural']
          AND is_explicit_line
          AND z >= 13
        ) OR (
          tags @> 'natural => coastline'
          AND z >= 13
        ) OR (
          tags ?| ARRAY['golf']
          AND is_explicit_line
          AND z >= 15
        ) OR (
          tags ?| ARRAY['indoor']
          AND is_explicit_line
          AND z >= 18
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
        WHERE w.geom && env_geom
          AND r.geom && env_geom
          AND w.tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'man_made', 'natural', 'power', 'railway', 'route', 'telecom', 'waterway']
          AND r.bbox_diagonal_length > min_rel_extent
          AND r.tags @> 'type => route'
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
        WHERE w.geom && env_geom
          AND r.geom && env_geom
          AND w.tags ? 'waterway'
          AND r.tags @> 'type => waterway'
          AND r.bbox_diagonal_length > min_rel_extent
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
        WHERE w.geom && env_geom
          AND r.geom && env_geom
          AND r.tags @> 'boundary => administrative'
          AND r.tags ? 'admin_level'
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
          ANY_VALUE(tags)::jsonb
            || COALESCE(jsonb_object_agg('m.' || relation_id::text, member_role) FILTER (WHERE relation_id IS NOT NULL), '{}'::jsonb) AS tags,
          ANY_VALUE(geom) AS geom,
          ARRAY_AGG(relation_id) AS relation_ids
        FROM combined_lines
        GROUP BY id
      ),
      simplified_lines AS (
        SELECT id, tags, ST_Simplify(geom, simplify_tolerance, true) AS geom, relation_ids
        FROM collapsed
      )
      SELECT
        id,
        (
          SELECT jsonb_object_agg(key, value)
          FROM jsonb_each(tags)
          WHERE key IN ({{LINE_KEY_LIST}}) {{LINE_KEY_PREFIX_LIKE_STATEMENTS}} OR key LIKE 'm.%'
        ) AS tags,
        geom,
        relation_ids
      FROM simplified_lines
      ;
  END IF;
  END;
$$;

CREATE OR REPLACE FUNCTION function_get_point_features(z integer, env_geom geometry, wide_env_geom geometry, min_area real, max_area real, min_rel_extent real, max_rel_extent real)
  RETURNS TABLE(_id int8, _tags jsonb, _geom geometry, _area_3857 real, _osm_type text, _relation_ids int8[])
  LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
  AS $$
    BEGIN
    IF z < 12 THEN
      RETURN QUERY
      WITH
      small_points AS (
          SELECT id, tags, geom, NULL::real AS area_3857, true AS is_node_or_explicit_area, 'n' AS osm_type FROM node
          WHERE geom && env_geom
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, is_explicit_area AS is_node_or_explicit_area, 'w' AS osm_type FROM way_no_explicit_line
          WHERE label_point && env_geom
            AND area_3857 <= min_area
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type FROM area_relation
          WHERE label_point && env_geom
            AND area_3857 <= min_area
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
          AND z >= 4
        ) OR (
          (
            tags @> 'place => town'
          )
          AND z >= 6
        ) OR (
          (
            tags @> 'place => village'
          )
          AND z >= 7
        ) OR (
          (
            tags @> 'place => hamlet'
            OR tags @> 'natural => peak'
            OR tags @> 'natural => volcano'
          )
          AND z >= 8
        ) OR (
          (
            tags @> 'place => locality'
            OR tags @> 'public_transport => station'
            OR tags @> 'aeroway => aerodrome'
            OR tags @> 'highway => motorway_junction'
          )
          AND z >= 9
        )
      ),
      large_points AS (
          SELECT id, tags, label_point AS geom, area_3857, is_explicit_area AS is_node_or_explicit_area, 'w' AS osm_type
          FROM way_no_explicit_line
          WHERE label_point && env_geom
            AND area_3857 > min_area
            AND area_3857 < max_area
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type
          FROM area_relation
          WHERE label_point && env_geom
            AND area_3857 > min_area
            AND area_3857 < max_area
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
          bbox_centerpoint_on_surface AS geom,
          NULL::real AS area_3857,
          'r' AS osm_type,
          ARRAY[id] AS relation_ids
        FROM non_area_relation
        WHERE bbox_centerpoint_on_surface && env_geom
          AND (
            (tags @> 'type => route' AND tags ? 'route')
            OR tags @> 'type => waterway'
          )
          AND bbox_diagonal_length > min_rel_extent
          AND bbox_diagonal_length < max_rel_extent
          AND z >= 4
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
    ELSE
      RETURN QUERY
      WITH
      small_points AS (
          SELECT id, tags, geom, NULL::real AS area_3857, true AS is_node_or_explicit_area, 'n' AS osm_type FROM node
          WHERE geom && env_geom
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, is_explicit_area AS is_node_or_explicit_area, 'w' AS osm_type FROM way_no_explicit_line
          WHERE label_point && env_geom
            AND area_3857 <= min_area
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type FROM area_relation
          WHERE label_point && env_geom
            AND area_3857 <= min_area
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
          -- Assume that a feature with a name (e.g. park, business, artwork) is more important one without
          -- (e.g. crossing, pole, gate). Features linked to Wikidata items are assumed to be notable regardless
          (tags ? 'name' OR tags ? 'wikidata') AS is_notable
        FROM small_points
        WHERE 
          tags ?| ARRAY['advertising', 'amenity', 'boundary', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'indoor', 'information', 'landuse', 'leisure', 'man_made', 'miltary', 'office', 'place', 'playground', 'public_transport', 'shop', 'tourism']
          OR (
            tags ? 'building'
            AND (tags ? 'name' OR tags ? 'wikidata' OR z >= 15)
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
          SELECT count(id) AS total FROM node
          WHERE geom && wide_env_geom
        UNION ALL
          SELECT count(id) AS total FROM way_no_explicit_line
          WHERE label_point && wide_env_geom
        UNION ALL
          SELECT count(id) AS total FROM area_relation
          WHERE label_point && wide_env_geom
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
          WHERE label_point && env_geom
            AND area_3857 > min_area
            AND area_3857 < max_area
        UNION ALL
          SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type
          FROM area_relation
          WHERE label_point && env_geom
            AND area_3857 > min_area
            AND area_3857 < max_area
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
          bbox_centerpoint_on_surface AS geom,
          NULL::real AS area_3857,
          'r' AS osm_type,
          ARRAY[id] AS relation_ids
        FROM non_area_relation
        WHERE bbox_centerpoint_on_surface && env_geom
          AND (
            (tags @> 'type => route' AND tags ? 'route')
            OR tags @> 'type => waterway'
          )
          AND bbox_diagonal_length > min_rel_extent
          AND bbox_diagonal_length < max_rel_extent
          AND z >= 4
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
  END IF;
  END;
$$;

CREATE OR REPLACE FUNCTION function_get_heirloom_tile_for_envelope(z integer, x integer, y integer, env_geom geometry, min_extent real)
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
      FROM function_get_area_features(z, env_geom, power(min_extent * 4, 2)::real, (min_extent * 0.75)::real)
    ),
    area_features AS (
        SELECT id, tags, geom, area_3857, osm_type
        FROM area_features_without_ocean
      UNION ALL
        SELECT NULL AS id, '{"natural": "coastline"}'::jsonb AS tags, geom, NULL AS area_3857, NULL AS osm_type
        FROM function_get_ocean_for_tile(env_geom)
    ),
    mvt_area_features AS (
      SELECT
        id * 10 + (CASE WHEN osm_type = 'w' THEN 2 WHEN osm_type = 'r' THEN 3 ELSE 0 END) AS feature_id,
        tags,
        -- area_3857,
        ST_AsMVTGeom(geom, env_geom, 4096, 64, true) AS geom
      FROM area_features
    ),
    line_features AS (
      SELECT
        _id AS id,
        _tags AS tags,
        _geom AS geom,
        _relation_ids AS relation_ids
      FROM function_get_line_features(z, env_geom, min_extent, (min_extent * 192)::real, (min_extent * 0.75)::real)
    ),
    mvt_line_features AS (
      SELECT
        id * 10 + 2 AS feature_id,
        tags,
        ST_AsMVTGeom(geom, env_geom, 4096, 64, true) AS geom
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
      FROM function_get_point_features(z, env_geom, ST_Expand(env_geom, ST_XMax(env_geom) - ST_XMin(env_geom)), power(min_extent * 32, 2)::real, power(min_extent * 4096, 2)::real, (min_extent * 192)::real, (min_extent * 192 * 16)::real)
    ),
    mvt_point_features AS (
      SELECT
        id * 10 + (CASE WHEN osm_type = 'n' THEN 1 WHEN osm_type = 'w' THEN 2 WHEN osm_type = 'r' THEN 3 ELSE 0 END) AS feature_id,
        tags,
        -- area_3857,
        ST_AsMVTGeom(geom, env_geom, 4096, 64, true) AS geom
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
          WHERE key IN ({{RELATION_KEY_LIST}}) {{RELATION_KEY_PREFIX_LIKE_STATEMENTS}}
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
  LANGUAGE sql VOLATILE STRICT PARALLEL SAFE
  AS $function_body$
  -- planning optimization can change a lot based on parameter values so don't used cached plans
  SET plan_cache_mode = force_custom_plan;
  SELECT * FROM function_get_heirloom_tile_for_envelope(z, x, y, ST_TileEnvelope(z, x, y), ((ST_XMax(ST_TileEnvelope(z, x, y)) - ST_XMin(ST_TileEnvelope(z, x, y))) / 1024.0)::real);
$function_body$;

COMMENT ON FUNCTION function_get_heirloom_tile IS
$tilejson$
{
  "description": "Server-farm-to-table OpenStreetMap tiles",
  "attribution": "OpenStreetMap"
}
$tilejson$;
