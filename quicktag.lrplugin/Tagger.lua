-- Tagger.lua
local LrApplication     = import 'LrApplication'
local LrBinding         = import 'LrBinding'
local LrDialogs         = import 'LrDialogs'
local LrFileUtils       = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils       = import 'LrPathUtils'
local LrTasks           = import 'LrTasks'
local LrView            = import 'LrView'
local json              = require 'json'

local Tagger = {}

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

    while pending > 0 do LrTasks.sleep(0.05) end
    return previews
end

local function formatTime(s)
    if s < 60 then return string.format('%d seconds', math.ceil(s)) end
    local m = math.floor(s / 60)
    local r = math.ceil(s % 60)
    if r == 0 then return string.format('%d minute%s', m, m == 1 and '' or 's') end
    return string.format('%d min %d sec', m, r)
end

local function showPreRunDialog(photos, taggedCount, secPerImage)
    local result, includeTagged

    LrFunctionContext.callWithContext('quickTagDialog', function(context)
        local props         = LrBinding.makePropertyTable(context)
        props.includeTagged = false
        local untaggedCount = #photos - taggedCount

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
                title = string.format('%d image%s selected (%d already have keywords)',
                    #photos, #photos == 1 and '' or 's', taggedCount),
            },
            f:static_text { title = LrView.bind 'estimatedTime' },
            f:separator   { fill_horizontal = 1 },
            f:checkbox    { title = 'Include already-tagged images', value = LrView.bind 'includeTagged' },
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
    local f = io.open(LrPathUtils.child(pluginPath(), 'quicktag.log'), 'a')
    if not f then return end
    f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' — skipped:\n')
    for _, p in ipairs(skipped) do f:write('  ' .. p .. '\n') end
    f:close()
end

local function callPython(previews, existingKeywords, config)
    local inputPath  = LrPathUtils.child(tempDir(), 'quicktag_in.json')
    local outputPath = LrPathUtils.child(tempDir(), 'quicktag_out.json')

    if not writeJson(inputPath, { images=previews, existing_keywords=existingKeywords, config_path=configPath() }) then
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

    for _, item in ipairs(previews) do LrFileUtils.delete(item.preview_path) end
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

    local taggedCount          = countTagged(photos)
    local config               = readConfig()
    local shouldRun, includeTagged = showPreRunDialog(photos, taggedCount, config.seconds_per_image or 5)
    if not shouldRun then return end

    if not includeTagged then
        local filtered = {}
        for _, photo in ipairs(photos) do
            local kws = photo:getRawMetadata('keywords')
            if not kws or #kws == 0 then table.insert(filtered, photo) end
        end
        photos = filtered
    end

    if #photos == 0 then
        LrDialogs.message('QuickTag', 'No untagged images to process.', 'info')
        return
    end

    local previews             = generatePreviews(photos)
    local output, callErr      = callPython(previews, getAllKeywordNames(catalog), config)

    if callErr        then LrDialogs.message('QuickTag Error', callErr, 'critical') return end
    if output.error   then LrDialogs.message('QuickTag Error', output.error, 'critical') return end
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
