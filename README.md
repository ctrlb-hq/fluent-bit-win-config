# Setting up FluentBit for log files tracking

Welcome to our guide for setting up FluentBit for tracking log files. We have built parsers for FluentBit specific to the logs shared previously. Correctly setting up FluentBit is very simple, a short walkthrough is mentioned below:

1. Install FluentBit

```ps
> Invoke-WebRequest -Uri https://packages.fluentbit.io/windows/fluent-bit-4.0.4-win64.exe -OutFile fluent-bit-installer.exe

> Start-Process -FilePath fluent-bit-installer.exe -ArgumentList "/S" -Wait

# Test if installed successfully
> Test-Path "C:\Program Files\fluent-bit\bin\fluent-bit.exe"
```

2. Copy over contents of `config\` to `C:\Program Files\fluent-bit\config\` directory (create if not exists).

3. (Optional) Create empty directory `C:\temp\flb-storage` (FluentBit handles this implicitly, but we like to be verbose).

4. Change the entries in `C:\Program Files\fluent-bit\config\fluent-bit-onbe-staging.conf` as per your local paths:
* Within `[INPUT]`, modify the `Path` value to track the correct log files.
* Within `[OUTPUT]`, modify the `Host` and `Port` to point to the correct endpoint where CtrlB will ingest the JSON logs.

5. Run Fluent Bit:

```ps
> & "C:\Program Files\fluent-bit\bin\fluent-bit.exe" -c "C:\Program Files\fluent-bit\config\fluent-bit-onbe-staging.conf"
```

The output should be a bunch of `info` level logs, ending with:

```ps
[ info] [http_server] listen iface=0.0.0.0 tcp_port=2020
[ info] [sp] stream processor started
[ info] [engine] Shutdown Grace Period=5, Shutdown Input Grace Period=2
```

### Additional Notes

* FluentBit is configured in such a way that it would not re-read files once read. In fact, if FluentBit goes down for a while, it will resume reading from the last positions in the files it left off.

* We try to extract some basic fields from the log body, specifically the timestamp mentioned there (smapped to field `onbe_timestamp`), and the log level (mapped to field `level`). In case parsing fails, we store the entire log entry as a string.
