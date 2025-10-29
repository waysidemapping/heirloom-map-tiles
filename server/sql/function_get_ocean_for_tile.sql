--
-- © 2025 Quincy Morgan
-- Licensed MIT: https://github.com/waysidemapping/heirloom-map-tiles/blob/main/LICENSE.md
--
-- # function_get_ocean_for_tile
--
-- ## What you get
--
-- This function returns a multipolygon representing the area of ocean in the tile given at
-- `z`/`x`/`y`, or null if the area contains no ocean. The output is suitable for rendering
-- the ocean with a fill but not with an outline since the shape may contain the tile edges.
-- 
-- This is done per-tile with no global preprocessing. Thus, it's compatible with databases
-- receiving frequent updates.
--
-- ## Prerequisites
--
-- This function requires the existence of a table `coastline` with two columns:
-- * `geom`, gist-indexed: linestring geometry of the coastline in projected coordinates (EPSG 3857)
-- * `area_3857`, btree-indexed: computed projected area of the coastlines if it's closed, else null
--
-- We're assuming the coastlines are in OpenStreetMap format: https://wiki.openstreetmap.org/wiki/Tag:natural%3Dcoastline
-- * Coastlines are mapped as ways bounding the ocean on their right side (winding counterclockwise).
-- * All ways must be connected by their endpoints without gaps to fully inscribe continents and islands.
-- * No coastlines should be wound clockwise, i.e. the ocean has no "outer" rings
--
-- ## How it works
-- 
-- Using the above assumptions:
-- * If the tile overlaps coastlines, clip them to the tile and add the missing segments 
--   along edges of the tile to fully enclosed the required area.
-- * If the tile fully inscribes islands, pass them through and add the tile envelope as an outer ring.
-- * If the tile contains no coastlines, get all the coastline segments south of the tile:
--     * If the northernmost segment is running east-to-west then we're in the ocean, return the tile envelope.
--     * Else we're on land, return null.
--
-- ## Caveats
-- 
-- * If your database contains incomplete data, certain tiles containing no coastlines will not render correctly.
-- 
-- 

