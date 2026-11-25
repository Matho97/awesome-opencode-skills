#Requires -Version 7
<#
.SYNOPSIS
    install_check_hook.ps1 - Install the skills integrity pre-commit hook
    (PowerShell port of scripts/install_check_hook.sh).

.DESCRIPTION
    Installs scripts/check_skills.ps1 as a git pre-commit hook so every commit
    validates: LICENSE presence per skill, valid SKILL.md frontmatter, registry
    consistency, and (in -Strict) stale-branding gating.

    The hook file itself is a POSIX sh script - Git for Windows runs hooks
    through its bundled sh even on Windows - which invokes pwsh to run the
    PowerShell checker. It is written with LF endings and no BOM because sh
    rejects CRLF/BOM files.

.PARAMETER Remove
    Uninstall the hook.

.EXAMPLE
    ./scripts/install_check_hook.ps1
    Install the pre-commit hook.

.EXAMPLE
    ./scripts/install_check_hook.ps1 -Remove
    Uninstall the pre-commit hook.
#>
[CmdletBinding()]
param([switch]$Remove)

# Emit UTF-8 so the status glyphs survive redirection and CI logs.
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$hook = Join-Path $root '.git/hooks/pre-commit'
$src  = Join-Path $root 'scripts/check_skills.ps1'

if ($Remove) {
    if ((Test-Path $hook -PathType Leaf) -and (Select-String -Path $hook -Pattern 'check_skills' -Quiet)) {
        Remove-Item $hook -Force
        Write-Host '🗑️  Removed pre-commit hook.'
    } else {
        Write-Host 'No installed check_skills hook found.'
    }
    exit 0
}

if (-not (Test-Path $src -PathType Leaf)) {
    [Console]::Error.WriteLine("❌ $src not found.")
    exit 1
}

New-Item -ItemType Directory -Force (Split-Path $hook -Parent) | Out-Null

$hookBody = @'
#!/bin/sh
# Pre-commit hook: run skills integrity/license/credit check on staged skills
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$ROOT" ] && [ -f "$ROOT/scripts/check_skills.ps1" ] && command -v pwsh >/dev/null 2>&1; then
  echo "🔍 Running skills integrity check (license/credit gate)..."
  pwsh -NoProfile -File "$ROOT/scripts/check_skills.ps1" -Staged || {
    echo ""
    echo "❌ Pre-commit skills check failed. Fix the issues above, or run:"
    echo "     pwsh -NoProfile -File scripts/check_skills.ps1 -Staged   # see details"
    exit 1
  }
fi
exit 0
'@

# Force LF line endings and UTF-8 without BOM: sh on Windows (Git for Windows)
# fails to parse hooks written with CRLF or a BOM.
[System.IO.File]::WriteAllText(
    $hook,
    $hookBody.Replace("`r", '') + "`n",
    [System.Text.UTF8Encoding]::new($false)
)

# chmod +x only matters on Unix filesystems; Git for Windows ignores the exec bit.
if (-not $IsWindows) { chmod +x $hook }

Write-Host "✅ Installed pre-commit hook -> $hook"
Write-Host '   (runs scripts/check_skills.ps1 -Staged on every commit)'
