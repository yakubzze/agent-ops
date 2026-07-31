<#
.SYNOPSIS
  agent-ops - memory doctor

.DESCRIPTION
  Audits the legacy/default <projects>/<slug>/memory layout. It does not attempt
  to reproduce Claude Code settings precedence or workspace-trust decisions.
  Confirm the active memory path in Claude Code with /memory or /context.

  A plain non-empty memory directory is at risk. A missing/broken/non-directory
  link is orphaned. A live external link is reported as LINKED but remains
  unverified unless -StableRoot is supplied; only containment in that root earns
  an OK result. A link back inside ProjectsDir is always at risk.

  Exit codes:
    0  every discovered memory path is verified OK (or no memory exists)
    1  at-risk, orphaned, unreadable, or unverified memory exists
    2  invalid input or missing scan directory

.EXAMPLE
  pwsh ./scripts/memory-doctor.ps1 -StableRoot "$HOME\agent-memory"
.EXAMPLE
  pwsh ./scripts/memory-doctor.ps1 -ProjectsDir "$HOME\.some-agent\projects" -MemoryDirectoryName memory -Quiet
#>
[CmdletBinding()]
param(
  [string] $ProjectsDir,
  [string] $MemoryDirectoryName = 'memory',
  [string] $StableRoot,
  [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-LexicalFullPath {
  param([Parameter(Mandatory)] [string] $Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path must not be empty' }
  $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  return [IO.Path]::GetFullPath($providerPath)
}

function Get-ParentDirectoryPath {
  param([Parameter(Mandatory)] [string] $Path)

  $parent = [IO.Path]::GetDirectoryName($Path)
  if ([string]::IsNullOrWhiteSpace($parent)) {
    $root = [IO.Path]::GetPathRoot($Path)
    return if ([string]::IsNullOrWhiteSpace($root)) { $Path } else { $root }
  }
  return $parent
}

function Resolve-LinkTarget {
  param([Parameter(Mandatory)] [System.IO.FileSystemInfo] $Item)

  # .Target can be null/empty on macOS for system symlinks (e.g. /var).
  # Fall back to .LinkTarget (PS 7+) then readlink(1).
  $targets = @($Item.Target)
  if ($targets.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string] $targets[0])) {
    return [string] $targets[0]
  }
  if ($Item.PSObject.Properties['LinkTarget'] -and
      -not [string]::IsNullOrWhiteSpace($Item.LinkTarget)) {
    return [string] $Item.LinkTarget
  }
  if (-not $IsWindows) {
    $rl = & readlink $Item.FullName 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($rl)) {
      return $rl.Trim()
    }
  }
  return $null
}

function Get-NormalizedFullPath {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [switch] $PreserveLeaf,
    [int] $LinkDepth = 0
  )

  if ($LinkDepth -gt 40) { throw "too many directory links while resolving: $Path" }
  $full = Get-LexicalFullPath $Path
  $root = [IO.Path]::GetPathRoot($full)
  if ([string]::IsNullOrEmpty($root)) { throw "path has no filesystem root: $Path" }
  $relative = [IO.Path]::GetRelativePath($root, $full)
  if ($relative -eq '.') { return $full }

  $separators = [char[]] @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $parts = @($relative.Split($separators, [StringSplitOptions]::RemoveEmptyEntries))
  $resolveCount = $parts.Count
  if ($PreserveLeaf -and $resolveCount -gt 0) { $resolveCount-- }
  $current = $root
  for ($i = 0; $i -lt $parts.Count; $i++) {
    $candidate = Get-LexicalFullPath (Join-Path $current $parts[$i])
    if ($i -ge $resolveCount) {
      $current = $candidate
      continue
    }
    try {
      $component = Get-Item -LiteralPath $candidate -Force
    } catch [Management.Automation.ItemNotFoundException] {
      $current = $candidate
      for ($j = $i + 1; $j -lt $parts.Count; $j++) {
        $current = Get-LexicalFullPath (Join-Path $current $parts[$j])
      }
      break
    }
    if ($component.LinkType -in @('Junction', 'SymbolicLink')) {
      $target = Resolve-LinkTarget $component
      if ([string]::IsNullOrWhiteSpace($target)) {
        throw "link has no single readable target: $candidate"
      }
      if (-not [IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Get-ParentDirectoryPath $component.FullName) $target
      }
      $current = Get-NormalizedFullPath -Path $target -LinkDepth ($LinkDepth + 1)
    } else {
      $current = $candidate
    }
  }
  return Get-LexicalFullPath $current
}

function Get-ItemIfExists {
  param([Parameter(Mandatory)] [string] $Path)
  try {
    return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  } catch [Management.Automation.ItemNotFoundException] {
    return $null
  }
}

function Get-PathComparison {
  if ($IsWindows) { return [StringComparison]::OrdinalIgnoreCase }
  return [StringComparison]::Ordinal
}

