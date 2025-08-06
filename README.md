# Setting up FluentBit

We have created a script which you would need to call just once to correctly setup FluentBit for log pipelining.

To use the script, just run:

```ps
.\Deploy-FluentBit.ps1 `
     -CtrlBHost "10.91.27.4" `
     -CtrlBPort "5080" `
     -CtrlBAuthHeader "Authorization Basic <key>" `
     -LogPaths @("C:\ProgramData\GuestConfig", "D:\c-base\logs") `
     -GzipPaths @("C:\ProgramData\GuestConfig", "D:\c-base\logs") `
     -MaxDirectoryDepth 4 `
     -MaxGzipFilesPerRun 4 `
     -MaxGzipBatchSizeMB 300 `
     -GzipSleepBetweenFiles 3 `
     -DeepClean `
     -CleanInstall `
     -FluentBitLogLevel "info"
```

The key points to note here are:
- `-LogPaths` accept an array of directories within which `.log` files will be tracked.
- `GzipPaths` accept an array of directories within which `.gz` files will be tracked.
- `MaxDirectoryDepth` indicates the max depth FluentBit will go recursively into to search for the `.log` and `.gz` files.

Do note this FluentBit is going to be deployed as a Windows Service, running in the background. To check its status, go to `localhost:2020/api/v1/metrics`.  
Logs of FluentBit can be found using this command: `Get-Content "C:\temp\logs\fluent-bit.log" -Tail 20 -Wait `.

Also, this FluentBit service will track SQL Server logs from the default location. It will only track the `ERRORLOG` file contents.

The deploy script is now idempotent as long as you use the `-DeepClean` and `-CleanInstall` flags.

## Possible Issues and Fixes

- Remember to run Powershell in Administrator mode.
- Powershell does not allow running of scripts by default. You might need to do:

```ps
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

and then Yes to All [A] to be able to run scripts.

To track the logs of FluentBit:

```ps
& 'C:\temp\logs\monitor-fluent-bit.ps1'
```
