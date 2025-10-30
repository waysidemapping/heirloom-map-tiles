
WITH to_update AS (
  SELECT
    r.id,
    COALESCE(n.geom, ST_PointOnSurface(r.geom)) AS centerpoint
  FROM area_relation r
  LEFT JOIN node n ON n.id = r.label_node_id
  WHERE r.label_point IS NULL
)
UPDATE area_relation r
SET
  label_point = centerpoint,
  label_point_z26_tile_x = floor((ST_X(centerpoint) + 20037508.3427892) / (40075016.6855784 / (1 << 26))),
  label_point_z26_tile_y = floor((20037508.3427892 - ST_Y(centerpoint)) / (40075016.6855784 / (1 << 26)))
FROM to_update u
WHERE r.id = u.id;
