std             = "ngx_lua"
unused_args     = false
redefined       = false
max_line_length = false


globals = {
    "_KONG",
    "kong",
    "ngx.IS_CLI",
    "string.pack",
    "string.unpack",
}


not_globals = {
    "string.len",
    "table.getn",
}


ignore = {
    "6.", -- ignore whitespace warnings
}


exclude_files = {
    --"spec/fixtures/invalid-module.lua",
    --"spec-old-api/fixtures/invalid-module.lua",
}


files["spec/**/*.lua"] = {
    std = "ngx_lua+busted",
}
