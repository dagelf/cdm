param (
    [string]$BaselineFile = "baseline.json",
    [string]$Size = "512m"
)

$OutputFile = "output.json"
$HistoryFile = "cdm_history.log"
$FioFile = "cdm.fio"

# Cleanup Function
function Remove-TempFiles {
    Remove-Item "temp_run_*.json" -ErrorAction SilentlyContinue
}

try {
    # Ensure output.json exists
    if (-not (Test-Path $OutputFile)) {
        "{}" | Out-File $OutputFile -Encoding ascii
    }

    # Parse Tests from cdm.fio
    if (-not (Test-Path $FioFile)) {
        Write-Error "Fio file $FioFile not found."
        exit 1
    }

    # Robust regex: Handles optional whitespace around brackets and inside
    $Tests = Select-String -Path $FioFile -Pattern "^\s*\[.*\]" | ForEach-Object { 
        $_.Line -replace "^\s*\[\s*", "" -replace "\s*\]\s*$", "" 
    } | Where-Object { $_ -notmatch "^(global|x)$" }

    Write-Host "Tests found in $FioFile :"
    $Tests
    Write-Host "--------------------------------"

    # Header for history
    Add-Content -Path $HistoryFile -Value "`n--- Run Date: $(Get-Date) ---"

    # Load existing results
    try {
        $OutputContent = Get-Content $OutputFile -Raw
        if ([string]::IsNullOrWhiteSpace($OutputContent)) {
            $OutputJson = @{ jobs = @() }
        } else {
            $OutputJson = $OutputContent | ConvertFrom-Json
            if (-not $OutputJson.jobs) { 
                $OutputJson = @{ jobs = @() } 
            }
        }
    } catch {
        $OutputJson = @{ jobs = @() }
    }

    # Run missing tests
    foreach ($TestName in $Tests) {
        $Exists = $false
        if ($OutputJson.jobs) {
            $Match = $OutputJson.jobs | Where-Object { $_.jobname -eq $TestName }
            if ($Match) { $Exists = $true }
        }

        if (-not $Exists) {
#            Write-Host "Running missing test: $TestName with size $Size"
            $TempFile = "temp_run_${TestName}.json"
            
            # Run FIO with --quiet
            & fio --section="$TestName" --size="$Size" --quiet --output-format=json --output="$TempFile" "$FioFile"
            
            if ($LASTEXITCODE -eq 0 -and (Test-Path $TempFile)) {
                $TempContent = Get-Content $TempFile -Raw
                if (-not [string]::IsNullOrWhiteSpace($TempContent)) {
                    # Handle potential garbage before JSON (fio oddities)
                    $JsonStart = $TempContent.IndexOf('{')
                    if ($JsonStart -ge 0) {
                        $TempContent = $TempContent.Substring($JsonStart)
                        try {
                            $TempJson = $TempContent | ConvertFrom-Json
                            
                            # Append to jobs. 
                            if (-not ($OutputJson.jobs -is [Array])) { $OutputJson.jobs = @($OutputJson.jobs) }
                            if ($OutputJson.jobs -eq $null) { $OutputJson.jobs = @() }
                            
                            $OutputJson.jobs += $TempJson.jobs
                            
                            # Save immediately
                            $OutputJson | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding ascii
                            
                            # Log formatted stats to history (mimicking jq output logic roughly or just simplified)
                            # For simplicity in PS, we can just skip the complex logging here or replicate the formatting logic
                            # The current script didn't log to history inside the loop, let's fix that to match cdm.sh behavior
                            
                            $Job = $TempJson.jobs[0]
                            $RBW = $Job.read.bw / 1024
                            $WBW = $Job.write.bw / 1024
                            $RIOPS = $Job.read.iops
                            $WIOPS = $Job.write.iops
                            $RLat = $Job.read.lat_ns.mean / 1000
                            $WLat = $Job.write.lat_ns.mean / 1000
                            
                            function Fmt-Val-Simple($v) {
                                if ($null -eq $v) { return "            N/A" }
                                return "{0,15}" -f [Math]::Round($v)
                            }
                            
                            $StatsLine = "{0,-25}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $TestName, (Fmt-Val-Simple $RBW), (Fmt-Val-Simple $WBW), (Fmt-Val-Simple $RIOPS), (Fmt-Val-Simple $WIOPS), (Fmt-Val-Simple $RLat), (Fmt-Val-Simple $WLat)
                            Write-Host $StatsLine
                            Add-Content -Path $HistoryFile -Value $StatsLine

                        } catch {
                            Write-Error "Failed to parse JSON for $TestName"
                        }
                    }
                }
                Remove-Item $TempFile -ErrorAction SilentlyContinue
            } else {
                Write-Error "Error running fio for $TestName"
                Remove-Item $TempFile -ErrorAction SilentlyContinue
            }
        } else {
            Write-Host "Test $TestName already exists. Skipping."
        }
    }

    Write-Host "--------------------------------"

    # Load Baseline
    if (Test-Path $BaselineFile) {
        try {
            $BaseJson = Get-Content $BaselineFile -Raw | ConvertFrom-Json
        } catch {
            $BaseJson = @{ jobs = @() }
        }
    } else {
        $BaseJson = @{ jobs = @() }
    }

    # Group jobs by Base Name (removing -Read/-Write)
    if ($OutputJson.jobs) {
        # Ensure jobs is an array
        $JobsArray = @($OutputJson.jobs)
        
        # Custom grouping
        $Groups = [Ordered]@{}
        foreach ($j in $JobsArray) {
            $BaseName = $j.jobname -replace "-(Read|Write)$", ""
            if (-not $Groups.Contains($BaseName)) { $Groups[$BaseName] = @() }
            $Groups[$BaseName] += $j
        }

        # Formatting Helpers
        function Fmt-Val($v) {
            if ($null -eq $v) { return "            N/A" } # 15 chars
            $val = [Math]::Round($v)
            return "{0,15}" -f $val
        }

        function Fmt-Diff($curr, $base) {
            if ($curr -and $base -and $base -gt 0) {
                $d = [Math]::Round( (($curr - $base) / $base * 100) )
                $s = if ($d -ge 0) { "+" } else { "" }
                return "$s$d%"
            }
            return "-"
        }

        # Print Header
        $Header = "{0,-25}`t{1,15}`t{2,15}`t{3,15}`t{4,15}`t{5,15}`t{6,15}`t{7,15}`t{8,15}`t{9,15}" -f "Test Name", "Read MB/s", "Write MB/s", "Read IOPS", "Write IOPS", "Read Lat (us)", "Write Lat (us)", "MB/s Diff", "IOPS Diff", "Lat Diff"
        Write-Host $Header

        # Iterate Groups
        foreach ($BaseName in $Groups.Keys) {
            $GroupJobs = $Groups[$BaseName]
            $RJob = $GroupJobs | Where-Object { $_.jobname -match "-Read$" } | Select-Object -First 1
            $WJob = $GroupJobs | Where-Object { $_.jobname -match "-Write$" } | Select-Object -First 1
            
            # Find Baseline Jobs
            $BRJob = if ($BaseJson.jobs) { $BaseJson.jobs | Where-Object { $_.jobname -eq "$BaseName-Read" } | Select-Object -First 1 } else { $null }
            $BWJob = if ($BaseJson.jobs) { $BaseJson.jobs | Where-Object { $_.jobname -eq "$BaseName-Write" } | Select-Object -First 1 } else { $null }
            
            # Extract Metrics
            $RBW = if ($RJob) { $RJob.read.bw / 1024 } else { $null }
            $WBW = if ($WJob) { $WJob.write.bw / 1024 } else { $null }
            $RIOPS = if ($RJob) { $RJob.read.iops } else { $null }
            $WIOPS = if ($WJob) { $WJob.write.iops } else { $null }
            $RLat = if ($RJob) { $RJob.read.lat_ns.mean / 1000 } else { $null }
            $WLat = if ($WJob) { $WJob.write.lat_ns.mean / 1000 } else { $null }
            
            # Baseline Metrics
            $BRBW = if ($BRJob) { $BRJob.read.bw / 1024 } else { $null }
            $BWBW = if ($BWJob) { $BWJob.write.bw / 1024 } else { $null }
            $BRIOPS = if ($BRJob) { $BRJob.read.iops } else { $null }
            $BWIOPS = if ($BWJob) { $BWJob.write.iops } else { $null }
            $BRLat = if ($BRJob) { $BRJob.read.lat_ns.mean / 1000 } else { $null }
            $BWLat = if ($BWJob) { $BWJob.write.lat_ns.mean / 1000 } else { $null }
            
            # Format Diff Strings "R% / W%"
            $D_BW = "$(Fmt-Diff $RBW $BRBW) / $(Fmt-Diff $WBW $BWBW)"
            $D_IOPS = "$(Fmt-Diff $RIOPS $BRIOPS) / $(Fmt-Diff $WIOPS $BWIOPS)"
            $D_Lat = "$(Fmt-Diff $RLat $BRLat) / $(Fmt-Diff $WLat $BWLat)"
            
            # Output Line
            $Line = "{0,-25}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7,15}`t{8,15}`t{9,15}" -f $BaseName, (Fmt-Val $RBW), (Fmt-Val $WBW), (Fmt-Val $RIOPS), (Fmt-Val $WIOPS), (Fmt-Val $RLat), (Fmt-Val $WLat), $D_BW, $D_IOPS, $D_Lat
            Write-Host $Line
        }
    }
} finally {
    Remove-TempFiles
}
