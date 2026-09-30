<#
.SYNOPSIS
  agent-ops - memory doctor

.DESCRIPTION
  Audits the legacy/default <projects>/<slug>/memory layout. It still does not
  reproduce Claude Code settings precedence or workspace-trust decisions, so the
  active path for a session is whatever /memory or /context reports.

  A plain non-empty memory directory is at risk. A missing/broken/non-directory
  link is orphaned. A link whose target exists and is a directory, but whose
  content cannot be fully read - a permission error, or a cloud placeholder that
  failed to download - is UNREADABLE: not missing, and never to be recreated. A
  live external link is reported as UNVERIFIED unless -StableRoot is supplied;
  only containment in that root earns an OK result. A link back inside
  ProjectsDir is always at risk.

  It additionally inspects the .claude settings of -ProjectDir (the current
  directory by default) and reports a declared autoMemoryDirectory that CANNOT
  work, without claiming to know which setting wins:
    - a relative value, which the agent ignores in favour of the derived layout
    - an absolute value pointing at a directory that does not exist
    - an absolute value written in a settings file that is itself inside a
      synced folder, which cannot be correct on two machines at once
  Use -SkipSettingsCheck to audit the on-disk layout only.

  -Hook is for a session-start hook. It implies -Quiet, prints nothing when the
  result is healthy, and otherwise prints a compact UTF-8 report whose last line
  names the exit code a manual run returns. It exits 0 once the script runs:
  Claude Code adds a SessionStart hook's plain-text stdout to the agent's
  context only on exit 0 (Claude Code 2.1.283 hooks reference, read
  2026-09-30), so a non-zero code would drop the very diagnosis the hook exists
  to deliver. An unknown parameter is reported that way too. A
  parameter PowerShell cannot bind at all - a missing value, or an ambiguous
  abbreviation - fails before the script runs, and Claude Code shows only a
  hook error.

  Exit codes (without -Hook):
    0  every discovered memory path is verified OK (or no memory exists)
    1  at-risk, orphaned, unreadable, or unverified memory exists
    2  invalid input (including an unknown parameter) or missing scan directory

.EXAMPLE
  pwsh ./scripts/memory-doctor.ps1 -StableRoot "$HOME\agent-memory"
.EXAMPLE
  pwsh -NoProfile -File ./scripts/memory-doctor.ps1 -Hook -StableRoot "$HOME\agent-memory"
.EXAMPLE
  pwsh ./scripts/memory-doctor.ps1 -ProjectsDir "$HOME\.some-agent\projects" -MemoryDirectoryName memory -Quiet
.EXAMPLE
  pwsh ./scripts/memory-doctor.ps1 -ProjectDir C:\git\my-app,C:\git\other-app
