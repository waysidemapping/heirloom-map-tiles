local helperDataDir = "/var/tmp/app/import_helper_data/"

local column_keys = {}
local table_keys = {}

local tables = {}

-- local multipolygonMemberNodeIds = {}

local file = io.open(helperDataDir .. "sql_column_keys.txt", "r")
local file_string = file:read("*all")
file:close()
for key in file_string:gmatch("[^\r\n]+") do
    column_keys[key] = true
end

file = io.open(helperDataDir .. "sql_table_keys.txt", "r")
file_string = file:read("*all")
file:close()
for key in file_string:gmatch("[^\r\n]+") do
    table_keys[key] = true
    column_keys[key] = true
end

local columns = {
    { column = 'tags', type = 'jsonb' },
    { column = 'area_3857', type = 'real' },
    { column = 'geom', type = 'geometry', proj = '3857', not_null = true },
    { column = 'geom_type', type = 'text', not_null = true }
    -- { column = 'admin_centre_node_id', type = 'int8' },
    -- { column = 'label_node_id', type = 'int8' }
}
local relation_columns = {
    { column = 'tags', type = 'jsonb' }
}

for key, _ in pairs(column_keys) do
    table.insert(columns, { column = key, type = 'text' })
    table.insert(relation_columns, { column = key, type = 'text' })
end

for key, _ in pairs(table_keys) do
    tables[key] = osm2pgsql.define_table{
        name = key,
        ids = { type = 'any', id_column = 'id', create_index = 'primary_key' },
        columns = columns
    }
end

local route_relation_table = osm2pgsql.define_table{
    name = 'route_relation',
    ids = { type = 'relation', id_column = 'id', create_index = 'primary_key' },
    columns = relation_columns
}

local waterway_relation_table = osm2pgsql.define_table{
    name = 'waterway_relation',
    ids = { type = 'relation', id_column = 'id', create_index = 'primary_key' },
    columns = relation_columns
}

local way_route_relation_link_table = osm2pgsql.define_table{
    name = 'way_route_relation_link',
    ids = { type = 'any', id_column = 'relation_id', create_index = 'always' },
    columns = {
        { column = 'way_id', type = 'int8' }
    },
    indexes = {
        { column = 'way_id', method = 'btree', include = 'relation_id' }
    }
}

local way_waterway_relation_link_table = osm2pgsql.define_table{
    name = 'way_waterway_relation_link',
    ids = { type = 'any', id_column = 'relation_id', create_index = 'always' },
    columns = {
        { column = 'way_id', type = 'int8' }
    },
    indexes = {
        { column = 'way_id', method = 'btree', include = 'relation_id' }
    }
}

local coastline_table = osm2pgsql.define_table{
    name = 'coastline',
    ids = { type = 'way', id_column = 'id', create_index = 'primary_key' },
    columns = {
        { column = 'area_3857', type = 'real' },
        { column = 'geom', type = 'linestring', proj = '3857', not_null = true },
    }
}

local multipolygon_relation_types = {
    multipolygon = true,
    boundary = true
}

local route_relation_types = {
    route = true,
    waterway = true
}

-- Define tags that should not quality features to be included in top-level tag tables. `no` is handled separately
local ignore_top_level_tags = {
    emergency = {
        -- these are access tags
        designated = true,
        destination = true,
        customers = true,
        official = true,
        permissive = true,
        private = true,
        unknown = true,
        yes = true
    },
    indoor = {
        -- these are boolean attribute tags
        yes = true,
        unknown = true
    },
    natural = {
        -- this is a very special tag we will handle separately
        coastline = true
    }
}

local no_is_attribute = {
    emergency = true,
    indoor = true,
}

function loadPointGeometry(object, row)
    row["geom"] = object:as_point():transform(3857)
    row["geom_type"] = "point"
    row["area_3857"] = 0
end

