local node_table = osm2pgsql.define_table({
    name = 'node',
    ids = { type = 'node', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'jsonb', not_null = true },
        { column = 'geom', type = 'point', proj = '3857', not_null = true },
        { column = 'z26_x', type = 'int', not_null = true },
        { column = 'z26_y', type = 'int', not_null = true }
    },
    indexes = {
        { column = 'tags', method = 'gin' },
        { column = 'geom', method = 'gist' },
        { column = {'z26_x', 'z26_y'}, method = 'btree' }
    }
})

-- Contains all ways (needed to select relation members)
local way_table = osm2pgsql.define_table({
    name = 'way',
    ids = { type = 'way', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'jsonb', not_null = true },
        { column = 'geom', type = 'linestring', proj = '3857', not_null = true }
    },
    indexes = {
        { column = 'tags', method = 'gin' },
        { column = 'geom', method = 'gist' }
    }
})

-- Contains: all open ways; all closed ways except those explicitly tagged as areas.
-- Alert! Most closed ways are duplicated in `way_no_explicit_line`.
local way_no_explicit_area_table = osm2pgsql.define_table({
    name = 'way_no_explicit_area',
    ids = { type = 'way', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'jsonb', not_null = true },
        { column = 'geom', type = 'linestring', proj = '3857', not_null = true },
        { column = 'is_explicit_line', type = 'boolean', not_null = true },
        { column = 'extent', type = 'real', not_null = true }
    },
    indexes = {
        { column = 'tags', method = 'gin' },
        { column = 'geom', method = 'gist' },
        { column = 'is_explicit_line', method = 'btree' },
        { column = 'extent', method = 'btree' }
    }
})

-- Contains: no open ways; all closed ways except those explicitly tagged as lines.
-- Alert! Most closed ways are duplicated in `way_no_explicit_area`.
local way_no_explicit_line_table = osm2pgsql.define_table({
    name = 'way_no_explicit_line',
    ids = { type = 'way', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'jsonb', not_null = true },
        { column = 'geom', type = 'polygon', proj = '3857', not_null = true },
        { column = 'is_explicit_area', type = 'boolean', not_null = true },
        { column = 'area_3857', type = 'real', not_null = true },
        { column = 'extent', type = 'real', not_null = true },
        { column = 'label_point', sql_type = 'GEOMETRY(Point, 3857)', create_only = true },
        { column = 'label_point_z26_x', type = 'int', create_only = true },
        { column = 'label_point_z26_y', type = 'int', create_only = true }
    },
    indexes = {
        { column = 'tags', method = 'gin' },
        { column = 'geom', method = 'gist' },
        { column = 'is_explicit_area', method = 'btree' },
        { column = 'area_3857', method = 'btree' },
        { column = 'extent', method = 'btree' },
        { column = 'label_point', method = 'gist' },
        { column = {'label_point_z26_x', 'label_point_z26_y'}, method = 'btree' }
    }
})

-- we need super fast coastline selection so store them redundantly here
local coastline_table = osm2pgsql.define_table({
    name = 'coastline',
    ids = { type = 'way', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'geom', type = 'linestring', proj = '3857', not_null = true },
        { column = 'area_3857', type = 'real' }
    },
    indexes = {
        { column = 'geom', method = 'gist' },
        { column = 'area_3857', method = 'btree' }
    }
})

-- Contains only multi-part area relations
local area_relation_table = osm2pgsql.define_table({
    name = 'area_relation',
    ids = { type = 'relation', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'jsonb', not_null = true },
        { column = 'geom', type = 'multipolygon', proj = '3857', not_null = true },
        { column = 'extent', type = 'real' },
        { column = 'area_3857', type = 'real' },
        { column = 'label_node_id', type = 'int8' },
        { column = 'label_point', sql_type = 'GEOMETRY(Point, 3857)', create_only = true },
        { column = 'label_point_z26_x', type = 'int', create_only = true },
        { column = 'label_point_z26_y', type = 'int', create_only = true }
    },
    indexes = {
        { column = 'tags', method = 'gin' },
        { column = 'geom', method = 'gist' },
        { column = 'extent', method = 'btree' },
        { column = 'area_3857', method = 'btree' },
        { column = 'label_node_id', method = 'btree' },
        { column = 'label_point', method = 'gist' },
        { column = {'label_point_z26_x', 'label_point_z26_y'}, method = 'btree' }
    }
})

