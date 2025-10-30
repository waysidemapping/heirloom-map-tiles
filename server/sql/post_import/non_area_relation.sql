
WITH to_update AS (
  SELECT
    id,
    ST_ClosestPoint(geom, ST_Centroid(bbox)) AS centerpoint
  FROM non_area_relation
  WHERE bbox_centerpoint_on_surface IS NULL
)
UPDATE non_area_relation r
SET
  bbox_centerpoint_on_surface = centerpoint,
  bbox_centerpoint_on_surface_z26_tile_x = floor((ST_X(centerpoint) + 20037508.3427892) / (40075016.6855784 / (1 << 26))),
  bbox_centerpoint_on_surface_z26_tile_y = floor((20037508.3427892 - ST_Y(centerpoint)) / (40075016.6855784 / (1 << 26)))
FROM to_update u
WHERE r.id = u.id;
