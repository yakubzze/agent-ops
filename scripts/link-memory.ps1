<#
.SYNOPSIS
  agent-ops - link-memory

.DESCRIPTION
  Copies every item in a legacy/default Claude Code project-memory directory to
  a stable store, verifies the copy, keeps the original as a timestamped backup,
  and links the original path to the store.

  Windows uses a directory junction (no administrator rights are required).
  Other platforms use a symbolic link.

  The operation refuses ambiguous or nested paths and never merges two non-empty
  directories. If a failure happens after mutation begins, the script attempts a
  transactional rollback.

  Exit codes:
    0  success / already linked / successful dry run
    1  unsafe or ambiguous existing state; nothing changed
    2  invalid input or missing prerequisite; nothing changed
    3  operation failed; rollback completed
    4  operation failed; rollback needs manual attention

.EXAMPLE
  pwsh ./scripts/link-memory.ps1 -Project c--git-my-app -Store "$HOME\agent-memory"
.EXAMPLE
  pwsh ./scripts/link-memory.ps1 -Project c--git-my-app -Store "$HOME\OneDrive\agent-memory" -Name my-app -DryRun

.NOTES
  This operates on the legacy/default <projects>/<slug>/memory layout. Confirm
  Claude Code's active memory path with /memory or /context before changing it.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Project,
  [Parameter(Mandatory)] [string] $Store,
  [string] $Name,
  [string] $ProjectsDir,
  [switch] $DryRun,

  # Deterministic fault injection for the repository's dependency-free tests.
  [Parameter(DontShow)]
  [ValidateSet('None', 'AfterDestinationReady', 'AfterSourceBackup', 'AfterLinkCreate')]
  [string] $TestFailurePoint = 'None'
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
      # Once a component is absent, the remaining lexical suffix cannot contain
      # an existing link. Preserve it for a later create operation.
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

  $separator = [IO.Path]::DirectorySeparatorChar
  $parentPrefix = $parentFull.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  ) + $separator
  return $childFull.StartsWith($parentPrefix, (Get-PathComparison))
}

function Assert-SafePathSegment {
  param([Parameter(Mandatory)] [string] $Value, [Parameter(Mandatory)] [string] $Label)

  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -in @('.', '..')) {
    throw "$Label must be one non-empty path segment"
  }
  if ([IO.Path]::IsPathRooted($Value) -or $Value.Contains('/') -or $Value.Contains('\')) {
    throw "$Label must be one path segment, not a path: $Value"
  }
  if ($Value.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw "$Label contains characters that are not valid in a file name: $Value"
  }
  if ($IsWindows -and ($Value.EndsWith(' ') -or $Value.EndsWith('.'))) {
    throw "$Label must not end with a space or dot on Windows: $Value"
  }
}

function Get-LinkTargetPath {
  param([Parameter(Mandatory)] [System.IO.FileSystemInfo] $Item)

  if ($Item.LinkType -notin @('Junction', 'SymbolicLink')) {
    throw "not a supported directory link: $($Item.FullName)"
  }
  $target = Resolve-LinkTarget $Item
  if ([string]::IsNullOrWhiteSpace($target)) {
    throw "link has no single readable target: $($Item.FullName)"
  }
  if (-not [IO.Path]::IsPathRooted($target)) {
    $target = Join-Path $Item.DirectoryName $target
  }
  return Get-NormalizedFullPath $target
}

