param(
    [Parameter(Mandatory=$true)]
    [string]$SourcePattern,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetDir,

    [Parameter(Mandatory=$true)]
    [string]$FluentBitDBPath,

    [Parameter(Mandatory=$true)]
    [string]$Sqlite3Path,
    
    [Parameter(Mandatory=$false)]
    [string]$ProcessedListFile = "C:\temp\processed-gzip-files.txt",
    
    [Parameter(Mandatory=$false)]
    [int]$FileSizeLimitMB = 100,
    
    [Parameter(Mandatory=$false)]
    [int]$SleepBetweenFiles = 1,
    
    [Parameter(Mandatory=$false)]
    [switch]$DisableCleanup,
    
    # NEW: Parameters for simplified gzip handling
    [Parameter(Mandatory=$false)]
    [string[]]$LogPaths = @(),
    
    [Parameter(Mandatory=$false)]
    [string]$CompletionMarkerFile = "C:\temp\gzip-initial-processing-complete.txt"
)

# Add .NET types for compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Function to ensure directory exists
function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# Function to get list of already processed files
function Get-ProcessedFiles {
    param([string]$ListFile)
    
    if (Test-Path $ListFile) {
        return Get-Content $ListFile
    }
    return @()
}

# Function to add file to processed list
function Add-ProcessedFile {
    param(
        [string]$FilePath,
        [string]$ListFile
    )
    
    $FilePath | Add-Content $ListFile -Encoding UTF8
}

# NEW: Function to check if initial processing is already complete
function Test-InitialProcessingComplete {
    param([string]$MarkerFile)
    
    if (Test-Path $MarkerFile) {
        Write-Host "Initial gzip processing already completed. Marker file exists: $MarkerFile" -ForegroundColor Green
        return $true
    }
    return $false
}

# NEW: Function to mark initial processing as complete
function Set-InitialProcessingComplete {
    param([string]$MarkerFile)
    
    try {
        $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ"
        $content = @"
Initial gzip processing completed at: $timestamp
Source pattern: $SourcePattern
Target directory: $TargetDir
Log paths that caused restriction: $($LogPaths -join ', ')
"@
        $content | Out-File -FilePath $MarkerFile -Encoding UTF8 -Force
        Write-Host "Marked initial gzip processing as complete: $MarkerFile" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Failed to create completion marker file: $($_.Exception.Message)"
        return $false
    }
}

