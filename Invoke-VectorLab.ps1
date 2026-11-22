[CmdletBinding()]
param([ValidateSet('Core','Regression')][string]$Phase = 'Core')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ARCH -ne 'X64' -or -not $env:GITHUB_RUN_ID) {
    throw 'This build requires the GitHub Actions Windows x64 runner'
}

$root = Join-Path $env:RUNNER_TEMP 'edb18-vector-build'
$src = "$root\upstream"
$pg = "$root\edb\pgsql"
$regressExe = "$pg\lib\pgxs\src\test\regress\pg_regress.exe"
$evidence = if ($Phase -eq 'Core') { "$root\evidence" } else { "$root\regression-evidence" }
$secretDir = "$root\credentials-$Phase"
$upload = "$root\upload"
if ($Phase -eq 'Core' -and (Test-Path -LiteralPath $root)) { throw 'Runner workspace must be fresh' }
if ($Phase -eq 'Regression' -and (-not (Test-Path -LiteralPath "$upload\build-manifest.json" -PathType Leaf) -or
        (Test-Path -LiteralPath $evidence))) { throw 'Regression requires a completed core phase and fresh evidence directory' }
[void][IO.Directory]::CreateDirectory($evidence)
$log = if ($Phase -eq 'Core') { "$evidence\build-and-test.log" } else { "$evidence\regression.log" }
$name = 'postgresql-18.7-1-windows-x64-binaries.zip'
$url = "https://get.enterprisedb.com/postgresql/$name"
$expected = 'ead0bbc27fb678fa24dcf86b738981323042abd073c744103bf7f3aed23f9a33'
$commit = 'f37c13f68b57d2c3472b2214fbcff699d6d34876'
$bundle = 'pgvector-0.8.7-edb18.7-win-x64'
$role = 'vector_lab_admin'
$port = 55432
$db = 'vector_lab'
$conn = @('-w','-h','127.0.0.1','-p',"$port",'-U',$role)

function Note([string]$Message) {
    $Message | Tee-Object -FilePath $log -Append | Write-Host
}

function Run {
    param([string]$Exe, [string[]]$Argv)
    Note "> $Exe $($Argv -join ' ')"
    $lines = @(& $Exe @Argv 2>&1)
    $code = $LASTEXITCODE
    foreach ($line in $lines) { Note "$line" }
    Note "exit=$code"
    if ($code -ne 0) { throw "$Exe exited $code" }
    return $lines
}

function Hash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-X64([string]$Path) {
    $file = [IO.File]::OpenRead($Path)
    try {
        $r = [IO.BinaryReader]::new($file)
        if ($r.ReadUInt16() -ne 0x5a4d) { throw "Missing MZ header: $Path" }
        $file.Position = 0x3c
        $file.Position = $r.ReadInt32()
        if ($r.ReadUInt32() -ne 0x4550 -or $r.ReadUInt16() -ne 0x8664) { throw "Not x64 PE: $Path" }
    } finally { $file.Dispose() }
}

