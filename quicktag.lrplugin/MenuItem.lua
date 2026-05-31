-- MenuItem.lua
-- Entry point executed by Lightroom when the menu item is clicked.
local LrTasks = import 'LrTasks'
local Tagger = require 'Tagger'

LrTasks.startAsyncTask(function()
    Tagger.run()
end)
