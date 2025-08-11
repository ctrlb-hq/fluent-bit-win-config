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
            $configContent = $configContent -replace '<LOG_FILE>', $FluentBitLogPath
            $configContent = $configContent -replace '<STORAGE_PATH>', $StoragePath
            $configContent = $configContent -replace '<CTRLB_BACKEND_HOST>', $CtrlBHost
            $configContent = $configContent -replace '<CTRLB_BACKEND_PORT>', $CtrlBPort
            $configContent = $configContent -replace '<CTRLB_BACKEND_AUTH_HEADER>', $CtrlBAuthHeader
            $configContent = $configContent -replace '<CTRLB_STREAM_NAME>', $CtrlBStreamName
            
            # Generate INPUT sections
            Write-Status "Generating INPUT sections for $($LogPaths.Count) log paths..." "Info"
            $logInputSections = Generate-LogInputSections -Paths $LogPaths -MaxDepth $MaxDirectoryDepth
            
            # Generate gzip INPUT sections if enabled
            $gzipInputSections = ""
            if ($ProcessGzipFiles) {
                Write-Status "Gzip processing enabled - initializing gzip file discovery..." "Info"
                
                # Initialize gzip processing and discover files
                if (Initialize-GzipProcessing -LogPaths $LogPaths -MaxDepth $MaxDirectoryDepth -StoragePath $StoragePath) {
                    Write-Status "Generating gzip INPUT sections..." "Info"
                    $gzipInputSections = Generate-GzipInputSections -StoragePath $StoragePath
                    
                    # Deploy gzip processing script
                    if (-not (Deploy-GzipProcessingScript)) {
                        Write-Status "Failed to deploy gzip processing script, but continuing..." "Warning"
                    }
                } else {
                    Write-Status "Gzip initialization failed, skipping gzip processing" "Warning"
                }
            } else {
                Write-Status "Gzip processing disabled" "Info"
            }

            $configContent = $configContent -replace "<REGULAR_LOG_INPUTS>", $logInputSections
            $configContent = $configContent -replace "<GZIP_INPUTS>", $gzipInputSections
            
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

            # Additional gzip configuration validation
            if ($ProcessGzipFiles) {
                Write-Status "Validating gzip processing configuration..." "Info"
                
                # Check if gzip state file exists
                $gzipStateFile = "$StoragePath\gzip-processing-state.json"
                if (Test-Path $gzipStateFile) {
                    try {
                        $gzipState = Get-Content $gzipStateFile -Raw | ConvertFrom-Json
                        $totalFiles = $gzipState.processing_stats.total_files
                        Write-Status "Gzip configuration valid: $totalFiles archive files ready for processing" "Success"
                    }
                    catch {
                        Write-Status "Warning: Gzip state file exists but is malformed" "Warning"
                    }
                } else {
                    Write-Status "Warning: Gzip processing enabled but no state file found" "Warning"
                }
                
                # Check if gzip processing script exists
                $gzipScript = "$InstallPath\scripts\Process-GzipFiles.ps1"
                if (Test-Path $gzipScript) {
                    Write-Status "Gzip processing script deployed successfully" "Success"
                } else {
                    Write-Status "Warning: Gzip processing script not found" "Warning"
                }
            }

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

    # NEW: Add gzip-specific cleanup paths
    $gzipCleanupPaths = @(
        "$StoragePath\gzip-temp",                       # Gzip temporary extraction directory
        "$StoragePath\gzip-processing-state.json",     # Gzip state tracking file
        "$StoragePath\gzip-processor.log",             # Gzip processor log file
        "$InstallPath\scripts\Process-GzipFiles.ps1"   # Gzip processing script
    )

    $cleanupPaths += $gzipCleanupPaths
    
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

# ============================================================================
# GZIP PROCESSING FUNCTIONS
# ============================================================================

