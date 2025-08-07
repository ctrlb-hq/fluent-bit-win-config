-- Global variable to store the last valid timestamp
local last_valid_timestamp = nil

-- Cache for host information (computed once per process)
local host_info_cache = nil

-- Global cache for gzip file mappings (loaded once per FluentBit process)
local gzip_mapping_cache = nil
local gzip_cache_loaded = false
local gzip_cache_load_time = 0


function add_host_info(tag, timestamp, record)
    if host_info_cache then
        for key, value in pairs(host_info_cache) do
            record[key] = value
        end
        return 1, timestamp, record
    end
    
    -- Build host information cache with safe environment variable handling
    host_info_cache = {}
    
    -- Get Windows-specific host information from environment with fallbacks
    local computer_name = os.getenv("COMPUTERNAME") or "unknown"
    local user_domain = os.getenv("USERDOMAIN") or os.getenv("USERDNSDOMAIN") or "unknown"
    local processor_arch = os.getenv("PROCESSOR_ARCHITECTURE") or "unknown"
    local processor_id = os.getenv("PROCESSOR_IDENTIFIER") or "unknown"
    
    -- Build FQDN safely
    local host_fqdn = computer_name
    if user_domain and user_domain ~= "unknown" and user_domain ~= "" then
        host_fqdn = computer_name .. "." .. user_domain
    end
    
    host_info_cache = {
        host_computer_name = computer_name,
        host_domain = user_domain,
        host_architecture = processor_arch,
        host_machine_id = processor_id,
        host_fqdn = host_fqdn
    }

    for key, value in pairs(host_info_cache) do
        record[key] = value
    end

    return 1, timestamp, record
end

function convert_timestamp(tag, timestamp, record)
    -- Check if we have a parsed timestamp from the regex parser
    if record["log_timestamp"] then
        local year, month, day, hour, min, sec, msec
        
        -- Try SQL Server format first: YYYY-MM-DD HH:MM:SS.mm
        year, month, day, hour, min, sec, msec = 
            record["log_timestamp"]:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)%.(%d+)")
        
        -- If SQL Server format didn't match, try Java format: YYYY-MM-DD HH:MM:SS,mmm
        if not year then
            year, month, day, hour, min, sec, msec = 
                record["log_timestamp"]:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+),(%d+)")
        end
        
        if year and month and day and hour and min and sec and msec then
            -- Convert to Unix timestamp in seconds
            local unix_seconds = os.time({
                year = tonumber(year),
                month = tonumber(month),
                day = tonumber(day),
                hour = tonumber(hour),
                min = tonumber(min),
                sec = tonumber(sec)
            })
            
            -- Handle different millisecond formats
            local milliseconds = tonumber(msec)
            if string.len(msec) == 2 then
                -- SQL Server format: .24 means 240 milliseconds
                milliseconds = milliseconds * 10
            end
            
            -- Convert to nanoseconds
            local unix_nanoseconds = (unix_seconds * 1000000000) + (milliseconds * 1000000)
            
            -- Store the nanoseconds timestamp
            record["_timestamp"] = unix_nanoseconds
            
            -- Update the last valid timestamp for future use
            last_valid_timestamp = unix_nanoseconds
        else
            -- If parsing failed, use the last valid timestamp
            if last_valid_timestamp then
                record["_timestamp"] = last_valid_timestamp
            else
                -- If no previous timestamp exists, use current time in nanoseconds
                record["_timestamp"] = os.time() * 1000000000
            end
        end
    else
        -- No timestamp field found, use the last valid timestamp
        if last_valid_timestamp then
            record["_timestamp"] = last_valid_timestamp
        else
            -- If no previous timestamp exists, use current time in nanoseconds
            record["_timestamp"] = os.time() * 1000000000
        end
    end

    -- Add ingested time in ISO format
    record["ingestion_timestamp"] = os.date("!%Y-%m-%dT%H:%M:%SZ")
    
    return 1, timestamp, record
end

-- Function to load gzip mappings into cache (called once)
function load_gzip_mappings()
    if gzip_cache_loaded then
        return gzip_mapping_cache
    end
    
    local state_file = "C:/temp/flb-storage/gzip-processing-state.json"
    local file = io.open(state_file, "r")
    if not file then
        gzip_cache_loaded = true
        gzip_mapping_cache = {}
        return gzip_mapping_cache
    end
    
    local content = file:read("*all")
    file:close()
    
    if not content or content == "" then
        gzip_cache_loaded = true
        gzip_mapping_cache = {}
        return gzip_mapping_cache
    end
    
    -- Build a mapping table: temp_filename -> original_path
    gzip_mapping_cache = {}
    
    -- Extract all file mappings and build lookup table
    for original_path in string.gmatch(content, '"original_path"%s*:%s*"([^"]+)"') do
        -- Find corresponding temp file pattern
        local pattern = '"original_path"%s*:%s*"' .. string.gsub(original_path, "([%(%)%.%+%-%*%?%[%]%^%$%%\\])", "%%%1") .. '".-"temp_file_path"%s*:%s*"([^"]*)"'
        local temp_path = string.match(content, pattern)
        if temp_path and temp_path ~= "" then
            -- Extract just the filename for lookup
            local temp_filename = string.match(temp_path, "([^/\\]+)$")
            if temp_filename then
                -- Unescape JSON backslashes
                original_path = string.gsub(original_path, "\\\\", "\\")
                gzip_mapping_cache[temp_filename] = original_path
            end
        end
    end
    
    gzip_cache_loaded = true
    gzip_cache_load_time = os.time()
    return gzip_mapping_cache
end

-- Improved function that uses cached mappings
function map_gzip_source_path(tag, timestamp, record)
    -- Only process records from gzip inputs
    if not (tag and string.match(tag, "app%.java%.gzip%..*%.archived")) then
        return 1, timestamp, record
    end
    
    -- Check if we have a temp_file_path to map
    if not record["temp_file_path"] then
        return 1, timestamp, record
    end
    
    local temp_path = record["temp_file_path"]
    
    -- Extract the temp filename for lookup
    local temp_filename = string.match(temp_path, "([^/\\]+)$")
    if not temp_filename then
        record["source_file_path"] = temp_path
        record["temp_file_path"] = nil
        return 1, timestamp, record
    end
    
    -- Load mappings into cache (only happens once per FluentBit process)
    local mappings = load_gzip_mappings()
    
    -- Fast lookup in cached mapping table
    local original_path = mappings[temp_filename]
    
    if original_path then
        -- Successfully mapped using cache
        record["source_file_path"] = original_path
        record["extraction_timestamp"] = os.date("!%Y-%m-%dT%H:%M:%SZ")
    else
        -- Not found in cache
        record["source_file_path"] = temp_path
        record["extraction_timestamp"] = os.date("!%Y-%m-%dT%H:%M:%SZ")
    end
    
    -- Remove the temp_file_path key
    record["temp_file_path"] = nil
    
    return 1, timestamp, record
end