function Build-Extension {
    $curl = "$env:SystemRoot\System32\curl.exe"
    $transfer = @('-q','--proto','=https','--proto-redir','=https','-fsSL','--connect-timeout','30','--retry','2')
    $null = Run $curl ($transfer + @('--max-time','60','-o',"$evidence\$name.sha256","$url.sha256"))
    $official = (Get-Content -Raw -LiteralPath "$evidence\$name.sha256").Trim()
    if ($official -cnotmatch '^([a-z0-9]{64})\s+\*?(.+)$' -or $Matches[1] -cne $expected -or $Matches[2] -cne $name) {
        throw 'Fresh EDB sidecar mismatch'
    }
    $archive = "$root\$name"
    $null = Run $curl ($transfer + @('--max-time','900','-o',$archive,$url))
    if ((Get-Item -LiteralPath $archive).Length -ne 389515503 -or (Hash $archive) -cne $expected) {
        throw 'EDB ZIP size or SHA-256 mismatch'
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $match = @($zip.Entries | Where-Object FullName -cmatch '^(?:[^/]+/)*bin/postgres\.exe$')
        if ($match.Count -ne 1 -or $match[0].FullName -cne 'pgsql/bin/postgres.exe') {
            throw 'Unexpected layout in the pinned EDB archive'
        }
        $prefix = $match[0].FullName -creplace 'bin/postgres\.exe$',''
    } finally { $zip.Dispose() }
    $dest = "$root\edb"
    [void][IO.Directory]::CreateDirectory($dest)
    $tree = @('bin','lib','share','include') | ForEach-Object { $prefix + $_ }
    $null = Run "$env:SystemRoot\System32\tar.exe" (@('-xf',$archive,'-C',$dest) + $tree)
    $keyFiles = @('bin/postgres.exe','bin/pg_config.exe','bin/initdb.exe','bin/pg_ctl.exe',
        'lib/postgres.lib','include/server/postgres.h','include/server/pg_config.h')
    if (Test-Path -LiteralPath $regressExe -PathType Leaf) { $keyFiles += 'lib/pgxs/src/test/regress/pg_regress.exe' }
    if (-not (Test-Path -LiteralPath "$pg\share\extension" -PathType Container)) { throw 'EDB extension directory missing' }
    foreach ($f in $keyFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $pg $f) -PathType Leaf)) { throw "EDB file missing: $f" }
        if ($f.EndsWith('.exe')) { Assert-X64 (Join-Path $pg $f) }
    }
    $version = @(Run "$pg\bin\postgres.exe" @('--version'))
    $pgConfig = @(Run "$pg\bin\pg_config.exe" @('--version'))
    if (($version -join '') -cne 'postgres (PostgreSQL) 18.7' -or ($pgConfig -join '') -cne 'PostgreSQL 18.7') {
        throw 'Wrong EDB version'
    }
    $headers = @(Get-ChildItem -LiteralPath "$pg\include\server" -Recurse -File | ForEach-Object {
        [IO.Path]::GetRelativePath($pg,$_.FullName).Replace('\','/')
    })
    $baseline = foreach ($f in (($keyFiles+$headers) | Sort-Object -Unique)) {
        [pscustomobject]@{Path=$f; SHA256=(Hash (Join-Path $pg $f))}
    }
    $baseline | Export-Csv -NoTypeInformation -LiteralPath "$evidence\edb-files.csv" -Encoding utf8
    Note "Verified EDB $expected with $($baseline.Count) hashed baseline files"

    $x86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $vswhere = "$x86\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsJson = @(Run $vswhere @('-products','*','-version','[17.0,18.0)','-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-latest','-format','json'))
    $vs = @(($vsJson -join [Environment]::NewLine) | ConvertFrom-Json)
    if ($vs.Count -ne 1 -or -not $vs[0].installationPath) { throw 'VS 2022 C++ x64 required' }
    $batch = Join-Path $vs[0].installationPath 'VC\Auxiliary\Build\vcvars64.bat'
    $vars = @(& $env:ComSpec /d /c ('call "{0}" >nul && set' -f $batch))
    if ($LASTEXITCODE -ne 0) { throw 'vcvars64 failed' }
    foreach ($line in $vars) {
        if ($line -match '^(Path|INCLUDE|LIB|LIBPATH|WindowsSDKVersion|WindowsSdkDir|UniversalCRTSdkDir|UCRTVersion|VCINSTALLDIR|VCToolsInstallDir|VCToolsVersion|VisualStudioVersion|VSCMD_ARG_TGT_ARCH|VSCMD_ARG_HOST_ARCH)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')
        }
    }
    if ($env:VSCMD_ARG_TGT_ARCH -ne 'x64' -or -not $env:WindowsSDKVersion) { throw 'Wrong MSVC target or SDK' }
    $cl = (Get-Command cl.exe -CommandType Application -TotalCount 1).Source
    $nmake = (Get-Command nmake.exe -CommandType Application -TotalCount 1).Source
    $dumpbin = (Get-Command dumpbin.exe -CommandType Application -TotalCount 1).Source
    $probe = "$root\probe.c"
    Set-Content -LiteralPath $probe -Value 'int main(void) { return 0; }' -Encoding ascii
    $compilerBanner = @(Run $cl @('/nologo','/Bv','/c',$probe,"/Fo$root\probe.obj"))
    $null = Run $nmake @('/?')
    $toolchain = [ordered]@{
        VSInstallationVersion=$vs[0].installationVersion; VSProduct=$vs[0].displayName
        MSVC=(Get-Item -LiteralPath $cl).VersionInfo.FileVersion; VCTools=$env:VCToolsVersion
        WindowsSDK=$env:WindowsSDKVersion.TrimEnd('\'); NMake=(Get-Item -LiteralPath $nmake).VersionInfo.FileVersion
        Target=$env:VSCMD_ARG_TGT_ARCH; CompilerBanner=@($compilerBanner | ForEach-Object { [string]$_ })
    }
    $toolchain | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$evidence\toolchain.json" -Encoding utf8
    $libHeaders = @(& $dumpbin /headers "$pg\lib\postgres.lib" | Select-String -Pattern '(?i)8664|machine.*(x86|ARM64)' | ForEach-Object Line | Sort-Object -Unique)
    if ($LASTEXITCODE -ne 0 -or -not ($libHeaders -match '(?i)8664') -or ($libHeaders -match '(?i)machine.*\((x86|ARM64)\)')) {
        throw 'EDB postgres.lib does not match x64'
    }
    $libHeaders | Set-Content -LiteralPath "$evidence\postgres-lib-architecture.txt" -Encoding utf8

    [void][IO.Directory]::CreateDirectory($src)
    $git = (Get-Command git.exe -CommandType Application -TotalCount 1).Source
    $env:GIT_TERMINAL_PROMPT = '0'
    $null = Run $git @('-C',$src,'init')
    $null = Run $git @('-C',$src,'-c','credential.helper=','fetch','--no-tags','--depth=1',
        'https://github.com/pgvector/pgvector.git',$commit)
    $null = Run $git @('-C',$src,'checkout','--detach','FETCH_HEAD')
    $head = @(Run $git @('-C',$src,'rev-parse','HEAD'))
    $dirty = @(Run $git @('-C',$src,'status','--porcelain'))
    if (($head -join '') -cne $commit -or $dirty.Count -or
        -not (Select-String -LiteralPath "$src\Makefile.win" -Pattern '^EXTVERSION\s*=\s*0\.8\.7\s*$') -or
        -not (Select-String -LiteralPath "$src\vector.control" -Pattern "^default_version\s*=\s*'0\.8\.7'\s*$")) {
        throw 'Pinned source or version verification failed'
    }
    $env:PGROOT = $pg
    Push-Location -LiteralPath $src
    try {
        $null = Run $nmake @('/NOLOGO','/F','Makefile.win')
        foreach ($f in @('vector.dll','vector.lib','vector.exp','sql\vector--0.8.7.sql')) {
            if (-not (Test-Path -LiteralPath "$src\$f" -PathType Leaf)) { throw "Missing output: $f" }
        }
        Assert-X64 "$src\vector.dll"
        $null = Run $nmake @('/NOLOGO','/F','Makefile.win','install')
    } finally { Pop-Location }
    if ((Hash "$src\vector.dll") -cne (Hash "$pg\lib\vector.dll")) { throw 'Installed DLL differs from build' }
    $null = Run $dumpbin @('/dependents',"$pg\lib\vector.dll")
    return $toolchain
}

