<#
Dependency-free tests for the PowerShell tools.

Run from any directory:
  pwsh -NoProfile -File ./tests/powershell/run-tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') '..'))
$linker = Join-Path $repoRoot 'scripts/link-memory.ps1'
$doctor = Join-Path $repoRoot 'scripts/memory-doctor.ps1'
$pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
$script:passed = 0
$script:failed = 0
$script:skipped = 0
$script:testRoots = [Collections.Generic.List[string]]::new()

function Assert-True {
  param([Parameter(Mandatory)] [bool] $Condition, [string] $Because = 'condition was false')
  if (-not $Condition) { throw "assertion failed: $Because" }
}

function Assert-Equal {
  param($Expected, $Actual, [string] $Because = '')
  if ($Expected -ne $Actual) {
    throw "assertion failed: expected [$Expected], got [$Actual]. $Because"
  }
}

function Assert-Match {
  param([Parameter(Mandatory)] [string] $Text, [Parameter(Mandatory)] [string] $Pattern)
  if ($Text -notmatch $Pattern) {
    throw "assertion failed: output did not match /$Pattern/`n--- output ---`n$Text"
  }
}

function Test-Case {
  param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [scriptblock] $Body)
  try {
    & $Body
    $script:passed++
    Write-Host "PASS  $Name" -ForegroundColor Green
  } catch {
    if ($_.Exception.Message.StartsWith('SKIP: ')) {
      Skip-Case $Name $_.Exception.Message.Substring(6)
      return
    }
    $script:failed++
    Write-Host "FAIL  $Name" -ForegroundColor Red
    Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
  }
}

function Skip-Case {
  param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Reason)
  $script:skipped++
  Write-Host "SKIP  $Name - $Reason" -ForegroundColor Yellow
}

function Skip-Test {
  # Ends the current Test-Case as skipped, with the reason printed.
  param([Parameter(Mandatory)] [string] $Reason)
  throw "SKIP: $Reason"
}

function Test-FileReadable {
  # A file's content, or a directory's listing, can be read.
  param([Parameter(Mandatory)] [string] $Path)
  try {
    if ([IO.Directory]::Exists($Path)) {
      [void] [IO.Directory]::GetFileSystemEntries($Path)
    } else {
      [void] [IO.File]::ReadAllBytes($Path)
    }
    return $true
  } catch {
    return $false
  }
}

function Lock-FileRead {
  <#
  Denies reading one file's content, or listing one directory: a deny-ReadData
  (ListDirectory) ACE for the current user on Windows, mode 000 elsewhere.
  Unlock-FileRead undoes exactly that change.
  #>
  param([Parameter(Mandatory)] [string] $Path)
  $lock = [pscustomobject]@{ Path = $Path; Rule = $null; Mode = $null }
  if ($IsWindows) {
    $info = Get-FileSystemInfo $Path
    $security = [IO.FileSystemAclExtensions]::GetAccessControl($info, [Security.AccessControl.AccessControlSections]::Access)
    $lock.Rule = [Security.AccessControl.FileSystemAccessRule]::new(
      [Security.Principal.WindowsIdentity]::GetCurrent().User,
      [Security.AccessControl.FileSystemRights]::ReadData,
      [Security.AccessControl.AccessControlType]::Deny
    )
    $security.AddAccessRule($lock.Rule)
    [IO.FileSystemAclExtensions]::SetAccessControl($info, $security)
  } else {
    $lock.Mode = [IO.File]::GetUnixFileMode($Path)
    [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]::None)
  }
  return $lock
}

function Get-FileSystemInfo {
  param([Parameter(Mandatory)] [string] $Path)
  if ([IO.Directory]::Exists($Path)) { return [IO.DirectoryInfo]::new($Path) }
  return [IO.FileInfo]::new($Path)
}

function Unlock-FileRead {
  param([Parameter(Mandatory)] $Lock)
  if ($IsWindows) {
    if ($null -eq $Lock.Rule) { return }
    $info = Get-FileSystemInfo $Lock.Path
    $security = [IO.FileSystemAclExtensions]::GetAccessControl($info, [Security.AccessControl.AccessControlSections]::Access)
    [void] $security.RemoveAccessRule($Lock.Rule)
    [IO.FileSystemAclExtensions]::SetAccessControl($info, $security)
  } elseif ($null -ne $Lock.Mode) {
    [IO.File]::SetUnixFileMode($Lock.Path, $Lock.Mode)
  }
}

function New-TestRoot {
  $path = Join-Path ([IO.Path]::GetTempPath()) ('agent-ops-pwsh-tests-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $path | Out-Null
  $script:testRoots.Add($path)
  return $path
}

function New-Project {
  param([Parameter(Mandatory)] [string] $Root, [string] $Slug = 'project-one')
  $projects = Join-Path $Root 'projects'
  $project = Join-Path $projects $Slug
  New-Item -ItemType Directory -Path $project -Force | Out-Null
  return [pscustomobject]@{ Projects = $projects; Project = $project; Slug = $Slug }
}

function Invoke-Tool {
  param(
    [Parameter(Mandatory)] [string] $Script,
    [Parameter(Mandatory)] [object[]] $Arguments,
    [string] $WorkingDirectory
  )
  $pushed = $false
  try {
    if ($WorkingDirectory) {
      Push-Location -LiteralPath $WorkingDirectory
      $pushed = $true
    }
    $lines = @(& $pwsh -NoLogo -NoProfile -File $Script @Arguments 2>&1)
    $code = $LASTEXITCODE
  } finally {
    if ($pushed) { Pop-Location }
  }
  return [pscustomobject]@{ Code = $code; Output = ($lines | Out-String) }
}

function Invoke-ToolSplit {
  <#
  Runs pwsh with stdout and stderr kept apart, both decoded as UTF-8. Hook mode
  depends on the report being on stdout, as UTF-8: Claude Code drops a hook's
  stderr on exit 0, and Invoke-Tool's 2>&1 capture cannot tell the two apart.
  #>
  param([Parameter(Mandatory)] [object[]] $PwshArguments)
  $info = [Diagnostics.ProcessStartInfo]::new($pwsh)
  foreach ($argument in @('-NoLogo', '-NoProfile') + $PwshArguments) { $info.ArgumentList.Add([string] $argument) }
  $info.UseShellExecute = $false
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $utf8 = [Text.UTF8Encoding]::new($false)
  $info.StandardOutputEncoding = $utf8
  $info.StandardErrorEncoding = $utf8
  $process = [Diagnostics.Process]::Start($info)
  try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
      Code = $process.ExitCode
      Stdout = $stdout.GetAwaiter().GetResult()
      Stderr = $stderr.GetAwaiter().GetResult()
    }
  } finally {
    $process.Dispose()
  }
}