function loadWayGeometry(object, row)
    local areaTag = object.tags.area
    if object.is_closed and areaTag ~= "no" then
        row["geom"] = object:as_polygon():transform(3857)
        row["area_3857"] = row["geom"]:area()
        if areaTag == "yes" then
            row["geom_type"] = "area"
        else
            row["geom_type"] = "closed_way"
        end
    else
        row["geom"] = object:as_linestring():transform(3857)
        row["area_3857"] = 0
        row["geom_type"] = "line"
    end
end

function loadMultipolygonGeometry(object, row)
    -- local didFindLabel = false
    -- local didFindAdminCentre = false
    -- for i, member in ipairs(object.members) do
    --     if member.type == 'n' then
    --         if not didFindLabel and member.role == 'label' then
    --             multipolygonMemberNodeIds[member.ref] = true
    --             row["label_node_id"] = member.ref
    --             didFindLabel = true
    --         end
    --         if not didFindAdminCentre and member.role == 'admin_centre' then
    --             multipolygonMemberNodeIds[member.ref] = true
    --             row["admin_centre_node_id"] = member.ref
    --             didFindAdminCentre = true
    --         end
    --         if didFindAdminCentre and didFindLabel then
    --             break
    --         end
    --     end
    -- end
    row["geom"] = object:as_multipolygon():transform(3857)
    row["area_3857"] = row["geom"]:area()
    row["geom_type"] = "area"
end

function loadTags(object, row)
    for k, v in pairs(object.tags) do
        if column_keys[k] then
            -- don't copy in negative values like `building=no` (troll tag) for top-level tags (unless it can be an attribute)
            if not (table_keys[k] and v == 'no' and not no_is_attribute[k]) then
                row[k] = v
            end
        end
    end
    row["tags"] = object.tags
end

function processObject(object, loadGeometry)
    local tags = object.tags
    local row
    for key, table in pairs(tables) do
        if tags[key] and tags[key] ~= 'no' and not (ignore_top_level_tags[key] and ignore_top_level_tags[key][tags[key]]) then
            if not row then
                -- wait to create the row until we know we'll actuallly want to insert it
                row = {}
                loadGeometry(object, row)
                loadTags(object, row)
            end
            table:insert(row)
        end
    end
end

function osm2pgsql.process_node(object)
    processObject(object, loadPointGeometry)
end

function osm2pgsql.process_way(object)
    if object.tags.natural == 'coastline' then
        local area_3857 = 0
        if object.is_closed then
            -- `area()` always returns 0 for linestrings so we need to convert to polygon 
            area_3857 = object:as_polygon():transform(3857):area()
        end
        coastline_table:insert({
            area_3857 = area_3857,
            geom = object:as_linestring():transform(3857)
        })
        -- don't return early since coastline might be double-tagged (e.g. `place=islet`)
    end
    processObject(object, loadWayGeometry)
end

function osm2pgsql.process_relation(object)
    local relType = object.tags.type
    if multipolygon_relation_types[relType] then
        processObject(object, loadMultipolygonGeometry)
    elseif route_relation_types[relType] then
        local row = {
            id = object.id
        }
        loadTags(object, row)
        if relType == 'route' then
            route_relation_table:insert(row)
        else
            waterway_relation_table:insert(row)
        end

        local seenWaysIds = {}

        for i, member in ipairs(object.members) do
            if member.type == 'w' and not seenWaysIds[member.ref] then
                if relType == 'route' then
                    seenWaysIds[member.ref] = true
                    way_route_relation_link_table:insert{
                        relation_id = object.id,
                        way_id = -member.ref
                    }
                elseif member.role == 'main_stream' then -- implied relType == 'waterway'
                    seenWaysIds[member.ref] = true
                    way_waterway_relation_link_table:insert{
                        relation_id = object.id,
                        way_id = -member.ref
                    }
                end
            end 
        end
    end
end

-- function osm2pgsql.select_relation_members(object)
--     local nodeIds = {}
--     local wayIds = {}
--     local relType = object.tags.type
--     if relType then
--         if multipolygon_relation_types[relType] then
--             nodeIds = osm2pgsql.node_member_ids(object)
--         end
--     end
--     return {
--         nodes = nodeIds,
--         ways = wayIds
--     }
-- end
