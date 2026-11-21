-- ============================================================================
-- IN-PROCESS UE5 IOSTORE (.utoc) / LEGACY (.pak) / CSM MANIFEST SCANNER
-- ============================================================================

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")

local PakScanner = {}

local SKIP_CONTAINERS = {
    ["pagoda-windows.utoc"] = true,
    ["pagoda-windows.pak"] = true,
    ["global.utoc"] = true,
    ["global.pak"] = true,
}

local function ReadAll(path)
    if type(path) ~= "string" or path == "" then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("a")
    f:close()
    return data
end

local function FileExists(path)
    if type(path) ~= "string" or path == "" then return false end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

function PakScanner.FindPaksRoot()
    local modRoot = UObjectUtils.GetModRootDir()
    local pagodaRoot = modRoot:match("^(.*)/Binaries/Win64/ue4ss/Mods/[^/]+/$")
    local candidates = {}
    if pagodaRoot then
        candidates[#candidates + 1] = pagodaRoot .. "/Content/Paks"
    end
    for _, rel in ipairs({
        "..\\..\\..\\Content\\Paks",
        "..\\..\\Content\\Paks",
        "Pagoda\\Content\\Paks",
        "..\\..\\..\\Pagoda\\Content\\Paks",
        "..\\Content\\Paks",
    }) do
        candidates[#candidates + 1] = rel
    end
    for _, root in ipairs(candidates) do
        if FileExists(root .. "/Pagoda-Windows.utoc")
            or FileExists(root .. "/global.utoc")
            or FileExists(root .. "\\Pagoda-Windows.utoc")
            or FileExists(root .. "\\global.utoc") then
            return root
        end
    end
    return nil
end

local function CollectFilesRecursive(dirTable, outUtocs, outPaks, outInfos, seen)
    if type(dirTable) ~= "table" then return end
    if type(dirTable.__files) == "table" then
        for _, fileEntry in pairs(dirTable.__files) do
            if type(fileEntry) == "table" then
                local fpath = fileEntry.__absolute_path or fileEntry.__full_path or fileEntry.__name
                if type(fpath) == "string" and fpath ~= "" then
                    local lowPath = fpath:lower()
                    local fname = (fpath:match("([^\\/]+)$") or ""):lower()
                    if fname ~= "" and not SKIP_CONTAINERS[fname] and not seen[lowPath] then
                        if lowPath:sub(-5) == ".utoc" then
                            seen[lowPath] = true
                            outUtocs[#outUtocs + 1] = fpath
                        elseif lowPath:sub(-4) == ".pak" then
                            seen[lowPath] = true
                            outPaks[#outPaks + 1] = fpath
                        elseif fname == "info.json" then
                            seen[lowPath] = true
                            outInfos[#outInfos + 1] = fpath
                        end
                    end
                end
            end
        end
    end
    for k, v in pairs(dirTable) do
        if k ~= "__name" and k ~= "__absolute_path" and k ~= "__full_path" and k ~= "__files" and type(v) == "table" then
            CollectFilesRecursive(v, outUtocs, outPaks, outInfos, seen)
        end
    end
end

local function ListContainerFiles(root)
    local utocs, paks, infos, seen = {}, {}, {}, {}

    if type(IterateGameDirectories) == "function" then
        pcall(function()
            local dirs = IterateGameDirectories()
            if dirs and dirs.Game and dirs.Game.Content and dirs.Game.Content.Paks then
                CollectFilesRecursive(dirs.Game.Content.Paks, utocs, paks, infos, seen)
            end
        end)
    end

    if (#utocs == 0 and #paks == 0) and root then
        local winRoot = root:gsub("/", "\\")
        local function scanExt(ext, dest)
            local ok, p = pcall(io.popen, 'dir /b /s /a-d "' .. winRoot .. '\\*' .. ext .. '" 2>nul')
            if ok and p then
                for line in p:lines() do
                    local fname = (line:match("([^\\/]+)$") or ""):lower()
                    local lowLine = line:lower()
                    if fname ~= "" and not SKIP_CONTAINERS[fname] and not seen[lowLine] then
                        seen[lowLine] = true
                        dest[#dest + 1] = line
                    end
                end
                p:close()
            end
        end
        scanExt(".utoc", utocs)
        scanExt(".pak", paks)
    end

    return utocs, paks, infos
end

local function ParseUtocPaths(data)
    if not data or #data < 144 then return nil end
    local u = string.unpack
    local hdrSize, entryCount, cblkCount, _cblkEntrySize, cmethCount, cmethLen, _cblkSize, dirIdxSize =
        u("<I4I4I4I4I4I4I4I4", data, 21)
    local flags = data:byte(81)
    if (flags & 2) ~= 0 then return nil end
    if (flags & 8) == 0 or dirIdxSize == 0 then return nil end
    local seeds = u("<I4", data, 85)
    local noHash = u("<I4", data, 97)

    local off = hdrSize
    off = off + entryCount * 12 + entryCount * 10 + seeds * 4 + noHash * 4
    off = off + cblkCount * 12 + cmethCount * cmethLen
    if (flags & 4) ~= 0 then
        local hs = u("<I4", data, off + 1)
        off = off + 4 + hs * 2 + cblkCount * 20
    end

    local d = data:sub(off + 1, off + dirIdxSize)
    if #d < 16 then return nil end
    local p = 1
    local function fstr()
        if p + 3 > #d then return "" end
        local n = u("<i4", d, p); p = p + 4
        if n == 0 then return "" end
        if n < 0 then
            local raw = d:sub(p, p + (-n * 2) - 1); p = p + (-n * 2)
            return (raw:gsub("(.)%z", "%1")):sub(1, -2)
        end
        local s = d:sub(p, p + n - 2); p = p + n
        return s
    end

    local mount = fstr()
    local nd = u("<I4", d, p); p = p + 4
    local dirs = {}
    for i = 0, nd - 1 do
        local a, b, c, e = u("<I4I4I4I4", d, p); p = p + 16
        dirs[i] = { a, b, c, e }
    end
    local nf = u("<I4", d, p); p = p + 4
    local files = {}
    for i = 0, nf - 1 do
        local a, b = u("<I4I4", d, p); p = p + 12
        files[i] = { a, b }
    end
    local ns = u("<I4", d, p); p = p + 4
    local names = {}
    for i = 0, ns - 1 do names[i] = fstr() end

    local NONE = 0xFFFFFFFF
    local out = {}
    local function walk(di, prefix, depth)
        if depth > 64 then return end
        while di ~= NONE and dirs[di] do
            local nameIdx, child, sib, firstFile = dirs[di][1], dirs[di][2], dirs[di][3], dirs[di][4]
            local path = prefix
            if nameIdx ~= NONE then path = prefix .. (names[nameIdx] or "") .. "/" end
            local f = firstFile
            while f ~= NONE and files[f] do
                out[#out + 1] = mount .. path .. (names[files[f][1]] or "")
                f = files[f][2]
            end
            if child ~= NONE then walk(child, path, depth + 1) end
            di = sib
        end
    end
    walk(0, "", 0)
    return out
end

local function ParseLegacyPakPaths(data)
    if not data or #data < 64 then return nil end
    local tail = (#data > 2097152) and data:sub(-2097152) or data
    local out, seen = {}, {}
    for path in tail:gmatch("[A-Za-z0-9_%-/.]+%.uasset") do
        if not seen[path] then
            seen[path] = true
            out[#out + 1] = path
        end
    end
    return out
end

local function ToObjectPath(filePath)
    local rel = filePath:match("[Pp]agoda/[Cc]ontent/(.+)%.uasset$")
        or filePath:match("^/?[Cc]ontent/(.+)%.uasset$")
        or filePath:match("^/?[Gg]ame/(.+)%.uasset$")
    if not rel then return nil end
    local name = rel:match("([^/]+)$")
    if not name then return nil end
    return "/Game/" .. rel .. "." .. name, name
end

local function ReadInfoJson(dirPath)
    if not dirPath then return nil end
    local data = ReadAll(dirPath .. "\\info.json") or ReadAll(dirPath .. "/info.json")
    if not data then return nil end
    return {
        CharacterName = data:match('"CharacterName"%s*:%s*"([^"]+)"')
            or data:match('"Name"%s*:%s*"([^"]+)"')
            or data:match('"DisplayName"%s*:%s*"([^"]+)"'),
        DisplayName = data:match('"DisplayName"%s*:%s*"([^"]+)"'),
        Author = data:match('"Author"%s*:%s*"([^"]+)"')
            or data:match('"Creator"%s*:%s*"([^"]+)"'),
        Version = data:match('"Version"%s*:%s*"([^"]+)"'),
        Description = data:match('"Description"%s*:%s*"([^"]+)"'),
        CosmeticDefPath = data:match('"CosmeticDefPath"%s*:%s*"([^"]+)"')
            or data:match('"CosmeticPath"%s*:%s*"([^"]+)"'),
        MeshPath = data:match('"MeshPath"%s*:%s*"([^"]+)"')
            or data:match('"SkeletalMesh"%s*:%s*"([^"]+)"'),
        AnimBPPath = data:match('"AnimBPPath"%s*:%s*"([^"]+)"')
            or data:match('"AnimBlueprint"%s*:%s*"([^"]+)"'),
    }
end

local function CollectFromPaths(paths, containerPath, results, seenKeys)
    if type(paths) ~= "table" then return end
    local byFolder = {}

    for _, fp in ipairs(paths) do
        local normFp = fp:gsub("\\", "/")
        local lower = normFp:lower()
        if lower:sub(-7) == ".uasset"
            and (lower:find("/characters/", 1, true)
                or lower:find("/moddedcharacters/", 1, true)
                or lower:find("/csm/", 1, true)
                or lower:find("/customcharacters/", 1, true)) then
            local objPath, assetName = ToObjectPath(normFp)
            local folder = normFp:match("/[Mm]odded[Cc]haracters/([^/]+)/")
                or normFp:match("/[Cc]ustom[Cc]haracters/([^/]+)/")
                or normFp:match("/[Cc][Ss][Mm]/([^/]+)/")
                or normFp:match("/([^/]+)/[^/]+%.uasset$")

            if objPath and folder then
                local an = assetName:lower()
                local isModFolder = (lower:find("/moddedcharacters/", 1, true) ~= nil)
                    or (lower:find("/csm/", 1, true) ~= nil)
                    or (lower:find("/customcharacters/", 1, true) ~= nil)

                local entry = byFolder[folder]
                if an:find("^ppcd_") or an:find("^playercosmetic_") then
                    entry = entry or { Folder = folder, MaterialPaths = {} }
                    entry.CosmeticDefPath = objPath
                    entry.IsModFolder = entry.IsModFolder or isModFolder
                    byFolder[folder] = entry
                elseif (an:find("^sk_") or an:find("^skm_"))
                    and not an:find("_skeleton$")
                    and not an:find("^sk_charlie")
                    and not an:find("^skm_charlie")
                    and not an:find("jacket")
                    and not an:find("glasses")
                    and not an:find("drumstick") then
                    entry = entry or { Folder = folder, MaterialPaths = {} }
                    if not entry.MeshPath or an == ("sk_" .. folder:lower()) or an == ("skm_" .. folder:lower()) then
                        entry.MeshPath = objPath
                    end
                    entry.IsModFolder = entry.IsModFolder or isModFolder
                    byFolder[folder] = entry
                elseif an:find("^pbap_") or an:find("^abp_") then
                    entry = entry or { Folder = folder, MaterialPaths = {} }
                    if not entry.AnimBPPath or an:find("^pbap_") then
                        entry.AnimBPPath = objPath .. "_C"
                    end
                    entry.IsModFolder = entry.IsModFolder or isModFolder
                    byFolder[folder] = entry
                elseif an:find("^mi_") and isModFolder then
                    entry = entry or { Folder = folder, MaterialPaths = {} }
                    entry.MaterialPaths[#entry.MaterialPaths + 1] = objPath
                    entry.IsModFolder = true
                    byFolder[folder] = entry
                end
            end
        end
    end

    local dir = containerPath:match("^(.*)[\\/][^\\/]+$")
    local info = ReadInfoJson(dir)
    local infoName = info and info.CharacterName or nil
    local container = containerPath:match("([^\\/]+)$") or containerPath

    for folder, e in pairs(byFolder) do
        if e.CosmeticDefPath or (e.MeshPath and e.IsModFolder) then
            local matchesInfo = (infoName ~= nil and infoName:lower() == folder:lower())
            local name = matchesInfo and infoName or folder
            local isTemplate = (folder:lower() == "testcharacter")
                and (infoName ~= nil and infoName:lower() ~= "testcharacter")

            local dedupeKey = (e.MeshPath or e.CosmeticDefPath or name):lower()
            if not seenKeys[dedupeKey] then
                seenKeys[dedupeKey] = true
                e.Container = container
                e.Name = (matchesInfo and info and info.DisplayName) or name
                e.RawFolderName = folder
                e.Author = (matchesInfo and info and info.Author) or nil
                e.Version = (matchesInfo and info and info.Version) or nil
                e.Description = (matchesInfo and info and info.Description) or nil
                e.IsTemplate = isTemplate
                results[#results + 1] = e
            end
        end
    end
end

function PakScanner.ScanCharacterMods(includeTemplates)
    local results, seenKeys = {}, {}
    local root = PakScanner.FindPaksRoot()
    local utocs, paks, infos = ListContainerFiles(root)

    if #utocs == 0 and #paks == 0 and #infos == 0 and not root then
        Logger.Warn("PakScanner", "Could not locate Pagoda/Content/Paks directory.")
        return results
    end

    local utocStems = {}
    for _, utoc in ipairs(utocs) do
        utocStems[utoc:lower():gsub("%.utoc$", "")] = true
        local raw = ReadAll(utoc)
        if raw then
            local ok, paths = pcall(ParseUtocPaths, raw)
            if ok and paths then
                CollectFromPaths(paths, utoc, results, seenKeys)
            end
        end
    end

    for _, pak in ipairs(paks) do
        local stem = pak:lower():gsub("%.pak$", "")
        if not utocStems[stem] then
            local raw = ReadAll(pak)
            if raw then
                local ok, paths = pcall(ParseLegacyPakPaths, raw)
                if ok and paths then
                    CollectFromPaths(paths, pak, results, seenKeys)
                end
            end
        end
    end

    for _, infoPath in ipairs(infos) do
        local dir = infoPath:match("^(.*)[\\/][^\\/]+$")
        local info = ReadInfoJson(dir)
        if info and info.CharacterName and (info.MeshPath or info.CosmeticDefPath) then
            local dedupeKey = (info.MeshPath or info.CosmeticDefPath):lower()
            if not seenKeys[dedupeKey] then
                seenKeys[dedupeKey] = true
                results[#results + 1] = {
                    Name = info.DisplayName or info.CharacterName,
                    Folder = info.CharacterName,
                    Container = "info.json",
                    Author = info.Author,
                    Version = info.Version,
                    Description = info.Description,
                    CosmeticDefPath = info.CosmeticDefPath,
                    MeshPath = info.MeshPath,
                    AnimBPPath = info.AnimBPPath,
                    MaterialPaths = {},
                    IsModFolder = true,
                    IsTemplate = false,
                }
            end
        end
    end

    local filtered = {}
    for _, e in ipairs(results) do
        if includeTemplates or not e.IsTemplate then
            filtered[#filtered + 1] = e
        end
    end

    table.sort(filtered, function(a, b) return tostring(a.Name) < tostring(b.Name) end)
    Logger.Info("PakScanner", "Discovered %d CSM character(s) across %d .utoc / %d .pak.", #filtered, #utocs, #paks)
    return filtered
end

function PakScanner.LoadObject(objPath)
    return UObjectUtils.LoadObject(objPath)
end

return PakScanner
