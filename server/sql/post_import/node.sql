
UPDATE node
SET z26_tile_x = floor((ST_X(geom) + 20037508.3427892) / (40075016.6855784 / (1 << 26))),
    z26_tile_y = floor((20037508.3427892 - ST_Y(geom)) / (40075016.6855784 / (1 << 26)))
WHERE z26_tile_x IS NULL;
