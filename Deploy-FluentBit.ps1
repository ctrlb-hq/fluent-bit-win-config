# FluentBit Complete Deployment Script with Windows Service
# Installs FluentBit, copies config files, customizes configuration, and creates Windows Service

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
    
    # NEW: Required parameters for simplified configuration
    [Parameter(Mandatory=$true)]
    [string]$CtrlBHost,
    
    [Parameter(Mandatory=$false)]
    [string]$CtrlBPort = "5080",
    
    [Parameter(Mandatory=$true)]
    [string]$CtrlBAuthHeader,
    
    [Parameter(Mandatory=$true)]
    [string]$CtrlBStreamName,
    
    # NEW: Log level parameter (simplified)
    [Parameter(Mandatory=$false)]
    [string]$LogLevel = "info",
    
    # Log Paths Configuration (simplified - no gzip paths)
    [Parameter(Mandatory=$false)]
    [string[]]$LogPaths = @("D:\c-base\logs"),

    [Parameter(Mandatory=$false)]
    [int]$MaxDirectoryDepth = 3,
    
    # NEW: Gzip Processing Parameters
    [Parameter(Mandatory=$false)]
    [switch]$ProcessGzipFiles = $false,
    
    [Parameter(Mandatory=$false)]
    [int]$GzipBatchSize = 5,
    
    [Parameter(Mandatory=$false)]
    [int]$GzipProcessingInterval = 15,  # 5 minutes
    
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
    [switch]$Force
)

# ============================================================================
# DOT-SOURCE SUPPORTING MODULES
# ============================================================================

