local node_table = osm2pgsql.define_table({
    name = 'node',
    ids = { type = 'node', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'hstore', not_null = true },
        { column = 'geom', type = 'point', proj = '3857', not_null = true }
    },
    indexes = {
        { column = 'geom', method = 'gist' },
        { column = 'tags', method = 'gin' }
    }
})

local way_table = osm2pgsql.define_table({
    name = 'way',
    ids = { type = 'way', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'tags', type = 'hstore', not_null = true },
        { column = 'is_explicit_area', type = 'boolean', not_null = true },
        { column = 'is_explicit_line', type = 'boolean', not_null = true },
        { column = 'area_3857', type = 'real', not_null = true },
        { column = 'length_3857', type = 'real', not_null = true },
        { column = 'is_closed', type = 'boolean', not_null = true },
        { column = 'geom', type = 'geometry', proj = '3857', not_null = true },
        { column = 'pole_of_inaccessibility', type = 'point', proj = '3857' }
    },
    indexes = {
        { column = 'geom', method = 'gist' },
        { column = 'pole_of_inaccessibility', method = 'gist' },
        { column = 'area_3857', method = 'btree' },
        { column = 'tags', method = 'gin' }
    }
})
-- we need super fast coastline selection so store them redundantly here
local coastline_table = osm2pgsql.define_table({
    name = 'coastline',
    ids = { type = 'way', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'area_3857', type = 'real', not_null = true },
        { column = 'length_3857', type = 'real', not_null = true },
        { column = 'geom', type = 'linestring', proj = '3857', not_null = true },
    },
    indexes = {
        { column = 'geom', method = 'gist' },
        { column = 'area_3857', method = 'btree' }
    }
})

local area_relation_table = osm2pgsql.define_table({
    name = 'area_relation',
    ids = { type = 'relation', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'relation_type', type = 'text', not_null = true },
        { column = 'tags', type = 'hstore', not_null = true },
        { column = 'area_3857', type = 'real' },
        { column = 'geom', type = 'multipolygon', proj = '3857', not_null = true },
        { column = 'pole_of_inaccessibility', type = 'point', proj = '3857' },
        { column = 'centroid', type = 'point', proj = '3857' }
    },
    indexes = {
        { column = 'geom', method = 'gist' },
        { column = 'pole_of_inaccessibility', method = 'gist' },
        { column = 'centroid', method = 'gist' },
        { column = 'area_3857', method = 'btree' },
        { column = 'tags', method = 'gin' }
    }
})

local non_area_relation_table = osm2pgsql.define_table({
    name = 'non_area_relation',
    ids = { type = 'relation', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'relation_type', type = 'text', not_null = true },
        { column = 'tags', type = 'hstore', not_null = true },
        { column = 'length_3857', type = 'real' },
        { column = 'centroid', type = 'point', proj = '3857' }
    },
    indexes = {
        { column = 'centroid', method = 'gist' },
        { column = 'length_3857', method = 'btree' },
        { column = 'tags', method = 'gin' }
    }
})

local node_relation_member_table = osm2pgsql.define_table({
    name = 'node_relation_member',
    ids = { type = 'relation', id_column = 'relation_id', create_index = 'always' },
    columns = {
        { column = 'member_index', type = 'int2' },
        { column = 'member_id', type = 'int8' },
        { column = 'member_role', type = 'text' }
    },
    indexes = {
        { column = 'member_id', method = 'btree', include = 'relation_id' }
    }
})

local way_relation_member_table = osm2pgsql.define_table({
    name = 'way_relation_member',
    ids = { type = 'relation', id_column = 'relation_id', create_index = 'always' },
    columns = {
        { column = 'member_index', type = 'int2' },
        { column = 'member_id', type = 'int8' },
        { column = 'member_role', type = 'text' }
    },
    indexes = {
        { column = 'member_id', method = 'btree', include = 'relation_id' }
    }
})

local relation_relation_member_table = osm2pgsql.define_table({
    name = 'relation_relation_member',
    ids = { type = 'relation', id_column = 'relation_id', create_index = 'always' },
    columns = {
        { column = 'member_index', type = 'int2' },
        { column = 'member_id', type = 'int8' },
        { column = 'member_role', type = 'text' }
    },
    indexes = {
        { column = 'member_id', method = 'btree', include = 'relation_id' }
    }
})

local multipolygon_relation_types = {
    multipolygon = true,
    boundary = true
}

-- only runs on tagged nodes
function osm2pgsql.process_node(object)
    node_table:insert({
        tags = object.tags,
        geom = object:as_point():transform(3857)
    })
end

function process_way(object)
    local line_geom = object:as_linestring():transform(3857)
    local length_3857 = line_geom:length()

    local area_geom = nil
    local pole_of_inaccessibility = nil
    local area_3857 = 0
    local geom = line_geom
    if object.is_closed then
        -- `area()` always returns 0 for linestrings so we need to convert to polygon
        area_geom = object:as_polygon():transform(3857)
        pole_of_inaccessibility = area_geom:pole_of_inaccessibility()
        area_3857 = area_geom:area()
        geom = area_geom
    end

    if object.tags.natural == 'coastline' then
        coastline_table:insert({
            area_3857 = area_3857,
            length_3857 = length_3857,
            geom = line_geom
        })
    end

    way_table:insert({
        tags = object.tags,
        is_explicit_area = object.tags.area == 'yes',
        is_explicit_line = object.tags.area == 'no',
        area_3857 = area_3857,
        length_3857 = length_3857,
        is_closed = object.is_closed,
        pole_of_inaccessibility = pole_of_inaccessibility,
        geom = geom
    })
end

-- only runs on tagged ways
function osm2pgsql.process_way(object)
    process_way(object)
end
-- relation member may be untagged and we want to include them
function osm2pgsql.process_untagged_way(object)
    process_way(object)
end

-- only runs on tagged relations
function osm2pgsql.process_relation(object)
    local relType = object.tags.type
    if relType then
        if multipolygon_relation_types[relType] then
            local geom = object:as_multipolygon():transform(3857)

            local largestArea = 0
            local largestPart = nil
            for g in geom:geometries() do
                local area = g:area()
                if area > largestArea then
                    largestArea = area
                    largestPart = g
                end
            end
            local pole_of_inaccessibility = nil
            if largestPart then
                pole_of_inaccessibility = largestPart:pole_of_inaccessibility()
            end

            local row = {
                relation_type = relType,
                tags = object.tags,
                geom = geom,
                pole_of_inaccessibility = pole_of_inaccessibility,
                centroid = geom:centroid(),
                area_3857 = geom:area()
            }
            area_relation_table:insert(row)
        else
            non_area_relation_table:insert({
                id = object.id,
                relation_type = relType,
                tags = object.tags,
                length_3857 = object:as_multilinestring():transform(3857):length(),
                centroid = object:as_geometrycollection():transform(3857):centroid()
            })
        end

        for i, member in ipairs(object.members) do
            local row = {
                relation_id = object.id,
                member_id = member.ref,
                member_index = i,
                member_role = member.role
            }
            if member.type == 'n' then
                node_relation_member_table:insert(row)
            elseif member.type == 'w' then
                way_relation_member_table:insert(row)
            else
                relation_relation_member_table:insert(row)
            end
        end
    end
end
