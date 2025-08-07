# Core Functionality for FluentBit Deployment

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

# Function to download file with progress
function Download-File {
    param(
        [string]$Url,
        [string]$OutputPath,
        [string]$Description
    )
    
    try {
        Write-Status "Downloading $Description..." "Step"
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($Url, $OutputPath)
        Write-Status "Downloaded: $Description" "Success"
        return $true
    }
    catch {
        Write-Status "Failed to download $Description - $($_.Exception.Message)" "Error"
        return $false
    }
}

# Function to install FluentBit
function Install-FluentBit {
    param([string]$Version)
    
    Write-Status "Installing FluentBit v$Version..." "Step"
    
    # Check if already installed
    if ((Test-Path "$InstallPath\bin\fluent-bit.exe") -and -not $Force -and -not $CleanInstall) {
        Write-Status "FluentBit already installed. Use -Force or -CleanInstall to reinstall." "Warning"
        return $true
    }
    
    $installerUrl = "https://packages.fluentbit.io/windows/fluent-bit-$Version-win64.exe"
    $installerPath = "$env:TEMP\fluent-bit-installer.exe"
    
    # Download installer
    if (-not (Download-File -Url $installerUrl -OutputPath $installerPath -Description "FluentBit installer")) {
        return $false
    }
    
    # Run installer silently
    try {
        Write-Status "Running FluentBit installer..." "Step"
        Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -NoNewWindow
        
        # Verify installation
        if (Test-Path "$InstallPath\bin\fluent-bit.exe") {
            Write-Status "FluentBit installed successfully" "Success"
            return $true
        } else {
            Write-Status "FluentBit installation verification failed" "Error"
            return $false
        }
    }
    catch {
        Write-Status "FluentBit installation failed - $($_.Exception.Message)" "Error"
        return $false
    }
    finally {
        # Cleanup installer
        if (Test-Path $installerPath) {
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# Function to install SQLite tools
function Install-SqliteTools {
    Write-Status "Installing SQLite tools..." "Step"
    
    # Check if already installed
    if ((Test-Path "$SqliteToolsPath\sqlite3.exe") -and -not $Force -and -not $CleanInstall) {
        Write-Status "SQLite tools already installed" "Success"
        return $true
    }
    
    $sqliteUrl = "https://sqlite.org/2024/sqlite-tools-win-x64-3450000.zip"
    $sqliteZip = "$env:TEMP\sqlite-tools.zip"
    
    # Download SQLite tools
    if (-not (Download-File -Url $sqliteUrl -OutputPath $sqliteZip -Description "SQLite tools")) {
        return $false
    }
    
    # Ensure target directory exists
    if (-not (Ensure-Directory -Path $SqliteToolsPath)) {
        return $false
    }
    
    # Extract SQLite tools
    try {
        Write-Status "Extracting SQLite tools..." "Step"
        Expand-Archive -Path $sqliteZip -DestinationPath $SqliteToolsPath -Force
        
        # Verify installation
        if (Test-Path "$SqliteToolsPath\sqlite3.exe") {
            Write-Status "SQLite tools installed successfully" "Success"
            return $true
        } else {
            Write-Status "SQLite tools installation verification failed" "Error"
            return $false
        }
    }
    catch {
        Write-Status "SQLite tools extraction failed - $($_.Exception.Message)" "Error"
        return $false
    }
    finally {
        # Cleanup zip file
        if (Test-Path $sqliteZip) {
            Remove-Item $sqliteZip -Force -ErrorAction SilentlyContinue
        }
    }
}

# Function to safely remove directory with retry logic
function Remove-DirectorySafely {
    param(
        [string]$Path,
        [int]$MaxRetries = 5,
        [int]$DelaySeconds = 3
    )
    
    if (-not (Test-Path $Path)) {
        return $true
    }
    
    Write-Status "Attempting to remove directory: $Path" "Step"
    
    # First, try to unlock any files by terminating processes that might be using them
    Stop-FluentBitProcesses
    
    # Try to take ownership and set permissions if needed
    try {
        Write-Status "Taking ownership of directory..." "Info"
        takeown /F $Path /R /D Y 2>$null | Out-Null
        icacls $Path /grant "Administrators:(F)" /T 2>$null | Out-Null
    }
    catch {
        Write-Status "Could not take ownership, continuing anyway..." "Warning"
    }
    
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try {
            # Try to unlock specific files that might be locked
            if (Test-Path "$Path\bin\fluent-bit.exe") {
                Write-Status "Attempting to unlock fluent-bit.exe..." "Info"
                # Use handle.exe if available, otherwise continue
                try {
                    $handleOutput = handle.exe "$Path\bin\fluent-bit.exe" 2>$null
                    if ($handleOutput) {
                        Write-Status "Found file handles, attempting to close..." "Info"
                    }
                }
                catch {
                    # handle.exe not available, continue
                }
            }
            
            # Attempt removal
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Status "Successfully removed directory: $Path" "Success"
            return $true
        }
        catch {
            $errorMsg = $_.Exception.Message
            Write-Status "Attempt $($i + 1) failed to remove $Path : $errorMsg" "Warning"
            
            # If it's an access denied error, try additional steps
            if ($errorMsg -like "*Access*denied*" -or $errorMsg -like "*being used by another process*") {
                Write-Status "Access denied - trying additional cleanup steps..." "Info"
                
                # Kill any remaining processes more aggressively
                try {
                    Get-Process | Where-Object { $_.Path -like "$Path*" } | ForEach-Object {
                        Write-Status "Force killing process using files in target directory: $($_.Name)" "Info"
                        taskkill /F /PID $_.Id 2>$null | Out-Null
                    }
                }
                catch {
                    # Continue if process killing fails
                }
                
                # Try to remove specific locked files individually
                try {
                    $lockedFiles = @("$Path\bin\fluent-bit.exe", "$Path\bin\fluent-bit.dll")
                    foreach ($file in $lockedFiles) {
                        if (Test-Path $file) {
                            Write-Status "Attempting to remove potentially locked file: $file" "Info"
                            Remove-Item $file -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                catch {
                    # Continue if individual file removal fails
                }
            }
            
            if ($i -lt ($MaxRetries - 1)) {
                Write-Status "Waiting $DelaySeconds seconds before retry..." "Info"
                Start-Sleep -Seconds $DelaySeconds
                
                # Double the delay for next attempt
                $DelaySeconds = $DelaySeconds * 2
            }
        }
    }
    
    # Final attempt - try to rename the directory if we can't remove it
    if (Test-Path $Path) {
        Write-Status "Could not remove directory, attempting to rename for later cleanup..." "Warning"
        try {
            $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $renamedPath = "$Path-REMOVE-$timestamp"
            Rename-Item -Path $Path -NewName $renamedPath -Force
            Write-Status "Renamed directory to: $renamedPath" "Warning"
            Write-Status "You may need to manually remove this directory after a reboot" "Warning"
            return $true  # Consider this a success since we've moved it out of the way
        }
        catch {
            Write-Status "Could not rename directory either: $($_.Exception.Message)" "Error"
        }
    }
    
    Write-Status "Failed to remove directory after $MaxRetries attempts: $Path" "Error"
    return $false
}

# ============================================================================
# SERVICE MANAGEMENT FUNCTIONS
# ============================================================================

# Function to terminate FluentBit processes
function Stop-FluentBitProcesses {
    Write-Status "Checking for running FluentBit processes..." "Step"
    
    $processNames = @("fluent-bit", "fluent-bit.exe")
    $killedProcesses = 0
    
    foreach ($processName in $processNames) {
        $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
        
        if ($processes) {
            Write-Status "Found $($processes.Count) FluentBit process(es) running" "Info"
            
            foreach ($process in $processes) {
                try {
                    Write-Status "Terminating process: $($process.Name) (PID: $($process.Id))" "Step"
                    $process.Kill()
                    $process.WaitForExit(10000)  # Wait up to 10 seconds
                    $killedProcesses++
                }
                catch {
                    Write-Status "Failed to terminate process $($process.Id): $($_.Exception.Message)" "Warning"
                    
                    # Try force kill with taskkill
                    try {
                        taskkill /F /PID $process.Id | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            Write-Status "Force killed process $($process.Id)" "Success"
                            $killedProcesses++
                        }
                    }
                    catch {
                        Write-Status "Failed to force kill process $($process.Id)" "Warning"
                    }
                }
            }
        }
    }
    
    if ($killedProcesses -gt 0) {
        Write-Status "Terminated $killedProcesses FluentBit process(es)" "Success"
        # Wait for file handles to be released
        Start-Sleep -Seconds 5
    } else {
        Write-Status "No FluentBit processes found running" "Info"
    }
    
    return $true
}

# Function to stop and remove FluentBit service
function Remove-FluentBitService {
    Write-Status "Checking and removing FluentBit service..." "Step"
    
    $serviceName = "fluent-bit"
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    
    if ($service) {
        Write-Status "Found FluentBit service, status: $($service.Status)" "Info"
        
        # Stop service if running
        if ($service.Status -eq 'Running') {
            try {
                Write-Status "Stopping FluentBit service..." "Step"
                Stop-Service -Name $serviceName -Force -Timeout 30
                
                # Wait for service to fully stop
                $timeout = 30
                $waited = 0
                do {
                    Start-Sleep -Seconds 1
                    $waited++
                    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                } while ($service.Status -eq 'Running' -and $waited -lt $timeout)
                
                if ($service.Status -eq 'Stopped') {
                    Write-Status "Service stopped successfully" "Success"
                } else {
                    Write-Status "Service may not have stopped completely (Status: $($service.Status))" "Warning"
                }
            }
            catch {
                Write-Status "Failed to stop service: $($_.Exception.Message)" "Warning"
            }
        }
        
        # Remove service
        try {
            Write-Status "Removing FluentBit service..." "Step"
            sc.exe delete $serviceName | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Status "FluentBit service removed successfully" "Success"
                Start-Sleep -Seconds 3
            } else {
                Write-Status "Failed to remove service (sc.exe exit code: $LASTEXITCODE)" "Warning"
            }
        }
        catch {
            Write-Status "Error removing service: $($_.Exception.Message)" "Warning"
        }
    } else {
        Write-Status "No FluentBit service found" "Info"
    }
    
    # Always check for and terminate any remaining processes
    Stop-FluentBitProcesses
    
    return $true
}


# Function to find and remove FluentBit installation
function Remove-FluentBitInstallation {
    Write-Status "Searching for existing FluentBit installation..." "Step"
    
    # Method 1: Check standard installation path
    if (Test-Path $InstallPath) {
        Write-Status "Found FluentBit installation at: $InstallPath" "Info"
        
        # Look for uninstaller
        $uninstallerPaths = @(
            "$InstallPath\Uninstall.exe",
            "$InstallPath\uninstall.exe",
            "$InstallPath\bin\Uninstall.exe"
        )
        
        $uninstallerFound = $false
        foreach ($uninstallerPath in $uninstallerPaths) {
            if (Test-Path $uninstallerPath) {
                Write-Status "Found uninstaller: $uninstallerPath" "Info"
                try {
                    Write-Status "Running FluentBit uninstaller silently..." "Step"
                    $process = Start-Process -FilePath $uninstallerPath -ArgumentList "/S" -Wait -PassThru -NoNewWindow
                    
                    if ($process.ExitCode -eq 0) {
                        Write-Status "FluentBit uninstalled successfully via uninstaller" "Success"
                        $uninstallerFound = $true
                        break
                    } else {
                        Write-Status "Uninstaller exit code: $($process.ExitCode)" "Warning"
                    }
                }
                catch {
                    Write-Status "Failed to run uninstaller: $($_.Exception.Message)" "Warning"
                }
            }
        }
        
        # Method 2: Check registry for uninstall information
        if (-not $uninstallerFound) {
            Write-Status "Searching Windows registry for FluentBit uninstall information..." "Step"
            
            $registryPaths = @(
                "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            
            foreach ($regPath in $registryPaths) {
                try {
                    $programs = Get-ItemProperty $regPath -ErrorAction SilentlyContinue | 
                                Where-Object { $_.DisplayName -like "*fluent*bit*" -or $_.DisplayName -like "*Fluent*Bit*" }
                    
                    foreach ($program in $programs) {
                        if ($program.UninstallString) {
                            Write-Status "Found registry entry: $($program.DisplayName)" "Info"
                            
                            try {
                                # Parse uninstall string and add silent flag
                                if ($program.UninstallString -match '^"([^"]+)"(.*)$') {
                                    $uninstallExe = $matches[1]
                                    $uninstallArgs = $matches[2].Trim()
                                } else {
                                    $uninstallExe = $program.UninstallString
                                    $uninstallArgs = ""
                                }
                                
                                $uninstallArgs = "$uninstallArgs /S".Trim()
                                
                                Write-Status "Running uninstaller: $uninstallExe $uninstallArgs" "Step"
                                $process = Start-Process -FilePath $uninstallExe -ArgumentList $uninstallArgs -Wait -PassThru -NoNewWindow
                                
                                if ($process.ExitCode -eq 0) {
                                    Write-Status "FluentBit uninstalled successfully via registry" "Success"
                                    $uninstallerFound = $true
                                    break
                                }
                            }
                            catch {
                                Write-Status "Failed to run registry uninstaller: $($_.Exception.Message)" "Warning"
                            }
                        }
                    }
                    
                    if ($uninstallerFound) { break }
                }
                catch {
                    # Registry path might not exist, continue
                }
            }
        }
        
        # Method 3: Manual cleanup if uninstaller failed or not found
        if (-not $uninstallerFound -or (Test-Path $InstallPath)) {
            Write-Status "Performing manual cleanup of installation directory..." "Step"
            
            # Ensure all processes are stopped before attempting directory removal
            Stop-FluentBitProcesses
            
            # Additional wait for file handles to be released
            Start-Sleep -Seconds 10
            
            Remove-DirectorySafely -Path $InstallPath -MaxRetries 5 -DelaySeconds 3
        }
    } else {
        Write-Status "No FluentBit installation found at standard path" "Info"
    }
    
    return $true
}

# ============================================================================
# CONFIGURATION FUNCTIONS (Modified for Simplified Version)
# ============================================================================

# Function to generate INPUT sections for log paths (simplified tag structure)
function Generate-LogInputSections {
    param(
        [string[]]$Paths,
        [int]$MaxDepth,
        [string]$BaseTag = "app.java"
    )
    
    $inputSections = @()
    
    foreach ($path in $Paths) {
        # Sanitize path for folder name (simpler sanitization)
        $folderName = Split-Path $path -Leaf
        $folderName = ($folderName -replace '[\\/:*?"<>|]', '_').Trim('_')
        if ([string]::IsNullOrEmpty($folderName)) {
            $folderName = "logs"
        }
        
        # Generate inputs for each directory depth level
        for ($depth = 0; $depth -le $MaxDepth; $depth++) {
            $wildcard = "\*" * $depth
            $logPath = "$path$wildcard\*.log"
            $tag = "$BaseTag.$folderName.level$depth"
            $dbFile = "$StoragePath\tail-$folderName-level$depth.db"
            
            $inputSection = @"

[INPUT]
    Name                        tail
    Path                        $logPath
    Tag                         $tag
    DB                          $dbFile
    DB.Sync                     Normal
    Path_Key                    source_file_path
    Read_from_Head              true
    Skip_Empty_Lines            On
    Refresh_Interval            1
    multiline.parser            java
    Buffer_Chunk_Size           256K
    Buffer_Max_Size             4M
    Mem_Buf_Limit               50M
    storage.type                filesystem
"@
            $inputSections += $inputSection
        }
    }
    
    # Add SQL Server ERRORLOG monitoring (always included)
    $sqlServerInput = @"

[INPUT]
    Name                        tail
    Path                        C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\Log\ERRORLOG*
    Tag                         app.sql_server.errorlog
    DB                          $StoragePath\tail-sqlserver-errorlog.db
    DB.Sync                     Normal
    Path_Key                    source_file_path
    Read_from_Head              true
    Skip_Empty_Lines            On
    Refresh_Interval            1
    Parser                      sql_server_parser
    multiline.parser            sql_server_multiline
    Buffer_Chunk_Size           256K
    Buffer_Max_Size             4M
    Mem_Buf_Limit               50M
    storage.type                filesystem
"@
    $inputSections += $sqlServerInput
    
    return $inputSections -join ""
}

# Function to copy and customize configuration files (simplified)
function Deploy-ConfigurationFiles {
    Write-Status "Deploying and customizing configuration files..." "Step"
    
    # Check if config source directory exists
    if (-not (Test-Path $ConfigSourceDir)) {
        Write-Status "Config source directory not found: $ConfigSourceDir" "Error"
        Write-Status "Please ensure your config files are in the '$ConfigSourceDir' directory" "Info"
        return $false
    }
    
    # Ensure target config directory exists
    if (-not (Ensure-Directory -Path $ConfigPath)) {
        return $false
    }
    
    # Copy static files (simplified list - no auto-decompress.ps1)
    $staticFiles = @(
        "parsers-onbe.conf",
        "supporting_functions.lua"
    )
    
    $copiedFiles = 0
    
    foreach ($file in $staticFiles) {
        $sourcePath = Join-Path $ConfigSourceDir $file
        $targetPath = Join-Path $ConfigPath $file
        
        if (Test-Path $sourcePath) {
            try {
                # Read the source file and convert to ASCII
                $content = Get-Content $sourcePath -Raw
                [System.IO.File]::WriteAllText($targetPath, $content, [System.Text.Encoding]::ASCII)
                Write-Status "Copied and converted to ASCII: $file" "Success"
                $copiedFiles++
            }
            catch {
                Write-Status "Failed to copy $file - $($_.Exception.Message)" "Error"
            }
        } else {
            Write-Status "Config file not found: $sourcePath" "Warning"
        }
    }
    
    # Process main configuration file (renamed skeleton)
    $mainConfigSource = Join-Path $ConfigSourceDir "fluent-bit-onbe.conf.skeleton"
    $mainConfigTarget = Join-Path $ConfigPath "fluent-bit-onbe.conf"
    
    if (Test-Path $mainConfigSource) {
        try {
            Write-Status "Customizing main configuration file..." "Step"
            
            # Read the template configuration
            $configContent = Get-Content $mainConfigSource -Raw
            
            # Replace placeholders with actual values
            $configContent = $configContent -replace '<LOG_LEVEL>', $LogLevel
            $configContent = $configContent -replace '<STORAGE_PATH>', $StoragePath
            $configContent = $configContent -replace '<CTRLB_BACKEND_HOST>', $CtrlBHost
            $configContent = $configContent -replace '<CTRLB_BACKEND_PORT>', $CtrlBPort
            $configContent = $configContent -replace '<CTRLB_BACKEND_AUTH_HEADER>', $CtrlBAuthHeader
            $configContent = $configContent -replace '<CTRLB_STREAM_NAME>', $CtrlBStreamName
            
            # Generate INPUT sections
            Write-Status "Generating INPUT sections for $($LogPaths.Count) log paths..." "Info"
            $logInputSections = Generate-LogInputSections -Paths $LogPaths -MaxDepth $MaxDirectoryDepth
            
            # Find and replace the INPUT placeholder comment
            $inputPlaceholder = "# Input sections would be generated programatically using the deployment script"
            if ($configContent -like "*$inputPlaceholder*") {
                $configContent = $configContent -replace [regex]::Escape($inputPlaceholder), $logInputSections
                Write-Status "Inserted generated INPUT sections" "Success"
            } else {
                Write-Status "INPUT placeholder comment not found, appending sections" "Warning"
                # Find [FILTER] section and insert before it
                $filterPattern = '(\[FILTER\])'
                $configContent = $configContent -replace $filterPattern, "$logInputSections`n`n`$1"
            }
            
            # Write the customized configuration using .NET method for true ASCII
            [System.IO.File]::WriteAllText($mainConfigTarget, $configContent, [System.Text.Encoding]::ASCII)
            Write-Status "Customized and converted to ASCII: fluent-bit-onbe.conf" "Success"
            $copiedFiles++
        }
        catch {
            Write-Status "Failed to customize main config - $($_.Exception.Message)" "Error"
            return $false
        }
    } else {
        Write-Status "Main config skeleton not found: $mainConfigSource" "Error"
        return $false
    }
    
    Write-Status "Configuration files processed: $copiedFiles files" "Success"
    return $true
}

# Function to create storage directories (simplified - no gzip directories)
function Create-StorageDirectories {
    Write-Status "Creating storage directories..." "Step"
    
    $directories = @(
        $StoragePath,
        "C:\temp"
    )
    
    foreach ($dir in $directories) {
        if (-not (Ensure-Directory -Path $dir)) {
            return $false
        }
    }
    
    Write-Status "Storage directories created successfully" "Success"
    return $true
}

# Function to setup FluentBit logging infrastructure
function Setup-FluentBitLogging {
    Write-Status "Setting up FluentBit service logging infrastructure..." "Step"
    
    # Ensure log directory exists
    $logDir = Split-Path $FluentBitLogPath -Parent
    if (-not (Ensure-Directory -Path $logDir)) {
        Write-Status "Failed to create FluentBit log directory: $logDir" "Error"
        return $false
    }
    
    # Set proper permissions on log directory
    try {
        Write-Status "Setting permissions on log directory: $logDir" "Info"
        icacls $logDir /grant "NT AUTHORITY\LOCAL SERVICE:(F)" /T 2>$null | Out-Null
        icacls $logDir /grant "NT AUTHORITY\SYSTEM:(F)" /T 2>$null | Out-Null
        icacls $logDir /grant "Administrators:(F)" /T 2>$null | Out-Null
    }
    catch {
        Write-Status "Warning: Could not set log directory permissions, but continuing..." "Warning"
    }
    
    # Create initial log file if it doesn't exist
    if (-not (Test-Path $FluentBitLogPath)) {
        try {
            $null = New-Item -Path $FluentBitLogPath -ItemType File -Force
            Write-Status "Created initial FluentBit log file: $FluentBitLogPath" "Success"
            
            # Add initial log entry
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Add-Content -Path $FluentBitLogPath -Value "[$timestamp] [info] FluentBit logging initialized by deployment script" -Encoding UTF8
        }
        catch {
            Write-Status "Warning: Could not create initial log file, but continuing..." "Warning"
        }
    }
    
    Write-Status "FluentBit logging infrastructure setup completed" "Success"
    return $true
}

# Function to test FluentBit configuration
function Test-FluentBitConfiguration {
    Write-Status "Testing FluentBit configuration..." "Step"
    
    $configFile = "$ConfigPath\fluent-bit-onbe.conf"  # Updated filename
    $fluentBitExe = "$InstallPath\bin\fluent-bit.exe"
    
    if (-not (Test-Path $configFile)) {
        Write-Status "Configuration file not found: $configFile" "Error"
        return $false
    }
    
    if (-not (Test-Path $fluentBitExe)) {
        Write-Status "FluentBit executable not found: $fluentBitExe" "Error"
        return $false
    }
    
    try {
        # Test configuration with dry-run flag
        $testResult = & $fluentBitExe -c $configFile -D 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "FluentBit configuration is valid" "Success"
            return $true
        } else {
            Write-Status "FluentBit configuration test failed" "Error"
            Write-Host $testResult -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Status "Failed to test FluentBit configuration - $($_.Exception.Message)" "Error"
        return $false
    }
}

# Function to create and manage Windows service
function Install-FluentBitService {
    Write-Status "Installing FluentBit as Windows Service..." "Step"
    
    $serviceName = "fluent-bit"
    $configFile = "$ConfigPath\fluent-bit-onbe.conf"  # Updated filename
    $fluentBitExe = "$InstallPath\bin\fluent-bit.exe"
    $displayName = "Fluent Bit Log Processor"
    $description = "Fluent Bit lightweight log processor and forwarder for logs, metrics and traces. Logs to: $FluentBitLogPath"
    
    # Validate prerequisites
    if (-not (Test-Path $fluentBitExe)) {
        Write-Status "FluentBit executable not found: $fluentBitExe" "Error"
        return $false
    }
    
    if (-not (Test-Path $configFile)) {
        Write-Status "Configuration file not found: $configFile" "Error"
        return $false
    }
    
    # Remove existing service if it exists (cleanup should have done this, but double-check)
    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-Status "Service already exists, this shouldn't happen after cleanup" "Warning"
        Remove-FluentBitService
        Start-Sleep -Seconds 3
    }
    
    try {
        # Create the service using PowerShell New-Service
        $serviceBinPath = "`"$fluentBitExe`" -c `"$configFile`""
        Write-Status "Creating service with binPath: $serviceBinPath" "Info"
        Write-Status "Service will log to: $FluentBitLogPath (configured in fluent-bit.conf)" "Info"
        
        New-Service -Name $serviceName -BinaryPathName $serviceBinPath -DisplayName $displayName -StartupType Automatic -Description $description
        Write-Status "FluentBit service created successfully using New-Service" "Success"
        
        # Configure service recovery options using sc.exe (this is still the best way for recovery options)
        try {
            sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/5000/restart/10000 | Out-Null
            Write-Status "Service recovery options configured" "Success"
        }
        catch {
            Write-Status "Warning: Could not configure service recovery options, but continuing..." "Warning"
        }
        
        # Start the service if requested
        if ($StartService) {
            Write-Status "Starting FluentBit service..." "Step"
            try {
                Start-Service -Name $serviceName
                Write-Status "FluentBit service started successfully" "Success"
                
                # Wait and verify service status
                Start-Sleep -Seconds 5
                $serviceStatus = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                if ($serviceStatus -and $serviceStatus.Status -eq 'Running') {
                    Write-Status "Service is running correctly (Status: $($serviceStatus.Status))" "Success"
                    
                    # Check if log file is being created
                    Start-Sleep -Seconds 3
                    if (Test-Path $FluentBitLogPath) {
                        $logSize = (Get-Item $FluentBitLogPath).Length
                        Write-Status "FluentBit is logging to: $FluentBitLogPath (current size: $logSize bytes)" "Success"
                    } else {
                        Write-Status "Warning: FluentBit log file not yet created at: $FluentBitLogPath" "Warning"
                    }
                } else {
                    Write-Status "Service status: $($serviceStatus.Status). Check Event Viewer and FluentBit logs." "Warning"
                }
            }
            catch {
                Write-Status "Failed to start FluentBit service: $($_.Exception.Message)" "Warning"
                Write-Status "You can start it manually with: Start-Service fluent-bit" "Info"
            }
        } else {
            Write-Status "Service created but not started (use -StartService to auto-start)" "Info"
        }
        
        return $true
    }
    catch {
        Write-Status "Failed to create FluentBit service: $($_.Exception.Message)" "Error"
        return $false
    }
}

# ============================================================================
# CLEANUP FUNCTIONS
# ============================================================================

# Function to perform deep cleanup
function Invoke-DeepCleanup {
    Write-Status "Performing deep cleanup of FluentBit-created files and databases..." "Step"
    
    # Only remove FluentBit-specific paths and files that FluentBit creates
    $cleanupPaths = @(
        $StoragePath,                                    # FluentBit storage/database files
        "C:\temp\sqlite-tools",                         # SQLite tools we installed
        (Split-Path $FluentBitLogPath -Parent)         # FluentBit log directory
    )
    
    foreach ($path in $cleanupPaths) {
        if (Test-Path $path) {
            Write-Status "Cleaning up FluentBit-created path: $path" "Info"
            if (Test-Path $path -PathType Container) {
                # Special handling for log directory - only remove FluentBit logs
                if ($path -eq (Split-Path $FluentBitLogPath -Parent)) {
                    Write-Status "Cleaning up FluentBit log files in: $path" "Info"
                    try {
                        Get-ChildItem -Path $path -Filter "fluent-bit*.log*" | Remove-Item -Force -ErrorAction SilentlyContinue
                        Write-Status "Removed FluentBit log files from: $path" "Success"
                    }
                    catch {
                        Write-Status "Failed to remove FluentBit log files: $($_.Exception.Message)" "Warning"
                    }
                } else {
                    Remove-DirectorySafely -Path $path
                }
            } else {
                try {
                    Remove-Item -Path $path -Force -ErrorAction Stop
                    Write-Status "Removed file: $path" "Success"
                }
                catch {
                    Write-Status "Failed to remove file: $path - $($_.Exception.Message)" "Warning"
                }
            }
        }
    }
    
    Write-Status "Deep cleanup completed - only FluentBit-created files were removed" "Success"
    return $true
}

# Function to perform cleanup operations
function Invoke-CleanupOperations {
    Write-Status "=== Starting Cleanup Operations ===" "Step"
    
    # Always remove service first
    Remove-FluentBitService
    
    # Remove installation
    Remove-FluentBitInstallation
    
    # Deep cleanup if requested
    if ($DeepClean) {
        Invoke-DeepCleanup
    }
    
    # Wait for cleanup to settle
    Write-Status "Waiting for cleanup operations to complete..." "Info"
    Start-Sleep -Seconds 5
    
    Write-Status "=== Cleanup Operations Completed ===" "Success"
}