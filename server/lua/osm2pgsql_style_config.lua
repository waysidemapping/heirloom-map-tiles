local node_table = osm2pgsql.define_table({
    name = 'node',
    ids = { type = 'node', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'hstore', not_null = true },
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

-- Untagged ways needed for selecting relation members
local untagged_way_table = osm2pgsql.define_table({
    name = 'untagged_way',
    ids = { type = 'way', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'geom', type = 'linestring', proj = '3857', not_null = true }
    },
    indexes = {
        { column = 'geom', method = 'gist' }
    }
})

-- Contains: all tagged open ways + closed ways explcitly tagged as non-areas
local way_explicit_line_table = osm2pgsql.define_table({
    name = 'way_explicit_line',
    ids = { type = 'way', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'hstore', not_null = true },
        { column = 'geom', type = 'linestring', proj = '3857', not_null = true },
        { column = 'extent', type = 'real', not_null = true }
    },
    indexes = {
        { column = 'tags', method = 'gin' },
        { column = 'geom', method = 'gist' },
        { column = 'extent', method = 'btree' }
    }
})

-- Contains: closed ways explicitly tagged as areas
local way_explicit_area_table = osm2pgsql.define_table({
    name = 'way_explicit_area',
    ids = { type = 'way', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'hstore', not_null = true },
        { column = 'geom', type = 'polygon', proj = '3857', not_null = true },
        { column = 'area_3857', type = 'real', not_null = true },
        { column = 'extent', type = 'real', not_null = true },
        { column = 'label_point', type = 'point', proj = '3857' },
        { column = 'label_point_z26_x', type = 'int' },
        { column = 'label_point_z26_y', type = 'int' }
    },
    indexes = {
        { column = 'tags', method = 'gin' },
        { column = 'geom', method = 'gist' },
        { column = 'area_3857', method = 'btree' },
        { column = 'extent', method = 'btree' },
        { column = 'label_point', method = 'gist' },
        { column = {'label_point_z26_x', 'label_point_z26_y'}, method = 'btree' }
    }
})

-- Contains: tagged closed ways lacking enough info to specify them as areas or lines 
local way_no_explicit_geometry_type_table = osm2pgsql.define_table({
    name = 'way_no_explicit_geometry_type',
    ids = { type = 'way', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'hstore', not_null = true },
        { column = 'geom', type = 'polygon', proj = '3857', not_null = true },
        { column = 'area_3857', type = 'real', not_null = true },
        { column = 'extent', type = 'real', not_null = true },
        { column = 'label_point', type = 'point', proj = '3857' },
        { column = 'label_point_z26_x', type = 'int' },
        { column = 'label_point_z26_y', type = 'int' }
    },
    indexes = {
        { column = 'tags', method = 'gin' },
        { column = 'geom', method = 'gist' },
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
        { column = 'tags', type = 'hstore', not_null = true },
        { column = 'geom', type = 'multipolygon', proj = '3857', not_null = true },
        { column = 'extent', type = 'real' },
        { column = 'area_3857', type = 'real' },
        { column = 'label_node_id', type = 'int8' },
        { column = 'label_point', type = 'point', proj = '3857' },
        { column = 'label_point_z26_x', type = 'int' },
        { column = 'label_point_z26_y', type = 'int' }
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
        { column = 'tags', type = 'hstore', not_null = true },
        { column = 'geom', type = 'geometrycollection', proj = '3857' },
        { column = 'extent', type = 'real' },
        { column = 'label_node_id', type = 'int8' }
    },
    indexes = {
        { column = 'tags', method = 'gin' },
        { column = 'geom', method = 'gist' },
        { column = 'extent', method = 'btree' },
        { column = 'label_node_id', method = 'btree' }
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

-- Runs only on tagged nodes or nodes specified by `select_relation_members`
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

-- Runs only on tagged ways or ways specified by `select_relation_members`
function osm2pgsql.process_way(object)
    local is_explicit_line = not object.is_closed or object.tags.area == 'no'
    local is_explicit_area = object.is_closed and (object.tags.area == 'yes' or object.tags.building ~= nil)

    local area_3857
    local line_geom

    if is_explicit_line then
        line_geom = object:as_linestring():transform(3857)
        local min_x, min_y, max_x, max_y = line_geom:get_bbox()
        local dx = max_x - min_x
        local dy = max_y - min_y
        local extent = math.sqrt(dx * dx + dy * dy)
        way_explicit_line_table:insert({
            tags = object.tags,
            geom = line_geom,
            extent = extent
        })
    else
        local area_geom = object:as_polygon():transform(3857)
        area_3857 = area_geom:area()
        local min_x, min_y, max_x, max_y = area_geom:get_bbox()
        local dx = max_x - min_x
        local dy = max_y - min_y
        local extent = math.sqrt(dx * dx + dy * dy)
        
        local label_point = area_geom:pole_of_inaccessibility()
        local z26_x, z26_y
        if label_point then
            z26_x, z26_y = z26_tile(label_point:get_bbox())
        end

        if is_explicit_area then
            way_explicit_area_table:insert({
                tags = object.tags,
                geom = area_geom,
                area_3857 = area_3857,
                extent = extent,
                label_point = label_point,
                label_point_z26_x = z26_x,
                label_point_z26_y = z26_y
            })
        else
            way_no_explicit_geometry_type_table:insert({
                tags = object.tags,
                geom = area_geom,
                area_3857 = area_3857,
                extent = extent,
                label_point = label_point,
                label_point_z26_x = z26_x,
                label_point_z26_y = z26_y
            })
        end
    end

    if object.tags.natural == 'coastline' then
        if not line_geom then
            line_geom = object:as_linestring():transform(3857)
        end
        if not area_3857 and object.is_closed then
            area_3857 = object:as_polygon():transform(3857):area()
        end
        coastline_table:insert({
            geom = line_geom,
            area_3857 = area_3857
        })
    end
end

-- Runs only on untagged ways
function osm2pgsql.process_untagged_way(object)
    -- Relation member ways might be untagged but we still want to include the somewhere.
    -- This will also include untagged ways that are not part of relations, but these
    -- are considered data errors and mappers will eventually delete them from OSM
    -- or add descriptive tags to them
    untagged_way_table:insert({
        geom = object:as_linestring():transform(3857)
    })
end

-- Runs only on tagged relations
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
            local dx = max_x - min_x
            local dy = max_y - min_y
            local extent = math.sqrt(dx * dx + dy * dy)
            local label_point, z26_x, z26_y
            if not label_node_id then

                local largest_polygon
                local max_area = 0
                for polygon in geom:geometries() do
                    local area = polygon:area()
                    if area > max_area then
                        max_area = area
                        largest_polygon = polygon
                    end
                end

                if largest_polygon then
                    -- pole_of_inaccessibility works only on polygons, so use the largest component
                    label_point = largest_polygon:pole_of_inaccessibility()
                    if label_point then
                        z26_x, z26_y = z26_tile(label_point:get_bbox())
                    end
                end
            end
            area_relation_table:insert({
                tags = object.tags,
                geom = geom,
                extent = extent,
                area_3857 = geom:area(),
                label_node_id = label_node_id,
                label_point = label_point,
                label_point_z26_x = z26_x,
                label_point_z26_y = z26_y
            })
        else
            local geom = object:as_geometrycollection():transform(3857)
            local min_x, min_y, max_x, max_y = geom:get_bbox()
            local dx = max_x - min_x
            local dy = max_y - min_y
            local extent = math.sqrt(dx * dx + dy * dy)

            non_area_relation_table:insert({
                tags = object.tags,
                geom = geom,
                extent = extent,
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

