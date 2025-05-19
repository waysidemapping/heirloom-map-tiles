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
        ST_Area(env_geom) AS env_area,
        (ST_XMax(env_geom) - ST_XMin(env_geom)) AS env_width,
        (ST_YMax(env_geom) - ST_YMin(env_geom)) AS env_height,

        ST_XMax(env_geom) AS rightX,
        ST_XMin(env_geom) AS leftX,
        ST_YMax(env_geom) AS topY,
        ST_YMin(env_geom) AS bottomY,

        ST_SetSRID(ST_Point(ST_XMin(env_geom), ST_YMax(env_geom)), 3857) AS topLeft,
        ST_SetSRID(ST_Point(ST_XMax(env_geom), ST_YMax(env_geom)), 3857) AS topRight,
        ST_SetSRID(ST_Point(ST_XMin(env_geom), ST_YMin(env_geom)), 3857) AS bottomLeft,
        ST_SetSRID(ST_Point(ST_XMax(env_geom), ST_YMin(env_geom)), 3857) AS bottomRight
      FROM raw_envelope
    ),
    tiles AS (
      SELECT ST_AsMVT(tile, 'area', 4096, 'geom') AS mvt FROM (
        SELECT {{COLUMN_NAMES_FOR_COASTLINE}}, ST_AsMVTGeom(geom, env.env_geom, 4096, 64, true) AS geom
        FROM (
          WITH
          coastlines AS (
            SELECT ST_Intersection(geom, env.env_geom) AS geom
            FROM "coastline", envelope env
            WHERE geom && env.env_geom
              AND ("area_3857" = 0 OR "area_3857" > env.env_area * 0.000005)
          ),
          merged_lines AS (
            SELECT ST_Multi(ST_LineMerge(ST_Collect(geom))) AS geom
            FROM coastlines
          ),
          segments AS (
            SELECT (ST_Dump(geom)).geom AS geom
            FROM merged_lines
          ),
          open_segments AS (
            SELECT geom,
              ST_StartPoint(geom) AS startP,
              -- ST_X(ST_StartPoint(geom)) AS startX,
              -- ST_Y(ST_StartPoint(geom)) AS startY,
              ST_EndPoint(geom) AS endP
              -- ST_X(ST_EndPoint(geom)) AS endX,
              -- ST_Y(ST_EndPoint(geom)) AS endY
            FROM segments
            WHERE NOT ST_IsClosed(geom)
          ),
          terminus_points AS (
            SELECT startP AS p, ST_X(startP) AS x, ST_Y(startP) AS y, 'start' AS placement
            FROM open_segments
            UNION ALL
            SELECT endP AS p, ST_X(endP) AS x, ST_Y(endP) AS y, 'end' AS placement
            FROM open_segments
          ),
          -- order the points in clockwise order around the sides of the tile
          ordered_terminus_points AS (
            SELECT *, ROW_NUMBER() OVER (
            ORDER BY
              CASE 
                WHEN x = leftX THEN
                  (y - bottomY) / env_width
                WHEN y = topY THEN
                  1 + (x - leftX) / env_height
                WHEN x = rightX THEN
                  2 + (1 - (y - bottomY) / env_width)
                ELSE -- assume y = bottomY
                  3 + (1 - (x - leftX) / env_height)
              END
            ) AS rn
            FROM terminus_points, envelope env
          ),
          should_bump AS (
            SELECT COUNT(*) AS flag FROM ordered_terminus_points WHERE rn = 1 AND placement = 'start'
          ),
          terminus_points_row_count AS (
            SELECT COUNT(*) AS numrows FROM ordered_terminus_points
          ),
          -- if the first point is a start point, bump everything up by one so the first point is an endpoint
          ordered_terminus_points_w_an_endpoint_first AS (
            SELECT p, x, y,
              CASE
                WHEN should_bump.flag = 1 THEN
                  CASE
                    WHEN rn = terminus_points_row_count.numrows THEN 1
                    ELSE rn + 1
                  END
                ELSE
                  rn
              END AS rn
            FROM ordered_terminus_points, should_bump, terminus_points_row_count
          ),
          paired_terminus_points AS (
            SELECT t1.p as endP, t2.p as startP, t1.x as endX, t2.x as startX, t1.y as endY, t2.y as startY
            FROM ordered_terminus_points_w_an_endpoint_first t1
            JOIN ordered_terminus_points_w_an_endpoint_first t2 ON t2.rn = t1.rn + 1
            WHERE t1.rn % 2 = 1
          ),
          manual_segment_info AS (
            SELECT
              CASE
                WHEN startX = leftX THEN
                  CASE
                    WHEN endX = leftX THEN
                      CASE
                        WHEN endY < startY THEN
                          ARRAY[endP, startP]
                        ELSE -- endY > startY
                          ARRAY[endP, topLeft, topRight, bottomRight, bottomLeft, startP]
                      END
                    WHEN endX = rightX THEN
                      ARRAY[endP, bottomRight, bottomLeft, startP]
                    WHEN endY = bottomY THEN
                      ARRAY[endP, bottomLeft, startP]
                    WHEN endY = topY THEN
                      ARRAY[endP, topRight, bottomRight, bottomLeft, startP]
                    ELSE NULL
                  END
                WHEN startX = rightX THEN
                  CASE
                    WHEN endX = leftX THEN
                      ARRAY[endP, topLeft, topRight, startP]
                    WHEN endX = rightX THEN
                      CASE
                        WHEN endY < startY THEN
                          ARRAY[endP, bottomRight, bottomLeft, topLeft, topRight, startP]
                        ELSE -- endY > startY
                          ARRAY[endP, startP]
                      END
                    WHEN endY = bottomY THEN
                      ARRAY[endP, bottomLeft, topLeft, topRight, startP]
                    WHEN endY = topY THEN
                      ARRAY[endP, topRight, startP]
                    ELSE NULL
                  END
                WHEN startY = bottomY THEN
                  CASE
                    WHEN endX = leftX THEN
                      ARRAY[endP, topLeft, topRight, bottomRight, startP]
                    WHEN endX = rightX THEN
                      ARRAY[endP, bottomRight, startP]
                    WHEN endY = bottomY THEN
                      CASE
                        WHEN endX < startX THEN
                          ARRAY[endP, bottomLeft, topLeft, topRight, bottomRight, startP]
                        ELSE -- endX > startX
                          ARRAY[endP, startP]
                      END
                    WHEN endY = topY THEN
                      ARRAY[endP, topRight, bottomRight, startP]
                    ELSE NULL
                  END
                WHEN startY = topY THEN
                  CASE
                    WHEN endX = leftX THEN
                      ARRAY[endP, topLeft, startP]
                    WHEN endX = rightX THEN
                      ARRAY[endP, bottomRight, bottomLeft, topLeft, startP]
                    WHEN endY = bottomY THEN
                      ARRAY[endP, bottomLeft, topLeft, startP]
                    WHEN endY = topY THEN
                      CASE
                      WHEN endX < startX THEN
                        ARRAY[endP, startP]
                      ELSE -- endX > startX
                        ARRAY[endP, topRight, bottomRight, bottomLeft, topLeft, startP]
                      END
                    ELSE NULL
                  END
                ELSE NULL
              END AS segment_points_array
            FROM paired_terminus_points, envelope env
          ),
          wireframe_lines AS (
            SELECT
              ST_MakeLine(
                segment_points_array
              ) AS geom
            FROM manual_segment_info
            WHERE segment_points_array IS NOT NULL
            UNION ALL
            SELECT geom FROM open_segments
          ),
          built_lines AS (
            SELECT (ST_Dump(ST_Multi(ST_LineMerge(ST_Multi(ST_Collect(geom)))))).geom AS geom
            FROM wireframe_lines
          ),
          all_lines AS (
              SELECT geom
              FROM built_lines
              WHERE ST_IsClosed(geom)
            UNION ALL 
              SELECT geom
              FROM segments
              WHERE ST_IsClosed(geom)
          )
          SELECT ST_Collect(ST_MakePolygon(geom)) AS geom
          FROM all_lines
        ), envelope env
        WHERE geom IS NOT NULL
        UNION ALL
        SELECT {{COLUMN_NAMES}}, ST_AsMVTGeom(geom, env.env_geom, 4096, 64, true) AS geom
        FROM (
          SELECT *
          FROM "aerialway", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'area'
            AND "public_transport" IS NULL 
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "aeroway", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "aeroway" NOT IN ('jet_bridge', 'parking_position', 'runway', 'taxiway'))
            )
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "advertising", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "amenity", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND "education" IS NULL
            AND "healthcare" IS NULL
            AND "public_transport" IS NULL 
            AND z >= 10
            AND (z >= 18 OR ("amenity" NOT IN ('parking_space')))
        UNION ALL
          SELECT *
          FROM "area:highway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 18
        UNION ALL
          SELECT *
          FROM "barrier", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'area'
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "building", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND ("area_3857" = 0 OR "area_3857" > env.env_area * 0.000001)
            AND z >= 14
        UNION ALL
          SELECT *
          FROM "building:part", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 18
        UNION ALL
          SELECT *
          FROM "club", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "craft", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "education", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "emergency", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "golf", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND "landuse" IS NULL
            AND "natural" IS NULL
            AND z >= 15
        UNION ALL
          SELECT *
          FROM "healthcare", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "highway", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'area'
            AND "amenity" IS NULL
            AND "building" IS NULL
            AND "public_transport" IS NULL 
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "historic", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "indoor", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "indoor" NOT IN ('wall'))
            )
            AND z >= 18
        UNION ALL
          SELECT *
          FROM "information", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "landuse", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND "area_3857" > env.env_area * 0.000001
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "leisure", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "man_made", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "man_made" NOT IN ('breakwater', 'cutline', 'dyke', 'embankment', 'gantry', 'goods_conveyor', 'groyne', 'pier', 'pipeline'))
            )
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "military", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "natural", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "natural" NOT IN ('cliff', 'gorge', 'ridge', 'strait', 'tree_row', 'valley'))
            )
            AND "area_3857" > env.env_area * 0.000001
            AND "building" IS NULL
            AND "natural" NOT IN ('bay', 'peninsula')
            AND (
              (z >= 0 AND "natural" = 'water')
              OR z >= 10
            )
        UNION ALL
          SELECT *
          FROM "office", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "playground", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND "leisure" IS NULL
            AND z >= 18
        UNION ALL
          SELECT *
          FROM "power", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "power" NOT IN ('cable', 'line', 'minor_line'))
            )
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "public_transport", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "railway", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'area'
            AND "building" IS NULL
            AND "public_transport" IS NULL 
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "shop", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "amenity" IS NULL
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "telecom", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'area'
              OR (geom_type = 'closed_way' AND "telecom" NOT IN ('line'))
            )
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "tourism", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('area', 'closed_way')
            AND "information" IS NULL
            AND "building" IS NULL
            AND z >= 10
        UNION ALL
          SELECT *
          FROM "waterway", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'area'
            AND "building" IS NULL
            AND z >= 10
        ), envelope env
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
            AND "highway" IS NULL 
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "aeroway", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'line'
              OR (geom_type = 'closed_way' AND "aeroway" IN ('jet_bridge', 'parking_position', 'runway', 'taxiway'))
            )
            AND "highway" IS NULL 
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "barrier", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('line', 'closed_way')
            AND "highway" IS NULL 
            AND z >= 13
        
        UNION ALL
          SELECT *
          FROM "golf", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'line'
            AND "highway" IS NULL 
            AND z >= 15
        UNION ALL
          SELECT *
          FROM "highway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('line', 'closed_way')
            AND (
              (z >= 4 AND ("highway" IN ('motorway') OR "expressway" = 'yes'))
              OR (z >= 6 AND ("highway" IN ('trunk')))
              OR (z >= 10 AND ("highway" IN ('motorway_link', 'primary', 'primary_link', 'trunk_link')))
              OR (z >= 11 AND ("highway" IN ('secondary', 'secondary_link')))
              OR (z >= 12 AND ("highway" IN ('tertiary', 'tertiary_link', 'residential', 'unclassified')))
              OR z >= 13
            )
            AND (z >= 15 OR "highway" != "footway" OR "footway" IS NULL)
        UNION ALL
          SELECT *
          FROM "historic", envelope env
          WHERE geom && env.env_geom
            AND geom_type = 'line'
            AND "highway" IS NULL 
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "indoor", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'line'
              OR (geom_type = 'closed_way' AND "indoor" IN ('wall'))
            )
            AND z >= 18
        UNION ALL
          SELECT *
          FROM "man_made", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'line'
              OR (geom_type = 'closed_way' AND "man_made" IN ('breakwater', 'cutline', 'dyke', 'embankment', 'gantry', 'goods_conveyor', 'groyne', 'pier', 'pipeline'))
            )
            AND "highway" IS NULL 
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "natural", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'line'
              OR (geom_type = 'closed_way' AND "natural" IN ('cliff', 'gorge', 'ridge', 'strait', 'tree_row', 'valley'))
            )
            AND "highway" IS NULL 
            AND "natural" NOT IN ('bay', 'peninsula')
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "power", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'line'
              OR (geom_type = 'closed_way' AND "power" IN ('cable', 'line', 'minor_line'))
            )
            AND "highway" IS NULL 
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "railway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('line', 'closed_way')
            AND "highway" IS NULL 
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
            AND "highway" IS NULL 
            AND (
              (z >= 4 AND ("route" IN ('ferry')))
              OR z >= 13
            )
        UNION ALL
          SELECT *
          FROM "telecom", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type = 'line'
              OR (geom_type = 'closed_way' AND "telecom" IN ('line'))
            )
            AND "highway" IS NULL 
            AND z >= 13
        UNION ALL
          SELECT *
          FROM "waterway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('line', 'closed_way')
            AND "highway" IS NULL 
            AND (
              (z >= 6 AND ("waterway" = 'river'))
              OR z >= 10
            )
        ), envelope env
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
          FROM "advertising", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "amenity", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND "education" IS NULL
            AND "healthcare" IS NULL
            AND "public_transport" IS NULL 
            AND z >= 12
            -- small stuff that may be associated with a larger facility
            AND (z >= 14 OR ("amenity" NOT IN ('atm', 'bbq', 'bicycle_parking', 'drinking_water', 'fountain', 'parcel_locker', 'post_box', 'public_bookcase', 'telephone', 'ticket_validator', 'toilets', 'shower', 'vending_machine', 'waste_disposal')))
            -- smaller stuff
            AND (z >= 15 OR ("amenity" NOT IN ('bench', 'letter_box', 'lounger', 'recycling', 'waste_basket')))
            -- micromapped stuff
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
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "golf", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 15
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
            AND "amenity" IS NULL
            AND "public_transport" IS NULL
            AND z >= 15
        UNION ALL
          SELECT *
          FROM "historic", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "indoor", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type IN ('point', 'area')
              OR (geom_type = 'closed_way' AND "indoor" NOT IN ('wall'))
            )
            AND z >= 18
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
            AND z >= 12
            AND (z >= 15 OR "leisure" NOT IN ('firepit', 'picnic_table', 'sauna'))
        UNION ALL
          SELECT *
          FROM "man_made", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type IN ('point', 'area')
              OR (geom_type = 'closed_way' AND "man_made" NOT IN ('breakwater', 'cutline', 'dyke', 'embankment', 'gantry', 'goods_conveyor', 'groyne', 'pier', 'pipeline'))
            )            
            AND z >= 12
            AND (z >= 15 OR "man_made" NOT IN ('flagpole', 'manhole', 'utility_pole'))
        UNION ALL
          SELECT *
          FROM "military", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')           
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "natural", envelope env
          WHERE geom && env.env_geom
            AND (
              geom_type IN ('point', 'area')
              OR (geom_type = 'closed_way' AND "natural" NOT IN ('cliff', 'gorge', 'ridge', 'strait', 'tree_row', 'valley'))
            )
            AND z >= 12
            AND (z >= 15 OR "natural" NOT IN ('rock', 'shrub', 'stone', 'termite_mound', 'tree', 'tree_stump'))
        UNION ALL
          SELECT *
          FROM "office", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "place", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND (
              (
                "population" ~ '^\d+$'
                AND (z >= 4 AND ("capital" IN ('2', '4') OR "population"::integer > 1000000))
                OR (z >= 8 AND ("capital" IN ('6')))
              )
              OR z >= 13
            )
        UNION ALL
          SELECT *
          FROM "playground", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND "leisure" IS NULL
            AND z >= 18
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
          FROM "public_transport", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "railway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area')
            AND "public_transport" IS NULL 
            AND z >= 15
        UNION ALL
          SELECT *
          FROM "shop", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area', 'closed_way')
            AND "amenity" IS NULL
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
            AND "information" IS NULL
            AND z >= 12
        UNION ALL
          SELECT *
          FROM "waterway", envelope env
          WHERE geom && env.env_geom
            AND geom_type IN ('point', 'area')
            AND z >= 12
        ), envelope env
        WHERE geom IS NOT NULL
      ) as tile
  )
  SELECT string_agg(mvt, ''::bytea) FROM tiles;
$$;

COMMENT ON FUNCTION function_get_rustic_tile IS
$$
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
$$;