function Initialize-LabEnvironment {
    [void][IO.Directory]::CreateDirectory($secretDir)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $acl = Get-Acl -LiteralPath $secretDir
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $identity.User,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $secretDir -AclObject $acl
    Get-ChildItem Env: | Where-Object Name -match '^PG' | ForEach-Object { Remove-Item -LiteralPath "Env:$($_.Name)" }
    $env:PGROOT = $pg
    $env:PGHOST = '127.0.0.1'
    $env:PGPORT = "$port"
    $env:PGUSER = $role
    $env:PGCONNECT_TIMEOUT = '6'
    $env:PGCLIENTENCODING = 'UTF8'
    $env:PGSYSCONFDIR = $secretDir
    $initial = @(Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq $port)
    if ($initial.Count) { throw "Port $port already occupied" }
}

function Lab-Pid([string]$Label) {
    $dir = "$root\$Label"
    $pidFile = "$dir\postmaster.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) { return }
    $lines = @(Get-Content -LiteralPath $pidFile -TotalCount 2)
    if ($lines.Count -ne 2 -or [IO.Path]::GetFullPath($lines[1]) -ine $dir) { throw 'Unexpected postmaster data directory' }
    $serverId = [int]$lines[0]
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$serverId"
    if (-not $p -or $p.ExecutablePath -ine "$pg\bin\postgres.exe" -or
        ($p.CommandLine -replace '/', '\') -notlike "*$dir*") { throw "Unverified lab PID $serverId" }
    return $serverId
}

function Start-Lab([string]$Label, [switch]$Existing) {
    $dir = "$root\$Label"
    $env:PGPASSFILE = "$secretDir\$Label.pgpass"
    if (-not $Existing) {
        $pass = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
        $pwfile = "$secretDir\$Label.init"
        [IO.File]::WriteAllText($pwfile,$pass+[Environment]::NewLine,[Text.Encoding]::ASCII)
        [IO.File]::WriteAllText($env:PGPASSFILE,('127.0.0.1:{0}:*:{1}:{2}' -f $port,$role,$pass)+[Environment]::NewLine,[Text.Encoding]::ASCII)
        try {
            $null = Run "$pg\bin\initdb.exe" @('-D',$dir,'--locale=C','--encoding=UTF8','--auth=scram-sha-256',"--username=$role","--pwfile=$pwfile",'--no-instructions')
        } finally { Remove-Item -LiteralPath $pwfile }
        @("listen_addresses = '127.0.0.1'","port = $port","unix_socket_directories = ''",
            "password_encryption = 'scram-sha-256'","timezone = 'UTC'","log_statement = 'none'") |
            Add-Content -LiteralPath "$dir\postgresql.conf" -Encoding ascii
        'host all all 127.0.0.1/32 scram-sha-256' | Set-Content -LiteralPath "$dir\pg_hba.conf" -Encoding ascii
    }
    if (Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq $port) { throw "Port $port occupied" }
    $argv = @('start','-w','-t','60','-D',('"{0}"' -f $dir),'-l',('"{0}"' -f "$evidence\postgres-$Label.log"),
        '-o',('"-c listen_addresses=127.0.0.1 -p {0}"' -f $port))
    Note "> pg_ctl $($argv -join ' ')"
    $out = "$root\pgctl-$Label.out"
    $err = "$root\pgctl-$Label.err"
    $p = Start-Process -FilePath "$pg\bin\pg_ctl.exe" -ArgumentList $argv -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if (-not $p.WaitForExit(65000)) { throw 'pg_ctl start timed out' }
    Get-Content -LiteralPath $out,$err | ForEach-Object { Note $_ }
    if ($p.ExitCode -ne 0) { throw "pg_ctl exit=$($p.ExitCode)" }
    $id = Lab-Pid $Label
    $socket = @(Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq $port)
    if (-not $id -or $socket.Count -ne 1 -or $socket[0].LocalAddress -ne '127.0.0.1' -or $socket[0].OwningProcess -ne $id) {
        throw 'Unexpected listening socket'
    }
    $settings = @(Run "$pg\bin\psql.exe" ($conn + @('-X','-A','-t','-d','postgres','-c',
        "SELECT current_setting('data_directory'), inet_server_addr(), inet_server_port(), current_setting('password_encryption');")))
    $fields = ($settings -join '') -split '\|'
    if ($fields.Count -ne 4 -or [IO.Path]::GetFullPath($fields[0]) -ine $dir -or
        $fields[1] -ne '127.0.0.1' -or $fields[2] -ne "$port" -or $fields[3] -ne 'scram-sha-256') {
        throw 'Server identity or authentication does not match'
    }
    Note "Verified isolated socket 127.0.0.1 port $port PID $id ($Label)"
}

function Stop-Lab([string]$Label) {
    $id = Lab-Pid $Label
    if (-not $id) { return }
    $null = Run "$pg\bin\pg_ctl.exe" @('stop','-w','-t','60','-m','fast','-D',"$root\$Label")
    if ((Get-Process -Id $id -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath "$root\$Label\postmaster.pid")) {
        throw 'PostgreSQL did not stop'
    }
}

function Test-Vectors([bool]$Seed, [string]$Stage) {
    $sql = Join-Path $PSScriptRoot 'vector-test.sql'
    $out = @(Run "$pg\bin\psql.exe" ($conn + @('-X','-A','-t','-q','-v','ON_ERROR_STOP=1',
        '-v',('seed='+$Seed.ToString().ToLowerInvariant()),'-d',$db,'-f',$sql)))
    $rows = @($out | Where-Object { $_ -is [string] -and $_.StartsWith('RESULT|') })
    if ($rows.Count -lt 10 -or @($rows -match '^RESULT\|recall\|.*\|10/10\|').Count -ne 3) {
        throw "Incomplete assertions for $Stage"
    }
    $rows | Set-Content -LiteralPath "$evidence\$Stage.txt" -Encoding utf8
    return ($rows -join [Environment]::NewLine)
}

function Invoke-RegressionCase([string]$Case, [int]$TimeoutSeconds) {
    $work = "$root\regression-work\$Case"
    $logs = "$evidence\$Case"
    [void][IO.Directory]::CreateDirectory($work)
    [void][IO.Directory]::CreateDirectory($logs)
    $argv = @("--bindir=$pg\bin", "--inputdir=$src\test", '--outputdir=.',
        '--host=127.0.0.1', "--port=$port", "--user=$role", "--dbname=reg_$Case",
        '--load-extension=vector', $Case)
    Note "START $Case (${TimeoutSeconds}s limit)"
    Note "> $regressExe $($argv -join ' ')"

    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $regressExe
    $process.StartInfo.WorkingDirectory = $work
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    foreach ($arg in $argv) { $process.StartInfo.ArgumentList.Add($arg) }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = $null
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Could not start pg_regress' }
        $process.StandardInput.Close()
        $streams = @($process.StandardOutput, $process.StandardError)
        $names = @('stdout', 'stderr')
        $pending = @($streams[0].ReadLineAsync(), $streams[1].ReadLineAsync())
        do {
            for ($i = 0; $i -lt $streams.Count; $i++) {
                while ($null -ne $pending[$i] -and $pending[$i].IsCompleted) {
                    $line = $pending[$i].GetAwaiter().GetResult()
                    if ($null -eq $line) {
                        $pending[$i] = $null
                        break
                    }
                    Add-Content -LiteralPath "$logs\$($names[$i]).log" -Value $line -Encoding utf8
                    Write-Host "[$Case/$($names[$i])] $line"
                    $pending[$i] = $streams[$i].ReadLineAsync()
                }
            }
            if ($process.HasExited -and $null -eq $pending[0] -and $null -eq $pending[1]) { break }
            if (-not $timedOut -and $clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                Note "Deadline reached for $Case. Stopping its process tree."
                if (-not $process.HasExited) { $process.Kill($true) }
            }
            Start-Sleep -Milliseconds 50
        } while ($clock.Elapsed.TotalSeconds -lt ($TimeoutSeconds + 5))
        if ($process.HasExited) { $exitCode = $process.ExitCode }
    } catch {
        Note "Harness error for ${Case}: $($_.Exception.Message)"
    } finally {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill($true)
                if (-not $process.WaitForExit(5000)) { throw "Could not stop pg_regress for $Case" }
            }
        } finally { $process.Dispose() }
    }

    foreach ($relative in @('regression.out', 'regression.diffs', "results\$Case.out")) {
        $file = Join-Path $work $relative
        if (Test-Path -LiteralPath $file -PathType Leaf) { Copy-Item -LiteralPath $file -Destination $logs }
    }
    $status = 'FAIL'
    if ($timedOut) { $status = 'TIMEOUT' }
    elseif ($exitCode -eq 0 -and (Test-Path -LiteralPath "$logs\regression.out" -PathType Leaf) -and
        (Test-Path -LiteralPath "$logs\$Case.out" -PathType Leaf) -and
        (Select-String -LiteralPath "$logs\regression.out" -Pattern '^ok\s+1\s')) { $status = 'PASS' }
    $seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2)
    Note "END $Case status=$status seconds=$seconds exit=$exitCode"
    [pscustomobject]@{ Case=$Case; Status=$status; Seconds=$seconds; ExitCode=$exitCode }
}

