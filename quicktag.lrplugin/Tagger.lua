-- Tagger.lua
local LrApplication = import 'LrApplication'
local LrDialogs     = import 'LrDialogs'
local LrPathUtils   = import 'LrPathUtils'
local json          = require 'json'

local Tagger = {}

local function pluginPath()
    return _PLUGIN.path
end

local function configPath()
    return LrPathUtils.child(pluginPath(), 'config.json')
end

local function helperPath()
    return LrPathUtils.child(pluginPath(), 'helper.py')
end

local function tempDir()
    return os.getenv('TEMP') or os.getenv('TMP') or pluginPath()
end

local function readJson(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local content = f:read('*all')
    f:close()
    local ok, result = pcall(json.decode, content)
    return ok and result or nil
end

local function writeJson(path, data)
    local f = io.open(path, 'w')
    if not f then return false end
    f:write(json.encode(data))
    f:close()
    return true
end

local function readConfig()
    return readJson(configPath()) or {
        model = 'moondream',
        max_keywords = 20,
        seconds_per_image = 5,
    }
end

local function getAllKeywordNames(catalog)
    local names = {}
    local function collect(kw)
        table.insert(names, kw:getName())
        for _, child in ipairs(kw:getChildren()) do
            collect(child)
        end
    end
    for _, kw in ipairs(catalog:getKeywords()) do
        collect(kw)
    end
    return names
end

local function getSelectedPhotos(catalog)
    local photos = catalog:getTargetPhotos()
    if photos and #photos > 0 then
        return photos
    end
    local folder = catalog:getTargetFolder()
    if folder then
        return folder:getPhotos()
    end
    return {}
end

local function countTagged(photos)
    local count = 0
    for _, photo in ipairs(photos) do
        local kws = photo:getRawMetadata('keywords')
        if kws and #kws > 0 then
            count = count + 1
        end
    end
    return count
end

function Tagger.run()
    local catalog = LrApplication.activeCatalog()
    local photos   = getSelectedPhotos(catalog)

    if #photos == 0 then
        LrDialogs.message('QuickTag', 'Please select at least one photo or folder.', 'info')
        return
    end

    -- remaining tasks will extend this function
end

return Tagger
