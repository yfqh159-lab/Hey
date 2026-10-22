[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('doctor', 'test', 'build', 'install', 'targets', 'logs')]
  [string]$Action = 'doctor',

  [string]$DevEcoHome = $env:DEVECO_HOME,
  [string]$Hap = '',
  [string]$BuildProfile = '',

  [ValidateRange(30, 3600)]
  [int]$TestTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($BuildProfile)) {
  $BuildProfile = Join-Path $ProjectRoot 'build-profile.json5'
}
if ([string]::IsNullOrWhiteSpace($Hap)) {
  $Hap = Join-Path $ProjectRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
}

function Resolve-DevEcoInstallation {
  param([string]$RequestedHome)

  $candidates = [System.Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace($RequestedHome)) {
    $candidates.Add($RequestedHome)
  }
  $hvigorCommand = Get-Command 'hvigorw.bat' -ErrorAction SilentlyContinue
  if ($null -ne $hvigorCommand) {
    $binDirectory = Split-Path -Parent $hvigorCommand.Source
    $candidates.Add((Resolve-Path (Join-Path $binDirectory '..\..\..')).Path)
  }
  $candidates.Add('C:\Program Files\Huawei\DevEco Studio')
  $candidates.Add('C:\Program Files\DevEco Studio')
  $candidates.Add('D:\Program Files\DevEco Studio')

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }
    $resolved = [System.Environment]::ExpandEnvironmentVariables($candidate)
    if (Test-Path (Join-Path $resolved 'tools\hvigor\bin\hvigorw.bat')) {
      return (Resolve-Path $resolved).Path
    }
  }
  return ''
}

function Invoke-ExternalTool {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $Executable"
  }
}

