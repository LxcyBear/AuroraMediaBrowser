scriptTitle = "Aurora Media Browser"
scriptAuthor = "Lxcy"
scriptVersion = 1
scriptDescription = "Download skins, background and cover layouts seamlessly!"
scriptPermissions = { "http", "filesystem", "settings" }
scriptIcon = "icon.png"

-- Live discovery: GitHub Contents API, no catalog.txt, workflow, or manifest required.
local OWNER = "LxcyBear"
local REPOSITORY = "AuroraMediaBrowser"
local BRANCH = "main"
local function rawURL(path)
    return "https://raw.githubusercontent.com/" .. OWNER .. "/" ..
        REPOSITORY .. "/" .. BRANCH .. "/" .. path
end
local function contentsURL(category)
    return "https://api.github.com/repos/" .. OWNER .. "/" .. REPOSITORY ..
        "/contents/repo/" .. category .. "?ref=" .. BRANCH
end

local SKINS_DIR = "Game:\\Skins\\"
local LAYOUTS_DIR = "Game:\\Media\\Layouts\\"
local TEMP_REL = "Downloads\\AuroraMediaBrowser\\"
local ZIP_REL = TEMP_REL .. "package.zip"
local PACKAGE_REL = TEMP_REL .. "package.media"
local EXTRACT_REL = TEMP_REL .. "unpacked\\"
local MAX_PACKAGE_BYTES = 350 * 1024 * 1024
local MAX_PREVIEW_BYTES = 12 * 1024 * 1024
local packages = nil
local BACKGROUNDS_DIR = "Game:\\User\\Backgrounds\\"
local CATEGORIES = {
    {key = "Skins", title = "Skins", target = SKINS_DIR, formats = {".xzp", ".zip"}},
    {key = "Layouts", title = "Layouts", target = LAYOUTS_DIR, formats = {".cfljson"}},
    {key = "Backgrounds", title = "Backgrounds", target = BACKGROUNDS_DIR,
        formats = {".jpg", ".jpeg", ".png", ".dds", ".bmp"}}
}

local function alert(title, body)
    Script.ShowMessageBox(title, body, "OK")
end

local function confirm(title, body, yes, no)
    local answer = Script.ShowMessageBox(title, body, yes or "Yes", no or "No")
    return answer ~= nil and answer.Button == 1