function Get-ContentInventory {
  param([Parameter(Mandatory)] [string] $Root)

  $rootItem = Get-Item -LiteralPath $Root -Force
  if (-not $rootItem.PSIsContainer) {
    throw "not a directory: $Root"
  }

  $entries = [Collections.Generic.List[object]]::new()
  foreach ($entry in @(Get-ChildItem -LiteralPath $Root -Force -Recurse)) {
    if ($entry.LinkType -in @('Junction', 'SymbolicLink')) {
      throw "nested links are not migrated automatically: $($entry.FullName)"
    }

    $relative = [IO.Path]::GetRelativePath($rootItem.FullName, $entry.FullName)
    if ($entry.PSIsContainer) {
      $entries.Add([pscustomobject]@{
        Relative = $relative
        Kind = 'directory'
        Length = [int64] 0
        Hash = ''
      })
    } else {
      $hash = (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash
      $entries.Add([pscustomobject]@{
        Relative = $relative
        Kind = 'file'
        Length = [int64] $entry.Length
        Hash = $hash
      })
    }
  }
  return $entries
}

function Test-InventoriesEqual {
  param([object[]] $Expected, [object[]] $Actual)

  if ($Expected.Count -ne $Actual.Count) { return $false }
  $expectedSorted = @($Expected | Sort-Object -Property Relative, Kind)
  $actualSorted = @($Actual | Sort-Object -Property Relative, Kind)
  for ($i = 0; $i -lt $expectedSorted.Count; $i++) {
    $left = $expectedSorted[$i]
    $right = $actualSorted[$i]
    if (-not [string]::Equals($left.Relative, $right.Relative, (Get-PathComparison)) -or
        $left.Kind -ne $right.Kind -or
        $left.Length -ne $right.Length -or
        $left.Hash -ne $right.Hash) {
      return $false
    }
  }
  return $true
}

function New-UniqueSiblingPath {
  param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Tag)

  $parent = Get-ParentDirectoryPath $Path
  $leaf = Split-Path -Leaf $Path
  return Join-Path $parent ('.agent-ops-{0}-{1}-{2}' -f $Tag, $leaf, [guid]::NewGuid().ToString('N'))
}

function New-BackupContainerPath {
  param([Parameter(Mandatory)] [string] $Path)

  return '{0}.backup-{1}-{2}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), [guid]::NewGuid().ToString('N')
}

function Assert-TestFailurePoint {
  param([Parameter(Mandatory)] [string] $Point)
  if ($TestFailurePoint -eq $Point) {
    throw "injected test failure at $Point"
  }
}