function Test-PathEqual {
  param([Parameter(Mandatory)] [string] $Left, [Parameter(Mandatory)] [string] $Right)
  return [string]::Equals(
    (Get-LexicalFullPath $Left),
    (Get-LexicalFullPath $Right),
    (Get-PathComparison)
  )
}

function Test-IsFileSystemRoot {
  param([Parameter(Mandatory)] [string] $Path)
  $full = Get-LexicalFullPath $Path
  $root = [IO.Path]::GetPathRoot($full)
  return -not [string]::IsNullOrEmpty($root) -and (Test-PathEqual $full $root)
}

function Test-PathInside {
  param(
    [Parameter(Mandatory)] [string] $Child,
    [Parameter(Mandatory)] [string] $Parent,
    [switch] $AllowEqual
  )
  $childFull = Get-LexicalFullPath $Child
  $parentFull = Get-LexicalFullPath $Parent
  if ($AllowEqual -and (Test-PathEqual $childFull $parentFull)) { return $true }
  $prefix = $parentFull.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  ) + [IO.Path]::DirectorySeparatorChar
  return $childFull.StartsWith($prefix, (Get-PathComparison))
}

function Assert-SafeMemoryDirectoryName {
  param([Parameter(Mandatory)] [string] $Value)
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -in @('.', '..') -or
      [IO.Path]::IsPathRooted($Value) -or $Value.Contains('/') -or $Value.Contains('\') -or
      $Value.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw 'MemoryDirectoryName must be one safe path segment'
  }
}

function Get-LinkTargetPath {
  param([Parameter(Mandatory)] [System.IO.FileSystemInfo] $Item)
  if ($Item.LinkType -notin @('Junction', 'SymbolicLink')) {
    throw 'not a supported directory link'
  }
  $target = Resolve-LinkTarget $Item
  if ([string]::IsNullOrWhiteSpace($target)) {
    throw 'link has no single readable target'
  }
  if (-not [IO.Path]::IsPathRooted($target)) {
    $target = Join-Path $Item.DirectoryName $target
  }
  return Get-NormalizedFullPath $target
}

function Get-ContentSummary {
  param([Parameter(Mandatory)] [string] $Path)
  $root = Get-Item -LiteralPath $Path -Force
  if (-not $root.PSIsContainer) { throw 'target is not a directory' }
  $items = @(Get-ChildItem -LiteralPath $Path -Force -Recurse)
  # Reading file metadata ensures inaccessible trees do not get a green result.
  foreach ($item in $items) {
    [void] $item.Attributes
    if ($item.LinkType -in @('Junction', 'SymbolicLink')) {
      [void] (Get-LinkTargetPath $item)
    } elseif (-not $item.PSIsContainer) {
      # A metadata-only walk can make unreadable or unhydrated files look safe.
      # Hashing forces a complete read and turns that condition into exit 1.
      [void] (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256)
    }
  }
  return [pscustomobject]@{
    Items = $items.Count
    Files = @($items | Where-Object { -not $_.PSIsContainer }).Count
  }
}

try {
  if ([string]::IsNullOrWhiteSpace($ProjectsDir)) {
    $userHome = if ([string]::IsNullOrWhiteSpace($HOME)) { $env:HOME } else { $HOME }
    if ([string]::IsNullOrWhiteSpace($userHome)) {
      $userHome = [System.Environment]::GetFolderPath('UserProfile')
    }
    if ([string]::IsNullOrWhiteSpace($userHome)) {
      $userHome = if ($IsWindows) { 'C:\Users\Default' } else { '/tmp' }
    }
    $ProjectsDir = Join-Path (Join-Path $userHome '.claude') 'projects'
  }
  Assert-SafeMemoryDirectoryName $MemoryDirectoryName
  $projectsRoot = Get-NormalizedFullPath $ProjectsDir
  $stableRootFull = if ($StableRoot) { Get-NormalizedFullPath $StableRoot } else { $null }
  if (Test-IsFileSystemRoot $projectsRoot) {
    throw 'ProjectsDir must not be a filesystem root'
  }
} catch {
  Write-Host "error: invalid argument: $($_.Exception.Message)"
  exit 2
}

try {
  $projectsItem = Get-ItemIfExists $projectsRoot
  $stableItem = if ($stableRootFull) { Get-ItemIfExists $stableRootFull } else { $null }
} catch {
  Write-Host "error: a scan root cannot be inspected: $($_.Exception.Message)"
  exit 2
}
if (-not $projectsItem -or -not $projectsItem.PSIsContainer) {
  Write-Host "No legacy/default agent projects directory at: $projectsRoot"
  Write-Host 'Point at the right one with -ProjectsDir.'
  exit 2
}
if ($stableRootFull) {
  if (-not $stableItem -or -not $stableItem.PSIsContainer) {
    Write-Host "error: StableRoot is missing or is not a directory: $stableRootFull"
    exit 2
  }
}