# NEW: Function to check if gzip path overlaps with any log path
function Test-GzipPathOverlapsWithLogPaths {
    param(
        [string]$GzipPath,
        [string[]]$LogPaths
    )
    
    if ($LogPaths.Count -eq 0) {
        Write-Host "No log paths specified - gzip monitoring will continue normally" -ForegroundColor Gray
        return $false
    }
    
    # Normalize paths for comparison
    $normalizedGzipPath = [System.IO.Path]::GetFullPath($GzipPath).TrimEnd('\')
    
    foreach ($logPath in $LogPaths) {
        try {
            $normalizedLogPath = [System.IO.Path]::GetFullPath($logPath).TrimEnd('\')
            
            # Check if gzip path is same as or subdirectory of log path
            if ($normalizedGzipPath.StartsWith($normalizedLogPath, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Host "Gzip path '$normalizedGzipPath' overlaps with log path '$normalizedLogPath'" -ForegroundColor Yellow
                Write-Host "Gzip monitoring will be restricted to initial processing only" -ForegroundColor Yellow
                return $true
            }
            
            # Also check if log path is subdirectory of gzip path (edge case)
            if ($normalizedLogPath.StartsWith($normalizedGzipPath, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Host "Log path '$normalizedLogPath' is subdirectory of gzip path '$normalizedGzipPath'" -ForegroundColor Yellow
                Write-Host "Gzip monitoring will be restricted to initial processing only" -ForegroundColor Yellow
                return $true
            }
        }
        catch {
            Write-Warning "Failed to normalize path '$logPath': $($_.Exception.Message)"
        }
    }
    
    Write-Host "No overlap detected between gzip path and log paths - normal processing" -ForegroundColor Gray
    return $false
}

function Get-FluentBitTrackedFiles {
   param(
        [string]$DBPath,
        [string]$Sqlite3Path
    )
   
   if (-not (Test-Path $DBPath)) {
       Write-Host "FluentBit database not found: $DBPath" -ForegroundColor Yellow
       return @()
   }
   
   try {
       if (-not (Test-Path $Sqlite3Path)) {
           Write-Host "sqlite3.exe not found at: $Sqlite3Path" -ForegroundColor Yellow
           return @()
       }
       
       $result = & $Sqlite3Path $DBPath "SELECT name, offset FROM in_tail_files;" 2>$null
       
       if ($LASTEXITCODE -eq 0 -and $result) {
           $trackedFiles = @()
           foreach ($line in $result) {
               if ($line -match '^(.+)\|(\d+)$') {
                   $trackedFiles += @{
                       Name = $matches[1]
                       Offset = [int64]$matches[2]
                   }
               }
           }
           return $trackedFiles
       }
       
       return @()
   }
   catch {
       Write-Warning "Error reading FluentBit database: $($_.Exception.Message)"
       return @()
   }
}

# Function to decompress gzip file with safety checks
function Decompress-GzipFile {
    param(
        [string]$SourcePath,
        [string]$TargetDirectory,
        [int]$MaxSizeMB
    )
    
    try {
        # Check file size before processing
        $sourceFile = Get-Item $SourcePath
        $sourceSizeMB = [math]::Round($sourceFile.Length / 1MB, 2)
        
        if ($sourceSizeMB -gt $MaxSizeMB) {
            Write-Warning "Skipping large file: $($sourceFile.Name) ($sourceSizeMB MB > $MaxSizeMB MB limit)"
            return $null
        }
        
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $targetFile = Join-Path $TargetDirectory "$fileName`_$timestamp.log"
        
        # Ensure target directory exists
        Ensure-Directory -Path $TargetDirectory
        
        Write-Host "Decompressing: $($sourceFile.Name) ($sourceSizeMB MB)" -ForegroundColor Green
        
        # Decompress using .NET streams with try-finally for proper cleanup
        $sourceStream = $null
        $gzipStream = $null
        $targetStream = $null
        
        try {
            $sourceStream = [System.IO.File]::OpenRead($SourcePath)
            $gzipStream = [System.IO.Compression.GzipStream]::new($sourceStream, [System.IO.Compression.CompressionMode]::Decompress)
            $targetStream = [System.IO.File]::Create($targetFile)
            
            $gzipStream.CopyTo($targetStream)
            
            Write-Host "Successfully decompressed: $SourcePath -> $targetFile"
            return $targetFile
        }
        finally {
            # Ensure all streams are closed
            if ($targetStream) { $targetStream.Close() }
            if ($gzipStream) { $gzipStream.Close() }
            if ($sourceStream) { $sourceStream.Close() }
        }
    }
    catch {
        Write-Error "Error decompressing $SourcePath : $($_.Exception.Message)"
        
        # Clean up partial file
        if ($targetFile -and (Test-Path $targetFile)) {
            try {
                Remove-Item $targetFile -Force -ErrorAction SilentlyContinue
                Write-Host "Cleaned up partial file: $targetFile" -ForegroundColor Yellow
            }
            catch {
                Write-Warning "Could not clean up partial file: $targetFile"
            }
        }
        
        return $null
    }
}

# Function to cleanup files that have been tracked by FluentBit
function Cleanup-TrackedDecompressedFiles {
    param(
        [string]$TargetDirectory,
        [string]$DBPath,
        [string]$Sqlite3Path
    )
    
    try {
        if (-not (Test-Path $TargetDirectory)) {
            return
        }
        
        # Get files tracked by FluentBit
        $trackedFiles = Get-FluentBitTrackedFiles -DBPath $DBPath -Sqlite3Path $Sqlite3Path
        
        if ($trackedFiles.Count -eq 0) {
            Write-Host "No tracked files found in FluentBit database" -ForegroundColor Gray
            return
        }
        
        Write-Host "Found $($trackedFiles.Count) file(s) tracked by FluentBit" -ForegroundColor Cyan
        
        # Get all decompressed files
        $decompressedFiles = Get-ChildItem -Path $TargetDirectory -File -Filter "*.log"
        
        $deletedCount = 0
        foreach ($file in $decompressedFiles) {
            $filePath = $file.FullName
            
            # Check if this file is tracked by FluentBit
            $isTracked = $trackedFiles | Where-Object { $_.Name -eq $filePath }
            
            if ($isTracked) {
                # Check if the file has been read (offset > 0) or file size equals offset
                $fileSize = $file.Length
                $offset = $isTracked.Offset
                
                # If offset equals file size, FluentBit has read the entire file
                if ($offset -ge $fileSize -and $fileSize -gt 0) {
                    try {
                        Remove-Item -Path $filePath -Force
                        Write-Host "Deleted fully ingested file: $($file.Name) (size: $fileSize, offset: $offset)" -ForegroundColor Green
                        $deletedCount++
                    }
                    catch {
                        Write-Warning "Could not delete file: $($file.Name) - $($_.Exception.Message)"
                    }
                } else {
                    Write-Host "File still being processed: $($file.Name) (size: $fileSize, offset: $offset)" -ForegroundColor Gray
                }
            }
        }
        
        if ($deletedCount -gt 0) {
            Write-Host "Cleaned up $deletedCount fully ingested file(s)" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Error during cleanup: $($_.Exception.Message)"
    }
}

# Main execution
try {
    Write-Host "=== Simplified Gzip Decompression Script Started ===" -ForegroundColor Cyan
    Write-Host "Source pattern: $SourcePattern" -ForegroundColor Gray
    Write-Host "Target directory: $TargetDir" -ForegroundColor Gray
    Write-Host "File size limit: $FileSizeLimitMB MB" -ForegroundColor Gray
    Write-Host "Log paths for overlap check: $($LogPaths -join ', ')" -ForegroundColor Gray
    
    # NEW: Check if this is a restricted gzip path (overlaps with log paths)
    $isRestrictedPath = Test-GzipPathOverlapsWithLogPaths -GzipPath (Split-Path $SourcePattern -Parent) -LogPaths $LogPaths
    
    # NEW: If restricted, check if initial processing is already complete
    if ($isRestrictedPath) {
        if (Test-InitialProcessingComplete -MarkerFile $CompletionMarkerFile) {
            Write-Host "=== Skipping gzip processing - initial processing already completed ===" -ForegroundColor Green
            
            # Still perform cleanup if enabled
            if (-not $DisableCleanup) {
                Write-Host "Performing cleanup of tracked decompressed files..." -ForegroundColor Cyan
                Cleanup-TrackedDecompressedFiles -TargetDirectory $TargetDir -DBPath $FluentBitDBPath -Sqlite3Path $Sqlite3Path
            }
            
            Write-Host "=== Script execution completed (no processing needed) ===" -ForegroundColor Cyan
            exit 0
        } else {
            Write-Host "=== Performing INITIAL one-time gzip processing ===" -ForegroundColor Yellow
        }
    } else {
        Write-Host "=== Normal gzip processing (no path restrictions) ===" -ForegroundColor Cyan
    }
    
    # Ensure target directory exists
    Ensure-Directory -Path $TargetDir
    
    # Get list of already processed files
    $processedFiles = Get-ProcessedFiles -ListFile $ProcessedListFile
    Write-Host "Previously processed files: $($processedFiles.Count)" -ForegroundColor Gray
    
    # Get all gzip files matching the pattern (recursively)
    if ($SourcePattern -like "*\*") {
        # Extract directory and pattern
        $directory = Split-Path $SourcePattern -Parent
        $pattern = Split-Path $SourcePattern -Leaf
        
        Write-Host "Searching recursively in: $directory for pattern: $pattern" -ForegroundColor Cyan
        $gzipFiles = Get-ChildItem -Path $directory -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue
    } else {
        # Single file or simple pattern
        $gzipFiles = Get-ChildItem -Path $SourcePattern -File -ErrorAction SilentlyContinue
    }
    
    # Filter out already processed files and sort by size (smallest first)
    $newFiles = $gzipFiles | Where-Object { $_.FullName -notin $processedFiles } | Sort-Object Length
    
    Write-Host "Total gzip files found: $($gzipFiles.Count)" -ForegroundColor Cyan
    Write-Host "New files to process: $($newFiles.Count)" -ForegroundColor Cyan
    
    if ($newFiles.Count -eq 0) {
        Write-Host "No new files to process." -ForegroundColor Green
        
        # NEW: If this is restricted path and no files to process, mark as complete
        if ($isRestrictedPath) {
            Set-InitialProcessingComplete -MarkerFile $CompletionMarkerFile
        }
    } else {
        # NEW: For restricted paths, process ALL files in one go (no MaxFilesPerRun limit)
        if ($isRestrictedPath) {
            Write-Host "Processing ALL $($newFiles.Count) files for initial one-time processing" -ForegroundColor Yellow
            $filesToProcess = $newFiles
        } else {
            # For non-restricted paths, maintain the original batching behavior
            # However, we'll remove MaxFilesPerRun limit since we're simplifying
            Write-Host "Processing $($newFiles.Count) file(s)" -ForegroundColor Yellow
            $filesToProcess = $newFiles
        }
        
        $newFilesProcessed = 0
        $skippedFiles = 0
        
        foreach ($file in $filesToProcess) {
            $filePath = $file.FullName
            $fileSizeMB = [math]::Round($file.Length / 1MB, 2)
            
            Write-Host "Processing file $($newFilesProcessed + 1)/$($filesToProcess.Count): $($file.Name) ($fileSizeMB MB)" -ForegroundColor Green
            
            # Decompress the file with size limit
            $decompressedFile = Decompress-GzipFile -SourcePath $filePath -TargetDirectory $TargetDir -MaxSizeMB $FileSizeLimitMB
            
            if ($decompressedFile) {
                # Mark as processed
                Add-ProcessedFile -FilePath $filePath -ListFile $ProcessedListFile
                $newFilesProcessed++
                
                # Output info as JSON
                $info = @{
                    action = "decompressed"
                    source_file = $filePath
                    target_file = $decompressedFile
                    timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
                    file_size_mb = $fileSizeMB
                    processing_type = if ($isRestrictedPath) { "initial_one_time" } else { "normal" }
                }
                $info | ConvertTo-Json -Compress
                
                # Sleep between files to prevent resource exhaustion
                if ($SleepBetweenFiles -gt 0) {
                    Start-Sleep -Seconds $SleepBetweenFiles
                }
            } else {
                $skippedFiles++
                # Still mark as processed to avoid retrying large/broken files
                Add-ProcessedFile -FilePath $filePath -ListFile $ProcessedListFile
            }
        }
        
        Write-Host "Processing complete: $newFilesProcessed processed, $skippedFiles skipped" -ForegroundColor Green
        
        # NEW: If this is restricted path and we processed files, mark as complete
        if ($isRestrictedPath) {
            Set-InitialProcessingComplete -MarkerFile $CompletionMarkerFile
            Write-Host "Initial gzip processing completed - future runs will skip gzip processing" -ForegroundColor Green
        }
    }
    
    # Clean up files that have been fully ingested by FluentBit
    if (-not $DisableCleanup) {
        Write-Host "Checking FluentBit database for fully ingested files..." -ForegroundColor Cyan
        Cleanup-TrackedDecompressedFiles -TargetDirectory $TargetDir -DBPath $FluentBitDBPath -Sqlite3Path $Sqlite3Path
    }
    
    Write-Host "=== Script execution completed ===" -ForegroundColor Cyan
    
}
catch {
    Write-Error "Script execution failed: $($_.Exception.Message)"
    Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
}