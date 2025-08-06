# FluentBit Complete Deployment Script with Windows Service
# Installs FluentBit, SQLite tools, copies config files, customizes configuration, and creates Windows Service

param(
    [Parameter(Mandatory=$false)]
    [string]$FluentBitVersion = "4.0.6",
    
    [Parameter(Mandatory=$false)]
    [string]$InstallPath = "C:\Program Files\fluent-bit",
    
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = "C:\Program Files\fluent-bit\conf",
    
    [Parameter(Mandatory=$false)]
    [string]$StoragePath = "C:\temp\flb-storage",
    
    [Parameter(Mandatory=$false)]
    [string]$SqliteToolsPath = "C:\temp\sqlite-tools",
    
    [Parameter(Mandatory=$false)]
    [string]$ConfigSourceDir = ".\config",
    
    # FluentBit Service Logging Configuration
    [Parameter(Mandatory=$false)]
    [string]$FluentBitLogPath = "C:\temp\logs\fluent-bit.log",
    
    [Parameter(Mandatory=$false)]
    [string]$FluentBitLogLevel = "info",
    
    [Parameter(Mandatory=$false)]
    [string]$FluentBitLogMaxSize = "50MB",
    
    [Parameter(Mandatory=$false)]
    [switch]$EnableLogRotation,
    
    # Backend Configuration
    [Parameter(Mandatory=$true)]
    [string]$CtrlBHost,
    
    [Parameter(Mandatory=$false)]
    [string]$CtrlBPort = "443",
    
    [Parameter(Mandatory=$true)]
    [string]$CtrlBAuthHeader,
    
    [Parameter(Mandatory=$false)]
    [string]$CtrlBUri = "/api/default/staging/_json",
    
    # Log Paths Configuration (can specify multiple paths)
    [Parameter(Mandatory=$false)]
    [string[]]$LogPaths = @("D:\c-base\logs"),
    
    [Parameter(Mandatory=$false)]
    [string[]]$GzipPaths = @("C:\logs"),
    
    [Parameter(Mandatory=$false)]
    [int]$MaxDirectoryDepth = 3,
    
    # Cleanup Options
    [Parameter(Mandatory=$false)]
    [switch]$CleanInstall,           # Forces complete uninstall before install
    
    [Parameter(Mandatory=$false)]
    [switch]$DeepClean,              # Also removes FluentBit-created temp files and databases
    
    # Service Configuration
    [Parameter(Mandatory=$false)]
    [switch]$SkipFluentBitInstall,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipSqliteInstall,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipServiceCreation,
    
    [Parameter(Mandatory=$false)]
    [switch]$StartService = $true,
    
    [Parameter(Mandatory=$false)]
    [switch]$TestOnly,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,

    [Parameter(Mandatory=$false)]
    [int]$MaxGzipFilesPerRun = 5,          # Batch size for gzip processing

    [Parameter(Mandatory=$false)]
    [int]$MaxGzipBatchSizeMB = 200,        # Total size limit per batch

    [Parameter(Mandatory=$false)]
    [int]$GzipSleepBetweenFiles = 2        # Longer pause for safety
)

# Function to write colored output
function Write-Status {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )
    
    switch ($Type) {
        "Success" { Write-Host "✓ $Message" -ForegroundColor Green }
        "Warning" { Write-Host "⚠ $Message" -ForegroundColor Yellow }
        "Error" { Write-Host "✗ $Message" -ForegroundColor Red }
        "Info" { Write-Host "ℹ $Message" -ForegroundColor Cyan }
        "Step" { Write-Host "➤ $Message" -ForegroundColor Magenta }
    }
}

# Function to test if running as administrator
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Function to ensure directory exists
function Ensure-Directory {
    param([string]$Path)
    
    if (-not (Test-Path -Path $Path)) {
        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-Status "Created directory: $Path" "Success"
        }
        catch {
            Write-Status "Failed to create directory: $Path - $($_.Exception.Message)" "Error"
            return $false
        }
    }
    return $true
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

