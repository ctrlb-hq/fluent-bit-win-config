-- Global variables to store network information
local host_ip_cache = {
    ip = nil,
    adapter_name = nil,
    gateway = nil,
    last_updated = 0,
    update_interval = 300  -- 5 minutes
}

function parse_and_store_ip(tag, timestamp, record)
    local exec_output = record["exec"]
    
    if not exec_output then
        -- Drop this record, nothing to process
        return -1, timestamp, record
    end
    
    -- Parse different types of output based on tag
    if string.match(tag, "internal%.host%.ip") then
        -- Simple IP parsing: "host_ip=192.168.1.100"
        local ip = string.match(exec_output, "host_ip=([%d%.]+)")
        if ip and ip ~= "unavailable" and ip ~= "error" then
            host_ip_cache.ip = ip
            host_ip_cache.last_updated = os.time()
        end
        
    elseif string.match(tag, "internal%.host%.network") then
        -- Complex network info parsing: "host_ip=192.168.1.100,adapter_name=Ethernet,gateway=192.168.1.1"
        local ip = string.match(exec_output, "host_ip=([^,]+)")
        local adapter = string.match(exec_output, "adapter_name=([^,]+)")
        local gateway = string.match(exec_output, "gateway=([^,]+)")
        
        if ip and ip ~= "unavailable" and ip ~= "error" then
            host_ip_cache.ip = ip
            host_ip_cache.adapter_name = adapter or "unknown"
            host_ip_cache.gateway = gateway or "unknown"
            host_ip_cache.last_updated = os.time()
        end
    end
    
    -- Always drop these internal records - don't forward to output
    return -1, timestamp, record
end

-- Function to get cached network information for use in other scripts
function get_cached_network_info()
    return host_ip_cache
end

-- Function to check if cached info is still valid
function is_network_cache_valid()
    local current_time = os.time()
    return (current_time - host_ip_cache.last_updated) < host_ip_cache.update_interval
end