function Invoke-ExternalToolWithTimeout {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][int]$TimeoutSeconds
  )

  $runId = [Guid]::NewGuid().ToString('N')
  $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) "hey-$runId.stdout.log"
  $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) "hey-$runId.stderr.log"
  $process = $null
  try {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $ProjectRoot `
      -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
      & taskkill.exe /PID $process.Id /T /F *> $null
      throw "Command timed out after $TimeoutSeconds seconds: $Executable"
    }
    $process.WaitForExit()
    $process.Refresh()
    if (Test-Path $stdoutPath) {
      $stdout = Get-Content -Raw -LiteralPath $stdoutPath
      if ($stdout.Length -gt 0) {
        [Console]::Out.Write($stdout)
      }
    }
    if (Test-Path $stderrPath) {
      $stderr = Get-Content -Raw -LiteralPath $stderrPath
      if ($stderr.Length -gt 0) {
        [Console]::Error.Write($stderr)
      }
    }
    $exitCode = $process.ExitCode
    if ($exitCode -ne 0) {
      throw "Command failed with exit code ${exitCode}: $Executable"
    }
  } finally {
    if ($null -ne $process -and -not $process.HasExited) {
      & taskkill.exe /PID $process.Id /T /F *> $null
    }
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

function Test-SigningConfiguration {
  param([string]$ProfilePath)

  if (-not (Test-Path $ProfilePath)) {
    return $false
  }
  $source = Get-Content -Raw -LiteralPath $ProfilePath
  return $source -match '(?s)["'']signingConfigs["'']\s*:\s*\[\s*\{'
}

function Assert-SignedHap {
  param([string]$HapPath)

  if (-not (Test-Path $HapPath)) {
    throw "Signed HAP not found: $HapPath"
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $requiredLibraries = @(
    'libs/arm64-v8a/libheyvpn.so',
    'libs/arm64-v8a/libxray.so',
    'libs/arm64-v8a/libsingbox.so',
    'libs/arm64-v8a/libheytun2socks.so',
    'libs/arm64-v8a/libhevsocks5tun.so'
  )
  $archive = [System.IO.Compression.ZipFile]::OpenRead($HapPath)
  try {
    $entries = @{}
    foreach ($entry in $archive.Entries) {
      $entries[$entry.FullName] = $true
    }
    foreach ($library in $requiredLibraries) {
      if (-not $entries.ContainsKey($library)) {
        throw "Packaged native library missing from HAP: $library"
      }
    }
  } finally {
    $archive.Dispose()
  }
  Write-Host "Signed HAP and native libraries verified: $HapPath"
}

$DevEcoHome = Resolve-DevEcoInstallation $DevEcoHome
$Hvigor = if ($DevEcoHome.Length -gt 0) {
  Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.bat'
} else {
  ''
}
$Ohpm = if ($DevEcoHome.Length -gt 0) {
  Join-Path $DevEcoHome 'tools\ohpm\bin\ohpm.bat'
} else {
  ''
}
$Hdc = if ($DevEcoHome.Length -gt 0) {
  Join-Path $DevEcoHome 'sdk\default\openharmony\toolchains\hdc.exe'
} else {
  ''
}
$JbrHome = if ($DevEcoHome.Length -gt 0) {
  Join-Path $DevEcoHome 'jbr'
} else {
  ''
}
$Java = if ($JbrHome.Length -gt 0) {
  Join-Path $JbrHome 'bin\java.exe'
} else {
  ''
}

if ($DevEcoHome.Length -gt 0) {
  $env:DEVECO_SDK_HOME = Join-Path $DevEcoHome 'sdk'
  if (Test-Path $Java) {
    $env:JAVA_HOME = $JbrHome
    $env:Path = "$(Join-Path $JbrHome 'bin');$env:Path"
  }
}

function Assert-DevEcoTools {
  if ($Hvigor.Length -eq 0 -or -not (Test-Path $Hvigor)) {
    throw 'DevEco Studio/Hvigor was not found. Set DEVECO_HOME or pass -DevEcoHome.'
  }
}

function Assert-Hdc {
  if ($Hdc.Length -eq 0 -or -not (Test-Path $Hdc)) {
    throw 'hdc was not found in the selected DevEco SDK.'
  }
}

Push-Location $ProjectRoot
try {
  switch ($Action) {
    'doctor' {
      $failed = $false
      if ($DevEcoHome.Length -gt 0) {
        Write-Host "OK: DevEco Studio: $DevEcoHome"
      } else {
        Write-Host 'MISSING: DevEco Studio. Set DEVECO_HOME or pass -DevEcoHome.'
        $failed = $true
      }
      foreach ($tool in @(
        @{ Name = 'hvigorw'; Path = $Hvigor },
        @{ Name = 'ohpm'; Path = $Ohpm },
        @{ Name = 'java'; Path = $Java },
        @{ Name = 'hdc'; Path = $Hdc }
      )) {
        if ($tool.Path.Length -gt 0 -and (Test-Path $tool.Path)) {
          Write-Host "OK: $($tool.Name): $($tool.Path)"
        } else {
          Write-Host "MISSING: $($tool.Name)"
          $failed = $true
        }
      }
      if (Test-SigningConfiguration $BuildProfile) {
        Write-Host "OK: signing configuration: $BuildProfile"
      } else {
        Write-Host "MISSING: non-empty signingConfigs in $BuildProfile"
        $failed = $true
      }
      if (Test-Path $Hap) {
        Write-Host "OK: signed HAP: $Hap"
      } else {
        Write-Host "INFO: signed HAP not found yet: $Hap"
      }
      if ($Hdc.Length -gt 0 -and (Test-Path $Hdc)) {
        Write-Host 'Targets:'
        $targetLines = @(& $Hdc list targets 2>&1)
        $targetExitCode = $LASTEXITCODE
        $targetsOutput = ($targetLines | ForEach-Object { $_.ToString() }) -join "`n"
        Write-Host $targetsOutput
        if ($targetExitCode -ne 0) {
          Write-Host 'MISSING: hdc could not enumerate targets.'
          $failed = $true
        } elseif ([string]::IsNullOrWhiteSpace($targetsOutput) -or
          $targetsOutput.Trim() -match '^(?i:\[?empty\]?)$') {
          Write-Host 'MISSING: no connected hdc target.'
          $failed = $true
        } else {
          Write-Host 'System:'
          & $Hdc shell 'param get const.product.model; param get const.product.software.version; param get const.ohos.apiversion'
          if ($LASTEXITCODE -ne 0) {
            Write-Host 'MISSING: connected target did not return system information.'
            $failed = $true
          }
          Write-Host 'VPN dialog package:'
          $vpnDialogLines = @(& $Hdc shell 'bm dump -n com.huawei.hmos.vpndialog' 2>&1)
          $vpnDialogExitCode = $LASTEXITCODE
          $vpnDialogOutput = ($vpnDialogLines | ForEach-Object { $_.ToString() }) -join "`n"
          if ($vpnDialogExitCode -ne 0 -or
            $vpnDialogOutput -match '(?i:failed|not exist|no bundle|no valid extension)') {
            Write-Host 'MISSING: com.huawei.hmos.vpndialog is not installed. VPN authorization cannot complete on this target.'
            Write-Host $vpnDialogOutput
            $failed = $true
          } else {
            Write-Host 'OK: com.huawei.hmos.vpndialog is installed.'
          }
        }
      }
      if ($failed) {
        exit 1
      }
    }
    'test' {
      Assert-DevEcoTools
      $testStartedAt = [DateTime]::UtcNow
      Invoke-ExternalToolWithTimeout -Executable $Hvigor -Arguments @(
        '--mode', 'module', '-p', 'module=entry@default', '-p', 'isLocalTest=true',
        'test', '--no-daemon', '--stacktrace'
      ) -TimeoutSeconds $TestTimeoutSeconds
      $resultLog = Join-Path $ProjectRoot 'entry\.test\default\intermediates\test\coverage_data\coverage.log'
      if (-not (Test-Path $resultLog)) {
        throw "LocalUnit result log was not generated: $resultLog"
      }
      $resultFile = Get-Item $resultLog
      if ($resultFile.LastWriteTimeUtc -lt $testStartedAt) {
        throw "LocalUnit result log was not refreshed: $resultLog"
      }
      $summaries = Select-String -LiteralPath $resultLog `
        -Pattern '\[Hypium\]total cases:[0-9]+;failure [0-9]+,error [0-9]+,pass [0-9]+;'
      if ($null -eq $summaries -or $summaries.Count -eq 0) {
        throw 'LocalUnit summary is missing; the preview runtime may have exited before running tests.'
      }
      $summary = $summaries[-1].Matches[0].Value
      if ($summary -notmatch ';failure 0,error 0,') {
        throw "LocalUnit assertions did not all pass: $summary"
      }
      Write-Host "LocalUnit assertions passed: $summary"
    }
    'build' {
      Assert-DevEcoTools
      if (-not (Test-SigningConfiguration $BuildProfile)) {
        throw "Configure a non-empty local signingConfigs entry first: $BuildProfile"
      }
      Invoke-ExternalTool $Hvigor @('clean', '--no-daemon', '--stacktrace')
      Invoke-ExternalTool $Hvigor @(
        '--mode', 'module', '-p', 'product=default', '-p', 'module=entry@default',
        '-p', 'buildMode=debug', 'assembleHap', '--no-daemon', '--stacktrace'
      )
      Assert-SignedHap $Hap
    }
    'install' {
      Assert-Hdc
      Assert-SignedHap $Hap
      Invoke-ExternalTool $Hdc @('install', '-r', $Hap)
    }
    'targets' {
      Assert-Hdc
      Invoke-ExternalTool $Hdc @('list', 'targets')
    }
    'logs' {
      Assert-Hdc
      & $Hdc shell hilog | Select-String -Pattern `
        'HeyVpn|HeyVpnAbility|HeyNative|NetworkVpnManager|NETMANAGER_EXT|vpndialog|connectAbility'
      if ($LASTEXITCODE -ne 0) {
        throw "hdc hilog failed with exit code $LASTEXITCODE"
      }
    }
  }
} finally {
  Pop-Location
}
