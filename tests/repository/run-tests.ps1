#!/usr/bin/env pwsh

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Test-Condition {
  param(
    [Parameter(Mandatory)] [bool] $Condition,
    [Parameter(Mandatory)] [string] $Message
  )

  $script:checks++
  if (-not $Condition) { $script:failures.Add($Message) }
}

function Get-RepoFiles {
  param([Parameter(Mandatory)] [string] $Filter)

  Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter $Filter |
    Where-Object { $_.FullName -notlike "*$([IO.Path]::DirectorySeparatorChar).git$([IO.Path]::DirectorySeparatorChar)*" }
}

Push-Location $repoRoot
try {
  foreach ($json in Get-RepoFiles '*.json') {
    try {
      Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json | Out-Null
      Test-Condition $true "JSON parses: $($json.FullName)"
    } catch {
      Test-Condition $false "Invalid JSON: $($json.FullName): $($_.Exception.Message)"
    }
  }

  $markdownLink = [regex]'(?<!!)\[[^\]]+\]\((?<target>[^)]+)\)'
  foreach ($markdown in Get-RepoFiles '*.md') {
    $text = Get-Content -LiteralPath $markdown.FullName -Raw
    foreach ($match in $markdownLink.Matches($text)) {
      $target = $match.Groups['target'].Value.Trim()
      if ($target.StartsWith('<') -and $target.EndsWith('>')) {
        $target = $target.Substring(1, $target.Length - 2)
      }
      if ($target -match '^(?:https?://|mailto:|#)') { continue }

      $pathPart = ($target -split '#', 2)[0]
      if ([string]::IsNullOrWhiteSpace($pathPart)) { continue }
      $pathPart = [Uri]::UnescapeDataString($pathPart)
      $resolved = Join-Path $markdown.DirectoryName $pathPart
      Test-Condition (Test-Path -LiteralPath $resolved) "Broken local link in $($markdown.FullName): $target"
    }
  }

  foreach ($adapter in 'CLAUDE.md', 'templates/CLAUDE.md') {
    $firstContent = Get-Content -LiteralPath (Join-Path $repoRoot $adapter) |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -First 1
    Test-Condition ($firstContent -eq '@AGENTS.md') "$adapter must begin with @AGENTS.md"
  }



  foreach ($shellScript in Get-RepoFiles '*.sh') {
    $bytes = [IO.File]::ReadAllBytes($shellScript.FullName)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    Test-Condition ($text.StartsWith('#!/usr/bin/env bash')) "$($shellScript.FullName) must use the Bash env shebang"
    Test-Condition (-not $text.Contains("`r`n")) "$($shellScript.FullName) must use LF line endings"
  }

  $requiredFiles = @(
    'README.md',
    'PROTOCOL.md',
    'LICENSE',
    'SECURITY.md',
    'CONTRIBUTING.md',
    'CODE_OF_CONDUCT.md',
    'CHANGELOG.md',
    'AGENTS.md',
    'CLAUDE.md',
    '.github/workflows/ci.yml',
    '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/ISSUE_TEMPLATE/feature_request.yml',
    '.github/pull_request_template.md'
  )
  foreach ($required in $requiredFiles) {
    Test-Condition (Test-Path -LiteralPath (Join-Path $repoRoot $required)) "$required is required"
  }
} finally {
  Pop-Location
}

if ($failures.Count -gt 0) {
  Write-Host "`nRepository checks failed ($($failures.Count)/$checks):" -ForegroundColor Red
  $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}

Write-Host "Repository checks passed ($checks assertions)." -ForegroundColor Green
exit 0