#>
[CmdletBinding()]
param(
  [string] $ProjectsDir,
  [string] $MemoryDirectoryName = 'memory',
  [string] $StableRoot,
  [string[]] $ProjectDir = @('.'),
  [switch] $SkipSettingsCheck,
  [switch] $Quiet,
  [switch] $Hook,
  # Catches a misspelled parameter name, so that it is reported like any other
  # invalid input (and, under -Hook, reaches the session) instead of failing in
  # parameter binding before the script can say anything.
  [Parameter(ValueFromRemainingArguments)] [string[]] $UnexpectedArgument
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Hook mode holds every line back and decides at the end: nothing when healthy,
# a compact report otherwise, and exit 0 either way (see Complete-Doctor).
$script:HookMode = $Hook.IsPresent
if ($script:HookMode) { $Quiet = [switch] $true }
$script:HookLines = [Collections.Generic.List[string]]::new()
$script:HookSection = $null
$script:Completing = $false
$script:BoundArguments = $PSBoundParameters
$script:SkipSettingsRequested = $SkipSettingsCheck.IsPresent
$script:ScriptPath = $PSCommandPath

# The hook report lands in the context of every session, and Claude Code 2.1.283
# keeps a hook's plain stdout whole only up to 10,000 characters (hooks
# reference, read 2026-09-30); past that, Claude gets a 2,000-character preview.
# This many problem lines keeps even long paths well inside the limit; the full
# report lists the rest.
$script:HookMaxLines = 12

function Write-Line {
  # Banner, healthy entries, blank lines and long legends: the full report only.
  param([Parameter(ValueFromPipeline)] [AllowEmptyString()] [string] $Text = '')
  process {
    if (-not $script:HookMode) { Write-Host $Text }
  }
}

function Write-Entry {
  # A line that needs attention. Hook mode keeps it for the compact report,
  # exactly as -Quiet prints it; a section header travels with its first line.
  param(
    [Parameter(Mandatory, ValueFromPipeline)] [AllowEmptyString()] [string] $Text,
    [string] $Section
  )
  process {
    if (-not $script:HookMode) {
      Write-Host $Text
      return
    }
    if ($Section -and $Section -ne $script:HookSection) {
      $script:HookLines.Add($Section)
      $script:HookSection = $Section
    }
    $script:HookLines.Add($Text)
  }
}

# PowerShell ends a single-quoted string at any of these, not only at U+0027.
$script:SingleQuoteChars = [char[]] @(0x27, 0x2018, 0x2019, 0x201A, 0x201B)
$script:DoubleQuoteChars = [char[]] @(0x22, 0x201C, 0x201D, 0x201E)

function Format-PowerShellLiteral {
  param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
  return "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'"
}

function Format-CommandArgument {
  <#
  Quotes one argument of the printed full-report command so the line runs as
  written in PowerShell and in a POSIX shell alike. An agent on Windows may paste
  it into Git Bash, which strips an unquoted backslash: C:\git\agent-ops arrives
  as C:gitagent-ops. Single quotes are literal in both shells, so they are the
  default. An apostrophe cannot be escaped the same way in both; such a value
  goes in double quotes when nothing inside is special to either shell, and
  falls back to PowerShell's own escaping otherwise.
  #>
  param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
  if ($Value -cmatch '^[A-Za-z0-9_./:=@%+,-]+$') { return $Value }
  if ($Value.IndexOfAny($script:SingleQuoteChars) -lt 0) { return "'$Value'" }
  if ($Value.IndexOfAny($script:DoubleQuoteChars) -lt 0 -and $Value -notmatch '[$`!]|\\\\|\\$') {
    return '"' + $Value + '"'
  }
  return Format-PowerShellLiteral $Value
}

function Get-FullReportCommand {
  # The same audit without -Hook, so the agent can ask for the long form.
  $names = @('ProjectsDir', 'MemoryDirectoryName', 'StableRoot', 'ProjectDir')
  $projectDirs = @(if ($script:BoundArguments.ContainsKey('ProjectDir')) { $script:BoundArguments['ProjectDir'] })
  if ($projectDirs.Count -le 1) {
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('pwsh -NoProfile -File')
    $parts.Add((Format-CommandArgument $script:ScriptPath))
    foreach ($name in $names) {
      if ($script:BoundArguments.ContainsKey($name)) {
        $parts.Add("-$name")
        $parts.Add((Format-CommandArgument ([string] @($script:BoundArguments[$name])[0])))
      }
    }
    if ($script:SkipSettingsRequested) { $parts.Add('-SkipSettingsCheck') }
    return $parts -join ' '
  }

  # pwsh -File hands the script every value as one string, so 'a,b' would be
  # audited as a single path that does not exist. Several -ProjectDir values
  # need -Command, whose exit code is only 0 or 1; the report line names the
  # real one. The outer double quotes keep the line usable in a POSIX shell too,
  # unless a path contains $, a backtick or a double quote.
  $inner = [Collections.Generic.List[string]]::new()
  $inner.Add('&')
  $inner.Add((Format-PowerShellLiteral $script:ScriptPath))
  foreach ($name in $names) {
    if ($script:BoundArguments.ContainsKey($name)) {
      $inner.Add("-$name")
      $inner.Add((@($script:BoundArguments[$name] | ForEach-Object { Format-PowerShellLiteral ([string] $_) }) -join ','))
    }
  }
  if ($script:SkipSettingsRequested) { $inner.Add('-SkipSettingsCheck') }
  return 'pwsh -NoProfile -Command "' + ($inner -join ' ') + '"'
}

function Write-HookReport {
  param([Parameter(Mandatory)] [string[]] $Lines)
  $text = ($Lines -join "`n") + "`n"
  if (-not [Console]::IsOutputRedirected) {
    Write-Host -NoNewline $text
    return
  }
  # Redirected output from PowerShell is encoded in the console code page, which
  # on a Polish Windows is ibm852 (measured 2026-09-30): a localized error
  # message or a non-ASCII path reaches the agent garbled. Write UTF-8 bytes
  # straight to stdout, and leave the console's own code page alone.
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
  $stdout = [Console]::OpenStandardOutput()
  $stdout.Write($bytes, 0, $bytes.Length)
  $stdout.Flush()
}

function Complete-Doctor {
  <#
  The only way out once arguments are bound. Without -Hook it exits with $Code.
  With -Hook it exits 0 whatever the verdict: Claude Code adds a SessionStart
  hook's plain-text stdout to the agent's context only on exit 0, and on any
  other code the report is dropped and at most a one-line hook error remains.
  Measured on 2026-09-30: the doctor exited 1 at every session start, correctly,
  and dangling memory links still went unnoticed for weeks.
  #>
  param(
    [Parameter(Mandatory)] [int] $Code,
    [string[]] $Summary = @(),
    [string[]] $Legend = @()
  )
  if (-not $script:HookMode) { exit $Code }
  $script:Completing = $true
  if ($Code -ne 0) {
    $report = [Collections.Generic.List[string]]::new()
    if ($Code -eq 2) {
      $report.Add('agent-ops memory doctor: agent memory needs attention; the audit could not run.')
    } else {
      $report.Add('agent-ops memory doctor: agent memory needs attention.')
    }
    $entries = @($script:HookLines)
    foreach ($line in @($entries | Select-Object -First $script:HookMaxLines)) { $report.Add($line) }
    if ($entries.Count -gt $script:HookMaxLines) {
      $report.Add("... and $($entries.Count - $script:HookMaxLines) more line(s); the full report lists every entry.")
    }
    foreach ($line in @($Summary) + @($Legend)) { $report.Add($line) }
    $report.Add("A manual run exits $Code. Full report: $(Get-FullReportCommand)")
    Write-HookReport $report
  }
  exit 0
}

# An unexpected terminating error ends a manual run with exit 1 and a message on
# stderr - both of which a hook would lose. Hook mode reports it instead, unless
# the failure is in writing that report, where only the plain error is left.
trap {
  if ($script:HookMode -and -not $script:Completing) {
    Write-Entry "error: $($_.Exception.Message)"
    Complete-Doctor -Code 1
  }
  break
}

if ($null -ne $UnexpectedArgument -and $UnexpectedArgument.Count -gt 0) {
  Write-Entry "error: unknown argument: $($UnexpectedArgument -join ' ')"
  Complete-Doctor -Code 2
}

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

# Directory names used by the consumer sync clients. A settings file living under
# one of these is copied to every other machine verbatim, so an absolute path
# written into it can only ever be correct on the machine that wrote it.
$script:SyncMarkers = @(
  'Mobile Documents', 'com~apple~CloudDocs', 'iCloudDrive', 'iCloud Drive',
  'Dropbox', 'OneDrive', 'Google Drive', 'GoogleDrive', 'Nextcloud', 'ownCloud',
  'Sync.com', 'pCloudDrive', 'Syncthing'
)

function Test-PathLooksSynced {
  param([Parameter(Mandatory)] [string] $Path)
  $separators = [char[]] @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  foreach ($segment in $Path.Split($separators, [StringSplitOptions]::RemoveEmptyEntries)) {
    # iCloud vaults are named "iCloud~md~obsidian" and friends, so match the prefix.
    if ($segment.StartsWith('iCloud~', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    foreach ($marker in $script:SyncMarkers) {
      if ([string]::Equals($segment, $marker, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
  }
  return $false
}

function Expand-HomePath {
  param([Parameter(Mandatory)] [string] $Path)
  if ($Path -notmatch '^~[/\\]') { return $Path }
  $userHome = if ([string]::IsNullOrWhiteSpace($HOME)) { $env:HOME } else { $HOME }
  if ([string]::IsNullOrWhiteSpace($userHome)) {
    $userHome = [System.Environment]::GetFolderPath('UserProfile')
  }
  if ([string]::IsNullOrWhiteSpace($userHome)) { return $Path }
  return Join-Path $userHome $Path.Substring(2)
}

<#
Read autoMemoryDirectory out of a project's .claude settings. Returns one record
per settings file that declares it; a project with no declaration returns none.
Local settings are listed last because that is the file a person edits by hand.
#>
function Get-DeclaredMemoryDirectory {
  param([Parameter(Mandatory)] [string] $ProjectPath)

  $results = [Collections.Generic.List[object]]::new()
  foreach ($name in @('settings.json', 'settings.local.json')) {
    $file = Join-Path (Join-Path $ProjectPath '.claude') $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }

    $record = [pscustomobject]@{ File = $file; Value = $null; Problem = $null }
    try {
      $parsed = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
      $record.Problem = "cannot be read as JSON: $($_.Exception.Message)"
      $results.Add($record)
      continue
    }
    if ($null -eq $parsed -or -not $parsed.PSObject.Properties['autoMemoryDirectory']) { continue }

    $value = $parsed.autoMemoryDirectory
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
      $record.Problem = 'autoMemoryDirectory is not a non-empty string'
    } else {
      $record.Value = $value
    }
    $results.Add($record)
  }
  return $results
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
  Write-Entry "error: invalid argument: $($_.Exception.Message)"
  Complete-Doctor -Code 2
}

try {
  $projectsItem = Get-ItemIfExists $projectsRoot
  $stableItem = if ($stableRootFull) { Get-ItemIfExists $stableRootFull } else { $null }
} catch {
  Write-Entry "error: a scan root cannot be inspected: $($_.Exception.Message)"
  Complete-Doctor -Code 2
}
if (-not $projectsItem -or -not $projectsItem.PSIsContainer) {
  Write-Entry "No legacy/default agent projects directory at: $projectsRoot"
  Write-Entry 'Point at the right one with -ProjectsDir.'
  Complete-Doctor -Code 2
}
if ($stableRootFull) {
  if (-not $stableItem -or -not $stableItem.PSIsContainer) {
    Write-Entry "error: StableRoot is missing or is not a directory: $stableRootFull"
    Complete-Doctor -Code 2
  }
}

$atRisk = 0
$orphans = 0
$unreadable = 0
$unverified = 0
$verified = 0
$total = 0

Write-Line 'agent-ops - memory doctor (legacy/default-layout scan)'
Write-Line "projects: $projectsRoot"
if ($stableRootFull) {
  Write-Line "verified stable root: $stableRootFull"
} else {
  Write-Line 'stable root: not supplied (live links will be UNVERIFIED)'
}
Write-Line 'Confirm Claude Code''s active path with /memory or /context.'
Write-Line ''

try {
  $projects = @(Get-ChildItem -LiteralPath $projectsRoot -Force -Directory)
} catch {
  Write-Entry "error: cannot enumerate projects: $($_.Exception.Message)"
  Complete-Doctor -Code 1
}

foreach ($project in $projects) {
  $slug = $project.Name
  $mem = Get-NormalizedFullPath (Join-Path $project.FullName $MemoryDirectoryName) -PreserveLeaf
  $total++
  try {
    $item = Get-ItemIfExists $mem
  } catch {
    $atRisk++
    '  {0,-11} {1,-40} memory path cannot be inspected: {2}' -f 'AT RISK', $slug, $_.Exception.Message | Write-Entry
    continue
  }

  if (-not $item) {
    if (-not $Quiet) {
      '  {0,-11} {1,-40} no memory directory yet' -f '-', $slug | Write-Line
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
    } catch {
      $orphans++
      '  {0,-11} {1,-40} -> {2} ({3})' -f 'ORPHAN', $slug, ($target ?? '<unreadable>'), $_.Exception.Message | Write-Entry
      continue
    }

    # The target is there and is a directory. A read failure inside it - one
    # iCloud file that failed to hydrate, measured 2026-09-30 - is not a missing
    # target, and calling it ORPHAN invites recreating a directory that exists.
    try {
      $summary = Get-ContentSummary $target
    } catch {
      $unreadable++
      '  {0,-11} {1,-40} -> {2} ({3})' -f 'UNREADABLE', $slug, $target, $_.Exception.Message | Write-Entry
      continue
    }

    if (Test-PathInside -Child $target -Parent $projectsRoot -AllowEqual) {
      $atRisk++
      '  {0,-11} {1,-40} -> {2} (inside legacy projects layout; {3} item(s))' -f 'AT RISK', $slug, $target, $summary.Items | Write-Entry
      continue
    }

    if (-not $stableRootFull) {
      $unverified++
      '  {0,-11} {1,-40} -> {2} (target exists; stability not verified; {3} item(s))' -f 'UNVERIFIED', $slug, $target, $summary.Items | Write-Entry
      continue
    }

    if (Test-PathInside -Child $target -Parent $stableRootFull -AllowEqual) {
      $verified++
      if (-not $Quiet) {
        '  {0,-11} {1,-40} -> {2} ({3} item(s))' -f 'OK', $slug, $target, $summary.Items | Write-Line
      }
    } else {
      $atRisk++
      '  {0,-11} {1,-40} -> {2} (outside StableRoot; {3} item(s))' -f 'AT RISK', $slug, $target, $summary.Items | Write-Entry
    }
    continue
  }

  if (-not $item.PSIsContainer) {
    $atRisk++
    '  {0,-11} {1,-40} memory path is not a directory' -f 'AT RISK', $slug | Write-Entry
    continue
  }

  try {
    $summary = Get-ContentSummary $mem
  } catch {
    $atRisk++
    '  {0,-11} {1,-40} real directory is unreadable: {2}' -f 'AT RISK', $slug, $_.Exception.Message | Write-Entry
    continue
  }
  if ($summary.Items -gt 0) {
    $atRisk++
    '  {0,-11} {1,-40} real directory, {2} item(s)' -f 'AT RISK', $slug, $summary.Items | Write-Entry
  } elseif (-not $Quiet) {
    '  {0,-11} {1,-40} real directory, empty' -f 'empty', $slug | Write-Line
  }
}

$settingsIssues = 0
$settingsSection = 'declared memory directory (.claude settings):'
if (-not $SkipSettingsCheck -and $ProjectDir.Count -gt 0) {
  $header = $false
  foreach ($candidate in $ProjectDir) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    try {
      $projectPath = Get-NormalizedFullPath $candidate
    } catch {
      $settingsIssues++
      if (-not $header) { Write-Line ''; Write-Line $settingsSection; $header = $true }
      '  {0,-11} {1,-40} project path cannot be resolved: {2}' -f 'INVALID', $candidate, $_.Exception.Message | Write-Entry -Section $settingsSection
      continue
    }

    $declarations = @(Get-DeclaredMemoryDirectory $projectPath)
    if ($declarations.Count -eq 0) {
      if (-not $Quiet) {
        if (-not $header) { Write-Line ''; Write-Line $settingsSection; $header = $true }
        '  {0,-11} {1,-40} no autoMemoryDirectory declared' -f '-', $projectPath | Write-Line
      }
      continue
    }

    foreach ($declaration in $declarations) {
      if (-not $header) { Write-Line ''; Write-Line $settingsSection; $header = $true }
      $label = Split-Path -Leaf $declaration.File

      if ($declaration.Problem) {
        $settingsIssues++
        '  {0,-11} {1,-40} {2}' -f 'INVALID', $label, $declaration.Problem | Write-Entry -Section $settingsSection
        continue
      }

      $raw = $declaration.Value
      # A relative value is not a different location - the agent discards it and
      # silently falls back to the path-derived layout this tool is auditing.
      if ($raw -notmatch '^~[/\\]' -and -not [IO.Path]::IsPathRooted($raw)) {
        $settingsIssues++
        '  {0,-11} {1,-40} relative value "{2}" is ignored; memory falls back to the derived layout' -f 'AT RISK', $label, $raw | Write-Entry -Section $settingsSection
        continue
      }

      $expanded = Expand-HomePath $raw
      try {
        $resolved = Get-NormalizedFullPath $expanded
      } catch {
        $settingsIssues++
        '  {0,-11} {1,-40} value "{2}" cannot be resolved: {3}' -f 'INVALID', $label, $raw, $_.Exception.Message | Write-Entry -Section $settingsSection
        continue
      }

      # The trap this check exists for: the settings file syncs, the path does not.
      if ((Test-PathLooksSynced $declaration.File) -and $raw -notmatch '^~[/\\]') {
        $settingsIssues++
        '  {0,-11} {1,-40} absolute path in a SYNCED settings file; it cannot be right on two machines' -f 'AT RISK', $label | Write-Entry -Section $settingsSection
        continue
      }

      $targetItem = Get-ItemIfExists $resolved
      if (-not $targetItem -or -not $targetItem.PSIsContainer) {
        $settingsIssues++
        '  {0,-11} {1,-40} -> {2} (declared directory does not exist)' -f 'AT RISK', $label, $resolved | Write-Entry -Section $settingsSection
        continue
      }

      if ($stableRootFull -and -not (Test-PathInside -Child $resolved -Parent $stableRootFull -AllowEqual)) {
        $settingsIssues++
        '  {0,-11} {1,-40} -> {2} (outside StableRoot)' -f 'AT RISK', $label, $resolved | Write-Entry -Section $settingsSection
        continue
      }

      if (-not $Quiet) {
        '  {0,-11} {1,-40} -> {2}' -f 'OK', $label, $resolved | Write-Line
      }
    }
  }
}

$summaryLines = @("$total project(s): $verified verified, $unverified unverified, $atRisk at risk, $orphans orphaned, $unreadable unreadable.")
if ($settingsIssues -gt 0) {
  $summaryLines += "$settingsIssues declared memory directory issue(s)."
}
Write-Line ''
foreach ($line in $summaryLines) { Write-Line $line }

# The paragraphs are for a person reading a full report. Hook mode gets one line
# per category instead, because it lands in the context of every session.
$legend = [Collections.Generic.List[string]]::new()
if ($unverified -gt 0) {
  Write-Line @'

UNVERIFIED - the link target exists and is readable, but no trusted stable root
was supplied. Re-run with -StableRoot <store-root> to verify containment and earn
an OK result. Until then the audit intentionally returns exit code 1.
'@
  $legend.Add('UNVERIFIED: the target exists, but no stable root was supplied, so its stability is not verified; a run with -StableRoot verifies it.')
}
if ($atRisk -gt 0) {
  Write-Line @'

AT RISK - data is still in the path-derived legacy/default layout, the link
points back into that layout, or the target falls outside the requested stable
root. Confirm the active path with /memory or /context before migrating it.
'@
  $legend.Add('AT RISK: memory sits in the path-derived layout, links back into it, or lies outside the stable root, so it is not in a store known to survive a move; /memory shows which path is active.')
}
if ($orphans -gt 0) {
  Write-Line @'

ORPHAN - the link target is missing or is not a directory, or the link itself
cannot be read. Restore/mount the target before allowing an agent to write memory.
'@
  $legend.Add('ORPHAN: the link target is missing or not a directory, so memory cannot be read or written through the link until the store is restored or mounted.')
}
if ($unreadable -gt 0) {
  Write-Line @'

UNREADABLE - the link target exists and is a directory, but some of its content
could not be read: a permission error, or a cloud placeholder that failed to
download. It is not missing and must not be recreated. Retry once sync settles,
and keep the store always available offline.
'@
  $legend.Add('UNREADABLE: the target exists but some content could not be read (e.g. a cloud placeholder that failed to download); a retry once sync settles is the fix. It is not missing and must not be recreated.')
}

if ($settingsIssues -gt 0) {
  Write-Line @'

DECLARED MEMORY DIRECTORY - a .claude setting names a memory location that
cannot work as written. This does not tell you which setting Claude Code
actually applied; it tells you this one would fail if it were applied. A settings
file inside a synced folder is the sharp case: it travels to your other machine,
where an absolute path from this one does not resolve. Prefer a link there, or a
path that is valid on every machine.
'@
  $legend.Add('DECLARED MEMORY DIRECTORY: a .claude autoMemoryDirectory cannot work as written (relative, missing, or an absolute path in a synced settings file).')
}

$code = 0
if ($atRisk -gt 0 -or $orphans -gt 0 -or $unreadable -gt 0 -or $unverified -gt 0 -or $settingsIssues -gt 0) { $code = 1 }
Complete-Doctor -Code $code -Summary $summaryLines -Legend $legend
