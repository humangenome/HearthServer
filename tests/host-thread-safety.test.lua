-- Run from the repository root: lua5.4 tests/host-thread-safety.test.lua [main.lua ...]
-- Default: the three host mods (bw_host, bw_fog, bw_seat4).
--
-- Background code must never call UE4SS's game-thread or hook functions, and never call a game
-- function (UFunction). UE4SS b50986bd's ExecuteInGameThread (and LoopInGameThread*, RegisterHook,
-- NotifyOnNewObject, the Register*Hook family) push onto and pop from the mod's hook Lua stack: the
-- same stack the game thread is running queued callbacks and hook callbacks on, with no lock
-- between the two. When the two interleave, a queued entry can point at a value that is not a
-- function ("Ref was not function": UE4SS removes its game-tick hook and every later callback is
-- skipped for the rest of the session), or a running UObject call reads a moved stack slot and the
-- game crashes. Found 2026-10-18 on 11 of 54 sessions since 10/16 and in 26 of 39 crashes.
--
-- The check is static and covers every function the background code can reach, not only paths a
-- mock happens to drive. It reads `luac5.4 -l -l` listings: function line ranges, closures, local
-- and upvalue names, global reads (GETTABUP _ENV) and method calls (SELF).
--   * Background roots: the main chunk (UE4SS runs it on its own start-up thread) and every function
--     handed to LoopAsync / ExecuteAsync / ExecuteWithDelay.
--   * Game-thread roots: every function handed to a game-thread scheduler or hook (the list below,
--     plus the mod's own queue function), so their bodies are not counted as background.
--   * Edges: a call of a named function (local, upvalue, global or table field, resolved to the
--     scope that defines it) and an inline function passed to any other call (pcall(function...)).
-- In background-reachable code it fails on: (1) any reference to a banned UE4SS function; (2) any
-- method call (obj:Name()) whose name is not a UE4SS built-in, a Lua string/file method or a known
-- table method of the mod; (3) any call of a property-write helper outside the one allowed start-up
-- path (the fast pin: GameMode/GameEngine travel settings for 12 s after host-up, proven against the
-- start-up crash and kept on purpose). The main chunk may register exactly one game-thread loop
-- (the pump) and it must be its last UE4SS call, so nothing of the mod runs on the game thread while
-- the start-up thread still touches the Lua registry.
local files = {}
for i = 1, #arg do files[#files + 1] = arg[i] end
if #files == 0 then
    files = {
        "dist/ue4ss-server/Mods/bw_host/Scripts/main.lua",
        "dist/ue4ss-server/Mods/bw_fog/Scripts/main.lua",
        "dist/ue4ss-server/Mods/bw_seat4/Scripts/main.lua",
    }
end

local BACKGROUND_SCHEDULERS = { LoopAsync = true, ExecuteAsync = true, ExecuteWithDelay = true }
local GAME_SCHEDULERS = {
    ExecuteInGameThread = true, ExecuteInGameThreadWithDelay = true, ExecuteInGameThreadAfterFrames = true,
    RetriggerableExecuteInGameThreadWithDelay = true, LoopInGameThreadWithDelay = true,
    LoopInGameThreadAfterFrames = true, RegisterHook = true, NotifyOnNewObject = true,
    RegisterCustomEvent = true, RegisterKeyBind = true, RegisterKeyBindAsync = true,
    RegisterConsoleCommandHandler = true, RegisterConsoleCommandGlobalHandler = true,
    RegisterLoadMapPreHook = true, RegisterLoadMapPostHook = true, RegisterInitGameStatePreHook = true,
    RegisterInitGameStatePostHook = true, RegisterBeginPlayPreHook = true, RegisterBeginPlayPostHook = true,
    RegisterEndPlayPreHook = true, RegisterEndPlayPostHook = true, RegisterProcessConsoleExecPreHook = true,
    RegisterProcessConsoleExecPostHook = true, RegisterCallFunctionByNameWithArgumentsPreHook = true,
    RegisterCallFunctionByNameWithArgumentsPostHook = true, RegisterULocalPlayerExecPreHook = true,
    RegisterULocalPlayerExecPostHook = true, UnregisterHook = true,
    -- the mods' own game-thread queue (callbacks handed to it run on the game thread)
    executeInGameThreadSafe = true, gtQueue = true,
    -- bw_host's start-up registrations, run in the pump's first run on the game thread
    atBoot = true,
}
local PUMP_REGISTRARS = { LoopInGameThreadWithDelay = true, LoopInGameThreadAfterFrames = true }
-- UE4SS functions that run on the caller's own Lua stack (object lookups and reads): allowed in
-- background code for now (coordinator's option 1, 2026-10-18); counted for the record.
local UE4SS_READS = { FindAllOf = true, FindFirstOf = true, StaticFindObject = true, FindObject = true,
    FindObjects = true, ForEachUObject = true, CreateInvalidObject = true, FName = true, FText = true,
    print = true }
-- UE4SS built-in methods (no game code runs) plus Lua string and file methods.
local ALLOWED_METHODS = {}
for name in ([[IsValid IsValidField GetFName GetFullName GetClass GetOuter GetSuperStruct GetArrayNum
    GetAddress ForEachProperty ForEachFunction IsA GetPropertyValue GetOffset_Internal GetFunctionFlags
    ForEach get type ToString IsClass HasAllFlags HasAnyFlags GetCDO Reflection GetFlags
    find match gsub sub lower upper gmatch rep byte format len reverse
    close write read lines seek flush setvbuf]]):gmatch("%S+") do ALLOWED_METHODS[name] = true end
local WRITE_HELPERS = { writeOptionalField = true, setOptionalField = true, setNetField = true, set_prop = true }
-- helpers that call a game function through a field lookup (fn(obj, ...)), which the SELF check cannot see
local CALL_HELPERS = { callMethod = true }
-- the fast pin (kept on purpose, see header) and nothing else may write from background code
local WRITE_ALLOWED_IN = { fastPinTick = true, pinMatchState = true, suppressTravel = true }

local function listing(path)
    local p = assert(io.popen("luac5.4 -l -l -p '" .. path .. "' 2>&1"))
    local out = p:read("*a")
    p:close()
    assert(out:find("main <", 1, true), "luac failed for " .. path .. ":\n" .. out)
    return out
end

local function parse(text)
    local protos, order, cur, section = {}, {}, nil, nil
    for line in text:gmatch("[^\n]+") do
        local a1, a2, addr = line:match("^main <[^:]*:(%d+),(%d+)> %(%d+ instructions? at (0x%x+)%)")
        local isMain = a1 ~= nil
        if not a1 then a1, a2, addr = line:match("^function <[^:]*:(%d+),(%d+)> %(%d+ instructions? at (0x%x+)%)") end
        if a1 then
            cur = { addr = addr, first = tonumber(a1), last = tonumber(a2), main = isMain, code = {},
                locals = {}, upvals = {}, children = {} }
            protos[addr] = cur; order[#order + 1] = cur; section = "code"
        elseif line:match("^constants %(") then section = "k"
        elseif line:match("^locals %(") then section = "locals"
        elseif line:match("^upvalues %(") then section = "upvals"
        elseif cur and section == "code" then
            local pc, ln, op, args = line:match("^%s+(%d+)%s+%[(%d+)%]%s+(%u+)%s*(.*)$")
            if pc then
                local regs, comment = args:match("^(.-)%s*;%s*(.*)$")
                if not regs then regs, comment = args, "" end
                local nums = {}
                for n in regs:gmatch("%-?%d+") do nums[#nums + 1] = tonumber(n) end
                cur.code[#cur.code + 1] = { pc = tonumber(pc), line = tonumber(ln), op = op, a = nums[1], b = nums[2],
                    c = nums[3], comment = comment or "" }
            end
        elseif cur and section == "locals" then
            local name, s, e = line:match("^%s+%d+%s+(%S+)%s+(%d+)%s+(%d+)")
            if name then cur.locals[#cur.locals + 1] = { name = name, s = tonumber(s), e = tonumber(e) } end
        elseif cur and section == "upvals" then
            local name = line:match("^%s+%d+%s+(%S+)%s+%d+%s+%d+")
            if name then cur.upvals[#cur.upvals + 1] = name end
        end
    end
    return protos, order
end

local function analyze(path)
    local protos, order = parse(listing(path))
    local main = order[1]
    -- parent links from CLOSURE instructions
    for _, p in ipairs(order) do
        for _, ins in ipairs(p.code) do
            if ins.op == "CLOSURE" then
                local child = ins.comment:match("(0x%x+)")
                if child and protos[child] then protos[child].parent = p; p.children[#p.children + 1] = protos[child] end
            end
        end
    end
    -- register -> local name at pc (active locals, in declaration order, occupy registers 0..n-1)
    local function localAt(p, reg, pc)
        local idx = -1
        for _, l in ipairs(p.locals) do
            if l.s <= pc and pc < l.e then
                idx = idx + 1
                if idx == reg then return l.name end
            end
        end
        return nil
    end
    local function startsLocal(p, reg, pc)
        -- a local that comes into scope right at this store (local x = ...; local function x)
        local idx = -1
        for _, l in ipairs(p.locals) do
            if l.s <= pc + 1 and pc + 1 < l.e then
                idx = idx + 1
                if idx == reg and (l.s == pc or l.s == pc + 1) then return l.name end
            end
        end
        return nil
    end
    -- the scope that defines a root name seen from proto p: p itself if it is a local there,
    -- else the nearest ancestor that declares a local of that name, else the global scope
    local function scopeOf(p, root, pcLocal)
        if pcLocal then return p end
        local q = p.parent
        while q do
            for _, l in ipairs(q.locals) do if l.name == root then return q end end
            q = q.parent
        end
        return "G"
    end
    local function key(scope, name) return (scope == "G" and "G" or scope.addr) .. "|" .. name end

    local bindings = {}      -- key -> { proto, ... }
    local refs = {}          -- proto -> { key, ... } (named references)
    local inline = {}        -- proto -> { childProto, ... }
    local gameRoots, bgRoots = {}, {}
    local banned = {}        -- proto -> { {name, line}, ... }
    local methods = {}       -- proto -> { {name, line}, ... }
    local mainApi = {}       -- ordered UE4SS references in the main chunk { name, pc, line }
    local function bind(k, child) bindings[k] = bindings[k] or {}; table.insert(bindings[k], child) end
    local function push(t, p, v) t[p] = t[p] or {}; table.insert(t[p], v) end

    for _, p in ipairs(order) do
        local reg = {}       -- register -> { key = <ref key>, name = <dotted>, closure = proto, tbl = {pending fields} }
        local lastLoad = {}  -- register -> pc of the load that set it
        local function nameOfReg(r, pc)
            if reg[r] and reg[r].name then return reg[r].name, reg[r].scope end
            local ln = localAt(p, r, pc)
            if ln then return ln, p end
            return nil
        end
        for _, ins in ipairs(p.code) do
            local op, A, B, C, pc = ins.op, ins.a, ins.b, ins.c, ins.pc
            local function global(field)
                reg[A] = { name = field, scope = "G", global = field }
                if GAME_SCHEDULERS[field] or BACKGROUND_SCHEDULERS[field] or UE4SS_READS[field] then
                    if p.main then mainApi[#mainApi + 1] = { name = field, pc = pc, line = ins.line } end
                end
                if GAME_SCHEDULERS[field] and field ~= "executeInGameThreadSafe" and field ~= "gtQueue" then
                    push(banned, p, { field, ins.line })
                end
            end
            if op == "GETUPVAL" then
                local nm = p.upvals[B + 1]
                if nm == "_ENV" then reg[A] = { env = true }
                else reg[A] = nm and { name = nm, scope = scopeOf(p, nm, false) } or {} end
            elseif op == "LOADK" or op == "LOADKX" then
                local str = ins.comment:match('^"(.*)"$')
                reg[A] = str and { str = str } or {}
            elseif op == "GETTABUP" then
                local up, field = ins.comment:match('^(%S+) "([^"]*)"')
                if up == "_ENV" then global(field)
                elseif up and field then
                    reg[A] = { name = up .. "." .. field, scope = scopeOf(p, up, false) }
                else reg[A] = {} end
            elseif op == "GETTABLE" then
                -- a function with more than 255 constants loads the key with LOADK
                local field = reg[C] and reg[C].str
                if field and reg[B] and reg[B].env then global(field)
                elseif field then
                    local base, scope = nameOfReg(B, pc)
                    reg[A] = base and { name = base .. "." .. field, scope = scope } or {}
                else reg[A] = {} end
            elseif op == "GETFIELD" then
                local field = ins.comment:match('"([^"]*)"')
                local base, scope = nameOfReg(B, pc)
                reg[A] = (base and field) and { name = base .. "." .. field, scope = scope } or {}
            elseif op == "MOVE" then
                local nm, scope = nameOfReg(B, pc)
                local src = reg[B] or {}
                reg[A] = { name = nm, scope = scope, closure = src.closure, global = src.global, tbl = src.tbl }
            elseif op == "SELF" then
                local m = ins.comment:match('"([^"]*)"') or (reg[C] and reg[C].str)
                if m then push(methods, p, { m, ins.line }) end
                reg[A] = {}; reg[A + 1] = {}
            elseif op == "CLOSURE" then
                local child = protos[ins.comment:match("(0x%x+)")]
                reg[A] = { closure = child }
                local ln = startsLocal(p, A, pc)
                if ln and child then bind(key(p, ln), child) end
            elseif op == "NEWTABLE" then
                reg[A] = { tbl = {} }
                local ln = startsLocal(p, A, pc)
                if ln then reg[A].tblName, reg[A].tblScope = ln, p end
            elseif op == "SETFIELD" then
                local field = ins.comment:match('"([^"]*)"')
                local src = reg[C] or {}
                if field and src.closure then
                    local base, scope = nameOfReg(A, pc)
                    if base then bind(key(scope, base .. "." .. field), src.closure)
                    elseif reg[A] and reg[A].tbl then reg[A].tbl[field] = src.closure end
                end
            elseif op == "SETTABLE" then
                local field = reg[B] and reg[B].str
                local src = reg[C] or {}
                if field and src.closure then
                    if reg[A] and reg[A].env then bind(key("G", field), src.closure)
                    else
                        local base, scope = nameOfReg(A, pc)
                        if base then bind(key(scope, base .. "." .. field), src.closure)
                        elseif reg[A] and reg[A].tbl then reg[A].tbl[field] = src.closure end
                    end
                end
            elseif op == "SETTABUP" then
                local up, field = ins.comment:match('^(%S+) "([^"]*)"')
                local src = reg[C] or {}
                if up and field and src.closure then
                    if up == "_ENV" then bind(key("G", field), src.closure)
                    else bind(key(scopeOf(p, up, false), up .. "." .. field), src.closure) end
                end
            elseif op == "SETUPVAL" then
                local nm = p.upvals[B + 1]
                local src = reg[A] or {}
                if nm and src.closure then bind(key(scopeOf(p, nm, false), nm), src.closure) end
            elseif op == "CALL" or op == "TAILCALL" then
                local callee = reg[A] or {}
                local cname = callee.global or (callee.name and callee.name:match("([%w_]+)$"))
                local nargs = (B and B > 0) and (B - 1) or 16
                -- pcall(Scheduler, ...) calls the scheduler: treat it as that call
                if (cname == "pcall" or cname == "xpcall") and reg[A + 1] then
                    local inner = reg[A + 1]
                    local iname = inner.global or (inner.name and inner.name:match("([%w_]+)$"))
                    if iname and (GAME_SCHEDULERS[iname] or BACKGROUND_SCHEDULERS[iname]) then
                        callee, cname, A, nargs = inner, iname, A + 1, nargs - 1
                    end
                end
                local isGame = cname and GAME_SCHEDULERS[cname]
                local isBg = cname and BACKGROUND_SCHEDULERS[cname]
                if callee.closure then push(inline, p, callee.closure) end
                if callee.name and not callee.global then push(refs, p, key(callee.scope, callee.name)) end
                if callee.global then push(refs, p, key("G", callee.global)) end
                for r = A + 1, A + nargs do
                    local v = reg[r]
                    if v then
                        local target = v.closure
                        local tkey = (not v.closure and v.name) and key(v.scope, v.name) or nil
                        if isGame then
                            if target then gameRoots[target] = true end
                            if tkey then gameRoots[tkey] = true end
                        elseif isBg then
                            if target then bgRoots[target] = true end
                            if tkey then bgRoots[tkey] = true end
                        else
                            if target then push(inline, p, target) end
                            -- a named function passed as an argument (callback) may be called by the callee
                            if tkey and v.name and not v.global then push(refs, p, tkey) end
                        end
                    end
                end
                for r = A, A + nargs do reg[r] = nil end
            end
            -- a table built in a constructor and then stored into a local: bind its function fields
            if op ~= "NEWTABLE" then
                for r, v in pairs(reg) do
                    if v.tbl and not v.tblName then
                        local ln = startsLocal(p, r, pc)
                        if ln then v.tblName, v.tblScope = ln, p end
                    end
                    if v.tbl and v.tblName then
                        for f, child in pairs(v.tbl) do bind(key(v.tblScope, v.tblName .. "." .. f), child) end
                        v.tbl = {}
                    end
                end
            end
        end
    end

    -- resolve keys to protos
    local function protosOf(k)
        if type(k) == "table" then return { k } end
        return bindings[k] or {}
    end
    local isGameRoot = {}
    for r in pairs(gameRoots) do for _, q in ipairs(protosOf(r)) do isGameRoot[q] = true end end
    -- background reachability
    local reach, queue, via = {}, {}, {}
    local function visit(q, from)
        -- a function handed to a game-thread scheduler is not reached through that hand-over (it is
        -- not an edge), but a direct call from background code still reaches it
        if not q or reach[q] then return end
        reach[q] = true; via[q] = from; queue[#queue + 1] = q
    end
    visit(main, nil)
    for r in pairs(bgRoots) do for _, q in ipairs(protosOf(r)) do visit(q, main) end end
    local i = 1
    while i <= #queue do
        local q = queue[i]; i = i + 1
        for _, c in ipairs(inline[q] or {}) do visit(c, q) end
        for _, k in ipairs(refs[q] or {}) do for _, t in ipairs(protosOf(k)) do visit(t, q) end end
    end

    -- the name a proto is bound to (for messages and the write allowlist)
    local nameOf = {}
    for k, list in pairs(bindings) do
        local nm = k:match("|(.*)$")
        for _, q in ipairs(list) do nameOf[q] = nameOf[q] or nm end
    end
    local function where(q)
        local n = nameOf[q] or (q.main and "main chunk") or "function"
        return string.format("%s (lines %d-%d)", n, q.first, q.last)
    end
    local function chain(q)
        local parts, n = {}, 0
        while q and n < 8 do parts[#parts + 1] = nameOf[q] or (q.main and "main") or ("fn@" .. q.first); q = via[q]; n = n + 1 end
        return table.concat(parts, " <- ")
    end
    local function inWriteAllowed(q)
        local n = 0
        while q and n < 6 do
            local nm = nameOf[q] and nameOf[q]:match("([%w_]+)$")
            if nm and WRITE_ALLOWED_IN[nm] then return true end
            -- inline closures inherit their parent's name
            if nameOf[q] then break end
            q = q.parent; n = n + 1
        end
        return false
    end

    local problems, reads = {}, 0
    for q in pairs(reach) do
        for _, b in ipairs(banned[q] or {}) do
            if not q.main then
                problems[#problems + 1] = string.format("line %d: background code references %s in %s [%s]", b[2], b[1], where(q), chain(q))
            end
        end
        for _, m in ipairs(methods[q] or {}) do
            if not ALLOWED_METHODS[m[1]] then
                problems[#problems + 1] = string.format("line %d: background code calls game function :%s() in %s [%s]", m[2], m[1], where(q), chain(q))
            end
        end
        for _, k in ipairs(refs[q] or {}) do
            local nm = k:match("|(.*)$"):match("([%w_]+)$")
            if CALL_HELPERS[nm] then
                problems[#problems + 1] = string.format("background code calls a game function through %s in %s [%s]", nm, where(q), chain(q))
            end
            if WRITE_HELPERS[nm] and not inWriteAllowed(q) then
                problems[#problems + 1] = string.format("background code writes an object property (%s) in %s [%s]", nm, where(q), chain(q))
            end
        end
    end
    -- the main chunk: only background schedulers and exactly one pump, registered last
    local pumps, lastApi, pumpAt = 0, nil, nil
    for _, api in ipairs(mainApi) do
        if PUMP_REGISTRARS[api.name] then pumps = pumps + 1; pumpAt = api.pc
        elseif GAME_SCHEDULERS[api.name] and api.name ~= "executeInGameThreadSafe" and api.name ~= "gtQueue" then
            problems[#problems + 1] = string.format("line %d: the main chunk calls %s (start-up thread)", api.line, api.name)
        end
        if UE4SS_READS[api.name] then reads = reads + 1 end
        lastApi = api
    end
    if pumps ~= 1 then
        problems[#problems + 1] = string.format("the main chunk must register exactly one game-thread pump, found %d", pumps)
    elseif lastApi and lastApi.pc ~= pumpAt then
        problems[#problems + 1] = string.format("line %d: %s is called after the pump is registered; the pump must be the main chunk's last UE4SS call", lastApi.line, lastApi.name)
    end
    local reachCount = 0
    for _ in pairs(reach) do reachCount = reachCount + 1 end
    return problems, reachCount, #order
end

local failed = 0
for _, path in ipairs(files) do
    local problems, reachable, total = analyze(path)
    local unique, seen = {}, {}
    for _, p in ipairs(problems) do if not seen[p] then seen[p] = true; unique[#unique + 1] = p end end
    problems = unique
    table.sort(problems)
    if #problems > 0 then
        failed = failed + 1
        io.stderr:write(("FAIL %s: %d problem(s)\n"):format(path, #problems))
        for _, p in ipairs(problems) do io.stderr:write("  " .. p .. "\n") end
    else
        print(("ok - %s: %d of %d functions reachable from background code, no game-thread/hook API, no game function, no property write outside the fast pin; one pump registered last"):format(path, reachable, total))
    end
end
os.exit(failed == 0 and 0 or 1)