function Invoke-UpstreamRegression {
    $cases = @('bit','btree','cast','copy','halfvec','hnsw_bit','hnsw_halfvec','hnsw_sparsevec','hnsw_vector',
        'ivfflat_bit','ivfflat_halfvec','ivfflat_vector','sparsevec','vector_type')
    $table = @($cases | ForEach-Object { [pscustomobject]@{ Case=$_; Status='NOT RUN'; Seconds=$null; ExitCode=$null } })
    $resultsPath = "$evidence\results.csv"
    $table | Export-Csv -NoTypeInformation -LiteralPath $resultsPath -Encoding utf8
    $priorPath = $env:Path
    try {
        Note 'Running the pinned upstream Windows regression list, one fresh database per case.'
        $manifest = Get-Content -Raw -LiteralPath "$upload\build-manifest.json" | ConvertFrom-Json
        $dll = @($manifest.files | Where-Object Path -CEQ 'lib/vector.dll')
        if ($manifest.coreTests -cne 'PASS' -or $manifest.workflowRunId -cne $env:GITHUB_RUN_ID -or
            $manifest.workflowCommit -cne $env:GITHUB_SHA -or $dll.Count -ne 1 -or
            (Hash "$pg\lib\vector.dll") -cne $dll[0].SHA256) { throw 'Core build identity mismatch' }
        Assert-X64 $regressExe
        $git = (Get-Command git.exe -CommandType Application -TotalCount 1).Source
        $diffDir = Join-Path (Split-Path -Parent (Split-Path -Parent $git)) 'usr\bin'
        if (-not (Test-Path -LiteralPath "$diffDir\diff.exe" -PathType Leaf)) { throw 'Git for Windows diff.exe missing' }
        $env:Path = "$pg\bin;$diffDir;$priorPath"
        $head = @(Run $git @('-C',$src,'rev-parse','HEAD'))
        $schedule = Select-String -LiteralPath "$src\Makefile.win" -Pattern '^REGRESS\s*=\s*(.+)$'
        if (($head -join '') -cne $commit -or $schedule.Matches[0].Groups[1].Value.Trim() -cne ($cases -join ' ')) {
            throw 'Pinned upstream regression list does not match'
        }

        Initialize-LabEnvironment
        Start-Lab 'regression'
        for ($i = 0; $i -lt $cases.Count; $i++) {
            $table[$i] = Invoke-RegressionCase $cases[$i] 45
            $table | Export-Csv -NoTypeInformation -LiteralPath $resultsPath -Encoding utf8
        }
    } finally {
        try { Stop-Lab 'regression' }
        finally {
            $env:Path = $priorPath
            $passed = @($table | Where-Object Status -EQ 'PASS').Count
            $failed = @($table | Where-Object Status -EQ 'FAIL').Count
            $timeouts = @($table | Where-Object Status -EQ 'TIMEOUT').Count
            $notRun = @($table | Where-Object Status -EQ 'NOT RUN').Count
            $summary = "Upstream regression: $passed/$($cases.Count) PASS, $failed FAIL, $timeouts TIMEOUT, $notRun NOT RUN."
            Note $summary
            Set-Content -LiteralPath "$evidence\SUMMARY.txt" -Value $summary -Encoding utf8
            if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary -Encoding utf8 }
        }
    }
    if ($passed -ne $cases.Count) { throw $summary }
    if (Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq $port) { throw 'Regression port still occupied' }
}