# Function to perform deep cleanup of FluentBit-created files only
function Invoke-DeepCleanup {
    Write-Status "Performing deep cleanup of FluentBit-created files and databases..." "Step"
    
    # Only remove FluentBit-specific paths and files that FluentBit creates
    $cleanupPaths = @(
        $StoragePath,                                    # FluentBit storage/database files
        "C:\temp\sqlite-tools",                         # SQLite tools we installed
        "C:\temp\processed-gzip-files.txt",             # Our decompress script tracking file
        "C:\temp\gzip-initial-processing-complete.txt", # Completion marker files
        "C:\temp\gzip-processing-progress.txt",         # NEW: Progress tracking file
        "C:\temp\decompressed-logs",                    # Only decompressed logs that our script creates
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
    
    # Setup log rotation if enabled
    if ($EnableLogRotation) {
        Setup-FluentBitLogRotation
    }
    
    Write-Status "FluentBit logging infrastructure setup completed" "Success"
    return $true
}

# Function to setup log rotation (optional enhancement)
function Setup-FluentBitLogRotation {
    Write-Status "Setting up FluentBit log rotation..." "Step"
    
    $logDir = Split-Path $FluentBitLogPath -Parent
    $logBaseName = [System.IO.Path]::GetFileNameWithoutExtension($FluentBitLogPath)
    
    # Create a simple PowerShell script for log rotation
    $rotationScript = @"
# FluentBit Log Rotation Script
# Auto-generated by Deploy-FluentBit.ps1

`$LogFile = "$FluentBitLogPath"
`$MaxSizeBytes = $($FluentBitLogMaxSize -replace 'MB', '') * 1024 * 1024
`$MaxArchiveFiles = 5

if (Test-Path `$LogFile) {
    `$LogFileInfo = Get-Item `$LogFile
    if (`$LogFileInfo.Length -gt `$MaxSizeBytes) {
        Write-Host "Rotating FluentBit log file (size: `$(`$LogFileInfo.Length) bytes)"
        
        # Archive existing logs
        for (`$i = `$MaxArchiveFiles; `$i -gt 1; `$i--) {
            `$oldFile = "$logDir\$logBaseName.`$(`$i-1).log"
            `$newFile = "$logDir\$logBaseName.`$i.log"
            if (Test-Path `$oldFile) {
                Move-Item `$oldFile `$newFile -Force
            }
        }
        
        # Move current log to .1
        Move-Item `$LogFile "$logDir\$logBaseName.1.log" -Force
        
        # Create new empty log file
        New-Item -Path `$LogFile -ItemType File -Force | Out-Null
        
        Write-Host "FluentBit log rotation completed"
    }
}
"@
    
    $rotationScriptPath = "$logDir\rotate-fluent-bit-logs.ps1"
    try {
        $rotationScript | Out-File -FilePath $rotationScriptPath -Encoding UTF8 -Force
        Write-Status "Created log rotation script: $rotationScriptPath" "Success"
        
        # You could add this to Windows Task Scheduler if desired
        Write-Status "Log rotation script created. Consider adding to Task Scheduler for automatic rotation." "Info"
    }
    catch {
        Write-Status "Failed to create log rotation script: $($_.Exception.Message)" "Warning"
    }
}

# Function to generate INPUT sections for log paths
function Generate-LogInputSections {
    param(
        [string[]]$Paths,
        [int]$MaxDepth,
        [string]$BaseTag = "log4j.app"
    )
    
    $inputSections = @()
    
    foreach ($path in $Paths) {
        # Sanitize path for tag name
        $pathSanitized = ($path -replace '[\\/:*?"<>|]', '_').Trim('_')
        
        # Generate inputs for each directory depth level
        for ($depth = 0; $depth -le $MaxDepth; $depth++) {
            $wildcard = "\*" * $depth
            $logPath = "$path$wildcard\*.log"
            $tag = "$BaseTag.$pathSanitized.level$depth"
            $dbFile = "$StoragePath\tail-$pathSanitized-level$depth.db"
            
            $inputSection = @"

[INPUT]
    Name                        tail
    Path                        $logPath
    Tag                         $tag
    DB                          $dbFile
    DB.Sync                     Normal
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
    Tag                         log4j.app.sqlserver.errorlog
    DB                          $StoragePath\tail-sqlserver-errorlog.db
    DB.Sync                     Normal
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

# Function to generate INPUT sections for gzip decompression with simplified logic
# Function to generate INPUT sections for gzip decompression with safe batch processing
function Generate-GzipInputSections {
    param(
        [string[]]$GzipPaths,
        [string[]]$LogPaths
    )
    
    $inputSections = @()
    
    foreach ($path in $GzipPaths) {
        # Sanitize path for tag name
        $pathSanitized = ($path -replace '[\\/:*?"<>|]', '_').Trim('_')
        
        # Build the command with all safety parameters
        $logPathsParam = ""
        if ($LogPaths.Count -gt 0) {
            $logPathsArray = ($LogPaths | ForEach-Object { "`"$_`"" }) -join ","
            $logPathsParam = " -LogPaths @($logPathsArray)"
        }
        
        # Updated command with safe batch processing parameters
        $command = "powershell.exe -ExecutionPolicy Bypass -File `"$ConfigPath\auto-decompress.ps1`" -SourcePattern `"$path\*.gz`" -TargetDir `"C:\temp\decompressed-logs\$pathSanitized`" -Sqlite3Path `"$SqliteToolsPath\sqlite3.exe`" -FluentBitDBPath `"$StoragePath\tail-gzip-$pathSanitized.db`" -MaxFilesPerRun $MaxGzipFilesPerRun -MaxTotalSizeMB $MaxGzipBatchSizeMB -FileSizeLimitMB 50 -SleepBetweenFiles $GzipSleepBetweenFiles$logPathsParam"
        
        $inputSection = @"

[INPUT]
    Name                        exec
    Tag                         gzip.decompressor.$pathSanitized
    Command                     $command
    Interval_Sec                30
    Oneshot                     false

[INPUT]
    Name                        tail
    Path                        C:\temp\decompressed-logs\$pathSanitized\*.log
    Tag                         log4j.app.gzip.$pathSanitized
    DB                          $StoragePath\tail-gzip-$pathSanitized.db
    DB.Sync                     Normal
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
    
    return $inputSections -join ""
}

# Function to copy and customize configuration files
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
    
    # Copy non-main config files first
    $staticFiles = @(
        "parsers-onbe-staging.conf",
        "ip_parser.lua",
        "timestamp_converter.lua",
        "auto-decompress.ps1"
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
    
    # Process main configuration file
    $mainConfigSource = Join-Path $ConfigSourceDir "fluent-bit-onbe-staging.conf"
    $mainConfigTarget = Join-Path $ConfigPath "fluent-bit-onbe-staging.conf"
    
    if (Test-Path $mainConfigSource) {
        try {
            Write-Status "Customizing main configuration file..." "Step"
            
            # Read the template configuration
            $configContent = Get-Content $mainConfigSource -Raw
            
            # Add log_file parameter to SERVICE section
            Write-Status "Adding FluentBit service logging configuration..." "Info"
            $servicePattern = '(\[SERVICE\].*?)(Flush\s+\d+)'
            $serviceReplacement = "`$1Log_File                    $FluentBitLogPath`n    Log_Level                   $FluentBitLogLevel`n    `$2"
            
            if ($configContent -match $servicePattern) {
                $configContent = $configContent -replace $servicePattern, $serviceReplacement
                Write-Status "Added log_file and log_level to SERVICE section" "Success"
            } else {
                # Fallback: add after [SERVICE]
                $configContent = $configContent -replace '(\[SERVICE\])', "`$1`n    Log_File                    $FluentBitLogPath`n    Log_Level                   $FluentBitLogLevel"
                Write-Status "Added log_file and log_level after [SERVICE] line" "Success"
            }
            
            # Replace backend configuration placeholders
            $configContent = $configContent -replace '<CTRLB_BACKEND_HOST>', $CtrlBHost
            $configContent = $configContent -replace '<CTRLB_BACKEND_PORT>', $CtrlBPort
            $configContent = $configContent -replace '<CTRLB_BACKEND_AUTH_HEADER>', $CtrlBAuthHeader
            $configContent = $configContent -replace '<STORAGE_PATH>', $StoragePath
            
            # Replace URI if different from default
            if ($CtrlBUri -ne "/api/default/staging/_json") {
                $configContent = $configContent -replace '/api/default/staging/_json', $CtrlBUri
            }
            
            # Generate dynamic INPUT sections
            Write-Status "Generating INPUT sections for $($LogPaths.Count) log paths and $($GzipPaths.Count) gzip paths..." "Info"
            Write-Status "NEW: Gzip processing includes overlap detection with log paths for simplified handling" "Info"
            
            $logInputSections = Generate-LogInputSections -Paths $LogPaths -MaxDepth $MaxDirectoryDepth
            # NEW: Pass LogPaths to GzipInputSections for overlap detection
            $gzipInputSections = Generate-GzipInputSections -GzipPaths $GzipPaths -LogPaths $LogPaths
            
            # Find and replace the INPUT sections in the config
            $allInputSections = $gzipInputSections + $logInputSections
            
            # Replace existing INPUT sections with generated ones
            # Look for pattern between SERVICE and FILTER sections
            $pattern = '(?s)(\[SERVICE\].*?)(\[INPUT\].*?)(\[FILTER\])'
            $replacement = "`$1$allInputSections`n`n`$3"
            
            if ($configContent -match $pattern) {
                $configContent = $configContent -replace $pattern, $replacement
            } else {
                # If pattern not found, append INPUT sections after SERVICE section
                $servicePattern = '(\[SERVICE\].*?)(\[FILTER\]|\[OUTPUT\])'
                $configContent = $configContent -replace $servicePattern, "`$1$allInputSections`n`n`$2"
            }
            
            # Write the customized configuration using .NET method for true ASCII
            [System.IO.File]::WriteAllText($mainConfigTarget, $configContent, [System.Text.Encoding]::ASCII)
            Write-Status "Customized and converted to ASCII: fluent-bit-onbe-staging.conf" "Success"
            $copiedFiles++
        }
        catch {
            Write-Status "Failed to customize main config - $($_.Exception.Message)" "Error"
            return $false
        }
    } else {
        Write-Status "Main config file not found: $mainConfigSource" "Error"
        return $false
    }
    
    Write-Status "Configuration files processed: $copiedFiles files" "Success"
    return $true
}

# Function to create storage directories
function Create-StorageDirectories {
    Write-Status "Creating storage directories..." "Step"
    
    $directories = @(
        $StoragePath,
        "C:\temp"
    )
    
    # Add directories for each gzip path
    foreach ($path in $GzipPaths) {
        $pathSanitized = ($path -replace '[\\/:*?"<>|]', '_').Trim('_')
        $directories += "C:\temp\decompressed-logs\$pathSanitized"
    }
    
    foreach ($dir in $directories) {
        if (-not (Ensure-Directory -Path $dir)) {
            return $false
        }
    }
    
    Write-Status "Storage directories created successfully" "Success"
    return $true
}

# Function to test FluentBit configuration
function Test-FluentBitConfiguration {
    Write-Status "Testing FluentBit configuration..." "Step"
    
    $configFile = "$ConfigPath\fluent-bit-onbe-staging.conf"
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
    $configFile = "$ConfigPath\fluent-bit-onbe-staging.conf"
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
        # Create the service using sc.exe with proper syntax
        # The log_file parameter in the config will handle logging, not command line parameters
        Write-Status "Creating service with binPath: `"$fluentBitExe`" -c `"$configFile`"" "Info"
        Write-Status "Service will log to: $FluentBitLogPath (configured in fluent-bit.conf)" "Info"
        
        # Use PowerShell's Start-Process for better control over sc.exe execution
        $scArgs = @(
            "create",
            $serviceName,
            "binpath=",
            "`"$fluentBitExe`" -c `"$configFile`"",
            "start=",
            "auto",
            "DisplayName=",
            $displayName
        )
        
        $createProcess = Start-Process -FilePath "sc.exe" -ArgumentList $scArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\sc_output.txt" -RedirectStandardError "$env:TEMP\sc_error.txt"
        
        if ($createProcess.ExitCode -eq 0) {
            Write-Status "FluentBit service created successfully" "Success"
            
            # Set service description
            sc.exe description $serviceName $description | Out-Null
            
            # Configure service recovery options (restart on failure)
            sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/5000/restart/10000 | Out-Null
            Write-Status "Service recovery options configured" "Success"
            
            # Start the service if requested
            if ($StartService) {
                Write-Status "Starting FluentBit service..." "Step"
                $startProcess = Start-Process -FilePath "sc.exe" -ArgumentList @("start", $serviceName) -Wait -PassThru -NoNewWindow
                
                if ($startProcess.ExitCode -eq 0) {
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
                } else {
                    Write-Status "Failed to start FluentBit service (Exit Code: $($startProcess.ExitCode))" "Warning"
                    Write-Status "You can start it manually with: Start-Service fluent-bit" "Info"
                }
            } else {
                Write-Status "Service created but not started (use -StartService to auto-start)" "Info"
            }
            
            return $true
        } else {
            Write-Status "Failed to create FluentBit service (Exit Code: $($createProcess.ExitCode))" "Error"
            
            # Show error details
            if (Test-Path "$env:TEMP\sc_error.txt") {
                $errorContent = Get-Content "$env:TEMP\sc_error.txt" -Raw
                if ($errorContent) {
                    Write-Host "Error details: $errorContent" -ForegroundColor Red
                }
            }
            if (Test-Path "$env:TEMP\sc_output.txt") {
                $outputContent = Get-Content "$env:TEMP\sc_output.txt" -Raw
                if ($outputContent) {
                    Write-Host "Output: $outputContent" -ForegroundColor Yellow
                }
            }
            
            # Try alternative method using PowerShell New-Service
            Write-Status "Trying alternative service creation method..." "Step"
            try {
                $serviceBinPath = "`"$fluentBitExe`" -c `"$configFile`""
                New-Service -Name $serviceName -BinaryPathName $serviceBinPath -DisplayName $displayName -StartupType Automatic -Description $description
                Write-Status "Service created using PowerShell New-Service" "Success"
                
                if ($StartService) {
                    Start-Service -Name $serviceName
                    Write-Status "FluentBit service started successfully" "Success"
                }
                return $true
            }
            catch {
                Write-Status "PowerShell New-Service also failed: $($_.Exception.Message)" "Error"
                return $false
            }
        }
    }
    catch {
        Write-Status "Exception during service creation: $($_.Exception.Message)" "Error"
        return $false
    }
}

# Function to create helpful monitoring tools
function Create-MonitoringTools {
    Write-Status "Creating FluentBit monitoring tools..." "Step"
    
    $logDir = Split-Path $FluentBitLogPath -Parent
    
    # Create log tail script for easy monitoring
    $tailScript = @"
# FluentBit Log Tail Script
# Auto-generated by Deploy-FluentBit.ps1

Write-Host "Monitoring FluentBit logs: $FluentBitLogPath" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop monitoring" -ForegroundColor Yellow
Write-Host "=" * 60

if (Test-Path "$FluentBitLogPath") {
    Get-Content "$FluentBitLogPath" -Tail 20 -Wait
} else {
    Write-Host "FluentBit log file not found: $FluentBitLogPath" -ForegroundColor Red
    Write-Host "Service may not be running or logging may not be configured correctly" -ForegroundColor Yellow
}
"@
    
    $tailScriptPath = "$logDir\monitor-fluent-bit.ps1"
    try {
        $tailScript | Out-File -FilePath $tailScriptPath -Encoding UTF8 -Force
        Write-Status "Created log monitoring script: $tailScriptPath" "Success"
    }
    catch {
        Write-Status "Failed to create log monitoring script: $($_.Exception.Message)" "Warning"
    }
    
    # Create service status check script
    $statusScript = @"
# FluentBit Service Status Script
# Auto-generated by Deploy-FluentBit.ps1

Write-Host "FluentBit Service Status Report" -ForegroundColor Cyan
Write-Host "=" * 40

# Check service status
`$service = Get-Service -Name "fluent-bit" -ErrorAction SilentlyContinue
if (`$service) {
    Write-Host "Service Status: `$(`$service.Status)" -ForegroundColor Green
    Write-Host "Start Type: `$(`$service.StartType)" -ForegroundColor Gray
} else {
    Write-Host "FluentBit service not found!" -ForegroundColor Red
}

# Check log file
Write-Host "`nLog File Status:" -ForegroundColor Cyan
if (Test-Path "$FluentBitLogPath") {
    `$logFile = Get-Item "$FluentBitLogPath"
    Write-Host "Log File: `$(`$logFile.FullName)" -ForegroundColor Green
    Write-Host "Size: `$([math]::Round(`$logFile.Length / 1KB, 2)) KB" -ForegroundColor Gray
    Write-Host "Last Modified: `$(`$logFile.LastWriteTime)" -ForegroundColor Gray
    
    Write-Host "`nLast 5 log entries:" -ForegroundColor Cyan
    Get-Content "$FluentBitLogPath" -Tail 5 | ForEach-Object { Write-Host "  `$_" -ForegroundColor Gray }
} else {
    Write-Host "Log file not found: $FluentBitLogPath" -ForegroundColor Red
}

# Check HTTP metrics endpoint
Write-Host "`nHTTP Metrics Endpoint:" -ForegroundColor Cyan
try {
    `$response = Invoke-WebRequest -Uri "http://localhost:2020/api/v1/metrics" -TimeoutSec 5 -UseBasicParsing
    Write-Host "HTTP Endpoint: Available (Status: `$(`$response.StatusCode))" -ForegroundColor Green
} catch {
    Write-Host "HTTP Endpoint: Not available" -ForegroundColor Yellow
    Write-Host "Error: `$(`$_.Exception.Message)" -ForegroundColor Red
}

# NEW: Check gzip processing status
Write-Host "`nGzip Processing Status:" -ForegroundColor Cyan
if (Test-Path "C:\temp\gzip-initial-processing-complete.txt") {
    Write-Host "Initial gzip processing: COMPLETED" -ForegroundColor Green
    `$completionInfo = Get-Content "C:\temp\gzip-initial-processing-complete.txt" -Raw
    Write-Host "Details: `$completionInfo" -ForegroundColor Gray
} else {
    Write-Host "Initial gzip processing: PENDING or IN-PROGRESS" -ForegroundColor Yellow
}

if (Test-Path "C:\temp\processed-gzip-files.txt") {
    `$processedCount = (Get-Content "C:\temp\processed-gzip-files.txt").Count
    Write-Host "Processed gzip files: `$processedCount" -ForegroundColor Gray
} else {
    Write-Host "No gzip files processed yet" -ForegroundColor Gray
}

Write-Host "`nQuick Commands:" -ForegroundColor Cyan
Write-Host "  Start Service: Start-Service fluent-bit" -ForegroundColor Gray
Write-Host "  Stop Service: Stop-Service fluent-bit" -ForegroundColor Gray
Write-Host "  Restart Service: Restart-Service fluent-bit" -ForegroundColor Gray
Write-Host "  Monitor Logs: & '$tailScriptPath'" -ForegroundColor Gray
Write-Host "  View Metrics: http://localhost:2020" -ForegroundColor Gray
Write-Host "  Reset Gzip Processing: Remove-Item 'C:\temp\gzip-initial-processing-complete.txt' -Force" -ForegroundColor Gray
"@
    
    $statusScriptPath = "$logDir\check-fluent-bit-status.ps1"
    try {
        $statusScript | Out-File -FilePath $statusScriptPath -Encoding UTF8 -Force
        Write-Status "Created status check script: $statusScriptPath" "Success"
    }
    catch {
        Write-Status "Failed to create status check script: $($_.Exception.Message)" "Warning"
    }
    
    return $true
}

# Function to show deployment summary with new gzip logic explanation
function Show-DeploymentSummary {
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    DEPLOYMENT SUMMARY                        " -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    Write-Host "`nInstallation Paths:" -ForegroundColor Yellow
    Write-Host "  • FluentBit: $InstallPath"
    Write-Host "  • Configuration: $ConfigPath"
    Write-Host "  • Storage: $StoragePath"
    Write-Host "  • SQLite Tools: $SqliteToolsPath"
    
    # Show logging configuration
    Write-Host "`nLogging Configuration:" -ForegroundColor Yellow
    Write-Host "  • Log File: $FluentBitLogPath"
    Write-Host "  • Log Level: $FluentBitLogLevel"
    if ($EnableLogRotation) {
        Write-Host "  • Log Rotation: Enabled (Max Size: $FluentBitLogMaxSize)"
    } else {
        Write-Host "  • Log Rotation: Disabled"
    }
    
    # Check if log file exists and show current status
    if (Test-Path $FluentBitLogPath) {
        $logFile = Get-Item $FluentBitLogPath
        $logSizeKB = [math]::Round($logFile.Length / 1KB, 2)
        Write-Host "  • Current Log Size: $logSizeKB KB"
        Write-Host "  • Last Updated: $($logFile.LastWriteTime)"
    } else {
        Write-Host "  • Log File Status: Not yet created (service may need to start)" -ForegroundColor Gray
    }
    
    Write-Host "`nBackend Configuration:" -ForegroundColor Yellow
    Write-Host "  • Host: $CtrlBHost"
    Write-Host "  • Port: $CtrlBPort"
    Write-Host "  • URI: $CtrlBUri"
    Write-Host "  • Auth: $CtrlBAuthHeader"
    
    Write-Host "`nMonitored Log Paths ($($LogPaths.Count) paths, depth 0-$MaxDirectoryDepth):" -ForegroundColor Yellow
    foreach ($path in $LogPaths) {
        Write-Host "  • $path\*.log (recursive)"
    }
    
    # NEW: Enhanced gzip path summary with overlap detection
# Enhanced gzip path summary with safe batch processing
    Write-Host "`nGzip Processing Configuration ($($GzipPaths.Count) paths):" -ForegroundColor Yellow
    Write-Host "  • Max files per batch: $MaxGzipFilesPerRun" -ForegroundColor Gray
    Write-Host "  • Max size per batch: $MaxGzipBatchSizeMB MB" -ForegroundColor Gray
    Write-Host "  • Sleep between files: $GzipSleepBetweenFiles seconds" -ForegroundColor Gray

    foreach ($gzipPath in $GzipPaths) {
        Write-Host "  • $gzipPath\*.gz" -ForegroundColor Gray
        
        # Check for overlap with log paths
        $hasOverlap = $false
        try {
            $normalizedGzipPath = [System.IO.Path]::GetFullPath($gzipPath).TrimEnd('\')
            
            foreach ($logPath in $LogPaths) {
                try {
                    $normalizedLogPath = [System.IO.Path]::GetFullPath($logPath).TrimEnd('\')
                    
                    if ($normalizedGzipPath.StartsWith($normalizedLogPath, [StringComparison]::OrdinalIgnoreCase) -or 
                        $normalizedLogPath.StartsWith($normalizedGzipPath, [StringComparison]::OrdinalIgnoreCase)) {
                        $hasOverlap = $true
                        Write-Host "    → RESTRICTED: Overlaps with log path '$normalizedLogPath'" -ForegroundColor Yellow
                        Write-Host "    → Processing: Safe batch processing until completion" -ForegroundColor Yellow
                        break
                    }
                }
                catch {
                    # Skip invalid paths
                }
            }
        }
        catch {
            Write-Host "    → Warning: Could not normalize path for overlap check" -ForegroundColor Red
        }
        
        if (-not $hasOverlap) {
            Write-Host "    → Processing: Safe batch processing (ongoing monitoring)" -ForegroundColor Green
        }
    }

    Write-Host "`nSafe Batch Processing Logic:" -ForegroundColor Yellow
    Write-Host "  • ALL gzip paths now use safe batch processing" -ForegroundColor Gray
    Write-Host "  • Memory protection: Max $MaxGzipFilesPerRun files or $MaxGzipBatchSizeMB MB per batch" -ForegroundColor Gray
    Write-Host "  • If gzip path overlaps with log paths:" -ForegroundColor Gray
    Write-Host "    - Process ALL existing files in safe batches" -ForegroundColor Gray
    Write-Host "    - Mark completion when finished" -ForegroundColor Gray
    Write-Host "    - Skip gzip processing in subsequent runs" -ForegroundColor Gray
    Write-Host "  • If no overlap:" -ForegroundColor Gray
    Write-Host "    - Process one batch per run (ongoing monitoring)" -ForegroundColor Gray
    Write-Host "  • Benefits: Prevents OOM kills, stable memory usage" -ForegroundColor Gray

    # Show cleanup actions if performed
    if ($CleanInstall -or $DeepClean) {
        Write-Host "`nCleanup Actions Performed:" -ForegroundColor Yellow
        if ($CleanInstall) {
            Write-Host "  • Complete FluentBit uninstall and service removal"
            Write-Host "  • Fresh installation and configuration"
        }
        if ($DeepClean) {
            Write-Host "  • Deep cleanup of FluentBit-created databases and temp files"
            Write-Host "  • Removed decompressed logs created by auto-decompress script"
        }
    }
    
    Write-Host "`nGenerated INPUT Sections:" -ForegroundColor Yellow
    $totalLogInputs = $LogPaths.Count * ($MaxDirectoryDepth + 1)
    $totalGzipInputs = $GzipPaths.Count * 2
    Write-Host "  • Log file inputs: $totalLogInputs"
    Write-Host "  • Gzip processing inputs: $totalGzipInputs (with simplified logic)"
    Write-Host "  • Total INPUT sections: $($totalLogInputs + $totalGzipInputs)"
    
    # Check service status
    $serviceStatus = Get-Service -Name "fluent-bit" -ErrorAction SilentlyContinue
    if ($serviceStatus) {
        Write-Host "`nWindows Service Status:" -ForegroundColor Yellow
        Write-Host "  • Service Name: fluent-bit"
        Write-Host "  • Status: $($serviceStatus.Status)"
        Write-Host "  • Start Type: $($serviceStatus.StartType)"
    }
    
    Write-Host "`nService Management:" -ForegroundColor Yellow
    Write-Host "  • Start Service: Start-Service fluent-bit"
    Write-Host "  • Stop Service: Stop-Service fluent-bit"
    Write-Host "  • Restart Service: Restart-Service fluent-bit"
    Write-Host "  • Check Status: Get-Service fluent-bit"
    Write-Host "  • Uninstall Service: sc.exe delete fluent-bit"

    # Show logging and monitoring commands
    Write-Host "`nLogging & Monitoring:" -ForegroundColor Yellow
    Write-Host "  • View Logs: Get-Content '$FluentBitLogPath' -Tail 20 -Wait"
    Write-Host "  • Monitor Live: & '$(Split-Path $FluentBitLogPath -Parent)\monitor-fluent-bit.ps1'"
    Write-Host "  • Check Status: & '$(Split-Path $FluentBitLogPath -Parent)\check-fluent-bit-status.ps1'"
    Write-Host "  • HTTP Metrics: http://localhost:2020/api/v1/metrics"

    Write-Host "`nGzip Processing Status Files:" -ForegroundColor Yellow
    Write-Host "  • Completion Markers: C:\temp\gzip-initial-processing-complete.txt"
    Write-Host "  • Processed Files List: C:\temp\processed-gzip-files.txt"
    Write-Host "  • Decompressed Files: C:\temp\decompressed-logs\"

    Write-Host "`nNext Steps:" -ForegroundColor Yellow
    Write-Host "  1. Service should be running automatically"
    Write-Host "  2. Monitor FluentBit logs at: $FluentBitLogPath"
    Write-Host "  3. Check HTTP status at: http://localhost:2020"
    Write-Host "  4. Verify log ingestion is working"
    Write-Host "  5. For gzip paths with overlap: Check completion markers after first run"
  
    Write-Host "`nTroubleshooting Commands:" -ForegroundColor Yellow
    Write-Host "  • Test Config: & '$InstallPath\bin\fluent-bit.exe' -c '$ConfigPath\fluent-bit-onbe-staging.conf' -D"
    Write-Host "  • Manual Run: & '$InstallPath\bin\fluent-bit.exe' -c '$ConfigPath\fluent-bit-onbe-staging.conf'"
    Write-Host "  • View Event Logs: Get-EventLog -LogName Application -Source fluent-bit -Newest 10"
    Write-Host "  • Reset Gzip Processing: Remove-Item 'C:\temp\gzip-initial-processing-complete.txt' -Force"
    Write-Host "  • Clean Reinstall: Add -CleanInstall flag to this script"
    Write-Host "  • Deep Clean Reinstall: Add -DeepClean flag to this script"
    
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
}

# Main deployment function
function Start-Deployment {
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║              FluentBit Complete Deployment                   ║" -ForegroundColor Cyan
    Write-Host "║         Install + Config + Service + Logging                ║" -ForegroundColor Cyan
    Write-Host "║              NEW: Simplified Gzip Processing                ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    # Check administrator privileges
    if (-not (Test-Administrator)) {
        Write-Status "This script requires Administrator privileges. Please run as Administrator." "Error"
        return $false
    }
    
    # Validate required parameters
    if (-not $CtrlBHost) {
        Write-Status "CtrlBHost parameter is required" "Error"
        return $false
    }
    
    if (-not $CtrlBAuthHeader) {
        Write-Status "CtrlBAuthHeader parameter is required" "Error"
        return $false
    }
    
    if ($TestOnly) {
        Write-Status "Running in test mode - no changes will be made" "Info"
        Write-Status "Config source directory: $ConfigSourceDir" "Info"
        Write-Status "Target config directory: $ConfigPath" "Info"
        Write-Status "Backend: $CtrlBHost`:$CtrlBPort" "Info"
        Write-Status "Log paths: $($LogPaths -join ', ')" "Info"
        Write-Status "Gzip paths: $($GzipPaths -join ', ')" "Info"
        Write-Status "FluentBit log file: $FluentBitLogPath" "Info"
        Write-Status "FluentBit log level: $FluentBitLogLevel" "Info"
        Write-Status "Clean install: $CleanInstall" "Info"
        Write-Status "Deep clean: $DeepClean" "Info"
        
        # NEW: Show gzip overlap detection results in test mode
        Write-Status "=== Gzip Overlap Detection Test ===" "Info"
        foreach ($gzipPath in $GzipPaths) {
            $hasOverlap = $false
            try {
                $normalizedGzipPath = [System.IO.Path]::GetFullPath($gzipPath).TrimEnd('\')
                
                foreach ($logPath in $LogPaths) {
                    try {
                        $normalizedLogPath = [System.IO.Path]::GetFullPath($logPath).TrimEnd('\')
                        
                        if ($normalizedGzipPath.StartsWith($normalizedLogPath, [StringComparison]::OrdinalIgnoreCase) -or 
                            $normalizedLogPath.StartsWith($normalizedGzipPath, [StringComparison]::OrdinalIgnoreCase)) {
                            $hasOverlap = $true
                            Write-Status "Gzip path '$gzipPath' OVERLAPS with log path '$logPath' → One-time processing" "Warning"
                            break
                        }
                    }
                    catch {
                        Write-Status "Could not normalize log path '$logPath'" "Warning"
                    }
                }
            }
            catch {
                Write-Status "Could not normalize gzip path '$gzipPath'" "Warning"
            }
            
            if (-not $hasOverlap) {
                Write-Status "Gzip path '$gzipPath' → Continuous monitoring" "Success"
            }
        }
        
        return $true
    }
    
    $success = $true
    
    # Perform cleanup operations first if requested
    if ($CleanInstall -or $DeepClean) {
        Write-Status "Cleanup operations requested..." "Info"
        Invoke-CleanupOperations
    }
    
    # Setup FluentBit logging infrastructure early
    Write-Status "Setting up FluentBit logging infrastructure..." "Step"
    if (-not (Setup-FluentBitLogging)) {
        Write-Status "FluentBit logging setup failed, but continuing..." "Warning"
    }
    
    # Step 1: Install FluentBit
    if (-not $SkipFluentBitInstall) {
        if (-not (Install-FluentBit -Version $FluentBitVersion)) {
            Write-Status "FluentBit installation failed" "Error"
            $success = $false
        }
    } else {
        Write-Status "Skipping FluentBit installation" "Info"
    }
    
    # Step 2: Install SQLite tools
    if ($success -and -not $SkipSqliteInstall) {
        if (-not (Install-SqliteTools)) {
            Write-Status "SQLite installation failed" "Error"
            $success = $false
        }
    } else {
        Write-Status "Skipping SQLite installation" "Info"
    }
    
    # Step 3: Create storage directories
    if ($success) {
        if (-not (Create-StorageDirectories)) {
            Write-Status "Storage directory creation failed" "Error"
            $success = $false
        }
    }
    
    # Step 4: Deploy and customize configuration files
    if ($success) {
        if (-not (Deploy-ConfigurationFiles)) {
            Write-Status "Configuration deployment failed" "Error"
            $success = $false
        }
    }
    
    # Step 5: Test configuration
    if ($success) {
        if (-not (Test-FluentBitConfiguration)) {
            Write-Status "Configuration test failed. Continuing with service creation..." "Warning"
        }
    }
    
    # Step 6: Create Windows Service
    if ($success -and -not $SkipServiceCreation) {
        if (-not (Install-FluentBitService)) {
            Write-Status "Windows Service creation failed" "Error"
            $success = $false
        }
    } else {
        Write-Status "Skipping Windows Service creation" "Info"
    }
    
    # Step 7: Create monitoring tools
    if ($success) {
        Create-MonitoringTools
    }
    
    # Show results
    if ($success) {
        Write-Status "Deployment completed successfully!" "Success"
        Show-DeploymentSummary
        
        # Final verification
        Write-Host "`n" -NoNewline
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "                     FINAL VERIFICATION                       " -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
        
        # Wait a moment for service to start logging
        Write-Status "Waiting for FluentBit to start logging..." "Info"
        Start-Sleep -Seconds 8
        
        # Check if FluentBit is logging
        if (Test-Path $FluentBitLogPath) {
            $logContent = Get-Content $FluentBitLogPath -Tail 5 -ErrorAction SilentlyContinue
            if ($logContent) {
                Write-Status "✓ FluentBit is successfully logging to: $FluentBitLogPath" "Success"
                Write-Host "`nRecent log entries:" -ForegroundColor Cyan
                $logContent | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
            } else {
                Write-Status "⚠ Log file exists but is empty. Service may still be starting..." "Warning"
            }
        } else {
            Write-Status "⚠ FluentBit log file not yet created. Check service status." "Warning"
        }
        
        # Quick service status check
        $service = Get-Service -Name "fluent-bit" -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') {
            Write-Status "✓ FluentBit service is running" "Success"
        } else {
            Write-Status "⚠ FluentBit service status: $($service.Status)" "Warning"
        }
        
        # NEW: Show gzip processing status
        Write-Host "`nGzip Processing Status:" -ForegroundColor Cyan
        if (Test-Path "C:\temp\gzip-initial-processing-complete.txt") {
            Write-Status "✓ Initial gzip processing completed" "Success"
        } else {
            Write-Status "⏳ Initial gzip processing pending (will happen on first run)" "Info"
        }
        
        Write-Host "`n🚀 Your FluentBit deployment with simplified gzip processing is ready!" -ForegroundColor Green
        Write-Host "📋 Monitor logs: Get-Content '$FluentBitLogPath' -Tail 20 -Wait" -ForegroundColor Cyan
        Write-Host "🌐 HTTP metrics: http://localhost:2020" -ForegroundColor Cyan
        Write-Host "📊 Check status: & '$(Split-Path $FluentBitLogPath -Parent)\check-fluent-bit-status.ps1'" -ForegroundColor Cyan
        
    } else {
        Write-Status "Deployment completed with errors. Please check the output above." "Error"
        Write-Host "`nFor troubleshooting:" -ForegroundColor Yellow
        Write-Host "1. Check FluentBit logs: Get-Content '$FluentBitLogPath'" -ForegroundColor Gray
        Write-Host "2. Check Windows Event Logs for service errors" -ForegroundColor Gray
        Write-Host "3. Try manual FluentBit run: & '$InstallPath\bin\fluent-bit.exe' -c '$ConfigPath\fluent-bit-onbe-staging.conf'" -ForegroundColor Gray
    }
    
    return $success
}

# Entry point
if ($MyInvocation.InvocationName -ne '.') {
    # Auto-enable CleanInstall if DeepClean is specified
    if ($DeepClean) {
        $CleanInstall = $true
        Write-Status "DeepClean enabled - CleanInstall will also be performed" "Info"
    }
    
    # Validate FluentBit log path
    if (-not $FluentBitLogPath) {
        Write-Status "FluentBitLogPath parameter is required" "Error"
        exit 1
    }
    
    # Ensure log directory in path exists or can be created
    $logDir = Split-Path $FluentBitLogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        Write-Status "FluentBit log directory will be created: $logDir" "Info"
    }
    
    Start-Deployment
}