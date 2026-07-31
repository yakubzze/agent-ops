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
