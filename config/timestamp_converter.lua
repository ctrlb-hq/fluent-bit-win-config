-- Global variable to store the last valid timestamp
local last_valid_timestamp = nil

-- Cache for host information (computed once per process)
local host_info_cache = nil

-- Import ip_parser functions if available
local function get_cached_network_info()
    -- Try to call the function from ip_parser.lua if it exists
    if _G.get_cached_network_info then
        return _G.get_cached_network_info()
    end
    return nil
end

function get_host_info()
    if host_info_cache then
        return host_info_cache
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
        host_fqdn = host_fqdn,
        host_os_type = "windows",
        host_log_source = "fluent-bit-windows"
    }
    
    return host_info_cache
end

function get_host_ip_via_powershell()
    -- Try to get IP address using PowerShell command
    -- This is a fallback method if the exec input isn't working
    local handle = io.popen('powershell.exe -Command "(Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -ne \'Disconnected\'} | Select-Object -First 1).IPv4Address.IPAddress" 2>nul')
    if handle then
        local result = handle:read("*a")
        handle:close()
        if result then
            local ip = string.match(result, "(%d+%.%d+%.%d+%.%d+)")
            if ip then
                return ip
            end
        end
    end
    
    -- Fallback to a simpler method using ipconfig
    handle = io.popen('ipconfig | findstr "IPv4" | findstr /v "169.254" | findstr /v "127.0.0.1"')
    if handle then
        local result = handle:read("*a")
        handle:close()
        if result then
            local ip = string.match(result, "(%d+%.%d+%.%d+%.%d+)")
            if ip then
                return ip
            end
        end
    end
    
    return "unknown"
end

function convert_timestamp(tag, timestamp, record)
    -- Add host information to every record
    local host_info = get_host_info()
    for key, value in pairs(host_info) do
        record[key] = value
    end
    
    -- Add IP address information from cached network data or fallback
    local network_info = get_cached_network_info()
    local host_ip = "unknown"
    
    if network_info and network_info.ip then
        host_ip = network_info.ip
        record["host_ip"] = host_ip
        -- record["host_ip_private"] = host_ip
        
        -- Add additional network info if available
        if network_info.adapter_name then
            record["host_adapter_name"] = network_info.adapter_name
        end
        if network_info.gateway then
            record["host_gateway"] = network_info.gateway
        end
    else
        -- Fallback to PowerShell method
        host_ip = get_host_ip_via_powershell()
        if host_ip and host_ip ~= "unknown" then
            record["host_ip"] = host_ip
            -- record["host_ip_private"] = host_ip
        else
            record["host_ip"] = "unavailable"
        end
    end
    
    -- Determine IP class/type for additional context
    if host_ip and host_ip ~= "unknown" and host_ip ~= "unavailable" then
        if string.match(host_ip, "^192%.168%.") then
            record["host_ip_class"] = "private_class_c"
        elseif string.match(host_ip, "^10%.") then
            record["host_ip_class"] = "private_class_a"
        elseif string.match(host_ip, "^172%.(%d+)%.") then
            local second_octet = tonumber(string.match(host_ip, "^172%.(%d+)%."))
            if second_octet and second_octet >= 16 and second_octet <= 31 then
                record["host_ip_class"] = "private_class_b"
            else
                record["host_ip_class"] = "unknown"
            end
        else
            record["host_ip_class"] = "public_or_other"
        end
    else
        record["host_ip_class"] = "unknown"
    end
    
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
    
    -- Add log type detection with host context
    if record["source"] == "Server" then
        record["log_type"] = "sql_server"
        record["log_category"] = "database"
    else
        record["log_category"] = "application"
    end
    
    -- Add deployment context (can be customized per environment)
    record["environment"] = "staging"  -- This could be parameterized
    record["data_pipeline"] = "fluent-bit-windows"
    
    return 1, timestamp, record
end