$atRisk = 0
$orphans = 0
$unverified = 0
$verified = 0
$total = 0

Write-Host 'agent-ops - memory doctor (legacy/default-layout scan)'
Write-Host "projects: $projectsRoot"
if ($stableRootFull) {
  Write-Host "verified stable root: $stableRootFull"
} else {
  Write-Host 'stable root: not supplied (live links will be UNVERIFIED)'
}
Write-Host 'Confirm Claude Code''s active path with /memory or /context.'
Write-Host ''

try {
  $projects = @(Get-ChildItem -LiteralPath $projectsRoot -Force -Directory)
} catch {
  Write-Host "error: cannot enumerate projects: $($_.Exception.Message)"
  exit 1
}

foreach ($project in $projects) {
  $slug = $project.Name
  $mem = Get-NormalizedFullPath (Join-Path $project.FullName $MemoryDirectoryName) -PreserveLeaf
  $total++
  try {
    $item = Get-ItemIfExists $mem
  } catch {
    $atRisk++
    '  {0,-11} {1,-40} memory path cannot be inspected: {2}' -f 'AT RISK', $slug, $_.Exception.Message | Write-Host
    continue
  }

  if (-not $item) {
    if (-not $Quiet) {
      '  {0,-11} {1,-40} no memory directory yet' -f '-', $slug | Write-Host
    }
    continue
  }

  if ($item.LinkType -in @('Junction', 'SymbolicLink')) {
    $target = $null
    try {
      $target = Get-LinkTargetPath $item
      $targetItem = Get-ItemIfExists $target
      if (-not $targetItem -or -not $targetItem.PSIsContainer) {
        throw 'target missing or not a directory'
      }
      $summary = Get-ContentSummary $target
    } catch {
      $orphans++
      '  {0,-11} {1,-40} -> {2} ({3})' -f 'ORPHAN', $slug, ($target ?? '<unreadable>'), $_.Exception.Message | Write-Host
      continue
    }

    if (Test-PathInside -Child $target -Parent $projectsRoot -AllowEqual) {
      $atRisk++
      '  {0,-11} {1,-40} -> {2} (inside legacy projects layout; {3} item(s))' -f 'AT RISK', $slug, $target, $summary.Items | Write-Host
      continue
    }

    if (-not $stableRootFull) {
      $unverified++
      '  {0,-11} {1,-40} -> {2} (target exists; stability not verified; {3} item(s))' -f 'UNVERIFIED', $slug, $target, $summary.Items | Write-Host
      continue
    }

    if (Test-PathInside -Child $target -Parent $stableRootFull -AllowEqual) {
      $verified++
      if (-not $Quiet) {
        '  {0,-11} {1,-40} -> {2} ({3} item(s))' -f 'OK', $slug, $target, $summary.Items | Write-Host
      }
    } else {
      $atRisk++
      '  {0,-11} {1,-40} -> {2} (outside StableRoot; {3} item(s))' -f 'AT RISK', $slug, $target, $summary.Items | Write-Host
    }
    continue
  }

  if (-not $item.PSIsContainer) {
    $atRisk++
    '  {0,-11} {1,-40} memory path is not a directory' -f 'AT RISK', $slug | Write-Host
    continue
  }

  try {
    $summary = Get-ContentSummary $mem
  } catch {
    $atRisk++
    '  {0,-11} {1,-40} real directory is unreadable: {2}' -f 'AT RISK', $slug, $_.Exception.Message | Write-Host
    continue
  }
  if ($summary.Items -gt 0) {
    $atRisk++
    '  {0,-11} {1,-40} real directory, {2} item(s)' -f 'AT RISK', $slug, $summary.Items | Write-Host
  } elseif (-not $Quiet) {
    '  {0,-11} {1,-40} real directory, empty' -f 'empty', $slug | Write-Host
  }
}

Write-Host ''
Write-Host "$total project(s): $verified verified, $unverified unverified, $atRisk at risk, $orphans orphaned."

if ($unverified -gt 0) {
  Write-Host @'

UNVERIFIED - the link target exists and is readable, but no trusted stable root
was supplied. Re-run with -StableRoot <store-root> to verify containment and earn
an OK result. Until then the audit intentionally returns exit code 1.
'@
}
if ($atRisk -gt 0) {
  Write-Host @'

AT RISK - data is still in the path-derived legacy/default layout, the link
points back into that layout, or the target falls outside the requested stable
root. Confirm the active path with /memory or /context before migrating it.
'@
}
if ($orphans -gt 0) {
  Write-Host @'

ORPHAN - the link target is missing, is not a directory, or cannot be read.
Restore/mount the target before allowing an agent to write memory.
'@
}

if ($atRisk -gt 0 -or $orphans -gt 0 -or $unverified -gt 0) { exit 1 }
exit 0