function Invoke-Hook {
  # The doctor with -Hook, as a SessionStart hook runs it.
  param([Parameter(Mandatory)] [object[]] $Arguments)
  $result = Invoke-ToolSplit (@('-File', $doctor) + $Arguments + '-Hook')
  Assert-Equal 0 $result.Code "a hook run must exit 0.`n$($result.Stdout)`n$($result.Stderr)"
  Assert-Equal '' $result.Stderr 'a hook run wrote to stderr, which Claude Code drops on exit 0'
  return $result
}

function Format-PowerShellLiteral {
  param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
  return "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'"
}

function Get-FullReportCommand {
  param([Parameter(Mandatory)] [string] $Report)
  $match = [regex]::Match($Report, '(?m)^A manual run exits \d\. Full report: (?<command>pwsh .+?)\r?$')
  Assert-True $match.Success "no full-report command in:`n$Report"
  return $match.Groups['command'].Value
}

function Get-PosixShell {
  <#
  The shell an agent pastes into: on Windows that is Git Bash, the shell behind
  Claude Code's Bash tool. WSL's bash.exe is not used, since it cannot run this
  Windows pwsh with Windows paths.
  #>
  if ($IsWindows) {
    # git.exe sits in Git\cmd or Git\mingw64\bin; bash.exe in Git\bin.
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) { return $null }
    $directory = Split-Path -Parent $git.Source
    for ($level = 0; $level -lt 3 -and $directory; $level++) {
      $bash = Join-Path (Join-Path $directory 'bin') 'bash.exe'
      if (Test-Path -LiteralPath $bash -PathType Leaf) { return $bash }
      $directory = Split-Path -Parent $directory
    }
    return $null
  }
  $bash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($bash) { return $bash.Source }
  return $null
}