-- Contains all relations except multi-part areas
local non_area_relation_table = osm2pgsql.define_table({
    name = 'non_area_relation',
    ids = { type = 'relation', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'jsonb', not_null = true },
        { column = 'geom', type = 'geometrycollection', proj = '3857' },
        { column = 'bbox', type = 'text', sql_type = 'GEOMETRY(Polygon, 3857)' },
        { column = 'extent', type = 'real' },
        { column = 'label_node_id', type = 'int8' },
        { column = 'label_point', sql_type = 'GEOMETRY(Point, 3857)', create_only = true },
        { column = 'label_point_z26_x', type = 'int', create_only = true },
        { column = 'label_point_z26_y', type = 'int', create_only = true }
    },
    indexes = {
        { column = 'tags', method = 'gin' },
        { column = 'geom', method = 'gist' },
        { column = 'bbox', method = 'gist' },
        { column = 'extent', method = 'btree' },
        { column = 'label_node_id', method = 'btree' },
        { column = 'label_point', method = 'gist' },
        { column = {'label_point_z26_x', 'label_point_z26_y'}, method = 'btree' }
    }
})

local node_relation_member_table = osm2pgsql.define_table({
    name = 'node_relation_member',
    ids = { type = 'relation', id_column = 'relation_id', create_index = 'auto' },
    columns = {
        { column = 'member_index', type = 'int2', not_null = true },
        { column = 'member_id', type = 'int8', not_null = true },
        { column = 'member_role', type = 'text', not_null = true }
    },
    indexes = {
        { column = {'relation_id', 'member_role'}, method = 'btree' },
        { column = {'member_id', 'member_role'}, method = 'btree' },
        { column = 'member_role', method = 'btree' }
    }
})

local way_relation_member_table = osm2pgsql.define_table({
    name = 'way_relation_member',
    ids = { type = 'relation', id_column = 'relation_id', create_index = 'auto' },
    columns = {
        { column = 'member_index', type = 'int2', not_null = true },
        { column = 'member_id', type = 'int8', not_null = true },
        { column = 'member_role', type = 'text', not_null = true }
    },
    indexes = {
        { column = {'relation_id', 'member_role'}, method = 'btree' },
        { column = {'member_id', 'member_role'}, method = 'btree' },
        { column = 'member_role', method = 'btree' }
    }
})

local relation_relation_member_table = osm2pgsql.define_table({
    name = 'relation_relation_member',
    ids = { type = 'relation', id_column = 'relation_id', create_index = 'auto' },
    columns = {
        { column = 'member_index', type = 'int2', not_null = true },
        { column = 'member_id', type = 'int8', not_null = true },
        { column = 'member_role', type = 'text', not_null = true }
    },
    indexes = {
        { column = {'relation_id', 'member_role'}, method = 'btree' },
        { column = {'member_id', 'member_role'}, method = 'btree' },
        { column = 'member_role', method = 'btree' }
    }
})

local multipolygon_relation_types = {
    multipolygon = true,
    boundary = true
}

function z26_tile(x, y)
    return math.floor((x + 20037508.3427892) / (40075016.6855784 / 2^26)),
           math.floor((20037508.3427892 - y) / (40075016.6855784 / 2^26))
end

-- function bbox_z26_tiles(bbox_min_x_3857, bbox_min_y_3857, bbox_max_x_3857, bbox_max_y_3857)
--     -- The return order of min y and max y are intentionally reversed since 3857 has origin at bottom left
--     -- and map tiles have origin at top left, i.e. the min y becomes the max y
--     return math.floor((bbox_min_x_3857 + 20037508.3427892) / (40075016.6855784 / 2^26)),
--            math.floor((20037508.3427892 - bbox_max_y_3857) / (40075016.6855784 / 2^26)),
--            math.floor((bbox_max_x_3857 + 20037508.3427892) / (40075016.6855784 / 2^26)),
--            math.floor((20037508.3427892 - bbox_min_y_3857) / (40075016.6855784 / 2^26))
-- end