# Get the directory where this script is located
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Dot-source the supporting modules
try {
    . "$ScriptPath\FluentBit-Core.ps1"
    . "$ScriptPath\FluentBit-Utils.ps1"
}
catch {
    Write-Host "ERROR: Failed to load supporting modules from $ScriptPath" -ForegroundColor Red
    Write-Host "Please ensure FluentBit-Core.ps1 and FluentBit-Utils.ps1 are in the same directory" -ForegroundColor Red
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ============================================================================
# MAIN DEPLOYMENT FUNCTION
# ============================================================================

# Main deployment function
function Start-Deployment {
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                   FluentBit Deployment                       ║" -ForegroundColor Cyan
    Write-Host "║         Install + Config + Service + Monitoring              ║" -ForegroundColor Cyan
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
    
    if (-not $CtrlBStreamName) {
        Write-Status "CtrlBStreamName parameter is required" "Error"
        return $false
    }
    
    if ($TestOnly) {
        Write-Status "Running in test mode - no changes will be made" "Info"
        Write-Status "Config source directory: $ConfigSourceDir" "Info"
        Write-Status "Target config directory: $ConfigPath" "Info"
        Write-Status "Backend: $CtrlBHost`:$CtrlBPort" "Info"
        Write-Status "Stream: $CtrlBStreamName" "Info"
        Write-Status "Log level: $LogLevel" "Info"
        Write-Status "Log paths: $($LogPaths -join ', ')" "Info"
        Write-Status "Max directory depth: $MaxDirectoryDepth" "Info"
        Write-Status "FluentBit log file: $FluentBitLogPath" "Info"
        Write-Status "Clean install: $CleanInstall" "Info"
        Write-Status "Deep clean: $DeepClean" "Info"

        if ($ProcessGzipFiles) {
            Write-Status "=== GZIP PROCESSING ENABLED ===" "Info"
            Write-Status "Gzip batch size: $GzipBatchSize" "Info"
            Write-Status "Gzip processing interval: $GzipProcessingInterval seconds" "Info"
            Write-Status "Gzip temp directory: $StoragePath\gzip-temp" "Info"
            Write-Status "Would scan LogPaths for .gz files at depths 0-$MaxDirectoryDepth" "Info"
        } else {
            Write-Status "Gzip processing: DISABLED (use -ProcessGzipFiles to enable)" "Info"
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
    
    # Step 3.5: Initialize gzip processing if enabled
    if ($success -and $ProcessGzipFiles) {
        Write-Status "Initializing gzip archive processing..." "Step"
        if (-not (Initialize-GzipProcessing -LogPaths $LogPaths -MaxDepth $MaxDirectoryDepth -StoragePath $StoragePath)) {
            Write-Status "Gzip processing initialization failed, continuing without gzip processing..." "Warning"
            $ProcessGzipFiles = $false  # Disable gzip processing for this deployment
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
        Write-Host "                     FINAL VERIFICATION                        " -ForegroundColor Green
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

        # Gzip processing verification
        if ($ProcessGzipFiles) {
            Write-Host "`n" -NoNewline
            Write-Status "Verifying gzip processing setup..." "Info"
            
            $gzipStateFile = "$StoragePath\gzip-processing-state.json"
            if (Test-Path $gzipStateFile) {
                try {
                    $gzipState = Get-Content $gzipStateFile -Raw | ConvertFrom-Json
                    $stats = $gzipState.processing_stats
                    Write-Status "✓ Gzip processing initialized: $($stats.total_files) archive files discovered" "Success"
                    
                    if ($stats.total_files -gt 0) {
                        Write-Status "✓ First gzip batch will process in $($gzipState.processing_interval) seconds" "Success"
                        Write-Host "📁 Gzip temp directory: $($gzipState.gzip_temp_dir)" -ForegroundColor Cyan
                        Write-Host "📊 Gzip status: Get-Content '$gzipStateFile' | ConvertFrom-Json | Select processing_stats" -ForegroundColor Cyan
                    } else {
                        Write-Status "ℹ No gzip files found in monitored directories" "Info"
                    }
                }
                catch {
                    Write-Status "⚠ Gzip state file exists but is malformed" "Warning"
                }
            } else {
                Write-Status "⚠ Gzip processing enabled but state file not created" "Warning"
            }
        }
        
        Write-Host "`n🚀 Your FluentBit deployment is ready!" -ForegroundColor Green
        Write-Host "📋 Monitor logs: Get-Content '$FluentBitLogPath' -Tail 20 -Wait" -ForegroundColor Cyan
        Write-Host "🌐 HTTP metrics: http://localhost:2020" -ForegroundColor Cyan
        Write-Host "📊 Check status: & '$(Split-Path $FluentBitLogPath -Parent)\check-fluent-bit-status.ps1'" -ForegroundColor Cyan

        if ($ProcessGzipFiles) {
            Write-Host "📦 Gzip processor: Get-Content '$StoragePath\gzip-processor.log' -Tail 10 -Wait" -ForegroundColor Cyan
            Write-Host "📈 Gzip status: Get-Content '$StoragePath\gzip-processing-state.json' | ConvertFrom-Json | Select processing_stats" -ForegroundColor Cyan
        }
    } else {
        Write-Status "Deployment completed with errors. Please check the output above." "Error"
        Write-Host "`nFor troubleshooting:" -ForegroundColor Yellow
        Write-Host "1. Check FluentBit logs: Get-Content '$FluentBitLogPath'" -ForegroundColor Gray
        Write-Host "2. Check Windows Event Logs for service errors" -ForegroundColor Gray
        Write-Host "3. Try manual FluentBit run: & '$InstallPath\bin\fluent-bit.exe' -c '$ConfigPath\fluent-bit-onbe.conf'" -ForegroundColor Gray
        
        if ($ProcessGzipFiles) {
            Write-Host "4. Check gzip processor logs: Get-Content '$StoragePath\gzip-processor.log'" -ForegroundColor Gray
            Write-Host "5. Check gzip state: Get-Content '$StoragePath\gzip-processing-state.json'" -ForegroundColor Gray
            Write-Host "6. Manual gzip test: & '$InstallPath\scripts\Process-GzipFiles.ps1' -StoragePath '$StoragePath'" -ForegroundColor Gray
        }
    }
    
    return $success
}

# ============================================================================
# PARAMETER VALIDATION AND ENTRY POINT
# ============================================================================

# Entry point - only run if script is executed directly (not dot-sourced)
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
    
    # Validate log level
    $validLogLevels = @("error", "warn", "info", "debug", "trace")
    if ($LogLevel -notin $validLogLevels) {
        Write-Status "Invalid log level: $LogLevel. Valid options: $($validLogLevels -join ', ')" "Error"
        exit 1
    }
    
    # Validate log paths exist (at least one should exist)
    $validLogPaths = @()
    foreach ($path in $LogPaths) {
        if (Test-Path $path) {
            $validLogPaths += $path
        } else {
            Write-Status "Warning: Log path does not exist: $path" "Warning"
        }
    }
    
    if ($validLogPaths.Count -eq 0 -and -not $TestOnly) {
        Write-Status "Warning: None of the specified log paths exist. Continuing anyway..." "Warning"
    }

    # Validate gzip processing parameters
    if ($ProcessGzipFiles) {
        Write-Status "Gzip processing enabled with batch size: $GzipBatchSize, interval: $GzipProcessingInterval seconds" "Info"
        
        if ($GzipBatchSize -lt 1 -or $GzipBatchSize -gt 20) {
            Write-Status "Invalid GzipBatchSize: $GzipBatchSize. Valid range: 1-20" "Error"
            exit 1
        }
        
        if ($GzipProcessingInterval -lt 10) {
            Write-Status "GzipProcessingInterval too low: $GzipProcessingInterval. Minimum: 10 seconds" "Error"
            exit 1
        }
    } else {
        Write-Status "Gzip processing disabled (use -ProcessGzipFiles to enable)" "Info"
    }
    
    # Show simplified startup information
    Write-Host "FluentBit Deployment Parameters:" -ForegroundColor Cyan
    Write-Host "  • Backend: $CtrlBHost`:$CtrlBPort" -ForegroundColor Gray
    Write-Host "  • Stream: $CtrlBStreamName" -ForegroundColor Gray
    Write-Host "  • Log Level: $LogLevel" -ForegroundColor Gray
    Write-Host "  • Log Paths: $($LogPaths.Count) paths, max depth $MaxDirectoryDepth" -ForegroundColor Gray
    Write-Host "  • Installation: $InstallPath" -ForegroundColor Gray
    Write-Host "  • Logging: $FluentBitLogPath" -ForegroundColor Gray

    if ($ProcessGzipFiles) {
        Write-Host "  • Gzip Processing: ENABLED (batch: $GzipBatchSize, interval: ${GzipProcessingInterval}s)" -ForegroundColor Green
    } else {
        Write-Host "  • Gzip Processing: DISABLED" -ForegroundColor Gray
    }
    
    Start-Deployment
}