function Invoke-InPosixShell {
  # Runs one command line exactly as printed, with this pwsh first on PATH.
  param(
    [Parameter(Mandatory)] [string] $Shell,
    [Parameter(Mandatory)] [string] $CommandLine,
    [Parameter(Mandatory)] [string] $ScratchDirectory
  )
  $file = Join-Path $ScratchDirectory 'full-report.sh'
  [IO.File]::WriteAllText($file, $CommandLine + "`n", [Text.UTF8Encoding]::new($false))
  $savedPath = $env:PATH
  try {
    $env:PATH = $PSHOME + [IO.Path]::PathSeparator + $env:PATH
    $lines = @(& $Shell ($file.Replace('\', '/')) 2>&1)
    $code = $LASTEXITCODE
  } finally {
    $env:PATH = $savedPath
  }
  return [pscustomobject]@{ Code = $code; Output = ($lines | Out-String) }
}

function New-DirectoryLink {
  param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Target)
  $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
  New-Item -ItemType $kind -Path $Path -Target $Target | Out-Null
}

function Get-LinkTargetFullPath {
  param([Parameter(Mandatory)] [string] $Path)
  $item = Get-Item -LiteralPath $Path -Force
  $target = [string] (@($item.Target)[0])
  if (-not [IO.Path]::IsPathRooted($target)) {
    $target = Join-Path $item.DirectoryName $target
  }
  return [IO.Path]::GetFullPath($target)
}

function Get-CanonicalFullPath {
  param([Parameter(Mandatory)] [string] $Path)
  $full = [IO.Path]::GetFullPath($Path)
  if (-not $IsWindows -and (Test-Path -LiteralPath $full)) {
    $rl = & readlink -f $full 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($rl)) {
      return $rl.Trim()
    }
  }
  return $full
}

try {
  Test-Case 'both scripts parse without errors' {
    foreach ($file in @($linker, $doctor)) {
      $tokens = $null
      $errors = $null
      [void] [Management.Automation.Language.Parser]::ParseFile($file, [ref] $tokens, [ref] $errors)
      Assert-Equal 0 @($errors).Count "parse errors in $file"
    }
  }

  Test-Case 'linker rejects Project path traversal with usage exit 2' {
    $root = New-TestRoot
    $tree = New-Project $root
    $result = Invoke-Tool $linker @('-Project', '..', '-ProjectsDir', $tree.Projects, '-Store', (Join-Path $root 'store'))
    Assert-Equal 2 $result.Code
    Assert-Match $result.Output 'Project must be one'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'store'))) 'validation must not create Store'
  }

  Test-Case 'linker rejects Name path traversal with usage exit 2' {
    $root = New-TestRoot
    $tree = New-Project $root
    $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-Name', '../escape', '-ProjectsDir', $tree.Projects, '-Store', (Join-Path $root 'store'))
    Assert-Equal 2 $result.Code
    Assert-Match $result.Output 'Name must be one path segment'
  }

  Test-Case 'linker rejects filesystem roots for ProjectsDir and Store without mutation' {
    $root = New-TestRoot
    $tree = New-Project $root
    $memory = Join-Path $tree.Project 'memory'
    New-Item -ItemType Directory -Path $memory | Out-Null
    Set-Content -LiteralPath (Join-Path $memory 'state.txt') -Value 'unchanged' -NoNewline
    $fileSystemRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root))
    $plannedStore = Join-Path $root 'must-not-exist'

    $projectsResult = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $fileSystemRoot, '-Store', $plannedStore)
    Assert-Equal 2 $projectsResult.Code
    Assert-Match $projectsResult.Output 'ProjectsDir must not be a filesystem root'
    Assert-True (-not (Test-Path -LiteralPath $plannedStore)) 'invalid ProjectsDir created Store'

    $storeResult = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $fileSystemRoot)
    Assert-Equal 2 $storeResult.Code
    Assert-Match $storeResult.Output 'Store must not be a filesystem root'
    Assert-Equal 'unchanged' (Get-Content -LiteralPath (Join-Path $memory 'state.txt') -Raw)
    Assert-True ((Get-Item -LiteralPath $memory).LinkType -notin @('Junction', 'SymbolicLink')) 'root refusal changed source'
  }

  Test-Case 'relative Store is canonicalized in dry-run and no data changes' {
    $root = New-TestRoot
    $tree = New-Project $root
    $memory = Join-Path $tree.Project 'memory'
    New-Item -ItemType Directory -Path (Join-Path $memory 'nested') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $memory 'nested/data.txt') -Value 'anything, not only markdown'
    $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', 'relative-store', '-DryRun') $root
    Assert-Equal 0 $result.Code
    Assert-Match $result.Output ([regex]::Escape([IO.Path]::GetFullPath((Join-Path $root 'relative-store'))))
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'relative-store'))) 'dry-run created the relative store'
    Assert-True ((Get-Item -LiteralPath $memory).LinkType -notin @('Junction', 'SymbolicLink')) 'dry-run changed source'
  }

  Test-Case 'linker rejects source equal to destination' {
    $root = New-TestRoot
    $tree = New-Project $root
    New-Item -ItemType Directory -Path (Join-Path $tree.Project 'memory') | Out-Null
    $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $tree.Project, '-Name', 'memory')
    Assert-Equal 1 $result.Code
    Assert-Match $result.Output 'equal or nested'
  }

  Test-Case 'linker resolves linked ancestors and blocks a missing suffix inside ProjectsDir' {
    $root = New-TestRoot
    $tree = New-Project $root
    $memory = Join-Path $tree.Project 'memory'
    New-Item -ItemType Directory -Path $memory | Out-Null
    Set-Content -LiteralPath (Join-Path $memory 'state.dat') -Value 'untouched' -NoNewline

    $projectsAlias = Join-Path $root 'apparently-external-projects'
    New-DirectoryLink $projectsAlias $tree.Projects
    $internalBase = Join-Path $tree.Projects 'internal-store-base'
    New-Item -ItemType Directory -Path $internalBase | Out-Null
    $storeAncestorAlias = Join-Path $root 'apparently-external-store'
    New-DirectoryLink $storeAncestorAlias $internalBase

    $direct = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $projectsAlias, '-Store', $storeAncestorAlias)
    Assert-Equal 1 $direct.Code
    Assert-Match $direct.Output 'store is inside the legacy/default projects layout'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $internalBase $tree.Slug))) 'destination suffix was created through linked Store'

    $requestedStore = Join-Path $storeAncestorAlias 'not-created-yet'

    $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $projectsAlias, '-Store', $requestedStore)
    Assert-Equal 1 $result.Code
    Assert-Match $result.Output 'store is inside the legacy/default projects layout'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $internalBase 'not-created-yet'))) 'missing suffix was created despite refusal'
    Assert-Equal 'untouched' (Get-Content -LiteralPath (Join-Path $memory 'state.dat') -Raw)
  }

  Test-Case 'all content types, spaces, Unicode, and empty directories are handled' {
    $testRoot = New-TestRoot
    $root = Join-Path $testRoot 'workspace zażółć 你好'
    New-Item -ItemType Directory -Path $root | Out-Null
    $tree = New-Project $root 'projekt żółw 你好'
    $memory = Join-Path $tree.Project 'memory'
    $nested = Join-Path $memory 'nested'
    New-Item -ItemType Directory -Path (Join-Path $nested 'empty-dir') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $memory 'opaque.bin'), [byte[]] @(0, 1, 2, 255))
    Set-Content -LiteralPath (Join-Path $nested '.hidden-data') -Value 'preserve me' -NoNewline
    $store = Join-Path $root 'store'
    $dest = Join-Path $store $tree.Slug

    $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $store)
    Assert-Equal 0 $result.Code $result.Output
    $sourceItem = Get-Item -LiteralPath $memory -Force
    Assert-True ($sourceItem.LinkType -in @('Junction', 'SymbolicLink')) 'source is not a directory link'
    Assert-Equal (Get-CanonicalFullPath $dest) (Get-CanonicalFullPath (Get-LinkTargetFullPath $memory))
    Assert-True (Test-Path -LiteralPath (Join-Path $dest 'nested/empty-dir') -PathType Container) 'empty directory was lost'
    Assert-Equal 'preserve me' (Get-Content -LiteralPath (Join-Path $dest 'nested/.hidden-data') -Raw)
    Assert-Equal 255 ([IO.File]::ReadAllBytes((Join-Path $dest 'opaque.bin'))[3])
    $backups = @(Get-ChildItem -LiteralPath $tree.Project -Force -Directory -Filter 'memory.backup-*')
    Assert-Equal 1 $backups.Count 'backup not retained'
    Assert-True (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'memory/opaque.bin') -PathType Leaf) 'reserved backup payload is missing'
  }

  Test-Case 'non-note data on both sides causes refusal and no overwrite' {
    $root = New-TestRoot
    $tree = New-Project $root
    $memory = Join-Path $tree.Project 'memory'
    $store = Join-Path $root 'store'
    $dest = Join-Path $store $tree.Slug
    New-Item -ItemType Directory -Path $memory, $dest -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $memory 'source.dat'), 'source')
    [IO.File]::WriteAllText((Join-Path $dest 'existing.dat'), 'destination-original')
    $before = (Get-FileHash -LiteralPath (Join-Path $dest 'existing.dat')).Hash

    $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $store)
    Assert-Equal 1 $result.Code
    Assert-Match $result.Output 'both sides contain data'
    Assert-Equal $before (Get-FileHash -LiteralPath (Join-Path $dest 'existing.dat')).Hash
    Assert-True ((Get-Item -LiteralPath $memory).LinkType -notin @('Junction', 'SymbolicLink')) 'source changed on refusal'
  }

  Test-Case 'nested directory links are refused without mutation' {
    $root = New-TestRoot
    $tree = New-Project $root
    $memory = Join-Path $tree.Project 'memory'
    $shared = Join-Path $tree.Project 'shared'
    $store = Join-Path $root 'store'
    $dest = Join-Path $store $tree.Slug
    New-Item -ItemType Directory -Path $memory, $shared, $store -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $shared 'state.txt') -Value 'must remain here' -NoNewline
    New-DirectoryLink (Join-Path $memory 'topic-link') $shared

    $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $store)
    Assert-Equal 1 $result.Code
    Assert-Match $result.Output 'nested links are not migrated automatically'
    Assert-True ((Get-Item -LiteralPath (Join-Path $memory 'topic-link') -Force).LinkType -in @('Junction', 'SymbolicLink')) 'nested link was changed'
    Assert-Equal 'must remain here' (Get-Content -LiteralPath (Join-Path $memory 'topic-link/state.txt') -Raw)
    Assert-True (-not (Test-Path -LiteralPath $dest)) 'destination was created despite refusal'
  }

  Test-Case 'existing destination data is preserved when source is empty' {
    $root = New-TestRoot
    $tree = New-Project $root
    $memory = Join-Path $tree.Project 'memory'
    $store = Join-Path $root 'store'
    $dest = Join-Path $store $tree.Slug
    New-Item -ItemType Directory -Path $memory, $dest -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dest 'existing.txt') -Value 'keep' -NoNewline

    $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $store)
    Assert-Equal 0 $result.Code $result.Output
    Assert-Equal 'keep' (Get-Content -LiteralPath (Join-Path $memory 'existing.txt') -Raw)
    $backups = @(Get-ChildItem -LiteralPath $tree.Project -Force -Directory -Filter 'memory.backup-*')
    Assert-Equal 1 $backups.Count
    $backupPayload = Join-Path $backups[0].FullName 'memory'
    Assert-True (Test-Path -LiteralPath $backupPayload -PathType Container) 'empty source backup is missing'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $backupPayload -Force).Count 'empty source backup gained content'
  }

  Test-Case 'idempotency verifies target and rejects a missing target' {
    $root = New-TestRoot
    $tree = New-Project $root
    $memory = Join-Path $tree.Project 'memory'
    New-Item -ItemType Directory -Path $memory | Out-Null
    Set-Content -LiteralPath (Join-Path $memory 'state.txt') -Value 'state'
    $store = Join-Path $root 'store'
    $dest = Join-Path $store $tree.Slug
    $first = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $store)
    Assert-Equal 0 $first.Code $first.Output
    $second = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $store)
    Assert-Equal 0 $second.Code $second.Output
    Assert-Match $second.Output 'Already linked.*verified'

    Move-Item -LiteralPath $dest -Destination "$dest-away"
    $broken = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $store)
    Assert-Equal 1 $broken.Code
    Assert-Match $broken.Output 'target is missing|missing or is not a directory'
  }

  Test-Case 'rollback restores source after failure following source backup' {
    $root = New-TestRoot
    $tree = New-Project $root
    $memory = Join-Path $tree.Project 'memory'
    New-Item -ItemType Directory -Path $memory | Out-Null
    Set-Content -LiteralPath (Join-Path $memory 'only.data') -Value 'original' -NoNewline
    $store = Join-Path $root 'store'
    $dest = Join-Path $store $tree.Slug

    $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $store, '-TestFailurePoint', 'AfterSourceBackup')
    Assert-Equal 3 $result.Code $result.Output
    Assert-Match $result.Output 'Rollback complete'
    Assert-Equal 'original' (Get-Content -LiteralPath (Join-Path $memory 'only.data') -Raw)
    Assert-True ((Get-Item -LiteralPath $memory).LinkType -notin @('Junction', 'SymbolicLink')) 'source remained linked'
    Assert-True (-not (Test-Path -LiteralPath $dest)) 'transaction-created destination remained'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $tree.Project -Force -Filter 'memory.backup-*').Count 'backup was not restored'
  }

  Test-Case 'rollback restores a pre-existing empty destination without nesting' {
    $root = New-TestRoot
    $tree = New-Project $root
    $memory = Join-Path $tree.Project 'memory'
    $store = Join-Path $root 'store'
    $dest = Join-Path $store $tree.Slug
    New-Item -ItemType Directory -Path $memory, $dest -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $memory 'only.data') -Value 'original' -NoNewline

    $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $store, '-TestFailurePoint', 'AfterDestinationReady')
    Assert-Equal 3 $result.Code $result.Output
    Assert-Match $result.Output 'Rollback complete'
    Assert-Equal 'original' (Get-Content -LiteralPath (Join-Path $memory 'only.data') -Raw)
    Assert-True (Test-Path -LiteralPath $dest -PathType Container) 'original empty destination was not restored'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $dest -Force).Count 'restored destination was nested or gained content'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $store -Force -Directory -Filter '.agent-ops-*').Count 'rollback container remained'
  }

  Test-Case 'rollback removes new link and restores source after link creation' {
    $root = New-TestRoot
    $tree = New-Project $root
    $memory = Join-Path $tree.Project 'memory'
    New-Item -ItemType Directory -Path $memory | Out-Null
    [IO.File]::WriteAllText((Join-Path $memory 'data.bin'), 'original')
    $store = Join-Path $root 'store'
    $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', $store, '-TestFailurePoint', 'AfterLinkCreate')
    Assert-Equal 3 $result.Code $result.Output
    Assert-Equal 'original' ([IO.File]::ReadAllText((Join-Path $memory 'data.bin')))
    Assert-True ((Get-Item -LiteralPath $memory).LinkType -notin @('Junction', 'SymbolicLink')) 'rollback left a link'
  }

  Test-Case 'doctor reports any plain content as at risk' {
    $root = New-TestRoot
    $tree = New-Project $root
    $memory = Join-Path $tree.Project 'memory'
    New-Item -ItemType Directory -Path (Join-Path $memory 'empty-subdir') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $memory 'not-a-note.bin'), [byte[]] @(7, 8))
    $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects)
    Assert-Equal 1 $result.Code
    Assert-Match $result.Output 'legacy/default-layout scan'
    Assert-Match $result.Output 'AT RISK.*2 item\(s\)'
    Assert-Match $result.Output '/memory or /context'
  }

  Test-Case 'doctor requires StableRoot before a live external link is OK' {
    $root = New-TestRoot
    $tree = New-Project $root
    $stable = Join-Path $root 'stable'
    $target = Join-Path $stable $tree.Slug
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $target 'state.any') -Value 'state'
    New-DirectoryLink (Join-Path $tree.Project 'memory') $target

    $unverified = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects)
    Assert-Equal 1 $unverified.Code
    Assert-Match $unverified.Output 'UNVERIFIED.*stability not verified'
    $verified = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-StableRoot', $stable)
    Assert-Equal 0 $verified.Code $verified.Output
    Assert-Match $verified.Output 'OK.*1 item\(s\)'
  }

  Test-Case 'doctor resolves link chains back inside ProjectsDir as at risk' {
    $root = New-TestRoot
    $tree = New-Project $root
    $internal = Join-Path $tree.Projects 'internal-store'
    New-Item -ItemType Directory -Path $internal | Out-Null
    $externalLookingAlias = Join-Path $root 'external-looking-store'
    New-DirectoryLink $externalLookingAlias $internal
    New-DirectoryLink (Join-Path $tree.Project 'memory') $externalLookingAlias
    $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-StableRoot', $tree.Projects)
    Assert-Equal 1 $result.Code
    Assert-Match $result.Output 'AT RISK.*inside legacy projects layout'
  }

  Test-Case 'doctor reports a broken link as orphaned' {
    $root = New-TestRoot
    $tree = New-Project $root
    $target = Join-Path $root 'temporary-target'
    $moved = Join-Path $root 'moved-target'
    New-Item -ItemType Directory -Path $target | Out-Null
    New-DirectoryLink (Join-Path $tree.Project 'memory') $target
    Move-Item -LiteralPath $target -Destination $moved
    $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects)
    Assert-Equal 1 $result.Code
    Assert-Match $result.Output 'ORPHAN.*target missing or not a directory'
  }

  Test-Case 'doctor supports a safe custom MemoryDirectoryName' {
    $root = New-TestRoot
    $tree = New-Project $root
    New-Item -ItemType Directory -Path (Join-Path $tree.Project 'custom-memory') | Out-Null
    Set-Content -LiteralPath (Join-Path $tree.Project 'custom-memory/state.txt') -Value 'x'
    $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-MemoryDirectoryName', 'custom-memory')
    Assert-Equal 1 $result.Code
    Assert-Match $result.Output 'AT RISK'
    $invalid = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-MemoryDirectoryName', '../escape')
    Assert-Equal 2 $invalid.Code
  }

  Test-Case 'doctor uses usage exit 2 for a missing ProjectsDir' {
    $root = New-TestRoot
    $result = Invoke-Tool $doctor @('-ProjectsDir', (Join-Path $root 'missing'))
    Assert-Equal 2 $result.Code
    Assert-Match $result.Output 'No legacy/default agent projects directory'
  }

  Test-Case 'doctor rejects a filesystem root ProjectsDir with usage exit 2' {
    $root = New-TestRoot
    $fileSystemRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root))
    $result = Invoke-Tool $doctor @('-ProjectsDir', $fileSystemRoot)
    Assert-Equal 2 $result.Code
    Assert-Match $result.Output 'ProjectsDir must not be a filesystem root'
  }

  function New-SettingsProject {
    param(
      [Parameter(Mandatory)] [string] $Root,
      [Parameter(Mandatory)] [string] $Value,
      [string] $Under = 'plain-parent',
      [string] $FileName = 'settings.local.json'
    )
    $project = Join-Path (Join-Path $Root $Under) 'my-app'
    New-Item -ItemType Directory -Path (Join-Path $project '.claude') -Force | Out-Null
    $payload = [pscustomobject]@{ autoMemoryDirectory = $Value } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path (Join-Path $project '.claude') $FileName) -Value $payload
    return $project
  }

  Test-Case 'doctor flags an absolute memory directory declared in a synced settings file' {
    $root = New-TestRoot
    $tree = New-Project $root
    $store = Join-Path $root 'store'
    New-Item -ItemType Directory -Path $store | Out-Null
    # The failure this check exists for: the settings file travels to the other
    # machine, where an absolute path written on this one cannot resolve.
    $project = New-SettingsProject -Root $root -Value $store -Under 'Dropbox'
    $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-ProjectDir', $project)
    Assert-Equal 1 $result.Code $result.Output
    Assert-Match $result.Output 'AT RISK.*SYNCED settings file'
    Assert-Match $result.Output 'declared memory directory issue'
  }

  Test-Case 'doctor leaves an absolute declaration alone when the settings file is not synced' {
    $root = New-TestRoot
    $tree = New-Project $root
    $store = Join-Path $root 'store'
    New-Item -ItemType Directory -Path $store | Out-Null
    $project = New-SettingsProject -Root $root -Value $store
    $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-ProjectDir', $project)
    Assert-Equal 0 $result.Code $result.Output
    Assert-Match $result.Output 'OK.*settings\.local\.json'
  }

  Test-Case 'doctor treats a ~/ declaration as portable even inside a synced folder' {
    $root = New-TestRoot
    $tree = New-Project $root
    # ~/ resolves per machine, so it is the one absolute-ish form that survives
    # syncing. It must not be reported as relative, nor as the synced-path trap.
    $project = New-SettingsProject -Root $root -Value '~/agent-memory/my-app' -Under 'OneDrive'
    $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-ProjectDir', $project)
    Assert-True ($result.Output -notmatch 'relative value') 'a ~/ value was misread as relative'
    Assert-True ($result.Output -notmatch 'SYNCED settings file') 'a ~/ value was flagged as the synced-path trap'
  }

  Test-Case 'doctor flags a relative memory directory as ignored' {
    $root = New-TestRoot
    $tree = New-Project $root
    $project = New-SettingsProject -Root $root -Value 'notes/memory'
    $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-ProjectDir', $project)
    Assert-Equal 1 $result.Code $result.Output
    Assert-Match $result.Output 'AT RISK.*relative value'
  }

  Test-Case 'doctor flags a declared memory directory that does not exist' {
    $root = New-TestRoot
    $tree = New-Project $root
    $project = New-SettingsProject -Root $root -Value (Join-Path $root 'never-created')
    $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-ProjectDir', $project)
    Assert-Equal 1 $result.Code $result.Output
    Assert-Match $result.Output 'AT RISK.*does not exist'
  }

  Test-Case 'doctor skips the settings check on request' {
    $root = New-TestRoot
    $tree = New-Project $root
    $project = New-SettingsProject -Root $root -Value 'notes/memory'
    $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-ProjectDir', $project, '-SkipSettingsCheck')
    Assert-Equal 0 $result.Code $result.Output
    Assert-True ($result.Output -notmatch 'declared memory directory') 'settings were inspected despite -SkipSettingsCheck'
  }

  Test-Case 'doctor reports unreadable settings JSON instead of ignoring it' {
    $root = New-TestRoot
    $tree = New-Project $root
    $project = Join-Path $root 'broken-app'
    New-Item -ItemType Directory -Path (Join-Path $project '.claude') -Force | Out-Null
    # Names the key and then fails to yield a value - the same payload the Bash
    # suite uses, so both implementations are held to one answer.
    Set-Content -LiteralPath (Join-Path $project '.claude/settings.local.json') -Value '{ "autoMemoryDirectory": }'
    $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-ProjectDir', $project)
    Assert-Equal 1 $result.Code $result.Output
    Assert-Match $result.Output 'INVALID'
  }

  # Claude Code adds a SessionStart hook's plain-text stdout to the agent's
  # context only on exit 0 (Claude Code 2.1.283 hooks reference, read
  # 2026-09-30). A doctor that exits 1 there has its diagnosis dropped - which is
  # how dangling links went unnoticed for weeks.
  Test-Case 'doctor hook mode prints nothing and exits 0 when healthy' {
    $root = New-TestRoot
    $tree = New-Project $root
    $stable = Join-Path $root 'stable'
    $target = Join-Path $stable $tree.Slug
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $target 'state.any') -Value 'state'
    New-DirectoryLink (Join-Path $tree.Project 'memory') $target
    $result = Invoke-Hook @('-ProjectsDir', $tree.Projects, '-StableRoot', $stable, '-ProjectDir', $root)
    Assert-Equal '' $result.Stdout 'a healthy hook run must add nothing to the session'
  }

  Test-Case 'doctor hook mode reports at-risk and orphaned memory on stdout and exits 0' {
    $root = New-TestRoot
    $tree = New-Project $root 'at-risk-project'
    New-Item -ItemType Directory -Path (Join-Path $tree.Project 'memory') | Out-Null
    Set-Content -LiteralPath (Join-Path $tree.Project 'memory/state.txt') -Value 'x'
    $orphan = New-Project $root 'orphan-project'
    $target = Join-Path $root 'temporary-target'
    New-Item -ItemType Directory -Path $target | Out-Null
    New-DirectoryLink (Join-Path $orphan.Project 'memory') $target
    Move-Item -LiteralPath $target -Destination (Join-Path $root 'moved-target')
    $arguments = @('-ProjectsDir', $tree.Projects, '-ProjectDir', $root)

    $hook = Invoke-Hook $arguments
    Assert-Match $hook.Stdout '^agent-ops memory doctor: agent memory needs attention\.'
    Assert-Match $hook.Stdout 'AT RISK\s+at-risk-project'
    Assert-Match $hook.Stdout 'ORPHAN\s+orphan-project'
    Assert-Match $hook.Stdout '2 project\(s\):.* 1 at risk, 1 orphaned, 0 unreadable\.'
    Assert-Match $hook.Stdout '(?m)^AT RISK: '
    Assert-Match $hook.Stdout '(?m)^ORPHAN: '
    Assert-Match $hook.Stdout '(?m)^A manual run exits 1\. Full report: pwsh -NoProfile -File .*memory-doctor\.ps1''? -ProjectsDir '
    Assert-True ($hook.Stdout -notmatch 'legacy/default-layout scan') 'hook mode printed the banner'
    Assert-True ($hook.Stdout -notmatch '-Hook') 'the full-report command still carries -Hook'
    Assert-True ($hook.Stdout -notmatch "`e\[") 'hook mode printed ANSI escapes'

    # The problem lines are exactly what -Quiet prints.
    $quiet = Invoke-Tool $doctor ($arguments + '-Quiet')
    Assert-Equal 1 $quiet.Code $quiet.Output
    foreach ($line in @($quiet.Output -split '\r?\n' | Where-Object { $_.StartsWith('  ') })) {
      Assert-True ($hook.Stdout.Contains($line)) "hook report lost a quiet line: $line"
    }

    # Without the flag nothing changes: a gate still fails.
    $manual = Invoke-Tool $doctor $arguments
    Assert-Equal 1 $manual.Code $manual.Output
  }

  Test-Case 'doctor hook mode names a full-report command that runs in PowerShell and in Bash' {
    $root = New-TestRoot
    $tree = New-Project $root 'spaced project'
    New-Item -ItemType Directory -Path (Join-Path $tree.Project 'memory') | Out-Null
    Set-Content -LiteralPath (Join-Path $tree.Project 'memory/state.txt') -Value 'x'
    # A space and an apostrophe force quoting in the printed command; on Windows
    # the backslashes are what an unquoted Git Bash paste used to strip.
    $projects = Join-Path $root "team's projects"
    Move-Item -LiteralPath $tree.Projects -Destination $projects
    $hook = Invoke-Hook @('-ProjectsDir', $projects, '-ProjectDir', $root)
    $command = Get-FullReportCommand $hook.Stdout
    Assert-Match $command '^pwsh -NoProfile -File '
    $arguments = $command.Substring('pwsh '.Length)

    $full = @(Invoke-Expression "& $(Format-PowerShellLiteral $pwsh) $arguments 2>&1") | Out-String
    Assert-Equal 1 $LASTEXITCODE $full
    Assert-Match $full 'legacy/default-layout scan'
    Assert-Match $full 'AT RISK\s+spaced project'

    $shell = Get-PosixShell
    if (-not $shell) { Skip-Test 'no Git Bash (or bash) to run the printed command in' }
    $posix = Invoke-InPosixShell -Shell $shell -CommandLine $command -ScratchDirectory $root
    Assert-Equal 1 $posix.Code $posix.Output
    Assert-Match $posix.Output 'legacy/default-layout scan'
    Assert-Match $posix.Output 'AT RISK\s+spaced project'
  }

  Test-Case 'doctor hook mode keeps several ProjectDir values in its full-report command' {
    $root = New-TestRoot
    $tree = New-Project $root
    $plain = Join-Path $root 'plain-app'
    New-Item -ItemType Directory -Path $plain | Out-Null
    $relative = New-SettingsProject -Root $root -Value 'notes/memory'
    # Several values only arrive through -Command or &: pwsh -File passes 'a,b'
    # as one string. The printed command must not collapse them either.
    $invocation = "& $(Format-PowerShellLiteral $doctor) -Hook -ProjectsDir $(Format-PowerShellLiteral $tree.Projects) " +
      "-ProjectDir $(Format-PowerShellLiteral $plain),$(Format-PowerShellLiteral $relative); exit `$LASTEXITCODE"
    $hook = Invoke-ToolSplit @('-Command', $invocation)
    Assert-Equal 0 $hook.Code "$($hook.Stdout)`n$($hook.Stderr)"
    Assert-Equal '' $hook.Stderr 'a hook run wrote to stderr'
    Assert-Match $hook.Stdout '1 declared memory directory issue\(s\)\.'
    $command = Get-FullReportCommand $hook.Stdout
    Assert-Match $command '^pwsh -NoProfile -Command "& '

    $full = @(Invoke-Expression "& $(Format-PowerShellLiteral $pwsh) $($command.Substring('pwsh '.Length)) 2>&1") | Out-String
    Assert-Match $full 'relative value "notes/memory" is ignored'
    Assert-Match $full ([regex]::Escape((Get-CanonicalFullPath $plain)) + '\s+no autoMemoryDirectory declared')
    Assert-Match $full '1 declared memory directory issue\(s\)\.'

    $shell = Get-PosixShell
    if (-not $shell) { Skip-Test 'no Git Bash (or bash) to run the printed command in' }
    $posix = Invoke-InPosixShell -Shell $shell -CommandLine $command -ScratchDirectory $root
    Assert-Match $posix.Output 'relative value "notes/memory" is ignored'
    Assert-Match $posix.Output '1 declared memory directory issue\(s\)\.'
  }

  Test-Case 'doctor hook mode reports an invalid argument and exits 0' {
    $root = New-TestRoot
    $tree = New-Project $root
    $invalid = Invoke-Hook @('-ProjectsDir', $tree.Projects, '-MemoryDirectoryName', '../escape')
    Assert-Match $invalid.Stdout 'needs attention; the audit could not run'
    Assert-Match $invalid.Stdout 'error: invalid argument: MemoryDirectoryName must be one safe path segment'
    Assert-Match $invalid.Stdout 'A manual run exits 2\.'

    $missing = Invoke-Hook @('-ProjectsDir', (Join-Path $root 'missing'))
    Assert-Match $missing.Stdout 'No legacy/default agent projects directory'
    Assert-Match $missing.Stdout 'A manual run exits 2\.'

    $manual = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-MemoryDirectoryName', '../escape')
    Assert-Equal 2 $manual.Code $manual.Output
  }

  Test-Case 'doctor reports a misspelled parameter as invalid input, and hook mode delivers it' {
    $root = New-TestRoot
    $tree = New-Project $root
    # Without the catch-all parameter this failed in PowerShell's binder: exit 1,
    # nothing on stdout, and under -Hook only a Claude Code hook error.
    $hook = Invoke-Hook @('-ProjectsDir', $tree.Projects, '-StabelRoot', $root)
    Assert-Match $hook.Stdout 'needs attention; the audit could not run'
    Assert-Match $hook.Stdout ('error: unknown argument: -StabelRoot ' + [regex]::Escape($root))
    Assert-Match $hook.Stdout 'A manual run exits 2\.'

    $manual = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects, '-StabelRoot', $root)
    Assert-Equal 2 $manual.Code $manual.Output
    Assert-Match $manual.Output 'error: unknown argument: -StabelRoot'
  }

  Test-Case 'doctor hook mode reports an unexpected failure and exits 0' {
    $root = New-TestRoot
    $tree = New-Project $root
    $project = New-SettingsProject -Root $root -Value (Join-Path $root 'store')
    # A function shadows the cmdlet inside the script, so the audit fails where
    # nothing catches it and only the script-level trap is left.
    $invocation = "function Split-Path { throw 'injected fault' }; & $(Format-PowerShellLiteral $doctor) " +
      "-ProjectsDir $(Format-PowerShellLiteral $tree.Projects) -ProjectDir $(Format-PowerShellLiteral $project)"
    $manual = Invoke-ToolSplit @('-Command', "$invocation; exit `$LASTEXITCODE")
    Assert-Equal 1 $manual.Code "$($manual.Stdout)`n$($manual.Stderr)"
    Assert-Match $manual.Stderr 'injected fault'

    $hook = Invoke-ToolSplit @('-Command', "$invocation -Hook; exit `$LASTEXITCODE")
    Assert-Equal 0 $hook.Code "$($hook.Stdout)`n$($hook.Stderr)"
    Assert-Equal '' $hook.Stderr 'a hook run wrote to stderr'
    Assert-Match $hook.Stdout '^agent-ops memory doctor: agent memory needs attention\.'
    Assert-Match $hook.Stdout '(?m)^error: injected fault\r?$'
    Assert-Match $hook.Stdout '(?m)^A manual run exits 1\. Full report: '
  }

  Test-Case 'doctor hook mode caps the problem lines it prints' {
    $root = New-TestRoot
    foreach ($i in 1..14) {
      $tree = New-Project $root ('p{0:d2}' -f $i)
      New-Item -ItemType Directory -Path (Join-Path $tree.Project 'memory') | Out-Null
      Set-Content -LiteralPath (Join-Path $tree.Project 'memory/state.txt') -Value 'x'
    }
    $hook = Invoke-Hook @('-ProjectsDir', $tree.Projects, '-ProjectDir', $root)
    $entries = @($hook.Stdout -split '\r?\n' | Where-Object { $_ -match '^\s+AT RISK\s' })
    Assert-Equal 12 $entries.Count $hook.Stdout
    Assert-Match $hook.Stdout '(?m)^\.\.\. and 2 more line\(s\); the full report lists every entry\.\r?$'
    Assert-Match $hook.Stdout '14 project\(s\):.* 14 at risk'
    Assert-Match $hook.Stdout '(?m)^A manual run exits 1\. Full report: '
  }

  Test-Case 'doctor hook mode writes its report as UTF-8' {
    $root = New-TestRoot
    $tree = New-Project $root 'zażółć-gęślą'
    New-Item -ItemType Directory -Path (Join-Path $tree.Project 'memory') | Out-Null
    Set-Content -LiteralPath (Join-Path $tree.Project 'memory/state.txt') -Value 'x'
    # Measured 2026-09-30: redirected output used the console code page (ibm852
    # on a Polish Windows), so non-ASCII text reached the agent garbled.
    $hook = Invoke-Hook @('-ProjectsDir', $tree.Projects, '-ProjectDir', $root)
    Assert-True ($hook.Stdout.Contains('AT RISK     zażółć-gęślą')) "the report is not UTF-8:`n$($hook.Stdout)"
  }

  Test-Case 'doctor reports unreadable content in an existing link target as UNREADABLE, not ORPHAN' {
    $root = New-TestRoot
    $tree = New-Project $root
    $stable = Join-Path $root 'stable'
    $target = Join-Path $stable $tree.Slug
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $target 'readable.md') -Value 'fine'
    $blocked = Join-Path $target 'placeholder.md'
    Set-Content -LiteralPath $blocked -Value 'content that cannot be read'
    New-DirectoryLink (Join-Path $tree.Project 'memory') $target
    # A second target exists and is a directory, but cannot be listed at all.
    $second = New-Project $root 'project-two'
    $closed = Join-Path $stable $second.Slug
    New-Item -ItemType Directory -Path $closed | Out-Null
    Set-Content -LiteralPath (Join-Path $closed 'readable.md') -Value 'fine'
    New-DirectoryLink (Join-Path $second.Project 'memory') $closed
    $arguments = @('-ProjectsDir', $tree.Projects, '-StableRoot', $stable, '-ProjectDir', $root)

    $locks = [Collections.Generic.List[object]]::new()
    try {
      $locks.Add((Lock-FileRead $blocked))
      $locks.Add((Lock-FileRead $closed))
      if ((Test-FileReadable $blocked) -or (Test-FileReadable $closed)) {
        Skip-Test 'this account still reads what it was denied (root or a privileged account), so unreadable content cannot be simulated'
      }
      $manual = Invoke-Tool $doctor $arguments
      $hook = Invoke-Hook $arguments
    } finally {
      foreach ($lock in $locks) { Unlock-FileRead $lock }
    }
    Assert-True (Test-FileReadable $blocked) 'the test did not restore read access'
    Assert-True (Test-FileReadable $closed) 'the test did not restore list access'

    Assert-Equal 1 $manual.Code $manual.Output
    Assert-Match $manual.Output 'UNREADABLE\s+project-one\s+->'
    Assert-Match $manual.Output 'UNREADABLE\s+project-two\s+->'
    Assert-Match $manual.Output '0 orphaned, 2 unreadable\.'
    Assert-Match $manual.Output 'It is not missing and must not be recreated'
    Assert-True ($manual.Output -cnotmatch '(?m)^\s+ORPHAN\s') 'an existing target was called ORPHAN'
    Assert-True ($manual.Output -cnotmatch '(?m)^\s+OK\s') 'unreadable content was reported OK'

    Assert-Match $hook.Stdout 'UNREADABLE\s+project-one'
    Assert-Match $hook.Stdout 'UNREADABLE\s+project-two'
    Assert-Match $hook.Stdout '(?m)^UNREADABLE: the target exists but some content could not be read'
  }

  if (-not $IsWindows) {
    Test-Case 'linker fails closed for an uninspectable project directory' {
      $root = New-TestRoot
      $tree = New-Project $root
      $memory = Join-Path $tree.Project 'memory'
      New-Item -ItemType Directory -Path $memory | Out-Null
      Set-Content -LiteralPath (Join-Path $memory 'state.bin') -Value 'must survive' -NoNewline
      $originalMode = [IO.File]::GetUnixFileMode($tree.Project)
      [IO.File]::SetUnixFileMode($tree.Project, [IO.UnixFileMode]::None)
      try {
        $enforced = $false
        try { [void] @(Get-ChildItem -LiteralPath $tree.Project -Force -ErrorAction Stop) } catch { $enforced = $true }
        if (-not $enforced) { return }
        $result = Invoke-Tool $linker @('-Project', $tree.Slug, '-ProjectsDir', $tree.Projects, '-Store', (Join-Path $root 'store'), '-DryRun')
        Assert-Equal 1 $result.Code
        Assert-Match $result.Output 'cannot be inspected'
      } finally {
        [IO.File]::SetUnixFileMode($tree.Project, $originalMode)
      }
      Assert-Equal 'must survive' (Get-Content -LiteralPath (Join-Path $memory 'state.bin') -Raw)
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'store'))) 'refusal created Store'
    }

    Test-Case 'doctor fails closed for an uninspectable ProjectsDir' {
      $root = New-TestRoot
      $tree = New-Project $root
      New-Item -ItemType Directory -Path (Join-Path $tree.Project 'memory') | Out-Null
      $originalMode = [IO.File]::GetUnixFileMode($tree.Projects)
      [IO.File]::SetUnixFileMode($tree.Projects, [IO.UnixFileMode]::None)
      try {
        $enforced = $false
        try { [void] @(Get-ChildItem -LiteralPath $tree.Projects -Force -ErrorAction Stop) } catch { $enforced = $true }
        if (-not $enforced) { return }
        $result = Invoke-Tool $doctor @('-ProjectsDir', $tree.Projects)
        Assert-Equal 1 $result.Code
        Assert-Match $result.Output 'cannot enumerate projects'
      } finally {
        [IO.File]::SetUnixFileMode($tree.Projects, $originalMode)
      }
    }
  }
} finally {
  foreach ($root in $script:testRoots) {
    if (Test-Path -LiteralPath $root) {
      try { Remove-Item -LiteralPath $root -Recurse -Force } catch {
        Write-Host "WARN  cleanup failed for $root`: $($_.Exception.Message)" -ForegroundColor Yellow
      }
    }
  }
}

Write-Host ''
Write-Host "PowerShell tests: $script:passed passed, $script:failed failed, $script:skipped skipped."
if ($script:failed -gt 0) { exit 1 }
exit 0
