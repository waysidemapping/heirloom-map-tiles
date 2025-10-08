CREATE OR REPLACE FUNCTION function_get_area_features(z integer, env_geom geometry, min_area real, simplify_tolerance real)
  RETURNS TABLE(_id int8, _tags jsonb, _geom geometry, _area_3857 real, _osm_type text)
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
    )
    SELECT id, tags::jsonb, ST_Simplify(geom, %4$L, true) AS geom, area_3857, osm_type FROM filtered_areas
  ;
  $fmt$, z, env_geom, min_area, simplify_tolerance);
END IF;
END;
$$;

CREATE OR REPLACE FUNCTION function_get_area_layer_for_tile(z integer, env_geom geometry)
  RETURNS bytea
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
  AS $area_function_body$
  WITH
    area_features_without_ocean AS (
      SELECT _id AS id, _tags AS tags, _geom AS geom, _area_3857 AS area_3857, _osm_type AS osm_type FROM function_get_area_features(z, env_geom, (ST_Area(env_geom) * 0.00001)::real, (((ST_XMax(env_geom) - ST_XMin(env_geom)))/4096 * 2)::real)
    ),
    unioned_area_features AS (
        SELECT id, tags, geom, area_3857, osm_type FROM area_features_without_ocean
      UNION ALL
        SELECT NULL AS id, '{"natural": "coastline"}'::jsonb AS tags, geom, NULL AS area_3857, NULL AS osm_type FROM function_get_ocean_for_tile(env_geom)
    ),
    tagged_area_features AS (
      SELECT
        id,
        jsonb_object_agg(key, value) FILTER (WHERE key IN ({{JSONB_KEYS}}) {{JSONB_PREFIXES}} OR key LIKE 'r.%') AS tags,
        geom,
        area_3857,
        osm_type
      FROM unioned_area_features
      LEFT JOIN LATERAL jsonb_each(tags) AS t(key, value) ON true
      GROUP BY id, geom, area_3857, osm_type
    ),
    mvt_area_features AS (
      SELECT
        osm_type,
        id AS osm_id,
        tags,
        area_3857,
        ST_AsMVTGeom(geom, env_geom, 4096, 64, true) AS geom
      FROM tagged_area_features
    )
    SELECT ST_AsMVT(tile, 'area', 4096, 'geom') AS mvt FROM mvt_area_features AS tile
$area_function_body$;