CREATE OR REPLACE FUNCTION function_get_ocean_for_tile(_z integer, _x integer, _y integer)
RETURNS TABLE (_geom geometry(multipolygon, 3857))
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  DECLARE
    env_geom geometry;
    min_area double precision;
    leftX double precision;
    rightX double precision;
    bottomY double precision;
    topY double precision;
    topLeft geometry;
    topRight geometry;
    bottomLeft geometry;
    bottomRight geometry;
    env_width double precision;
    env_height double precision;
    simplify_tolerance double precision;
    tile_to_antarctica_bbox geometry;
  BEGIN
    env_geom := ST_TileEnvelope(_z, _x, _y);
    min_area := ST_Area(env_geom) * 0.00001;

    leftX := ST_XMin(env_geom);
    rightX := ST_XMax(env_geom);
    bottomY := ST_YMin(env_geom);
    topY := ST_YMax(env_geom);

    topLeft := ST_SetSRID(ST_Point(leftX, topY), 3857);
    topRight := ST_SetSRID(ST_Point(rightX, topY), 3857);
    bottomLeft := ST_SetSRID(ST_Point(leftX, bottomY), 3857);
    bottomRight := ST_SetSRID(ST_Point(rightX, bottomY), 3857);

    env_width := rightX - leftX;
    env_height := topY - bottomY;
    simplify_tolerance := env_width / 4096 * 2;

    -- A VERY skinny bounding box stretching from the bottom left corner of the tile
    -- to the interior of Antarctica (roughly -85° Lat), expected to be south of all valid coastline features
    tile_to_antarctica_bbox := ST_MakeEnvelope(leftX, -20000000, leftX + 0.000000001, bottomY, 3857);

    RETURN QUERY
    WITH
    -- First, we fetch all the coastlines in the tile and clip them to the bounds of the tile.
    coastline_raw AS (
      SELECT ST_Intersection(geom, env_geom) AS geom
      FROM coastline
      WHERE geom && env_geom
        -- Ignore very small islands. This will not work if the island is mapped using more than one way.
        AND (area_3857 IS NULL OR area_3857 > min_area)
    ),
    -- Create continuous coastline segments by merging the linestrings together based on their endpoints.
    coastline_merged_segments AS (
      SELECT (ST_Dump(ST_Multi(ST_Simplify(ST_LineMerge(ST_Collect(geom)), simplify_tolerance, true)))).geom AS geom
      FROM coastline_raw
      GROUP BY simplify_tolerance
    ),
    -- Fetch only the unclosed linestrings. We need to manually close them in order for the
    -- ocean fill to render correctly in the client. We can take advantage of the fact that
    -- the startpoints and endpoints of the open segments are guaranteed to lay exactly on the
    -- edge of the tile.
    coastline_open_segments AS (
      SELECT geom,
        ST_StartPoint(geom) AS startP,
        ST_EndPoint(geom) AS endP
      FROM coastline_merged_segments
      WHERE NOT ST_IsClosed(geom)
    ),
    -- We'll close the open segments by matching every endpoint with a startpoint and adding a
    -- path between them along the perimeter of the tile. Each pair of terminus points may not
    -- necessary belong to the same open segment.
    --
    -- We'll start by creating a single table containing all the startpoints and endpoints of the open segments.
    coastline_open_segment_terminus_points AS (
      SELECT startP AS p, ST_X(startP) AS x, ST_Y(startP) AS y, 'start' AS placement
      FROM coastline_open_segments
      UNION ALL
      SELECT endP AS p, ST_X(endP) AS x, ST_Y(endP) AS y, 'end' AS placement
      FROM coastline_open_segments
    ),
    -- Order the points in clockwise order around the sides of the tile starting at the bottom left corner.
    coastline_open_segment_terminus_points_ordered AS (
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
      FROM coastline_open_segment_terminus_points
    ),
    -- Determine if the first point is a startpoint.
    coastline_open_segment_terminus_points_ordered_is_first_start AS (
      SELECT COUNT(*) AS flag FROM coastline_open_segment_terminus_points_ordered WHERE rn = 1 AND placement = 'start'
    ),
    -- Get the number of points in the table.
    coastline_open_segment_terminus_points_ordered_row_count AS (
      SELECT COUNT(*) AS numrows FROM coastline_open_segment_terminus_points_ordered
    ),
    -- We want the points to be in (endpoint, startpoint) order, so if the first point is a startpoint,
    -- bump everything up by one so the first point is an endpoint.
    coastline_open_segment_terminus_points_ordered_w_first_end AS (
      SELECT p, x, y,
        CASE
          WHEN coastline_open_segment_terminus_points_ordered_is_first_start.flag = 1 THEN
            CASE
              WHEN rn = coastline_open_segment_terminus_points_ordered_row_count.numrows THEN 1
              ELSE rn + 1
            END
          ELSE
            rn
        END AS rn
      FROM coastline_open_segment_terminus_points_ordered,
        coastline_open_segment_terminus_points_ordered_is_first_start,
        coastline_open_segment_terminus_points_ordered_row_count
    ),
    -- Create a single table with one row per (endpoint, startpoint) pair.
    coastline_open_segment_terminus_points_paired AS (
      SELECT t1.p as endP, t2.p as startP, t1.x as endX, t2.x as startX, t1.y as endY, t2.y as startY
      FROM coastline_open_segment_terminus_points_ordered_w_first_end t1
      JOIN coastline_open_segment_terminus_points_ordered_w_first_end t2 ON t2.rn = t1.rn + 1
      WHERE mod(t1.rn, 2) = 1
    ),
    -- Calculate the array of points needed to connect the endpoint with the startpoint
    -- along the perimeter of the tile based on their relative positions. This could be
    -- as simple as [endpoint, startpoint], or we might need incorporate the corners of
    -- the tile.
    coastline_open_segment_closure_point_arrays AS (
      SELECT
        CASE
          WHEN startX = leftX THEN
            CASE
              WHEN endX = leftX THEN
                CASE
                  WHEN endY < startY THEN
                    --   ■             ■
                    --                 
                    --   S             
                    --   ↑             
                    --   E             
                    --                 
                    --   ■             ■
                    ARRAY[endP, startP]                  
                  ELSE -- endY > startY
                    --   ■ → → → → → → ■
                    --   ↑             ↓
                    --   E             ↓
                    --                 ↓
                    --   S             ↓
                    --   ↑             ↓
                    --   ■ ← ← ← ← ← ← ■
                    ARRAY[endP, topLeft, topRight, bottomRight, bottomLeft, startP]
                END
              WHEN endX = rightX THEN
                --   ■             ■
                --                 
                --   S             E
                --   ↑             ↓
                --   ↑             ↓
                --   ■ ← ← ← ← ← ← ■
                ARRAY[endP, bottomRight, bottomLeft, startP]
              WHEN endY = bottomY THEN
                --   ■             ■
                --                 
                --   S             
                --   ↑              
                --   ↑              
                --   ■ ← ← E       ■
                ARRAY[endP, bottomLeft, startP]
              WHEN endY = topY THEN
                --   ■       E → → ■
                --                 ↓
                --                 ↓
                --                 ↓
                --   S             ↓
                --   ↑             ↓
                --   ■ ← ← ← ← ← ← ■
                ARRAY[endP, topRight, bottomRight, bottomLeft, startP]
              ELSE NULL
            END
          WHEN startX = rightX THEN
            CASE
              WHEN endX = leftX THEN
                --   ■ → → → → → → ■
                --   ↑             ↓
                --   ↑             ↓
                --   E             S
                --                 
                --                  
                --   ■             ■
                ARRAY[endP, topLeft, topRight, startP]
              WHEN endX = rightX THEN
                CASE
                  WHEN endY < startY THEN
                    --   ■ → → → → → → ■
                    --   ↑             ↓
                    --   ↑             S
                    --   ↑              
                    --   ↑             E
                    --   ↑             ↓
                    --   ■ ← ← ← ← ← ← ■
                    ARRAY[endP, bottomRight, bottomLeft, topLeft, topRight, startP]
                  ELSE -- endY > startY
                    --   ■             ■
                    --                 
                    --                 E             
                    --                 ↓             
                    --                 S            
                    --                 
                    --   ■             ■
                    ARRAY[endP, startP]
                END
              WHEN endY = bottomY THEN
                --   ■ → → → → → → ■
                --   ↑             ↓
                --   ↑             ↓
                --   ↑             S
                --   ↑             
                --   ↑              
                --   ■ ← ← E       ■
                ARRAY[endP, bottomLeft, topLeft, topRight, startP]
              WHEN endY = topY THEN
                --   ■       E → → ■
                --                 ↓
                --                 ↓
                --                 S
                --                 
                --                  
                --   ■             ■
                ARRAY[endP, topRight, startP]
              ELSE NULL
            END
          WHEN startY = bottomY THEN
            CASE
              WHEN endX = leftX THEN
                --   ■ → → → → → → ■
                --   ↑             ↓
                --   ↑             ↓
                --   E             ↓
                --                 ↓
                --                 ↓
                --   ■       S ← ← ■
                ARRAY[endP, topLeft, topRight, bottomRight, startP]
              WHEN endX = rightX THEN
                --   ■             ■
                --   
                --    
                --                 E
                --                 ↓
                --                 ↓
                --   ■       S ← ← ■
                ARRAY[endP, bottomRight, startP]
              WHEN endY = bottomY THEN
                CASE
                  WHEN endX < startX THEN
                    --   ■ → → → → → → ■
                    --   ↑             ↓
                    --   ↑             ↓
                    --   ↑             ↓
                    --   ↑             ↓
                    --   ↑             ↓
                    --   ■ ← E     S ← ■
                    ARRAY[endP, bottomLeft, topLeft, topRight, bottomRight, startP]
                  ELSE -- endX > startX
                    --   ■             ■
                    --                  
                    --                  
                    --                  
                    --                 
                    --                  
                    --   ■   S ← ← E   ■
                    ARRAY[endP, startP]
                END
              WHEN endY = topY THEN
                --   ■       E → → ■
                --                 ↓
                --                 ↓
                --                 ↓
                --                 ↓
                --                 ↓
                --   ■       S ← ← ■
                ARRAY[endP, topRight, bottomRight, startP]
              ELSE NULL
            END
          WHEN startY = topY THEN
            CASE
              WHEN endX = leftX THEN
                --   ■ → → S       ■
                --   ↑              
                --   ↑              
                --   E             
                --   
                --   
                --   ■             ■
                ARRAY[endP, topLeft, startP]
              WHEN endX = rightX THEN
                --   ■ → → S       ■
                --   ↑              
                --   ↑              
                --   ↑             E
                --   ↑             ↓
                --   ↑             ↓
                --   ■ ← ← ← ← ← ← ■
                ARRAY[endP, bottomRight, bottomLeft, topLeft, startP]
              WHEN endY = bottomY THEN
                --   ■ → → S       ■
                --   ↑              
                --   ↑              
                --   ↑             
                --   ↑              
                --   ↑              
                --   ■ ← ← E       ■
                ARRAY[endP, bottomLeft, topLeft, startP]
              WHEN endY = topY THEN
                CASE
                WHEN endX < startX THEN
                  --   ■   E → → S   ■
                  --                  
                  --                  
                  --                  
                  --                  
                  --                  
                  --   ■             ■
                  ARRAY[endP, startP]
                ELSE -- endX > startX
                  --   ■ → S     E → ■
                  --   ↑             ↓
                  --   ↑             ↓
                  --   ↑             ↓
                  --   ↑             ↓
                  --   ↑             ↓
                  --   ■ ← ← ← ← ← ← ■
                  ARRAY[endP, topRight, bottomRight, bottomLeft, topLeft, startP]
                END
              ELSE NULL
            END
          ELSE NULL
        END AS points_array
      FROM coastline_open_segment_terminus_points_paired
    ),
    -- Build a single table of linestrings containing the the open segments and the connecting points built into lines.
    coastline_open_segments_and_closure_lines AS (
        SELECT
          ST_MakeLine(
            points_array
          ) AS geom
        FROM coastline_open_segment_closure_point_arrays
        WHERE points_array IS NOT NULL
      UNION ALL
        SELECT geom FROM coastline_open_segments
    ),
    -- Connect the connecting lines and the open segments to form continuous closed linestrings.
    coastline_manually_closed_segments AS (
      SELECT (ST_Dump(ST_Multi(ST_LineMerge(ST_Multi(ST_Collect(geom)))))).geom AS geom
      FROM coastline_open_segments_and_closure_lines
    ),
    coastline_already_closed_segments AS (
      SELECT geom FROM coastline_merged_segments WHERE ST_IsClosed(geom) AND ST_NumPoints(geom) >=4
    ),
    -- Combine the segments we manually closed with those that were already closed (i.e. islands that
    -- are fully contained by the tile).
    coastline_all_closed_lines AS (
        SELECT geom FROM coastline_manually_closed_segments
        WHERE ST_IsClosed(geom) AND ST_NumPoints(geom) >=4
      UNION ALL
        SELECT geom FROM coastline_already_closed_segments
      UNION ALL
        -- If the tile fully contains at least one island, but doesn't have
        -- any coastline intesecting the edge of the tile, then we need to
        -- add the tile bounding box as an exterior ring
        SELECT ST_Boundary(env_geom) AS geom
        WHERE (SELECT count(geom) FROM coastline_open_segments) = 0
          AND (SELECT count(geom) FROM coastline_already_closed_segments LIMIT 1) > 0
    ),
    -- Turn the closed lines into polygons and collect them into a single multipolygon without
    -- doing any expensive geometry-based processing. This is our finished feature.
    ocean_multipolygon AS (
        SELECT ST_Collect(ST_MakePolygon(geom)) AS geom
        FROM coastline_all_closed_lines
    ),
    -- HOWEVER: If there are no coastlines in the tile then we need to look outside the tile
    -- to figure out if the tile should be rendered as ocean or land. We'll do this by
    -- fetching all the coastlines in the database between the tile and the interior of Antarctica,
    -- a point south of all valid coastline features. We can't go all the way to the south pole since
    -- we're dealing with Web Mercator coordinates which stretch infinitely south.
    --
    -- We'll use an extremely thin bounding box. Once we intersect and merge the coastlines in this box,
    -- we can assume we have a table containing east-west segments.
    coastlines_between_tile_and_antarctica AS (
      SELECT (ST_Dump(ST_Multi(ST_LineMerge(ST_Collect(ST_Intersection(geom, tile_to_antarctica_bbox)))))).geom AS geom
      FROM coastline
      WHERE geom && tile_to_antarctica_bbox
    ),
    -- Fetch the northmost coastline segment that's south of the tile bounds.
    -- This is all we need to tell if we're in the ocean or not.
    northermost_coastline_under_tile AS (
      SELECT * FROM coastlines_between_tile_and_antarctica
      ORDER BY ST_Y(ST_StartPoint(geom)) DESC
      LIMIT 1
    ),
    -- If there is no segment south of the tile then we're in Antactica (land). Otherwise,
    -- if the segment's end point is east of its start point then we're in the ocean.
    --
    -- If we're dealing with an extract and not the full planet then this will only work
    -- on ocean tiles north of coastlines. However, it will err on the side of caution
    -- by rendering land in the ocean rather than ocean on land.
    blank_tile_is_ocean AS (
      SELECT count(geom) = 1 AS flag FROM northermost_coastline_under_tile
      WHERE ST_X(ST_EndPoint(geom)) < ST_X(ST_StartPoint(geom))
    )
    SELECT
      CASE
        -- If there are coastlines in the tile then use our computed multipolygon
        WHEN (SELECT count(geom) FROM coastline_all_closed_lines LIMIT 1) > 0 THEN
          geom
        ELSE
          -- Use a case to try and avoid computing the blank ocean logic if we don't need to
          CASE
            -- If we're dealing with the full planet data then we could simply do:
            --   MOD((SELECT count(geom) FROM coastlines_between_tile_and_antarctica), 2) = 1
            -- but this will not always work with extracts, so use this safer option.
            WHEN (SELECT flag FROM blank_tile_is_ocean) THEN
              -- If we're in the ocean then just return the tile's bounding box
              ST_Multi(env_geom)
            ELSE
              NULL
          END
      END AS _geom
      FROM ocean_multipolygon
    ;
  END;
$$
SET plan_cache_mode = force_custom_plan;
