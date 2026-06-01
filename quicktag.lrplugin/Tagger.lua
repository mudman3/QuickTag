-- Tagger.lua
local LrApplication = import 'LrApplication'
local LrDialogs     = import 'LrDialogs'
local LrPathUtils   = import 'LrPathUtils'
local LrFileUtils   = import 'LrFileUtils'
local json          = require 'json'

local Tagger = {}

local RAW_EXTENSIONS = {
    nef=true, cr2=true, cr3=true, raf=true, arw=true, orf=true,
    rw2=true, dng=true, pef=true, srw=true, x3f=true, kdc=true,
}

local function pluginPath() return _PLUGIN.path end
local function configPath() return LrPathUtils.child(pluginPath(), 'config.json') end
local function helperPath() return LrPathUtils.child(pluginPath(), 'helper.py') end
local function tempDir()    return LrPathUtils.getStandardFilePath('temp') end

local function readJson(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('*all'); f:close()
    local ok, r = pcall(json.decode, s)
    return ok and r or nil
end

local function writeJson(path, data)
    local f = io.open(path, 'w')
    if not f then return false end
    f:write(json.encode(data)); f:close()
    return true
end

local function readConfig()
    return readJson(configPath()) or { model='moondream', max_keywords=20, seconds_per_image=5 }
end

local function getAllKeywordNames(catalog)
    local names = {}
    local function collect(kw)
        table.insert(names, kw:getName())
        for _, c in ipairs(kw:getChildren()) do collect(c) end
    end
    for _, kw in ipairs(catalog:getKeywords()) do collect(kw) end
    return names
end

local function getSelectedPhotos(catalog)
    local photos = catalog:getTargetPhotos()
    if photos and #photos > 0 then return photos end
    local folder = catalog:getTargetFolder()
    if folder then return folder:getPhotos() end
    return {}
end

local function countTagged(photos)
    local n = 0
    for _, photo in ipairs(photos) do
        local kws = photo:getRawMetadata('keywords')
        if kws and #kws > 0 then n = n + 1 end
    end
    return n
end

-- JPEG/TIFF/PNG: pass original path directly to Python.
-- RAW files are excluded — Python cannot open them; they appear in skipped.
local function buildImageList(photos)
    local images, skipped = {}, {}
    for _, photo in ipairs(photos) do
        local path = photo:getRawMetadata('path')
        local ext  = LrPathUtils.extension(path):lower()
        if RAW_EXTENSIONS[ext] then
            table.insert(skipped, path)
        else
            table.insert(images, { original_path = path, preview_path = path })
        end
    end
    return images, skipped
end

local function formatTime(s)
    if s < 60 then return string.format('%d seconds', math.ceil(s)) end
    local m = math.floor(s / 60)
    local r = math.ceil(s % 60)
    if r == 0 then return string.format('%d minute%s', m, m == 1 and '' or 's') end
    return string.format('%d min %d sec', m, r)
end

local function showPreRunDialog(photos, taggedCount, secPerImage)
    local untagged = #photos - taggedCount
    local info = string.format(
        '%d image%s selected, %d already have keywords.\nEstimated time: ~%s',
        #photos, #photos == 1 and '' or 's', taggedCount,
        formatTime(untagged * secPerImage)
    )
    return LrDialogs.confirm('QuickTag', info, 'Run') == 'ok'
end

local function writeLog(skipped)
    if #skipped == 0 then return end
    local f = io.open(LrPathUtils.child(pluginPath(), 'quicktag.log'), 'a')
    if not f then return end
    f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' — skipped:\n')
    for _, p in ipairs(skipped) do f:write('  ' .. p .. '\n') end
    f:close()
end

local function callPython(images, existingKeywords, config)
    local inputPath  = LrPathUtils.child(tempDir(), 'quicktag_in.json')
    local outputPath = LrPathUtils.child(tempDir(), 'quicktag_out.json')

    if not writeJson(inputPath, { images=images, existing_keywords=existingKeywords, config_path=configPath() }) then
        return nil, 'Could not write temp input file.'
    end

    local pythonExe = config.python_path or 'python'
    local batPath   = LrPathUtils.child(tempDir(), 'quicktag_run.bat')
    local batFile   = io.open(batPath, 'w')
    if not batFile then return nil, 'Could not write temp batch file.' end
    batFile:write('@echo off\n')
    batFile:write(string.format('"%s" "%s" --input "%s" --output "%s"\n',
        pythonExe, helperPath(), inputPath, outputPath))
    batFile:close()

    local h = io.popen('"' .. batPath .. '"')
    if h then h:read('*all'); h:close() end
    LrFileUtils.delete(batPath)
    LrFileUtils.delete(inputPath)

    local th = io.open(outputPath, 'r')
    if not th then return nil, 'Python did not run. Make sure Python 3 is installed and on your PATH.' end
    th:close()

    local output = readJson(outputPath)
    LrFileUtils.delete(outputPath)
    if not output then return nil, 'Could not read results from helper.py.' end
    return output, nil
end

function Tagger.run()
    local catalog = LrApplication.activeCatalog()
    local photos  = getSelectedPhotos(catalog)

    if #photos == 0 then
        LrDialogs.message('QuickTag', 'Please select at least one photo or folder.', 'info')
        return
    end

    local taggedCount = countTagged(photos)
    local config      = readConfig()

    if not showPreRunDialog(photos, taggedCount, config.seconds_per_image or 5) then return end

    local filtered = {}
    for _, photo in ipairs(photos) do
        local kws = photo:getRawMetadata('keywords')
        if not kws or #kws == 0 then table.insert(filtered, photo) end
    end
    photos = filtered

    local images, rawSkipped = buildImageList(photos)

    if #images == 0 then
        LrDialogs.message('QuickTag', 'No supported images to process. RAW files cannot be tagged directly.', 'info')
        return
    end

    local output, callErr = callPython(images, getAllKeywordNames(catalog), config)

    if callErr then LrDialogs.message('QuickTag Error', callErr, 'critical') return end
    if output.error then LrDialogs.message('QuickTag Error', output.error, 'critical') return end
    if not output.results then LrDialogs.message('QuickTag Error', 'Helper returned no results.', 'critical') return end

    local photoByPath = {}
    for _, photo in ipairs(photos) do
        photoByPath[photo:getRawMetadata('path')] = photo
    end

    local taggedTotal = 0
    catalog:withWriteAccessDo('QuickTag', function()
        for path, keywords in pairs(output.results) do
            local photo = photoByPath[path]
            if photo then
                for _, word in ipairs(keywords) do
                    local kw = catalog:createKeyword(word, {}, true, nil, true)
                    photo:addKeyword(kw)
                end
                taggedTotal = taggedTotal + 1
            end
        end
    end, { timeout = 30 })

    local allSkipped = rawSkipped
    for _, p in ipairs(output.skipped or {}) do table.insert(allSkipped, p) end
    writeLog(allSkipped)

    local msg
    if #allSkipped > 0 then
        msg = string.format('Done — %d image%s tagged, %d skipped (see quicktag.log).',
            taggedTotal, taggedTotal == 1 and '' or 's', #allSkipped)
    else
        msg = string.format('Done — %d image%s tagged.',
            taggedTotal, taggedTotal == 1 and '' or 's')
    end
    LrDialogs.message('QuickTag', msg, 'info')
end

return Tagger
