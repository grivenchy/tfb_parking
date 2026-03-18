Locales = Locales or {}

local DEFAULT_LOCALE = "en"

local function ResolveLocale()
    if Config and type(Config.Locale) == "string" and Locales[Config.Locale] then
        return Config.Locale
    end

    return DEFAULT_LOCALE
end

function Lang(key, vars)
    local locale = ResolveLocale()
    local dictionary = Locales[locale] or Locales[DEFAULT_LOCALE] or {}
    local phrase = dictionary[key] or key

    if vars then
        for varName, value in pairs(vars) do
            phrase = phrase:gsub("%%{" .. varName .. "}", tostring(value))
        end
    end

    return phrase
end
