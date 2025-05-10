CREATE OR REPLACE
  FUNCTION function_get_rustic_tile(z integer, x integer, y integer)
  RETURNS bytea 
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
  AS $$
  WITH
    raw_envelope AS (
      SELECT ST_TileEnvelope(z, x, y) AS env_geom
    ),
    envelope AS (
      SELECT 
        env_geom,
        ST_Area(env_geom) AS env_area
      FROM raw_envelope
    ),
    tiles AS (
      SELECT ST_AsMVT(tile, 'area', 4096, 'geom') AS mvt FROM (
        SELECT {{COLUMN_NAMES}}, ST_AsMVTGeom(geom, env.env_geom, 4096, 64, true) AS geom
        FROM (
          SELECT *
          FROM "aerialway", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'area'
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "aeroway", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "aeroway" NOT IN ('jet_bridge', 'parking_position', 'runway', 'taxiway'))
            )
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "amenity", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("education" IS NULL OR "education" = 'no')
            AND ("healthcare" IS NULL OR "healthcare" = 'no')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
            AND (z >= 18 OR ("amenity" NOT IN ('parking_space')))
        UNION ALL
          SELECT *
          FROM "barrier", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'area'
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "building", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("area_3857" = 0 OR "area_3857" > env.env_area * 0.000001)
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "club", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "craft", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "education", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "emergency", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("highway" IS NULL OR "highway" = 'no')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "healthcare", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "highway", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'area'
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "historic", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "information", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "landuse", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("building" IS NULL OR "building" = 'no')
            AND "area_3857" > env.env_area * 0.000001
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "leisure", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "man_made", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "man_made" NOT IN ('breakwater', 'cutline', 'dyke', 'embankment', 'gantry', 'goods_conveyor', 'groyne', 'pier', 'pipeline'))
            )
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "military", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "military" NOT IN ('trench'))
            )
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "natural", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "natural" NOT IN ('cliff', 'coastline', 'gorge', 'ridge', 'strait', 'tree_row', 'valley'))
            )
            AND "area_3857" > env.env_area * 0.000001
            AND ("building" IS NULL OR "building" = 'no')
            AND "natural" NOT IN ('bay', 'coastline')
            AND (
              (z >= 0 AND ("natural" = 'water'))
              OR z >= 10
            )
        UNION ALL
          SELECT *
          FROM "office", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "power", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "power" NOT IN ('cable', 'line', 'minor_line'))
            )
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "railway", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'area'
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "shop", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("amenity" IS NULL OR "amenity" = 'no')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "telecom", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "telecom" NOT IN ('line'))
            )
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "tourism", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("information" IS NULL OR "information" = 'no')
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "waterway", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'area'
            AND ("building" IS NULL OR "building" = 'no')
            AND z >= 10
        )
        AS raw_data, envelope env
        WHERE geom IS NOT NULL
      ) as tile
    UNION ALL
      SELECT ST_AsMVT(tile, 'line', 4096, 'geom') AS mvt FROM (
        SELECT {{COLUMN_NAMES}}, ST_AsMVTGeom(geom, env.env_geom, 4096, 64, true) AS geom
        FROM (
          SELECT *
          FROM "aerialway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('line', 'closed_way')
            AND ("highway" IS NULL OR "highway" = 'no')
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "aeroway", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'line'
              OR (geom_type = 'closed_way' AND "aeroway" IN ('jet_bridge', 'parking_position', 'runway', 'taxiway'))
            )
            AND ("highway" IS NULL OR "highway" = 'no')
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "barrier", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('line', 'closed_way')
            AND ("highway" IS NULL OR "highway" = 'no')
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "highway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('line', 'closed_way')
            AND (
              (z >= 4 AND ("highway" IN ('motorway', 'motorway_link') OR "expressway" = 'yes'))
              OR (z >= 6 AND ("highway" IN ('trunk', 'trunk_link')))
              OR (z >= 10 AND ("highway" IN ('primary', 'primary_link', 'unclassified')))
              OR (z >= 11 AND ("highway" IN ('secondary', 'secondary_link')))
              OR (z >= 12 AND ("highway" IN ('tertiary', 'tertiary_link', 'residential')))
              OR z >= 13
            )
        UNION ALL
          SELECT *
          FROM "man_made", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'line'
              OR (geom_type = 'closed_way' AND "man_made" IN ('breakwater', 'cutline', 'dyke', 'embankment', 'gantry', 'goods_conveyor', 'groyne', 'pier', 'pipeline'))
            )
            AND ("highway" IS NULL OR "highway" = 'no')
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "military", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'line'
              OR (geom_type = 'closed_way' AND "military" IN ('trench'))
            )
            AND ("highway" IS NULL OR "highway" = 'no')
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "natural", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'line'
              OR (geom_type = 'closed_way' AND "natural" IN ('cliff', 'coastline', 'gorge', 'ridge', 'strait', 'tree_row', 'valley'))
            )
            AND ("highway" IS NULL OR "highway" = 'no')
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "power", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'power'
              OR (geom_type = 'closed_way' AND "power" IN ('cable', 'line', 'minor_line'))
            )
            AND ("highway" IS NULL OR "highway" = 'no')
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "railway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('line', 'closed_way')
            AND ("highway" IS NULL OR "highway" = 'no')
            AND ("railway" NOT IN ('abandoned', 'razed', 'proposed'))
            AND (
              (z >= 4 AND ("railway" = 'rail' AND "usage" = 'main'))
              OR (z >= 8 AND ("railway" = 'rail' AND "usage" IN ('main', 'branch')))
              OR (z >= 10 AND ("service" IS NULL))
              OR z >= 13
            )
        UNION ALL
          SELECT *
          FROM "route", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('line', 'closed_way')
            AND ("highway" IS NULL OR "highway" = 'no')
            AND (
              (z >= 4 AND ("route" IN ('ferry')))
              OR z >= 13
            )
        UNION ALL
          SELECT *
          FROM "telecom", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'telecom'
              OR (geom_type = 'closed_way' AND "telecom" IN ('line'))
            )
            AND ("highway" IS NULL OR "highway" = 'no')
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "waterway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('line', 'closed_way')
            AND ("highway" IS NULL OR "highway" = 'no')
            AND (
              (z >= 6 AND ("waterway" = 'river'))
              OR z >= 10
            )
        )
        AS raw_data, envelope env
        WHERE geom IS NOT NULL
      ) as tile
    UNION ALL
      SELECT ST_AsMVT(tile, 'point', 4096, 'geom') AS mvt FROM (
        SELECT {{COLUMN_NAMES}}, ST_AsMVTGeom(ST_PointOnSurface(geom), env.env_geom, 4096, 64, true) AS geom
        FROM (
          SELECT *
          FROM "aerialway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area')
            AND z >= 15
        UNION ALL
          SELECT *
          FROM "aeroway", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type IN ('point', 'area')
              OR (geom_type = 'closed_way' AND "aeroway" NOT IN ('jet_bridge', 'parking_position', 'runway', 'taxiway'))
            )            
            AND z >= 12
            AND (z >= 15 OR ("aeroway" NOT IN ('gate', 'navigationaid', 'windsock')))
        UNION ALL
          SELECT *
          FROM "amenity", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND ("education" IS NULL OR "education" = 'no')
            AND ("healthcare" IS NULL OR "healthcare" = 'no')
            AND z >= 12
            AND (z >= 15 OR ("amenity" NOT IN ('bench', 'waste_basket')))
            AND (z >= 18 OR ("amenity" NOT IN ('parking_space')))
        UNION ALL
          SELECT *
          FROM "barrier", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area')
            AND z >= 15
        UNION ALL
          SELECT *
          FROM "club", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "craft", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "education", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "emergency", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND ("highway" IS NULL OR "highway" = 'no')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "healthcare", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "highway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area')
            AND z >= 15
        UNION ALL
          SELECT *
          FROM "historic", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "information", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 15
        UNION ALL
          SELECT *
          FROM "landuse", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "leisure", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 15
            AND (z >= 12 OR "leisure" NOT IN ('picnic_table'))
        UNION ALL
          SELECT *
          FROM "man_made", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type IN ('point', 'area')
              OR (geom_type = 'closed_way' AND "man_made" NOT IN ('breakwater', 'cutline', 'dyke', 'embankment', 'gantry', 'goods_conveyor', 'groyne', 'pier', 'pipeline'))
            )            
            AND z >= 15
            AND (z >= 12 OR "man_made" NOT IN ('flagpole', 'manhole', 'utility_pole'))
        UNION ALL
          SELECT *
          FROM "military", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type IN ('point', 'area')
              OR (geom_type = 'closed_way' AND "military" NOT IN ('trench'))
            )            
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "natural", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type IN ('point', 'area')
              OR (geom_type = 'closed_way' AND "natural" NOT IN ('cliff', 'coastline', 'gorge', 'ridge', 'strait', 'tree_row', 'valley'))
            )
            AND z >= 15
            AND (z >= 12 OR "natural" NOT IN ('rock', 'shrub', 'stone', 'termite_mound', 'tree', 'tree_stump'))
        UNION ALL
          SELECT *
          FROM "office", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "power", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type IN ('point', 'area')
              OR (geom_type = 'closed_way' AND "power" NOT IN ('cable', 'line', 'minor_line'))
            )
            AND z >= 15
        UNION ALL
          SELECT *
          FROM "railway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area')
            AND z >= 15
        UNION ALL
          SELECT *
          FROM "shop", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND ("amenity" IS NULL OR "amenity" = 'no')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "telecom", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type IN ('point', 'area')
              OR (geom_type = 'closed_way' AND "telecom" NOT IN ('line'))
            )
            AND z >= 15
        UNION ALL
          SELECT *
          FROM "tourism", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND ("information" IS NULL OR "information" = 'no')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "waterway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area')
            AND z >= 12
        )
        AS raw_data, envelope env
        WHERE geom IS NOT NULL
      ) as tile
  )
  SELECT string_agg(mvt, ''::bytea) FROM tiles;
$$;

DO $do$ BEGIN
    EXECUTE 'COMMENT ON FUNCTION function_get_rustic_tile IS $tj$' || $$
    {
        "description": "Delightfully unrefined OpenStreetMap tiles",
        "attribution": "© OpenStreetMap",
        "vector_layers": [
          {
            "id": "area",
            "fields": {{{FIELD_DEFS}}}
          },
          {
            "id": "line",
            "fields": {{{FIELD_DEFS}}}
          },
          {
            "id": "point",
            "fields": {{{FIELD_DEFS}}}
          }
        ]
    }
    $$::json || '$tj$';
END $do$;

/*
advertising
attraction
boundary
golf
place
playground
public_transport
*/