-- Format the bounding box we get from calling get_bbox() on the parameter
-- in the way needed for the PostgreSQL/PostGIS box2d type.
function format_bbox(min_x, min_y, max_x, max_y)
    if min_x == nil then
        return nil
    end
    return 'POLYGON(('.. tostring(min_x) .. ' '.. tostring(min_y) .. ', '.. tostring(min_x) .. ' '.. tostring(max_y) .. ', '.. tostring(max_x) .. ' '.. tostring(max_y) .. ', '.. tostring(max_x) .. ' '.. tostring(min_y) .. ', '.. tostring(min_x) .. ' '.. tostring(min_y) .. '))'
end

-- runs only on tagged nodes or nodes specified by `select_relation_members`
function osm2pgsql.process_node(object)
    local geom = object:as_point():transform(3857)
    local z26_x, z26_y = z26_tile(geom:get_bbox())
    node_table:insert({
        tags = object.tags,
        geom = geom,
        z26_x = z26_x,
        z26_y = z26_y
    })
end

-- runs only on tagged ways or ways specified by `select_relation_members`
function osm2pgsql.process_way(object)
    local is_explicit_line = not object.is_closed or object.tags.area == 'no'
    local is_explicit_area = object.is_closed and (object.tags.area == 'yes' or object.tags.building ~= nil)

    local line_geom = object:as_linestring():transform(3857)
    local min_x, min_y, max_x, max_y = line_geom:get_bbox()
    local extent = math.sqrt(math.pow(max_x - min_x, 2) + math.pow(max_y - min_y, 2))

    local area_3857 = nil

    if not is_explicit_area then
        way_no_explicit_area_table:insert({
            tags = object.tags,
            geom = line_geom,
            is_explicit_line = is_explicit_line,
            extent = extent
        })
    end

    if not is_explicit_line then
        local area_geom = object:as_polygon():transform(3857)
        area_3857 = area_geom:area()
        way_no_explicit_line_table:insert({
            tags = object.tags,
            geom = area_geom,
            is_explicit_area = is_explicit_area,
            area_3857 = area_3857,
            extent = extent
        })
    end

    if object.tags.natural == 'coastline' then
        coastline_table:insert({
            geom = line_geom,
            area_3857 = area_3857
        })
    end

    way_table:insert({
        tags = object.tags,
        geom = line_geom
    })
end
-- relation member may be untagged and but we still want to include them
function osm2pgsql.process_untagged_way(object)
    way_table:insert({
        tags = object.tags,
        geom = object:as_linestring():transform(3857)
    })
end

-- only runs on tagged relations
function osm2pgsql.process_relation(object)
    local relType = object.tags.type

    -- relations without a `type` tag are uncommon and ambiguous so ignore them
    if relType then

        local label_node_id = nil

        for i, member in ipairs(object.members) do
            local row = {
                relation_id = object.id,
                member_id = member.ref,
                member_index = i,
                member_role = member.role
            }
            if member.type == 'n' then
                if member.role == 'label' then
                    label_node_id = member.ref
                end
                node_relation_member_table:insert(row)
            elseif member.type == 'w' then
                way_relation_member_table:insert(row)
            else
                relation_relation_member_table:insert(row)
            end
        end

        if multipolygon_relation_types[relType] then
            local geom = object:as_multipolygon():transform(3857) 
            local min_x, min_y, max_x, max_y = geom:get_bbox()
            area_relation_table:insert({
                tags = object.tags,
                geom = geom,
                extent = math.sqrt(math.pow(max_x - min_x, 2) + math.pow(max_y - min_y, 2)),
                area_3857 = geom:area(),
                label_node_id = label_node_id
            })
        else
            local geom = object:as_geometrycollection():transform(3857)
            local min_x, min_y, max_x, max_y = geom:get_bbox()
            non_area_relation_table:insert({
                tags = object.tags,
                geom = geom,
                bbox = format_bbox(min_x, min_y, max_x, max_y),
                extent = math.sqrt(math.pow(max_x - min_x, 2) + math.pow(max_y - min_y, 2)),
                label_node_id = label_node_id
            })
        end

    end
end

-- Label nodes are sometimes untagged so we need to manually send them to `process_node`
function osm2pgsql.select_relation_members(object)
    local node_member_ids = {}

    for _, member in ipairs(object.members) do
        if member.role == 'label' and member.type == 'n' then
            table.insert(node_member_ids, member.ref)
        end
    end

    if #node_member_ids > 0 then
        return {
            nodes = node_member_ids,
            ways = {}
        }
    end
end

