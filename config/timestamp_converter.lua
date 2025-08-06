-- Global variable to store the last valid timestamp
local last_valid_timestamp = nil

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

    -- Add ingested time
    record["ingestion_timestamp"] = os.date("!%Y-%m-%dT%H:%M:%SZ")
    
    -- Add log type detection
    if record["source"] == "Server" then
        record["log_type"] = "sql_server"
    end
    
    return 1, timestamp, record
end