if ($Phase -eq 'Regression') {
    Invoke-UpstreamRegression
    return
}

$toolchain = Build-Extension
Initialize-LabEnvironment
$backup = "$root\vector-lab.dump"
try {
    Start-Lab 'source'
    $null = Run "$pg\bin\createdb.exe" ($conn + @('--template=template0',$db))
    $source = Test-Vectors $true '01-source'
    $null = Run "$pg\bin\pg_dump.exe" ($conn + @('-d',$db,'-Fc','-f',$backup))
    $toc = @(Run "$pg\bin\pg_restore.exe" @('--list',$backup))
    if (-not ($toc -match 'EXTENSION .*vector') -or -not ($toc -match 'INDEX .*vector_test_hnsw_idx') -or
        -not ($toc -match 'TABLE DATA .*vector_test')) { throw 'Vector backup TOC incomplete' }
    $toc | Set-Content -LiteralPath "$evidence\backup-toc.txt" -Encoding utf8
    Note "Logical backup SHA-256 $(Hash $backup)"
    Stop-Lab 'source'
    Start-Lab 'restore'
    $null = Run "$pg\bin\createdb.exe" ($conn + @('--template=template0',$db))
    $null = Run "$pg\bin\pg_restore.exe" ($conn + @('-d',$db,'--exit-on-error','--single-transaction',$backup))
    $restored = Test-Vectors $false '02-restore'
    if ($source -cne $restored) { throw 'Restored data, index or query fingerprint differs' }
    Stop-Lab 'restore'
    Start-Lab 'source' -Existing
    if ($source -cne (Test-Vectors $false '03-source-after-restore')) { throw 'Source changed after restore' }
    Note 'PASS source, restored, and post-restore source fingerprints match'
} finally {
    try { Stop-Lab 'restore' }
    finally { Stop-Lab 'source' }
}
foreach ($label in @('source','restore')) {
    $null = Run "$pg\bin\pg_checksums.exe" @('--check','-D',"$root\$label")
}
if (Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq $port) { throw 'Lab port still occupied' }
Note 'PASS both local-only runner clusters stopped'

