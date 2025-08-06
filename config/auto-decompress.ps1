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
    [int]$MaxFilesPerRun = 5,
    
    [Parameter(Mandatory=$false)]
    [int]$FileSizeLimitMB = 100,
    
    [Parameter(Mandatory=$false)]
    [int]$SleepBetweenFiles = 1,
    
    [Parameter(Mandatory=$false)]
    [switch]$DisableCleanup
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
    Write-Host "=== Gzip Decompression Script Started ===" -ForegroundColor Cyan
    Write-Host "Max files per run: $MaxFilesPerRun" -ForegroundColor Gray
    Write-Host "File size limit: $FileSizeLimitMB MB" -ForegroundColor Gray
    Write-Host "Sleep between files: $SleepBetweenFiles seconds" -ForegroundColor Gray
    
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
    } else {
        # Limit the number of files processed per run
        $filesToProcess = $newFiles | Select-Object -First $MaxFilesPerRun
        Write-Host "Processing $($filesToProcess.Count) file(s) this run (limited by MaxFilesPerRun)" -ForegroundColor Yellow
        
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
        
        $remainingFiles = $newFiles.Count - $filesToProcess.Count
        if ($remainingFiles -gt 0) {
            Write-Host "Remaining files to process in future runs: $remainingFiles" -ForegroundColor Yellow
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