function Invoke-LinkMemory {
  $exitCode = 0

  try {
    Assert-SafePathSegment -Value $Project -Label 'Project'
    if (-not $Name) { $script:Name = $Project }
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
    Assert-SafePathSegment -Value $Name -Label 'Name'

    $projectsRoot = Get-NormalizedFullPath $ProjectsDir
    $storeRoot = Get-NormalizedFullPath $Store
    $projectPath = Get-NormalizedFullPath (Join-Path $projectsRoot $Project) -PreserveLeaf
    $agentMem = Get-NormalizedFullPath (Join-Path $projectPath 'memory') -PreserveLeaf
    $dest = Get-NormalizedFullPath (Join-Path $storeRoot $Name) -PreserveLeaf

    if (Test-IsFileSystemRoot $projectsRoot) {
      throw 'ProjectsDir must not be a filesystem root'
    }
    if (Test-IsFileSystemRoot $storeRoot) {
      throw 'Store must not be a filesystem root'
    }

    if (-not (Test-PathInside -Child $projectPath -Parent $projectsRoot)) {
      throw 'the project path escapes ProjectsDir'
    }
    if (-not (Test-PathInside -Child $dest -Parent $storeRoot)) {
      throw 'the destination path escapes Store'
    }
  } catch {
    Write-Host "error: invalid path or argument: $($_.Exception.Message)"
    return 2
  }

  try {
    $projectItem = Get-ItemIfExists $projectPath
    $storeItem = Get-ItemIfExists $storeRoot
  } catch {
    Write-Host "error: a project or Store path cannot be inspected: $($_.Exception.Message)"
    return 2
  }
  if (-not $projectItem -or -not $projectItem.PSIsContainer) {
    Write-Host "error: no such project directory: $projectPath"
    return 2
  }
  if ($projectItem.LinkType -in @('Junction', 'SymbolicLink')) {
    Write-Host "error: project entries must be real directories, not links: $projectPath"
    return 2
  }

  if ($storeItem -and -not $storeItem.PSIsContainer) {
    Write-Host "error: Store is not a directory: $storeRoot"
    return 2
  }

  if ((Test-PathEqual $agentMem $dest) -or
      (Test-PathInside -Child $agentMem -Parent $dest) -or
      (Test-PathInside -Child $dest -Parent $agentMem)) {
    Write-Host 'REFUSING - source and destination are equal or nested.'
    Write-Host "  source      : $agentMem"
    Write-Host "  destination : $dest"
    return 1
  }
  if (Test-PathInside -Child $dest -Parent $projectsRoot -AllowEqual) {
    Write-Host 'REFUSING - the requested store is inside the legacy/default projects layout.'
    Write-Host "  projects : $projectsRoot"
    Write-Host "  target   : $dest"
    return 1
  }

  Write-Host 'agent-ops - link-memory (legacy/default-layout migration)'
  Write-Host "  agent memory : $agentMem"
  Write-Host "  store        : $dest"
  if ($DryRun) { Write-Host '  (dry run - nothing will be changed)' }
  Write-Host ''

  try {
    $sourceItem = Get-ItemIfExists $agentMem
    $destItem = Get-ItemIfExists $dest
  } catch {
    Write-Host "REFUSING - a source or destination path cannot be inspected: $($_.Exception.Message)"
    return 1
  }
  if ($sourceItem -and $sourceItem.LinkType -in @('Junction', 'SymbolicLink')) {
    try {
      $current = Get-LinkTargetPath $sourceItem
    } catch {
      Write-Host "error: existing memory link cannot be verified: $($_.Exception.Message)"
      return 1
    }

    if (-not (Test-PathEqual $current $dest)) {
      Write-Host 'REFUSING - memory is already linked somewhere else.'
      Write-Host "  current : $current"
      Write-Host "  wanted  : $dest"
      return 1
    }

    try { $currentTarget = Get-ItemIfExists $current } catch {
      Write-Host "error: the existing target cannot be inspected safely: $($_.Exception.Message)"
      return 1
    }
    if (-not $currentTarget -or -not $currentTarget.PSIsContainer) {
      Write-Host "error: the requested link already exists, but its target is missing or is not a directory: $current"
      return 1
    }
    try { [void] @(Get-ContentInventory $current) } catch {
      Write-Host "error: the existing target is not safely readable: $($_.Exception.Message)"
      return 1
    }
    Write-Host 'Already linked to the requested, verified directory. Nothing to do.'
    return 0
  }

  if ($sourceItem -and -not $sourceItem.PSIsContainer) {
    Write-Host "REFUSING - the memory path exists but is not a directory: $agentMem"
    return 1
  }

  if ($destItem -and ($destItem.LinkType -in @('Junction', 'SymbolicLink') -or -not $destItem.PSIsContainer)) {
    Write-Host "REFUSING - destination must be a real directory, not a file or another link: $dest"
    return 1
  }

  try {
    $sourceInventory = @(if ($sourceItem) { Get-ContentInventory $agentMem })
    $destInventory = @(if ($destItem) { Get-ContentInventory $dest })
  } catch {
    Write-Host "REFUSING - contents could not be inventoried safely: $($_.Exception.Message)"
    return 1
  }

  if ($sourceInventory.Count -gt 0 -and $destInventory.Count -gt 0) {
    Write-Host 'REFUSING - both sides contain data.'
    Write-Host "  $agentMem"
    Write-Host "      $($sourceInventory.Count) item(s)"
    Write-Host "  $dest"
    Write-Host "      $($destInventory.Count) item(s)"
    Write-Host ''
    Write-Host 'Nothing was compared or overwritten. Merge deliberately, then re-run.'
    return 1
  }

  if ($DryRun) {
    if ($sourceInventory.Count -gt 0) {
      Write-Host "  would stage, copy, and verify all $($sourceInventory.Count) source item(s)"
    } else {
      Write-Host '  source has no items to copy'
    }
    if ($sourceItem) { Write-Host '  would retain the original directory as a timestamped backup' }
    Write-Host "  would create a verified directory link: $agentMem -> $dest"
    Write-Host ''
    Write-Host 'Dry run complete.'
    return 0
  }

  $committed = $false
  $mutationStarted = $false
  $sourceBackedUp = $false
  $linkCreated = $false
  $destCreatedByUs = $false
  $destReplacedEmpty = $false
  $storeCreatedByUs = $false
  $backup = $null
  $backupContainer = $null
  $stage = New-UniqueSiblingPath -Path $dest -Tag 'stage'
  $emptyDestHold = $null
  $emptyDestHoldContainer = $null
  $heldDestInventory = @()
  $failure = $null
  $rollbackProblems = [Collections.Generic.List[string]]::new()

  try {
    if (-not $storeItem) {
      New-Item -ItemType Directory -Path $storeRoot | Out-Null
      $storeCreatedByUs = $true
      $mutationStarted = $true
    }

    # Re-resolve both the originally requested path and the physical path after
    # Store exists. This closes the pre-create gap where an existing ancestor or
    # the newly-created directory could be replaced with a junction/symlink.
    $requestedStoreNow = Get-NormalizedFullPath $Store
    $physicalStoreNow = Get-NormalizedFullPath $storeRoot
    if (-not (Test-PathEqual $requestedStoreNow $storeRoot) -or
        -not (Test-PathEqual $physicalStoreNow $storeRoot)) {
      throw 'Store resolved to a different physical location after creation; refusing the race'
    }
    if (Test-PathInside -Child $physicalStoreNow -Parent $projectsRoot -AllowEqual) {
      throw 'Store resolves inside the legacy/default projects layout after creation'
    }
    $destNowPath = Get-NormalizedFullPath (Join-Path $physicalStoreNow $Name) -PreserveLeaf
    if (-not (Test-PathEqual $destNowPath $dest)) {
      throw 'destination resolved to a different physical path after Store creation'
    }
    $destNowItem = Get-ItemIfExists $dest
    if ([bool] $destNowItem -ne [bool] $destItem) {
      throw 'destination appeared or disappeared during preflight'
    }
    if ($destNowItem -and
        ($destNowItem.LinkType -in @('Junction', 'SymbolicLink') -or -not $destNowItem.PSIsContainer)) {
      throw 'destination became a file or link during preflight'
    }
    if ($destNowItem) {
      $destNowInventory = @(Get-ContentInventory $dest)
      if (-not (Test-InventoriesEqual $destInventory $destNowInventory)) {
        throw 'destination contents changed during preflight'
      }
    }

    if ($sourceInventory.Count -gt 0) {
      New-Item -ItemType Directory -Path $stage | Out-Null
      $mutationStarted = $true
      foreach ($child in @(Get-ChildItem -LiteralPath $agentMem -Force)) {
        Copy-Item -LiteralPath $child.FullName -Destination $stage -Recurse -Force
      }

      $sourceAfterCopy = @(Get-ContentInventory $agentMem)
      $stageInventory = @(Get-ContentInventory $stage)
      if (-not (Test-InventoriesEqual $sourceInventory $sourceAfterCopy)) {
        throw 'source changed while it was being copied'
      }
      if (-not (Test-InventoriesEqual $sourceInventory $stageInventory)) {
        throw 'staged copy does not exactly match the source inventory'
      }

      if ($destItem) {
        $emptyDestHoldContainer = New-UniqueSiblingPath -Path $dest -Tag 'empty'
        New-Item -ItemType Directory -Path $emptyDestHoldContainer | Out-Null
        $emptyDestHold = Join-Path $emptyDestHoldContainer 'original'
        if (Get-ItemIfExists $emptyDestHold) {
          throw 'reserved destination rollback path was unexpectedly occupied'
        }
        Move-Item -LiteralPath $dest -Destination $emptyDestHold
        $destReplacedEmpty = $true
        $heldDestInventory = @(Get-ContentInventory $emptyDestHold)
        if ($heldDestInventory.Count -gt 0) {
          throw 'destination gained content before it was preserved; refusing to discard it'
        }
      }
      Move-Item -LiteralPath $stage -Destination $dest
      $destCreatedByUs = $true
    } elseif (-not $destItem) {
      New-Item -ItemType Directory -Path $dest | Out-Null
      $destCreatedByUs = $true
      $mutationStarted = $true
    }

    $readyInventory = @(Get-ContentInventory $dest)
    if ($sourceInventory.Count -gt 0 -and -not (Test-InventoriesEqual $sourceInventory $readyInventory)) {
      throw 'destination verification failed before the source was changed'
    }
    Assert-TestFailurePoint 'AfterDestinationReady'

    if ($sourceItem) {
      $backupContainer = New-BackupContainerPath $agentMem
      New-Item -ItemType Directory -Path $backupContainer | Out-Null
      $mutationStarted = $true
      $backup = Join-Path $backupContainer 'memory'
      if (Get-ItemIfExists $backup) {
        throw 'reserved backup path was unexpectedly occupied'
      }
      Move-Item -LiteralPath $agentMem -Destination $backup
      $sourceBackedUp = $true
      Write-Host "Keeping the original at: $backup"
      $backupInventory = @(Get-ContentInventory $backup)
      if (-not (Test-InventoriesEqual $sourceInventory $backupInventory)) {
        throw 'source changed between copy verification and backup; refusing to publish an incomplete target'
      }
    }
    Assert-TestFailurePoint 'AfterSourceBackup'

    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    # Mark the attempt before calling New-Item: a provider can create the link
    # and still throw, and that partial mutation must also be rolled back.
    $linkCreated = $true
    $mutationStarted = $true
    New-Item -ItemType $linkType -Path $agentMem -Target $dest | Out-Null
    Assert-TestFailurePoint 'AfterLinkCreate'

    $check = Get-Item -LiteralPath $agentMem -Force
    $checkTarget = Get-LinkTargetPath $check
    if (-not (Test-PathEqual $checkTarget $dest)) {
      throw "created link points to an unexpected target: $checkTarget"
    }
    $targetItem = Get-Item -LiteralPath $checkTarget -Force
    if (-not $targetItem.PSIsContainer) {
      throw 'created link target is not a directory'
    }
    $linkedInventory = @(Get-ContentInventory $agentMem)
    if (-not (Test-InventoriesEqual $readyInventory $linkedInventory)) {
      throw 'content reachable through the new link differs from the verified destination'
    }

    if ($destReplacedEmpty -and (Get-ItemIfExists $emptyDestHold)) {
      $heldNowInventory = @(Get-ContentInventory $emptyDestHold)
      if (-not (Test-InventoriesEqual $heldDestInventory $heldNowInventory) -or $heldNowInventory.Count -gt 0) {
        throw 'preserved destination changed during the transaction; refusing to discard it'
      }
      Remove-Item -LiteralPath $emptyDestHold -Force
      Remove-Item -LiteralPath $emptyDestHoldContainer -Force
      $destReplacedEmpty = $false
    }
    $committed = $true
  } catch {
    $failure = $_
  } finally {
    if (-not $committed -and $mutationStarted) {
      # Restore the source first. Until this succeeds, the destination may be the
      # only complete copy and must not be removed.
      try {
        $sourceNow = Get-ItemIfExists $agentMem
        if ($sourceNow -and $sourceNow.LinkType -in @('Junction', 'SymbolicLink')) {
          $sourceNowTarget = Get-LinkTargetPath $sourceNow
          if ($linkCreated -and (Test-PathEqual $sourceNowTarget $dest)) {
            Remove-Item -LiteralPath $agentMem -Force
          } else {
            throw 'an unexpected link occupies the source path'
          }
        } elseif ($sourceNow -and $sourceBackedUp) {
          throw 'an unexpected item occupies the source path'
        }

        if ($sourceBackedUp) {
          if (-not (Get-ItemIfExists $backup)) {
            throw "source backup is missing: $backup"
          }
          $restoreInventory = @(Get-ContentInventory $backup)
          Move-Item -LiteralPath $backup -Destination $agentMem
          $sourceBackedUp = $false
          $restoredInventory = @(Get-ContentInventory $agentMem)
          if (-not (Test-InventoriesEqual $restoreInventory $restoredInventory)) {
            throw 'restored source inventory differs from the reserved backup'
          }
        }

        if ($backupContainer -and (Get-ItemIfExists $backupContainer)) {
          if (Get-ItemIfExists $backup) {
            throw "backup payload remains safely at: $backup"
          }
          if (@(Get-ChildItem -LiteralPath $backupContainer -Force -ErrorAction Stop).Count -gt 0) {
            throw "backup container gained unexpected content: $backupContainer"
          }
          Remove-Item -LiteralPath $backupContainer -Force
        }
      } catch {
        $rollbackProblems.Add("source: $($_.Exception.Message)")
      }

      if ($rollbackProblems.Count -eq 0) {
        try {
          if ($destCreatedByUs -and (Get-ItemIfExists $dest)) {
            $currentDestInventory = @(Get-ContentInventory $dest)
            $expectedDestInventory = @($sourceInventory)
            if (-not (Test-InventoriesEqual $expectedDestInventory $currentDestInventory)) {
              throw 'destination changed after creation; preserved it for manual recovery'
            }
            Remove-Item -LiteralPath $dest -Recurse -Force
            $destCreatedByUs = $false
          }
          if ($destReplacedEmpty -and (Get-ItemIfExists $emptyDestHold)) {
            if (Get-ItemIfExists $dest) {
              throw 'cannot restore the original empty destination because its path is occupied'
            }
            $restoreDestInventory = @(Get-ContentInventory $emptyDestHold)
            Move-Item -LiteralPath $emptyDestHold -Destination $dest
            $destReplacedEmpty = $false
            $restoredDestInventory = @(Get-ContentInventory $dest)
            if (-not (Test-InventoriesEqual $restoreDestInventory $restoredDestInventory)) {
              throw 'restored destination inventory differs from its reserved copy'
            }
          }
          if ($emptyDestHoldContainer -and (Get-ItemIfExists $emptyDestHoldContainer)) {
            if ($emptyDestHold -and (Get-ItemIfExists $emptyDestHold)) {
              throw "preserved destination remains safely at: $emptyDestHold"
            }
            if (@(Get-ChildItem -LiteralPath $emptyDestHoldContainer -Force -ErrorAction Stop).Count -gt 0) {
              throw "destination rollback container gained unexpected content: $emptyDestHoldContainer"
            }
            Remove-Item -LiteralPath $emptyDestHoldContainer -Force
          }
          if (Get-ItemIfExists $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force
          }
          if ($storeCreatedByUs -and (Get-ItemIfExists $storeRoot)) {
            if (@(Get-ChildItem -LiteralPath $storeRoot -Force).Count -eq 0) {
              Remove-Item -LiteralPath $storeRoot -Force
            }
          }
        } catch {
          $rollbackProblems.Add("destination: $($_.Exception.Message)")
        }
      }
    }
  }

  if (-not $committed) {
    Write-Host "error: $($failure.Exception.Message)"
    if ($rollbackProblems.Count -eq 0) {
      Write-Host 'Rollback complete: the original source state was restored.'
      return 3
    }
    Write-Host 'ROLLBACK INCOMPLETE - manual attention is required:'
    foreach ($problem in $rollbackProblems) { Write-Host "  $problem" }
    if ($backup) { Write-Host "  backup candidate: $backup" }
    Write-Host "  destination     : $dest"
    return 4
  }

  Write-Host ''
  Write-Host "Linked and verified. $($readyInventory.Count) item(s) are reachable through the agent path."
  Write-Host 'Verify stability with: pwsh ./scripts/memory-doctor.ps1 -StableRoot <store-root>'
  return $exitCode
}

exit (Invoke-LinkMemory)