$payload = "$root\$bundle"
[void][IO.Directory]::CreateDirectory($upload)
[void][IO.Directory]::CreateDirectory($payload)
$extensions = @('lib/vector.dll','share/extension/vector.control') +
    @(Get-ChildItem -LiteralPath "$pg\share\extension" -Filter 'vector--*.sql' -File | ForEach-Object { "share/extension/$($_.Name)" })
$extensions += 'halfvec.h','sparsevec.h','vector.h' | ForEach-Object { "include/server/extension/vector/$_" }
foreach ($f in $extensions) {
    $dest = Join-Path $payload $f
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest))
    Copy-Item -LiteralPath (Join-Path $pg $f) -Destination $dest
}
Copy-Item -LiteralPath "$src\LICENSE" -Destination "$payload\LICENSE"
$files = foreach ($relative in (($extensions + 'LICENSE') | Sort-Object -Unique)) {
    $f = Join-Path $payload $relative
    [pscustomobject]@{Path=$relative; SHA256=(Hash $f); Bytes=(Get-Item -LiteralPath $f).Length}
}
$os = Get-CimInstance Win32_OperatingSystem
$meta = [ordered]@{
    postgresql='18.7'; edbArchive=$name; edbSha256=$expected; pgvector='0.8.7'; pgvectorCommit=$commit
    runnerLabel='windows-2022'; runnerArch=$env:RUNNER_ARCH; runnerImageOS=$env:ImageOS
    runnerImageVersion=$env:ImageVersion; windowsVersion=$os.Version; windowsBuild=$os.BuildNumber
    toolchain=$toolchain
    buildCommands=@('nmake /NOLOGO /F Makefile.win','nmake /NOLOGO /F Makefile.win install')
    coreTests='PASS'; upstreamRegression='NOT RUN at packaging time'; seedRows=10004; nonNullVectors=10003; testsPort=$port
    dateUtc=[DateTime]::UtcNow.ToString('o'); workflowRunId=$env:GITHUB_RUN_ID; workflowCommit=$env:GITHUB_SHA
    runAttempt=$env:GITHUB_RUN_ATTEMPT; workflowRunUrl="$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    baselineManifestSHA256=(Hash "$evidence\edb-files.csv"); testResultSHA256=(Hash "$evidence\01-source.txt")
    sqlSHA256=(Hash (Join-Path $PSScriptRoot 'vector-test.sql'))
    files=@($files)
}
$meta | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$payload\build-manifest.json" -Encoding utf8
@('# pgvector 0.8.7 for EDB PostgreSQL 18.7-1','',
    "Run: $($meta.workflowRunUrl)",
    "Runner: windows-2022 X64 / $($meta.runnerImageVersion) / $($meta.windowsVersion)",
    "MSVC $($toolchain.MSVC) / NMAKE $($toolchain.NMake) / SDK $($toolchain.WindowsSDK)",
    "Source $commit", "EDB SHA-256 $expected", "vector.dll SHA-256 $(Hash "$pg\lib\vector.dll")",
    'Upstream regression had not run at packaging time. See the separate regression evidence artifact.',
    'Functional tests, three exact/HNSW comparisons, independent restore, and source recheck passed.'
) | Set-Content -LiteralPath "$payload\BUILD-REPORT.md" -Encoding utf8
$sums = foreach ($relative in (@($files.Path) + @('build-manifest.json','BUILD-REPORT.md'))) {
    "$(Hash (Join-Path $payload $relative))  $relative"
}
$sums | Set-Content -LiteralPath "$payload\SHA256SUMS.txt" -Encoding ascii
$package = "$upload\$bundle.zip"
Compress-Archive -LiteralPath $payload -DestinationPath $package -CompressionLevel Optimal
$packageHash = Hash $package
"$packageHash  $bundle.zip" | Set-Content -LiteralPath "$package.sha256" -Encoding ascii
Note "PACKAGE_SHA256=$packageHash"
Note "VECTOR_DLL_SHA256=$(Hash "$pg\lib\vector.dll")"
foreach ($f in @('BUILD-REPORT.md','build-manifest.json','SHA256SUMS.txt')) {
    Copy-Item -LiteralPath "$payload\$f" -Destination $upload
}
foreach ($f in @('edb-files.csv','build-and-test.log','backup-toc.txt','01-source.txt','02-restore.txt','03-source-after-restore.txt',
    'toolchain.json','postgres-lib-architecture.txt','postgres-source.log','postgres-restore.log')) {
    Copy-Item -LiteralPath "$evidence\$f" -Destination $upload
}