CREATE OR REPLACE FUNCTION function_get_line_features(z integer, env_geom geometry, min_diagonal_length real, simplify_tolerance real)
  RETURNS TABLE(_id int8, _tags jsonb, _geom geometry)
  LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
  AS $$
    BEGIN
    IF z < 10 THEN
      RETURN QUERY EXECUTE format($fmt$
      WITH
        ways_in_tile AS (
          SELECT id, tags, geom, bbox_diagonal_length
          FROM way_no_explicit_area
          WHERE geom && %2$L
        ),
        filtered_ways AS (
          SELECT id, tags, geom FROM ways_in_tile
          WHERE (
            tags @> 'highway => motorway'
            OR tags @> 'highway => trunk'
            OR tags @> 'highway => primary'
          ) OR (
            tags @> 'railway => rail'
            AND NOT tags ? 'service'
            AND (
              tags @> 'usage => main'
              OR tags @> 'usage => branch'
            )
          ) OR (
            tags @> 'route => ferry'
            AND bbox_diagonal_length > %3$L * 50.0
          )
        ),
        filtered_ways_from_relations AS (
          SELECT w.id, w.tags, w.geom FROM ways_in_tile w
          JOIN way_relation_member rw ON w.id = rw.member_id
          JOIN non_area_relation r ON rw.relation_id = r.id
          WHERE (
            r.tags @> 'route => hiking'
            AND r.bbox_diagonal_length > 100000
          ) OR (
            w.tags ? 'waterway'
            AND rw.member_role = 'main_stream'
            AND r.tags @> 'type => waterway'
            AND (
              r.bbox_diagonal_length > 100000
              -- OR w.tags->'order:strahler' IN ('8', '9', '10', '11', '12', '13', '14', '15')
            )
          )
        ),
        admin_boundary_lines AS (
          SELECT w.id,
            FIRST_VALUE(w.tags) OVER (PARTITION BY w.id)
              || hstore('r.boundary.min:admin_level', MIN((r.tags->'admin_level')::int)::text)
              || hstore('r.boundary.max:admin_level', MAX((r.tags->'admin_level')::int)::text)
              || hstore('r.boundary', '┃' || STRING_AGG(r.tags -> 'boundary', '┃' ORDER BY r.id) || '┃')
              || hstore('r.boundary:admin_level', '┃' || STRING_AGG(r.tags -> 'admin_level', '┃' ORDER BY r.id) || '┃') AS tags,
            FIRST_VALUE(w.geom) OVER (PARTITION BY w.id) AS geom
          FROM way w
          JOIN way_relation_member rw ON w.id = rw.member_id
          JOIN area_relation r ON rw.relation_id = r.id
          WHERE w.geom && %2$L
            AND r.tags @> 'boundary => administrative'
            AND (
              r.tags @> 'admin_level => 1'
              OR r.tags @> 'admin_level => 2'
              OR r.tags @> 'admin_level => 3'
              OR r.tags @> 'admin_level => 4'
              OR r.tags @> 'admin_level => 5'
            )
          GROUP BY w.id
        ),
        all_filtered_lines AS (
            SELECT * FROM filtered_ways
          UNION ALL
            SELECT * FROM filtered_ways_from_relations
          UNION ALL
            SELECT * FROM admin_boundary_lines
        ),
        with_filtered_tags AS (
          SELECT
            id,
            (
              SELECT jsonb_object_agg(e.key, e.value)
              FROM each(tags) AS e(key, value)
              WHERE
                key IN ({{LOW_ZOOM_LINE_JSONB_KEYS}})
                {{LOW_ZOOM_LINE_JSONB_PREFIXES}}
                OR key LIKE 'r.%%'
            ) AS tags,
            geom
          FROM all_filtered_lines
        )
        SELECT  NULL::int8 AS id, tags, ST_Simplify(ST_LineMerge(ST_Multi(ST_Collect(geom))), %4$L, true) AS geom
        FROM with_filtered_tags
        GROUP BY tags
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
      filtered_highways AS (
        SELECT DISTINCT ON (w.id)
          w.id,
          w.tags,
          w.geom
        FROM ways_in_tile w
        LEFT JOIN way_relation_member rw ON w.id = rw.member_id
        LEFT JOIN non_area_relation r ON rw.relation_id = r.id
        WHERE w.tags ? 'highway' AND r.tags @> 'route => hiking' AND r.bbox_diagonal_length > 100000
      ),
      filtered_lines AS (
        SELECT * FROM ways_in_tile
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
          OR tags @> 'highway => unclassified'
          OR (tags ? 'highway' AND tags @> 'expressway => yes')
        ) OR (
            (
              tags @> 'highway => residential'
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
      admin_boundary_lines AS (
        SELECT w.id,
          FIRST_VALUE(w.tags) OVER (PARTITION BY w.id)
            || hstore('r.boundary.min:admin_level', MIN((r.tags->'admin_level')::int)::text)
            || hstore('r.boundary.max:admin_level', MAX((r.tags->'admin_level')::int)::text)
            || hstore('r.boundary', '┃' || STRING_AGG(r.tags -> 'boundary', '┃' ORDER BY r.id) || '┃')
            || hstore('r.boundary:admin_level', '┃' || STRING_AGG(r.tags -> 'admin_level', '┃' ORDER BY r.id) || '┃') AS tags,
          FIRST_VALUE(w.geom) OVER (PARTITION BY w.id) AS geom
        FROM way w
        JOIN way_relation_member rw ON w.id = rw.member_id
        JOIN area_relation r ON rw.relation_id = r.id
        WHERE w.geom && %2$L
          AND r.tags @> 'boundary => administrative'
          AND r.tags ? 'admin_level'
        GROUP BY w.id
      )
        SELECT id, tags::jsonb, ST_Simplify(geom, %4$L, true) AS geom FROM filtered_lines
      UNION ALL
        SELECT id, tags::jsonb, ST_Simplify(geom, %4$L, true) AS geom FROM admin_boundary_lines
    ;
    $fmt$, z, env_geom, min_diagonal_length, simplify_tolerance);
  END IF;
  END;
$$;

CREATE OR REPLACE FUNCTION function_get_line_layer_for_tile(z integer, env_geom geometry)
  RETURNS bytea
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
  AS $line_function_body$
  WITH
    line_features AS (
      SELECT _id AS id, _tags AS tags, _geom AS geom FROM function_get_line_features(z, env_geom, sqrt(2.0 * (ST_Area(env_geom) * 0.000000075))::real, (((ST_XMax(env_geom) - ST_XMin(env_geom)))/4096 * 2)::real)
    ),
    tagged_line_features AS (
      SELECT
        id,
        jsonb_object_agg(key, value) FILTER (WHERE key IN ({{JSONB_KEYS}}) {{JSONB_PREFIXES}} OR key LIKE 'r.%') AS tags,
        geom
      FROM line_features
      LEFT JOIN LATERAL jsonb_each(tags) AS t(key, value) ON true
      GROUP BY id, geom
    ),
    mvt_line_features AS (
      SELECT
        CASE
          WHEN id IS NULL THEN NULL
          ELSE 'w'
        END AS osm_type,
        id AS osm_id,
        tags,
        ST_AsMVTGeom(geom, env_geom, 4096, 64, true) AS geom
      FROM tagged_line_features
    )
    SELECT ST_AsMVT(tile, 'line', 4096, 'geom') AS mvt FROM mvt_line_features AS tile
$line_function_body$;

CREATE OR REPLACE FUNCTION function_compute_point_tags_score(tags hstore)
RETURNS INTEGER
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $function_body$
  SELECT
    (CASE WHEN tags ? 'name' THEN 100000 ELSE 0 END) +
    (CASE WHEN tags ? 'wikidata' THEN 10000 ELSE 0 END) +
    (CASE WHEN tags ?| ARRAY['boundary', 'place']
      THEN 800
      WHEN tags @> 'public_transport => station'
        OR tags @> 'aeroway => aerodrome'
      THEN 500
      WHEN tags->'natural' IN ('peak', 'water')
      THEN 100
      WHEN tags ?| ARRAY['aerialway', 'golf', 'highway', 'information', 'landuse', 'natural', 'public_transport', 'power', 'railway', 'telecom', 'waterway']
        OR tags->'aeroway' IN ('gate', 'windsock')
        OR tags->'amenity' IN ('atm', 'bbq', 'bench', 'bicycle_parking', 'drinking_water', 'fountain', 'letter_box', 'loading_dock', 'lounger', 'parcel_locker', 'parking_entrance', 'post_box', 'public_bookcase', 'recycling', 'telephone', 'ticket_validator', 'toilets', 'shower', 'vending_machine', 'waste_basket', 'waste_disposal')
        OR tags->'emergency' IN ('fire_hydrant')
        OR tags->'leisure' IN ('firepit', 'picnic_table', 'sauna', 'swimming_pool')
        OR tags->'man_made' IN ('flagpole', 'manhole', 'utility_pole', 'surveillance')
      THEN -100
      WHEN tags ?| ARRAY['barrier', 'building', 'indoor', 'playground']
        OR tags->'aeroway' IN ('navigationaid')
        OR tags->'amenity' IN ('parking_space')
        OR tags->'natural' IN ('tree', 'tree_stump', 'shrub')
      THEN -500
      ELSE 0
    END) +
    (CASE WHEN tags->'access' IN ('discouraged', 'no', 'private') THEN -10 ELSE 0 END)
$function_body$;

CREATE OR REPLACE FUNCTION function_get_point_features(z integer, env_geom geometry, min_area real, max_area real)
  RETURNS TABLE(_id int8, _tags jsonb, _geom geometry, _area_3857 real, _osm_type text)
  LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
  AS $$
    BEGIN
    RETURN QUERY EXECUTE format($fmt$
    WITH
    nodes AS (
      SELECT id, tags, geom, NULL::real AS area_3857, true AS is_node_or_explicit_area, 'n' AS osm_type FROM node
      WHERE geom && %2$L
    ),
    closed_way_centerpoints AS (
      SELECT id, tags, label_point AS geom, area_3857, is_explicit_area AS is_node_or_explicit_area, 'w' AS osm_type FROM way_no_explicit_line
      WHERE label_point && %2$L
        AND area_3857 < %4$L
    ),
    relation_area_centerpoints AS (
      SELECT id, tags, label_point AS geom, area_3857, true AS is_node_or_explicit_area, 'r' AS osm_type FROM area_relation
      WHERE label_point && %2$L
        AND area_3857 < %4$L
    ),
    points_in_tile AS (
        SELECT * FROM nodes
      UNION ALL
        SELECT * FROM closed_way_centerpoints
      UNION ALL
        SELECT * FROM relation_area_centerpoints
    ),
    filtered_points_in_tile AS (
      SELECT * FROM points_in_tile
      WHERE (
        tags @> 'place => continent'
        OR tags @> 'place => ocean'
        OR tags @> 'place => sea'
        OR tags @> 'place => country'
        OR tags @> 'place => state'
        OR tags @> 'place => province'
      ) OR (
        tags @> 'place => city'
        AND %1$L >= 5
      ) OR (
        tags @> 'place => town'
        AND %1$L >= 7
      ) OR (
        tags @> 'place => village'
        AND %1$L >= 9
      ) OR (
        tags ?| ARRAY['advertising', 'amenity', 'club', 'craft', 'education', 'emergency', 'golf', 'healthcare', 'historic', 'indoor', 'information', 'leisure', 'man_made', 'miltary', 'office', 'place', 'playground', 'public_transport', 'shop', 'tourism']
        AND (%1$L >= 10 OR area_3857 > %3$L)
      ) OR (
        -- Assume named features are POIs, otherwise landcover
        tags ?| ARRAY['landuse', 'natural']
        AND (
          %1$L >= 10
          OR (
            tags ? 'name'
            AND area_3857 > %3$L
          )
        )
      ) OR (
        tags ? 'building'
        AND tags ? 'name'
        AND (%1$L >= 10 OR area_3857 > %3$L)
      ) OR (
        (
          tags @> 'boundary => protected_area'
          OR tags @> 'boundary => aboriginal_lands'
        )
        AND (%1$L >= 10 OR area_3857 > %3$L)
      ) OR (
        tags ?| ARRAY['aerialway', 'aeroway', 'barrier', 'highway', 'power', 'railway', 'telecom', 'waterway']
        AND is_node_or_explicit_area
        AND (%1$L >= 10 OR area_3857 > %3$L)
      )
    ),
    route_centerpoints AS (
      SELECT id, tags, bbox_centerpoint_on_surface AS geom, NULL::real AS area_3857, 'r' AS osm_type FROM non_area_relation
      WHERE bbox_centerpoint_on_surface && %2$L
        AND tags ? 'route'
        AND bbox_diagonal_length > sqrt(2.0 * %3$L)
        AND bbox_diagonal_length < sqrt(2.0 * %4$L)
        AND %1$L >= 4
    ),
    cell_grid AS (
      SELECT
        ST_XMin(%2$L::geometry) AS grid_origin_x,
        ST_YMin(%2$L::geometry) AS grid_origin_y,
        ((ST_XMax(%2$L::geometry) - ST_XMin(%2$L::geometry)) / 8.0) AS cell_width,
        ((ST_YMax(%2$L::geometry) - ST_YMin(%2$L::geometry)) / 8.0) AS cell_height
    ),
    scored_and_gridded AS (
      SELECT *,
        function_compute_point_tags_score(tags) AS score,
        FLOOR((ST_X(geom) - cg.grid_origin_x) / cg.cell_width)::int AS cell_x,
        FLOOR((ST_Y(geom) - cg.grid_origin_y) / cg.cell_height)::int AS cell_y
      FROM filtered_points_in_tile, cell_grid cg
    ),
    ranked AS (
      SELECT *, ROW_NUMBER() OVER (PARTITION BY cell_x, cell_y ORDER BY score DESC, id ASC) AS rank
      FROM scored_and_gridded
    )
      SELECT id, tags::jsonb, geom, area_3857, osm_type FROM ranked
      WHERE rank <= 100
    UNION ALL
      SELECT id, tags::jsonb, geom, area_3857, osm_type FROM route_centerpoints
    ;
    $fmt$, z, env_geom, min_area, max_area);
  END;
$$;

CREATE OR REPLACE FUNCTION function_get_point_layer_for_tile(z integer, env_geom geometry)
  RETURNS bytea
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
  AS $point_function_body$
  WITH
    point_features AS (
      SELECT _id AS id, _tags AS tags, _geom AS geom, _area_3857 AS area_3857, _osm_type AS osm_type FROM function_get_point_features(z, env_geom, (ST_Area(env_geom) * 0.0005)::real, (ST_Area(env_geom) * 16)::real)
    ),
    tagged_point_features AS (
      SELECT
        id,
        jsonb_object_agg(key, value) FILTER (WHERE key IN ({{JSONB_KEYS}}) {{JSONB_PREFIXES}} OR key LIKE 'r.%') AS tags,
        geom,
        area_3857,
        osm_type
      FROM point_features
      LEFT JOIN LATERAL jsonb_each(tags) AS t(key, value) ON true
      GROUP BY id, geom, area_3857, osm_type
    ),
    mvt_point_features AS (
      SELECT
        osm_type,
        id AS osm_id,
        tags,
        area_3857,
        ST_AsMVTGeom(geom, env_geom, 4096, 64, true) AS geom
      FROM tagged_point_features
    )
    SELECT ST_AsMVT(tile, 'point', 4096, 'geom') AS mvt FROM mvt_point_features AS tile
$point_function_body$;

CREATE OR REPLACE FUNCTION function_get_heirloom_tile(z integer, x integer, y integer)
  RETURNS bytea
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
  AS $function_body$
  WITH
    envelope AS (
      SELECT ST_TileEnvelope(z, x, y) AS env_geom  
    ),
    tiles AS (
        SELECT function_get_area_layer_for_tile(z, env_geom) AS mvt FROM envelope
      UNION ALL
        SELECT function_get_line_layer_for_tile(z, env_geom) AS mvt FROM envelope
      UNION ALL
        SELECT function_get_point_layer_for_tile(z, env_geom) AS mvt FROM envelope
    )
    SELECT string_agg(mvt, ''::bytea) FROM tiles;
$function_body$;

COMMENT ON FUNCTION function_get_heirloom_tile IS
$tilejson$
{
  "description => Server-farm-to-table OpenStreetMap tiles",
  "attribution => © OpenStreetMap",
  "vector_layers": [
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
