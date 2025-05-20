local helperDataDir = "/var/tmp/app/import_helper_data/"

local column_keys = {}
local table_keys = {}

local tables = {}

local coastline_table = osm2pgsql.define_table{
    name = 'coastline',
    ids = { type = 'any', id_column = 'id' },
    columns = {
        { column = 'area_3857', type = 'real' },
        { column = 'geom', type = 'linestring', proj = '3857', not_null = true },
    }
}

local file = io.open(helperDataDir .. "column_keys.txt", "r")
local file_string = file:read("*all")
file:close()
for key in file_string:gmatch("[^\r\n]+") do
    column_keys[key] = true
end

file = io.open(helperDataDir .. "table_keys.txt", "r")
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
}

for key, _ in pairs(column_keys) do
    table.insert(columns, { column = key, type = 'text' })
end

for key, _ in pairs(table_keys) do
    tables[key] = osm2pgsql.define_table{
        name = key,
        ids = { type = 'any', id_column = 'id' },
        columns = columns
    }
end

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
    row["geom"] = object:as_multipolygon():transform(3857)
    row["area_3857"] = row["geom"]:area()
    row["geom_type"] = "area"
end

function loadTags(object, row)
    row["tags"] = {}
    for k, v in pairs(object.tags) do
        if column_keys[k] then
            -- don't copy in negative values like `building=no` (troll tag) for top-level tags (unless it can be an attribute)
            if not (table_keys[k] and v == 'no' and not no_is_attribute[k]) then
                row[k] = v
            end
        else
            row["tags"][k] = v
        end
    end
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

local multipolygon_relation_types = {
    multipolygon = true,
    boundary = true
}

function osm2pgsql.process_relation(object)
    if multipolygon_relation_types[object.tags.type] then
        processObject(object, loadMultipolygonGeometry)
    end
end

-- function osm2pgsql.select_relation_members(object)
--     if multipolygon_relation_types[object.tags.type] then
--         for i, member in ipairs(object.members) do
--             if member.type == 'n' and member.role == 'label' then
--                 return {
--                     nodes = {member.ref},
--                     ways = {}
--                 }
--             end 
--         end
--     end
-- end
