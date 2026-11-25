#Requires -Version 7
<#
.SYNOPSIS
    Install OpenCode skills (PowerShell port of scripts/install_opencode_skills.sh).

.DESCRIPTION
    Copies skill directories (top-level dirs containing a SKILL.md) into the
    OpenCode skills directory - either the global one (~/.config/opencode/skills)
    or the project-local one (.opencode/skills). Both are V2's preferred
    discovery locations; the legacy singular `skill` directories are also
    scanned for compatibility.

.PARAMETER SkillName
    Install only this skill directory (positional). Omit to install every skill.

.PARAMETER Project
    Install to the project-local directory (.opencode/skills).

.PARAMETER Global
    Install to the global directory (the default; kept for explicitness).

.EXAMPLE
    ./scripts/install_opencode_skills.ps1
    Install all skills, globally.

.EXAMPLE
    ./scripts/install_opencode_skills.ps1 mcp-builder
    Install the mcp-builder skill, globally.

.EXAMPLE
    ./scripts/install_opencode_skills.ps1 -Project
    Install all skills, project-local.

.NOTES
    Requires PowerShell 7+ (pwsh). The bash flags --global/--project also work:
    PowerShell's parser strips extra leading dashes, so --project binds to -Project.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$SkillName,
    [switch]$Project,
    [switch]$Global
)

# Emit UTF-8 so the status glyphs survive redirection and CI logs.
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}

$ErrorActionPreference = 'Stop'

# Determine installation directory (V2-preferred plural `skills`; the legacy
# singular `skill` dir is also discovered, so both spellings work on V2).
$installDir = $Project ? '.opencode/skills' : (Join-Path $HOME '.config/opencode/skills')
Write-Host "📦 Installing to $(($Project ? 'project-local' : 'global')) OpenCode skills directory: $installDir"

# Create directory if needed
New-Item -ItemType Directory -Force $installDir | Out-Null

# Install specific skill or all skills
if ($SkillName) {
    if (-not (Test-Path $SkillName -PathType Container)) {
        Write-Host "❌ Error: Skill directory '$SkillName' not found"
        exit 1
    }
    Write-Host "📁 Copying skill: $SkillName"
    Copy-Item $SkillName $installDir -Recurse -Force
    Write-Host "✅ Installed '$SkillName' to $installDir"
} else {
    Write-Host '📁 Installing all skills...'
    Get-ChildItem -Directory |
        Where-Object { Test-Path "$($_.Name)/SKILL.md" -PathType Leaf } |
        ForEach-Object {
            Write-Host "📁 Copying $($_.Name)"
            Copy-Item $_.FullName $installDir -Recurse -Force
        }
    Write-Host "✅ Installed all skills to $installDir"
}

''
Write-Host '🚀 Next steps:'
Write-Host ($Project ? '1. Start OpenCode in this directory: opencode' : '1. Start OpenCode: opencode')
Write-Host '2. Skills will be automatically discovered'
