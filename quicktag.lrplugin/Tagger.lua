-- Tagger.lua
local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrPathUtils       = import 'LrPathUtils'
local LrView            = import 'LrView'
local LrBinding         = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks           = import 'LrTasks'
local LrFileUtils       = import 'LrFileUtils'
local json              = require 'json'

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
    return LrPathUtils.getStandardFilePath('temp')
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

local function generatePreviews(photos)
    local pending  = #photos
    local previews = {}

    for i, photo in ipairs(photos) do
        local origPath    = photo:getRawMetadata('path')
        local previewPath = LrPathUtils.child(tempDir(), string.format('quicktag_preview_%d.jpg', i))

        photo:requestJpegThumbnail(1024, 1024, function(jpeg)
            if jpeg then
                local f = io.open(previewPath, 'wb')
                if f then
                    f:write(jpeg)
                    f:close()
                    table.insert(previews, { original_path = origPath, preview_path = previewPath })
                end
            end
            pending = pending - 1
        end)
    end

    while pending > 0 do
        LrTasks.sleep(0.05)
    end

    return previews
end

local function formatTime(seconds)
    if seconds < 60 then
        return string.format('%d seconds', math.ceil(seconds))
    end
    local mins = math.floor(seconds / 60)
    local secs = math.ceil(seconds % 60)
    if secs == 0 then
        return string.format('%d minute%s', mins, mins == 1 and '' or 's')
    end
    return string.format('%d min %d sec', mins, secs)
end

local function showPreRunDialog(photos, taggedCount, secPerImage)
    local result, includeTagged

    LrFunctionContext.callWithContext('quickTagDialog', function(context)
        local props          = LrBinding.makePropertyTable(context)
        props.includeTagged  = false
        local untaggedCount  = #photos - taggedCount

        local function updateEstimate()
            local count         = props.includeTagged and #photos or untaggedCount
            props.estimatedTime = 'Estimated time: ~' .. formatTime(count * secPerImage)
        end

        updateEstimate()
        props:addObserver('includeTagged', context, updateEstimate)

        local f        = LrView.osFactory()
        local contents = f:column {
            bind_to_object = props,
            spacing        = f:dialog_spacing(),
            f:static_text {
                title = string.format(
                    '%d images selected (%d already have keywords)',
                    #photos, taggedCount
                ),
            },
            f:static_text { title = LrView.bind 'estimatedTime' },
            f:separator  { fill_horizontal = 1 },
            f:checkbox   { title = 'Include already-tagged images', value = LrView.bind 'includeTagged' },
        }

        local dialogResult = LrDialogs.presentModalDialog {
            title      = 'QuickTag',
            contents   = contents,
            actionVerb = 'Run',
        }

        result        = dialogResult == 'ok'
        includeTagged = props.includeTagged
    end)

    return result, includeTagged
end

local function writeLog(skipped)
    if #skipped == 0 then return end
    local logPath = LrPathUtils.child(pluginPath(), 'quicktag.log')
    local f       = io.open(logPath, 'a')
    if not f then return end
    f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' — skipped:\n')
    for _, path in ipairs(skipped) do
        f:write('  ' .. path .. '\n')
    end
    f:close()
end

local function applyKeywordsToPhoto(catalog, photo, keywords)
    for _, word in ipairs(keywords) do
        local kw = catalog:createKeyword(word, {}, true, nil, true)
        photo:addKeyword(kw)
    end
end

local function callPython(previews, existingKeywords)
    local inputPath  = LrPathUtils.child(tempDir(), 'quicktag_in.json')
    local outputPath = LrPathUtils.child(tempDir(), 'quicktag_out.json')

    local inputData = {
        images            = previews,
        existing_keywords = existingKeywords,
        config_path       = configPath(),
    }

    if not writeJson(inputPath, inputData) then
        return nil, 'Could not write temp input file.'
    end

    local cmd    = string.format('python "%s" --input "%s" --output "%s"', helperPath(), inputPath, outputPath)
    local handle = io.popen(cmd)
    if handle then
        handle:read('*all')
        handle:close()
    end

    for _, item in ipairs(previews) do
        LrFileUtils.delete(item.preview_path)
    end
    LrFileUtils.delete(inputPath)

    local testHandle = io.open(outputPath, 'r')
    if not testHandle then
        return nil, 'Python did not run. Make sure Python 3 is installed and on your PATH.'
    end
    testHandle:close()

    local output = readJson(outputPath)
    LrFileUtils.delete(outputPath)

    if not output then
        return nil, 'Could not read results from helper.py.'
    end

    return output, nil
end

function Tagger.run()
    local catalog = LrApplication.activeCatalog()
    local photos   = getSelectedPhotos(catalog)

    if #photos == 0 then
        LrDialogs.message('QuickTag', 'Please select at least one photo or folder.', 'info')
        return
    end

    local taggedCount = countTagged(photos)

    local config = readConfig()
    local shouldRun, includeTagged = showPreRunDialog(photos, taggedCount, config.seconds_per_image or 5)
    if not shouldRun then return end

    if not includeTagged then
        local filtered = {}
        for _, photo in ipairs(photos) do
            local kws = photo:getRawMetadata('keywords')
            if not kws or #kws == 0 then
                table.insert(filtered, photo)
            end
        end
        photos = filtered
    end

    local previews        = generatePreviews(photos)
    local allKeywords     = getAllKeywordNames(catalog)
    local output, callErr = callPython(previews, allKeywords)

    if callErr then
        LrDialogs.message('QuickTag Error', callErr, 'critical')
        return
    end

    if output.error then
        LrDialogs.message('QuickTag Error', output.error, 'critical')
        return
    end

    if not output.results then
        LrDialogs.message('QuickTag Error', 'Helper returned no results. Check quicktag.log.', 'critical')
        return
    end

    local photoByPath = {}
    for _, photo in ipairs(photos) do
        photoByPath[photo:getRawMetadata('path')] = photo
    end

    local taggedTotal = 0

    local ok = pcall(function()
        catalog:withWriteAccessDo('QuickTag', function()
            for path, keywords in pairs(output.results) do
                local photo = photoByPath[path]
                if photo then
                    applyKeywordsToPhoto(catalog, photo, keywords)
                    taggedTotal = taggedTotal + 1
                end
            end
        end)
    end)

    if not ok then
        LrDialogs.message('QuickTag Error', 'Lightroom could not save keywords. Please try again.', 'critical')
        return
    end

    if ok and taggedTotal == 0 and next(output.results) ~= nil then
        LrDialogs.message('QuickTag Error', 'Lightroom could not save keywords — the catalog may be read-only. Please try again.', 'critical')
        return
    end

    writeLog(output.skipped or {})

    local skippedCount = #(output.skipped or {})
    local msg
    if skippedCount > 0 then
        msg = string.format('Done — %d image%s tagged, %d skipped (see quicktag.log).',
            taggedTotal, taggedTotal == 1 and '' or 's', skippedCount)
    else
        msg = string.format('Done — %d image%s tagged.',
            taggedTotal, taggedTotal == 1 and '' or 's')
    end

    LrDialogs.message('QuickTag', msg, 'info')
end

return Tagger