end

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isSafeFilename(name, extension)
    if type(name) ~= "string" or #name > 110 or #name < 5 then return false end
    if name:find("..", 1, true) or name:sub(1, 1) == "." or name:sub(-1) == " " then return false end
    if not name:match("^[A-Za-z0-9 _%(%)%.%+%-]+$") then return false end
    return name:lower():sub(-#extension) == extension
end

local function basename(path)
    return path:match("([^/]+)$") or path
end

local function isSafeMember(path, extension)
    if type(path) ~= "string" or #path > 260 or path:find("..", 1, true) then return false end
    if path:find("\\", 1, true) or path:find(":", 1, true) or path:sub(1, 1) == "/" then return false end
    if not isSafeFilename(basename(path), extension) then return false end
    local count = 0
    for part in (path .. "/"):gmatch("(.-)/") do
        count = count + 1
        if count > 16 or #part == 0 or part == "." or part:sub(-1) == " "
            or not part:match("^[A-Za-z0-9 _%(%)%.%+%-]+$") then
            return false
        end
    end
    return true
end

-- Category paths are fixed, server-supplied filenames are separately validated.

local function prettySize(bytes)
    if bytes >= 1024 * 1024 then
        return string.format("%.2f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%.1f KB", bytes / 1024)
    end
    return tostring(bytes) .. " B"
end

local function encodeUrlPath(path)
    -- Percent-encode each file path byte, keeping only folder separators intact.
    return (path:gsub("([^A-Za-z0-9%._%-%/])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function absolute(relative)
    return Script.GetBasePath() .. relative
end

local function eraseStaging()
    local folder = absolute(TEMP_REL)
    FileSystem.DeleteDirectory(folder)
end

local function prepareStaging()
    eraseStaging()
    Script.CreateDirectory("Downloads")
    Script.CreateDirectory("Downloads\\AuroraMediaBrowser")
end

-- GitHub Contents API returns JSON metadata with name, size and type.
-- Aurora's built-in HTTP client supplies the response string; the scanner only
-- admits conservative ASCII filenames in the selected category. It also ignores
-- directory entries (and any .gitkeep placeholders).
local function allowedExtension(filename, category)
    for _, ext in ipairs(category.formats) do
        if isSafeFilename(filename, ext) then return ext end
    end
    return nil
end

local function parseGitHubFiles(data, category)
    local result, seen, previewMap = {}, {}, {}
    if type(data) ~= "string" or #data > 4 * 1024 * 1024 then return result end
    for object in data:gmatch("%b{}") do
        local name = object:match('"name"%s*:%s*"([^"\\]*)"')
        local size = tonumber(object:match('"size"%s*:%s*(%d+)'))
        local kind = object:match('"type"%s*:%s*"([^"\\]*)"')
        local ext = name and allowedExtension(name, category) or nil
        if ext and kind == "file" and size and size == math.floor(size)
            and size > 0 and size <= MAX_PACKAGE_BYTES
            and not seen[name:lower()] and #result < 500 then
            seen[name:lower()] = true
            local stem = category.key == "Backgrounds" and
                (name:lower():match("^(.-)%.preview%.jpe?g$") or
                 name:lower():match("^(.-)%.preview%.png$"))
            if stem then
                -- A background's optional preview image is not a separate listing.
                if size <= MAX_PREVIEW_BYTES then
                    previewMap[stem] = {filename = name, size = size}
                end
            else
                local isZip = ext == ".zip"
                result[#result + 1] = {
                    path = "repo/" .. category.key .. "/" .. name,
                    filename = name,
                    name = name:sub(1, #name - #ext),
                    size = size, zip = isZip,
                    category = category,
                    skin = category.key == "Skins" and not isZip and name or nil,
                    layouts = {}
                }
            end
        end
    end
    for _, pkg in ipairs(result) do
        if category.key == "Backgrounds" then
            pkg.preview = previewMap[pkg.name:lower()]
        end
    end
    table.sort(result, function(a, b) return a.name:lower() < b.name:lower() end)
    return result
end

local function requestSummary(request)
    if type(request) ~= "table" then return "No response returned" end
    local pieces = {}
    for _, name in ipairs({"StatusCode", "ResponseCode", "HttpStatus", "ErrorCode", "ErrorMessage", "Error"}) do
        local value = request[name]
        if value ~= nil and type(value) ~= "table" then
            pieces[#pieces + 1] = name .. ": " .. tostring(value):sub(1, 100)
        end
    end
    if #pieces == 0 then return "HTTP failed (no status supplied)" end
    return table.concat(pieces, ", "):sub(1, 240)
end

local function fetch(url)
    local ok, response = pcall(Http.Get, url)
    if not ok then return nil, "Lua HTTP exception: " .. tostring(response):sub(1, 160) end
    if type(response) ~= "table" then return nil, "No HTTP response" end
    if response.Success ~= true then return nil, requestSummary(response) end
    if type(response.OutputData) ~= "string" or #response.OutputData == 0 then
        return nil, "HTTP succeeded, but response has no text content"
    end
    return response.OutputData, "OK"
end

local function reloadLiveList(category)
    Script.SetStatus("Reading " .. category.title .. " from GitHub...")
    Script.SetProgress(8)
    local data, issue = fetch(contentsURL(category.key))
    if not data then
        alert("Cannot load " .. category.title,
            "Could not retrieve " .. category.key .. " from " .. OWNER ..
            "/" .. REPOSITORY .. "." .. "\n\n" .. tostring(issue) ..
            "\n\nCheck GitHub availability and try Refresh List.")
        Script.SetProgress(0)
        return false
    end
    packages = parseGitHubFiles(data, category)
    Script.SetStatus("Found " .. #packages .. " " .. category.title:lower())
    Script.SetProgress(100)
    return true
end

local function installedState(pkg)
    local targetName = pkg.filename
    if pkg.category.key == "Skins" then
        targetName = pkg.skin or (pkg.zip and pkg.name .. ".xzp")
    end
    if not targetName or not FileSystem.FileExists(pkg.category.target .. targetName) then
        return ""
    end
    if pkg.category.key == "Skins" and pkg.zip then
        for _, member in ipairs(pkg.layouts) do
            if not FileSystem.FileExists(LAYOUTS_DIR .. basename(member)) then
                return "[Skin only] "
            end
        end
    end
    return "[Installed] "
end

local function copySafely(src, target)
    if not FileSystem.CopyFile(src, target, true) then return false end
    return FileSystem.FileExists(target)
        and FileSystem.GetFileSize(src) == FileSystem.GetFileSize(target)
end

local function installFiles(items)
    -- Stage all files, protect anything already installed, then copy/rollback as needed.
    local backupDir = absolute(TEMP_REL .. "backups\\")
    FileSystem.CreateDirectory(backupDir)
    for i, item in ipairs(items) do
        if not FileSystem.FileExists(item.source) then
            return false, "The package is missing " .. item.name
        end
        item.existed = FileSystem.FileExists(item.target)
        if item.existed then
            item.backup = backupDir .. tostring(i) .. ".bak"
            if not copySafely(item.target, item.backup) then
                return false, "Could not back up " .. item.name
            end
        end
    end
    for i, item in ipairs(items) do
        if not copySafely(item.source, item.target) then
            for j = i, 1, -1 do
                local previous = items[j]
                if previous.existed then
                    if not copySafely(previous.backup, previous.target) then
                        print("WARNING: rollback failed for " .. previous.target)
                    end
                else
                    FileSystem.DeleteFile(previous.target)
                end
            end
            return false, "Failed installing " .. item.name .. ". Previous files were restored if possible."
        end
    end
    return true
end

-- After a ZIP is downloaded, discover its skin and any included layouts.
-- Aurora ZipFile exposes Extract, but not a ZIP member listing method.
local function inspectExtracted(extractDir)
    local discovered, count, visited = {skins = {}, layouts = {}}, 0, {}
    local function walk(dir, relative, depth)
        if depth > 12 or count > 2000 then return false, "ZIP has too many nested files" end
        local fileEntries = FileSystem.GetFiles(dir .. "*")
        if type(fileEntries) ~= "table" then return false, "Could not scan extracted ZIP files" end
        for _, entry in pairs(fileEntries) do
            count = count + 1
            if count > 2000 then return false, "ZIP contains too many entries" end
            local filename = type(entry) == "table" and entry.Name or entry
            if type(filename) ~= "string" or filename == "" then
                return false, "Unexpected extracted filename"
            end
            filename = filename:gsub("^.*[\\/]", "")
            local lower = filename:lower()
            if lower:sub(-4) == ".xzp" or lower:sub(-8) == ".cfljson" then
                if not isSafeFilename(filename, lower:sub(-4) == ".xzp" and ".xzp" or ".cfljson") then
                    return false, "Unsafe internal filename: " .. filename
                end
                local item = {source = dir .. filename, name = filename}
                if lower:sub(-4) == ".xzp" then
                    discovered.skins[#discovered.skins + 1] = item
                else
                    if visited[lower] then return false, "Duplicate layout name: " .. filename end
                    visited[lower] = true
                    discovered.layouts[#discovered.layouts + 1] = item
                end
            end
        end
        local dirs = FileSystem.GetDirectories(dir .. "*")
        if type(dirs) ~= "table" then return false, "Could not scan extracted folders" end
        for _, entry in pairs(dirs) do
            local folder = type(entry) == "table" and entry.Name or entry
            if type(folder) ~= "string" or folder == "" then
                return false, "Unexpected ZIP folder name"
            end
            folder = folder:gsub("[\\/]$", ""):gsub("^.*[\\/]", "")
            if folder == "." or folder == ".." or folder == "" or
                folder:find("..", 1, true) or
                not folder:match("^[A-Za-z0-9 _%(%)%.%+%-]+$") then
                return false, "Unsafe ZIP folder: " .. folder
            end
            local ok, issue = walk(dir .. folder .. "\\", relative .. folder .. "\\", depth + 1)
            if not ok then return false, issue end
        end
        return true
    end
    local ok, issue = walk(extractDir, "", 0)
    if not ok then return nil, issue end
    if #discovered.skins ~= 1 then
        return nil, "ZIP needs exactly one .xzp skin (found " .. #discovered.skins .. ")"
    end
    if #discovered.layouts > 32 then return nil, "ZIP has too many layouts" end
    return discovered
end

local function downloadAndInstall(pkg)
    local category = pkg.category
    local isSkin = category.key == "Skins"
    local infoType = pkg.zip and "ZIP skin + layout bundle"
        or (isSkin and "XZP skin" or category.title:sub(1, -2))
    local action = installedState(pkg) ~= "" and "Replace" or "Install"
    local extra = pkg.zip and "\nIncluded .xzp and .cfljson files will be detected after extraction." or ""
    if not confirm(action .. " " .. category.title:sub(1,-2) .. "?",
        pkg.name .. "\n" .. prettySize(pkg.size) .. "\nType: " .. infoType ..
        extra .. "\n\nDestination: " .. category.target,
        action, "Cancel") then return end

    prepareStaging()
    local downloadRel = pkg.zip and ZIP_REL or PACKAGE_REL
    local downloadAbs = absolute(downloadRel)
    Script.SetStatus("Downloading " .. pkg.filename .. "...")
    Script.SetProgress(10)
    local okHttp, http = pcall(Http.Get, rawURL(encodeUrlPath(pkg.path)), downloadRel)
    if not okHttp or type(http) ~= "table" or http.Success ~= true then
        eraseStaging()
        alert("Download failed", "Could not download " .. pkg.path)
        Script.SetProgress(0)
        return
    end
    local downloadedFile = http.OutputPath or downloadAbs
    if not FileSystem.FileExists(downloadedFile) or
        FileSystem.GetFileSize(downloadedFile) ~= pkg.size then
        eraseStaging()
        alert("Download mismatch", "The download did not match GitHub's file size. Nothing was installed.")
        Script.SetProgress(0)
        return
    end
    Script.SetProgress(60)

    local items = {}
    if pkg.zip then
        Script.SetStatus("Extracting ZIP skin...")
        Script.SetProgress(70)
        Script.CreateDirectory("Downloads\\AuroraMediaBrowser\\unpacked")
        local archive = ZipFile.OpenFile(downloadRel)
        if not archive or archive:Extract(EXTRACT_REL) ~= true then
            eraseStaging()
            alert("ZIP extraction failed", "Aurora could not extract this ZIP.")
            Script.SetProgress(0)
            return
        end
        local found, issue = inspectExtracted(absolute(EXTRACT_REL))
        if not found then
            eraseStaging()
            alert("Unsupported ZIP contents", issue)
            Script.SetProgress(0)
            return
        end
        pkg.skin = found.skins[1].name
        pkg.layouts = {}
        items[#items + 1] = {
            source = found.skins[1].source,
            target = SKINS_DIR .. pkg.skin, name = pkg.skin
        }
        for _, layout in ipairs(found.layouts) do
            pkg.layouts[#pkg.layouts + 1] = layout.name
            items[#items + 1] = {
                source = layout.source,
                target = LAYOUTS_DIR .. layout.name, name = layout.name
            }
        end
        FileSystem.CreateDirectory(SKINS_DIR)
        FileSystem.CreateDirectory(LAYOUTS_DIR)
    else
        items[1] = {
            source = downloadedFile,
            target = category.target .. pkg.filename,
            name = pkg.filename
        }
        FileSystem.CreateDirectory(category.target)
    end

    Script.SetStatus("Installing " .. pkg.name .. "...")
    Script.SetProgress(85)
    local success, issue = installFiles(items)
    if not success then
        alert("Installation failed", issue)
        eraseStaging()
        Script.SetProgress(0)
        return
    end
    eraseStaging()
    Script.SetStatus("Installed: " .. pkg.name)
    Script.SetProgress(100)
    if isSkin then
        local info = "Installed " .. (pkg.skin or pkg.filename) .. " successfully."
        if #pkg.layouts > 0 then
            info = info .. "\n\nAlso installed " .. #pkg.layouts ..
                " layout(s) to Game:\\Media\\Layouts\\."
        end
        if confirm("Installation complete",
            info .. "\n\nApply the skin and restart Aurora?", "Apply", "Later") then
            local changed = Settings.SetSystem("Skin", pkg.skin)
            if changed == false or
                (type(changed) == "table" and changed.Success == false) then
                alert("Select skin manually", "The skin was installed, but Aurora did not accept automatic selection.")
            else
                Aurora.Restart()
            end
        end
    elseif category.key == "Layouts" then
        alert("Layout installed", pkg.filename .. " is now in " .. LAYOUTS_DIR ..
            "\n\nChoose it in Aurora's View / Theme layout settings.")
    else
        alert("Background installed", pkg.filename .. " is now in " .. BACKGROUNDS_DIR ..
            "\n\nIn Aurora's View / Theme settings, press X to refresh available backgrounds.")
    end
end

-- Background previews use the official SkinDownloader XUI preview scene.
-- Skins and layouts deliberately retain their simple text-only list.
local PREVIEW_DIR = "Previews\\"
local PREVIEW_PLACEHOLDER = "preview_unavailable.png"

local function getBackgroundPreview(pkg, index)
    local wanted = pkg.preview and ("repo/Backgrounds/" .. pkg.preview.filename) or pkg.path
    local expected = pkg.preview and pkg.preview.size or pkg.size
    local ext = wanted:lower():match("(%.[^.]+)$")
    if (ext ~= ".jpg" and ext ~= ".jpeg" and ext ~= ".png")
        or expected > MAX_PREVIEW_BYTES then
        return PREVIEW_PLACEHOLDER, false
    end
    Script.CreateDirectory("Previews")
    local relative = PREVIEW_DIR .. "background_" .. tostring(index) .. ext
    local absolutePath = absolute(relative)
    if FileSystem.FileExists(absolutePath) and
       FileSystem.GetFileSize(absolutePath) == expected then
        return relative, true
    end
    FileSystem.DeleteFile(absolutePath)
    Script.SetStatus("Loading preview for " .. pkg.name .. "...")
    Script.SetProgress(15)
    local ok, response = pcall(Http.Get, rawURL(encodeUrlPath(wanted)), relative)
    if ok and type(response) == "table" and response.Success == true and
       FileSystem.FileExists(absolutePath) and
       FileSystem.GetFileSize(absolutePath) == expected then
        Script.SetProgress(100)
        return relative, true
    end
    FileSystem.DeleteFile(absolutePath)
    Script.SetProgress(0)
    return PREVIEW_PLACEHOLDER, false
end

local function showBackgroundPreviewScene(pkg, imagePath, previewAvailable)
    if type(GizmoUI) ~= "table" or type(GizmoUI.CreateInstance) ~= "function" then
        return "unsupported"
    end
    local ok, action = pcall(function()
        local gizmo = GizmoUI.CreateInstance()
        if not gizmo then return "unsupported" end
        gizmo:RegisterCallback(0, function(this, data)
            local name = this:RegisterControl(7, "Nombre")
            local size = this:RegisterControl(7, "Autor")
            local sizeLabel = this:RegisterControl(7, "lblAutor")
            local picture = this:RegisterControl(2, "Captura")
            if name then name:SetText(data.name) end
            if size then
                size:SetText(previewAvailable and prettySize(data.size)
                    or (prettySize(data.size) .. " - Preview unavailable"))
            end
            if sizeLabel then sizeLabel:SetText("Size:") end
            if picture then picture:SetImagePath(imagePath) end
            this:SetCommandEnabled(1, true)
            this:SetCommandText(1, "Download")
            this:SetCommandEnabled(2, true)
            this:SetCommandText(2, "Next")
            this:SetCommandEnabled(3, true)
            this:SetCommandText(3, "Previous")
        end)
        gizmo:RegisterCallback(11, function(this, command)
            if command == 1 then this:Dismiss("download")
            elseif command == 2 then this:Dismiss("next")
            elseif command == 3 then this:Dismiss("previous") end
        end)
        local result = gizmo:InvokeUI(Script.GetBasePath(),
            "Background Preview", "scene.xur", "skin.xur",
            {name = pkg.name, size = pkg.size})
        return type(result) == "table" and result.Result or "back"
    end)
    if not ok then
        print("Background preview XUI failed: " .. tostring(action))
        return "unsupported"
    end
    return action
end

local function browseBackgroundPreviews(first)
    local position = first
    while #packages > 0 do
        local pkg = packages[position]
        local previewPath, available = getBackgroundPreview(pkg, position)
        local action = showBackgroundPreviewScene(pkg, previewPath, available)
        if action == "next" then
            position = position % #packages + 1
        elseif action == "previous" then
            position = (position - 2) % #packages + 1
        elseif action == "download" then
            downloadAndInstall(pkg)
            -- Return to the same preview after installation (B exits).
        elseif action == "unsupported" then
            if confirm("Background: " .. pkg.name,
                "Preview isn't available on this Aurora build.\n" ..
                "Size: " .. prettySize(pkg.size) ..
                "\n\nDownload this background?", "Download", "Back") then
                downloadAndInstall(pkg)
            end
            return
        else
            return
        end
    end
end

local function browseCategory(category)
    if not reloadLiveList(category) then return end
    while true do
        local rows = {"[ Refresh List ]"}
        if #packages == 0 then
            rows[#rows + 1] = "(No " .. category.title:lower() .. " uploaded yet)"
        else
            for _, pkg in ipairs(packages) do
                rows[#rows + 1] = installedState(pkg) .. pkg.name ..
                    "  (" .. prettySize(pkg.size) .. ")" .. (pkg.zip and " [ZIP]" or "")
            end
        end
        local response = Script.ShowPopupList(
            "Aurora Media Browser - " .. category.title .. " (" .. #packages .. ")",
            "No " .. category.title:lower(), rows)
        if not response or response.Canceled or not response.Selected then return end
        local index = tonumber(response.Selected.Key)
        if index == 1 then
            reloadLiveList(category)
        elseif index and index > 1 and packages[index - 1] then
            local pkg = packages[index - 1]
            if category.key == "Backgrounds" then
                browseBackgroundPreviews(index - 1)
            else
                local description = pkg.name .. "\nSize: " .. prettySize(pkg.size) ..
                    "\nPackage: " .. pkg.filename ..
                    "\nInstall to: " .. category.target ..
                    (pkg.zip and "\nZIP contents are scanned when downloaded" or "")
                if confirm(category.title:sub(1,-2) .. " details", description, "Download", "Back") then
                    downloadAndInstall(pkg)
                end
            end
        end
    end
end

local function browseMedia()
    -- Show three categories immediately. Each category fetches live from GitHub.
    while true do
        local options = {"Skins", "Layouts", "Backgrounds"}
        local response = Script.ShowPopupList("Aurora Media Browser", "No categories", options)
        if not response or response.Canceled or not response.Selected then return end
        local selection = tonumber(response.Selected.Key)
        if selection and CATEGORIES[selection] then
            browseCategory(CATEGORIES[selection])
        else
            return
        end
    end
end

function main()
    browseMedia()
end