# Function to initialize gzip processing state
function Initialize-GzipProcessing {
    param(
        [string[]]$LogPaths,
        [int]$MaxDepth,
        [string]$StoragePath
    )
    
    Write-Status "Initializing gzip processing for archived log files..." "Step"
    
    # Create gzip temp directory structure
    $gzipTempDir = "$StoragePath\gzip-temp"
    if (-not (Ensure-Directory -Path $gzipTempDir)) {
        Write-Status "Failed to create gzip temp directory: $gzipTempDir" "Error"
        return $false
    }
    
    # Scan for existing gzip files
    $discoveredFiles = @()
    $totalFiles = 0
    
    foreach ($logPath in $LogPaths) {
        if (-not (Test-Path $logPath)) {
            Write-Status "Warning: LogPath does not exist: $logPath" "Warning"
            continue
        }
        
        # Create sanitized folder name for this LogPath
        $folderName = Split-Path $logPath -Leaf
        $folderName = ($folderName -replace '[\\/:*?"<>|]', '_').Trim('_')
        if ([string]::IsNullOrEmpty($folderName)) {
            $folderName = "logs_$(Get-Random -Maximum 9999)"
        }
        
        # Create corresponding temp subdirectory
        $tempSubDir = "$gzipTempDir\$folderName"
        if (-not (Ensure-Directory -Path $tempSubDir)) {
            Write-Status "Failed to create gzip temp subdirectory: $tempSubDir" "Warning"
            continue
        }
        
        Write-Status "Scanning for gzip files in: $logPath (depth 0-$MaxDepth)" "Info"
        
        # Scan for .gz files at each depth level
        for ($depth = 0; $depth -le $MaxDepth; $depth++) {
            $searchPath = $logPath
            if ($depth -gt 0) {
                $searchPath = $logPath + ("\*" * $depth)
            }
            $gzipPattern = "$searchPath\*.gz"
            
            try {
                $gzipFiles = Get-ChildItem -Path $gzipPattern -File -ErrorAction SilentlyContinue
                
                foreach ($gzipFile in $gzipFiles) {
                    $fileInfo = @{
                        original_path = $gzipFile.FullName
                        logpath_parent = $logPath
                        folder_name = $folderName
                        relative_path = $gzipFile.FullName.Replace($logPath, '').TrimStart('\')
                        size_bytes = $gzipFile.Length
                        modified_date = $gzipFile.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
                        status = "pending"
                        processed_timestamp = $null
                        temp_file_path = $null
                        extraction_attempts = 0
                    }
                    
                    $discoveredFiles += $fileInfo
                    $totalFiles++
                }
            }
            catch {
                Write-Status "Warning: Error scanning depth $depth in $logPath - $($_.Exception.Message)" "Warning"
            }
        }
        
        Write-Status "Found $($discoveredFiles.Count) gzip files for folder: $folderName" "Info"
    }
    
    # Create state file
    $stateFile = "$StoragePath\gzip-processing-state.json"
    $stateData = @{
        initialization_timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
        gzip_temp_dir = $gzipTempDir
        batch_size = $GzipBatchSize
        processing_interval = $GzipProcessingInterval
        discovered_files = $discoveredFiles
        processing_stats = @{
            total_files = $totalFiles
            completed = 0
            failed = 0
            pending = $totalFiles
            current_batch = @()
        }
    }
    
    try {
        $stateJson = $stateData | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($stateFile, $stateJson, [System.Text.Encoding]::UTF8)
        Write-Status "Created gzip processing state file: $stateFile" "Success"
        Write-Status "Total gzip files discovered: $totalFiles" "Success"
        return $true
    }
    catch {
        Write-Status "Failed to create gzip state file: $($_.Exception.Message)" "Error"
        return $false
    }
}

# Function to generate gzip INPUT sections for FluentBit configuration
function Generate-GzipInputSections {
    param(
        [string]$StoragePath
    )
    
    $gzipTempDir = "$StoragePath\gzip-temp"
    $stateFile = "$StoragePath\gzip-processing-state.json"
    
    # Check if state file exists
    if (-not (Test-Path $stateFile)) {
        Write-Status "No gzip state file found, skipping gzip INPUT generation" "Info"
        return ""
    }
    
    try {
        $stateData = Get-Content $stateFile -Raw | ConvertFrom-Json
        $inputSections = @()
        
        # Get unique folder names from discovered files
        $folderNames = $stateData.discovered_files | 
                      Select-Object -ExpandProperty folder_name | 
                      Sort-Object -Unique
        
        foreach ($folderName in $folderNames) {
            $tempPath = "$gzipTempDir\$folderName\*.log"
            $tag = "app.java.gzip.$folderName.archived"
            $dbFile = "$StoragePath\tail-gzip-$folderName.db"
            
            $inputSection = @"

[INPUT]
    Name                        tail
    Path                        $tempPath
    Tag                         $tag
    DB                          $dbFile
    DB.Sync                     Normal
    Path_Key                    temp_file_path
    Read_from_Head              true
    Skip_Empty_Lines            On
    Refresh_Interval            1
    multiline.parser            java
    Buffer_Chunk_Size           256K
    Buffer_Max_Size             2M
    Mem_Buf_Limit               25M
    storage.type                filesystem
"@
            $inputSections += $inputSection
        }
        
        # Add exec input for gzip processor
        $execInput = @"

[INPUT]
    Name                        exec
    Command                     powershell.exe -ExecutionPolicy Bypass -File "$InstallPath\scripts\Process-GzipFiles.ps1" -StoragePath "$StoragePath"
    Interval_Sec                $($stateData.processing_interval)
    Tag                         gzip.processor.status
"@
        $inputSections += $execInput
        
        Write-Status "Generated $($folderNames.Count) gzip INPUT sections and exec processor" "Success"
        return $inputSections -join ""
    }
    catch {
        Write-Status "Failed to generate gzip INPUT sections: $($_.Exception.Message)" "Error"
        return ""
    }
}

# Function to deploy the gzip processing script with cleanup capabilities
function Deploy-GzipProcessingScript {
    Write-Status "Deploying gzip processing script with cleanup..." "Step"
    
    # Create scripts directory
    $scriptsDir = "$InstallPath\scripts"
    if (-not (Ensure-Directory -Path $scriptsDir)) {
        Write-Status "Failed to create scripts directory: $scriptsDir" "Error"
        return $false
    }
    
    # Create the enhanced Process-GzipFiles.ps1 script content (FIXED SYNTAX)
    $gzipScriptContent = @'
# FluentBit Gzip Processing Script with Cleanup
# Auto-generated by Deploy-FluentBit.ps1

param(
    [Parameter(Mandatory=$true)]
    [string]$StoragePath
)

# Set up logging
$logFile = "$StoragePath\gzip-processor.log"

function Write-GzipLog {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $logFile -Value $entry -Encoding UTF8
    Write-Output $entry
}

function Update-GzipMappingFile {
    param([object]$StateData, [string]$StoragePath)
    
    $mappingFile = "$StoragePath\gzip-mappings.txt"
    $mappingContent = @()
    
    # Create simple key=value mappings for completed files
    $completedFiles = $StateData.discovered_files | Where-Object { $_.status -eq "completed" -and $_.temp_file_path }
    
    foreach ($fileInfo in $completedFiles) {
        $tempFileName = Split-Path $fileInfo.temp_file_path -Leaf
        # $originalPath = $fileInfo.original_path -replace '\\', '\\'  # Escape backslashes for file format
        $originalPath = $fileInfo.original_path
        $mappingContent += "$tempFileName=$originalPath"
    }
    
    # Write the mapping file
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($mappingFile, $mappingContent, $utf8NoBom)
    Write-GzipLog "Updated mapping file with $($mappingContent.Count) entries" "INFO"
}

function Get-FileProcessingStatus {
    param([string]$FilePath, [string]$DbPath)
    
    # Check if file is fully processed by examining FluentBit's SQLite database
    if (-not (Test-Path $DbPath)) {
        return $false
    }
    
    try {
        # Simple check: if file exists and hasn't been modified recently, assume processed
        if (Test-Path $FilePath) {
            $fileInfo = Get-Item $FilePath
            $timeSinceModified = (Get-Date) - $fileInfo.LastWriteTime
            
            # If file hasn't been modified in 2 minutes and exists, consider it processed
            return ($timeSinceModified.TotalMinutes -gt 2)
        }
        return $true  # File doesn't exist = already cleaned up
    }
    catch {
        Write-GzipLog "Error checking file status for ${FilePath}: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Remove-ProcessedTempFiles {
    param([object]$StateData)
    
    $cleanupCount = 0
    $gzipTempDir = $StateData.gzip_temp_dir
    
    # Check each completed file for cleanup eligibility
    $completedFiles = $StateData.discovered_files | Where-Object { $_.status -eq "completed" -and $_.temp_file_path }
    
    foreach ($fileInfo in $completedFiles) {
        $tempFile = $fileInfo.temp_file_path
        $folderName = $fileInfo.folder_name
        $dbFile = "$StoragePath\tail-gzip-$folderName.db"
        
        if ((Test-Path $tempFile) -and (Get-FileProcessingStatus -FilePath $tempFile -DbPath $dbFile)) {
            try {
                Remove-Item $tempFile -Force
                Write-GzipLog "Cleaned up processed file: $tempFile" "INFO"
                $fileInfo.temp_file_path = $null
                $fileInfo.status = "cleaned"
                $cleanupCount++
            }
            catch {
                Write-GzipLog "Failed to cleanup ${tempFile}: $($_.Exception.Message)" "ERROR"
            }
        }
    }
    
    if ($cleanupCount -gt 0) {
        Write-GzipLog "Cleaned up $cleanupCount processed temp files" "SUCCESS"
    }
    
    return $cleanupCount
}

if (Test-Path $logFile) {
    $logSizeBytes = (Get-Item $logFile).Length
    $logSizeMB = $logSizeBytes / 1MB
    
    if ($logSizeMB -gt 100) {
        Write-GzipLog "Log file too large ($([math]::Round($logSizeMB, 2)) MB), rotating..." "WARN"
        $rotatedLog = "$logFile.old"
        if (Test-Path $rotatedLog) { Remove-Item $rotatedLog -Force }
        Move-Item $logFile $rotatedLog
        Write-GzipLog "Log rotated. Previous log saved as $rotatedLog" "INFO"
    }
}

try {
    $stateFile = "$StoragePath\gzip-processing-state.json"
    
    if (-not (Test-Path $stateFile)) {
        Write-GzipLog "No gzip state file found: $stateFile" "WARN"
        exit 0
    }
    
    # Read current state
    $stateData = Get-Content $stateFile -Raw | ConvertFrom-Json
    
    # First, clean up any processed files
    Remove-ProcessedTempFiles -StateData $stateData
    
    # Then process new batch
    $pendingFiles = $stateData.discovered_files | Where-Object { $_.status -eq "pending" }
    
    if ($pendingFiles.Count -eq 0) {
        Write-GzipLog "No pending gzip files to process" "INFO"
        
        # Update state file with any cleanup changes
        $updatedJson = $stateData | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($stateFile, $updatedJson, [System.Text.Encoding]::UTF8)
        exit 0
    }
    
    # Get next batch
    $batchSize = $stateData.batch_size
    $currentBatch = $pendingFiles | Select-Object -First $batchSize
    
    Write-GzipLog "Processing batch of $($currentBatch.Count) gzip files (batch size: $batchSize)" "INFO"
    
    $processedCount = 0
    $failedCount = 0
    
    foreach ($fileInfo in $currentBatch) {
        try {
            $originalPath = $fileInfo.original_path
            $folderName = $fileInfo.folder_name
            
            # Create temp file path
            $fileName = [System.IO.Path]::GetFileNameWithoutExtension($originalPath)
            $tempFileName = "$fileName-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$(Get-Random -Maximum 9999).log"
            $tempFilePath = "$($stateData.gzip_temp_dir)\$folderName\$tempFileName"
            
            Write-GzipLog "Extracting: $originalPath -> $tempFilePath" "INFO"
            
            # Extract gzip file
            if (Test-Path $originalPath) {
                # Use .NET GZipStream for extraction
                $inputStream = [System.IO.File]::OpenRead($originalPath)
                $gzipStream = New-Object System.IO.Compression.GZipStream($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
                $outputStream = [System.IO.File]::Create($tempFilePath)
                
                $gzipStream.CopyTo($outputStream)
                
                $outputStream.Close()
                $gzipStream.Close()
                $inputStream.Close()
                
                # Update file info in state
                $fileInfo.status = "completed"
                $fileInfo.processed_timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
                $fileInfo.temp_file_path = $tempFilePath
                
                $processedCount++
                Write-GzipLog "Successfully extracted: $originalPath" "SUCCESS"
            } else {
                Write-GzipLog "Source file not found: $originalPath" "ERROR"
                $fileInfo.status = "failed"
                $fileInfo.extraction_attempts = ($fileInfo.extraction_attempts + 1)
                $failedCount++
            }
        }
        catch {
            Write-GzipLog "Failed to extract $($fileInfo.original_path): $($_.Exception.Message)" "ERROR"
            $fileInfo.status = "failed"
            $fileInfo.extraction_attempts = ($fileInfo.extraction_attempts + 1)
            $failedCount++
        }
    }
    
    # Update state statistics
    $stateData.processing_stats.completed += $processedCount
    $stateData.processing_stats.failed += $failedCount
    $stateData.processing_stats.pending -= ($processedCount + $failedCount)

    Update-GzipMappingFile -StateData $stateData -StoragePath $StoragePath
    
    # Save updated state
    $updatedJson = $stateData | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($stateFile, $updatedJson, [System.Text.Encoding]::UTF8)
    
    Write-GzipLog "Batch completed: $processedCount processed, $failedCount failed. Remaining: $($stateData.processing_stats.pending)" "INFO"
}
catch {
    Write-GzipLog "Gzip processing script error: $($_.Exception.Message)" "ERROR"
    exit 1
}
'@
    
    # Write the script file
    $gzipScriptPath = "$scriptsDir\Process-GzipFiles.ps1"
    try {
        [System.IO.File]::WriteAllText($gzipScriptPath, $gzipScriptContent, [System.Text.Encoding]::UTF8)
        Write-Status "Created enhanced gzip processing script: $gzipScriptPath" "Success"
        return $true
    }
    catch {
        Write-Status "Failed to create gzip processing script: $($_.Exception.Message)" "Error"
        return $false
    }
}