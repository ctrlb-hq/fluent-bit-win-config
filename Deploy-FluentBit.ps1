# FluentBit Complete Deployment Script with Windows Service
# Installs FluentBit, SQLite tools, copies config files, customizes configuration, and creates Windows Service
# Version: 3.0

param(
    [Parameter(Mandatory=$false)]
    [string]$FluentBitVersion = "4.0.4",
    
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
    [switch]$Force
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
    if ((Test-Path "$InstallPath\bin\fluent-bit.exe") -and -not $Force) {
        Write-Status "FluentBit already installed. Use -Force to reinstall." "Warning"
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
    if ((Test-Path "$SqliteToolsPath\sqlite3.exe") -and -not $Force) {
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

# Function to generate INPUT sections for gzip decompression
function Generate-GzipInputSections {
    param(
        [string[]]$Paths
    )
    
    $inputSections = @()
    
    foreach ($path in $Paths) {
        # Sanitize path for tag name
        $pathSanitized = ($path -replace '[\\/:*?"<>|]', '_').Trim('_')
        
        $inputSection = @"

[INPUT]
    Name                        exec
    Tag                         gzip.decompressor.$pathSanitized
    Command                     powershell.exe -ExecutionPolicy Bypass -File "$ConfigPath\auto-decompress.ps1" -SourcePattern "$path\*.gz" -TargetDir "C:\temp\decompressed-logs\$pathSanitized" -Sqlite3Path "$SqliteToolsPath\sqlite3.exe" -FluentBitDBPath "$StoragePath\tail-gzip-$pathSanitized.db" -MaxFilesPerRun 3 -FileSizeLimitMB 50
    Interval_Sec                5
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
            
            # Replace backend configuration placeholders
            $configContent = $configContent -replace '<CTRLB_BACKEND_HOST>', $CtrlBHost
            $configContent = $configContent -replace '<CTRLB_BACKEND_PORT>', $CtrlBPort
            $configContent = $configContent -replace '<CTRLB_BACKEND_AUTH_HEADER>', $CtrlBAuthHeader
            
            # Replace URI if different from default
            if ($CtrlBUri -ne "/api/default/staging/_json") {
                $configContent = $configContent -replace '/api/default/staging/_json', $CtrlBUri
            }
            
            # Generate dynamic INPUT sections
            Write-Status "Generating INPUT sections for $($LogPaths.Count) log paths and $($GzipPaths.Count) gzip paths..." "Info"
            
            $logInputSections = Generate-LogInputSections -Paths $LogPaths -MaxDepth $MaxDirectoryDepth
            $gzipInputSections = Generate-GzipInputSections -Paths $GzipPaths
            
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
    $description = "Fluent Bit lightweight log processor and forwarder for logs, metrics and traces"
    
    # Validate prerequisites
    if (-not (Test-Path $fluentBitExe)) {
        Write-Status "FluentBit executable not found: $fluentBitExe" "Error"
        return $false
    }
    
    if (-not (Test-Path $configFile)) {
        Write-Status "Configuration file not found: $configFile" "Error"
        return $false
    }
    
    # Remove existing service if it exists
    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-Status "Removing existing FluentBit service..." "Warning"
        try {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            sc.exe delete $serviceName | Out-Null
            Start-Sleep -Seconds 2
            Write-Status "Existing service removed" "Success"
        }
        catch {
            Write-Status "Failed to remove existing service: $($_.Exception.Message)" "Error"
            return $false
        }
    }
    
    try {
        # Create the service using sc.exe with proper syntax
        Write-Status "Creating service with binPath: `"$fluentBitExe`" -c `"$configFile`"" "Info"
        
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
                    } else {
                        Write-Status "Service status: $($serviceStatus.Status). Check Event Viewer for details." "Warning"
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

# Function to show deployment summary
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
    
    Write-Host "`nBackend Configuration:" -ForegroundColor Yellow
    Write-Host "  • Host: $CtrlBHost"
    Write-Host "  • Port: $CtrlBPort"
    Write-Host "  • URI: $CtrlBUri"
    Write-Host "  • Auth: $CtrlBAuthHeader"
    
    Write-Host "`nMonitored Log Paths ($($LogPaths.Count) paths, depth 0-$MaxDirectoryDepth):" -ForegroundColor Yellow
    foreach ($path in $LogPaths) {
        Write-Host "  • $path\*.log (recursive)"
    }
    
    Write-Host "`nMonitored Gzip Paths ($($GzipPaths.Count) paths):" -ForegroundColor Yellow
    foreach ($path in $GzipPaths) {
        Write-Host "  • $path\*.gz"
    }
    
    Write-Host "`nGenerated INPUT Sections:" -ForegroundColor Yellow
    $totalLogInputs = $LogPaths.Count * ($MaxDirectoryDepth + 1)
    $totalGzipInputs = $GzipPaths.Count * 2
    Write-Host "  • Log file inputs: $totalLogInputs"
    Write-Host "  • Gzip processing inputs: $totalGzipInputs"
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

    Write-Host "`nNext Steps:" -ForegroundColor Yellow
    Write-Host "  1. Service should be running automatically"
    Write-Host "  2. Monitor status at: http://localhost:2020"
    Write-Host "  3. Check service status: Get-Service fluent-bit"
  
    Write-Host "`nTroubleshooting Commands:" -ForegroundColor Yellow
    Write-Host "  • Test Config: & '$InstallPath\bin\fluent-bit.exe' -c '$ConfigPath\fluent-bit-onbe-staging.conf' -D"
    Write-Host "  • Manual Run: & '$InstallPath\bin\fluent-bit.exe' -c '$ConfigPath\fluent-bit-onbe-staging.conf'"
    Write-Host "  • HTTP Status: http://localhost:2020"
    
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
}

# Main deployment function
function Start-Deployment {
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║              FluentBit Complete Deployment                   ║" -ForegroundColor Cyan
    Write-Host "║               Install + Config + Service                     ║" -ForegroundColor Cyan
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
        return $true
    }
    
    $success = $true
    
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
    
    # Step 6: Create Windows Service (ALWAYS RUNS unless explicitly skipped)
    if ($success -and -not $SkipServiceCreation) {
        if (-not (Install-FluentBitService)) {
            Write-Status "Windows Service creation failed" "Error"
            $success = $false
        }
    } else {
        Write-Status "Skipping Windows Service creation" "Info"
    }
    
    # Show results
    if ($success) {
        Write-Status "Deployment completed successfully!" "Success"
        Show-DeploymentSummary
    } else {
        Write-Status "Deployment completed with errors. Please check the output above." "Error"
    }
    
    return $success
}

# Entry point
if ($MyInvocation.InvocationName -ne '.') {
    Start-Deployment
}