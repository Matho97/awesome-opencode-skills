#Requires -Version 7
<#
.SYNOPSIS
    check_skills.ps1 - Pre-commit integrity & license/credit validator
    (PowerShell port of scripts/check_skills.sh for Windows).

.DESCRIPTION
    Verifies, for EVERY skill directory in this repo:
      1. A valid SKILL.md exists with parseable YAML frontmatter
      2. A LICENSE / LICENSE.md file is present for license & attribution
      3. No stale Claude/Anthropic branding remains (OpenCode fork)
      4. The skill is registered in .opencode/skills.json (registry consistency)
      5. Registry paths resolve to real directories

    Also checks the registry itself is valid JSON and its version tag is present.
    (JSON is parsed natively by PowerShell - no python3 dependency.)

.PARAMETER Staged
    Check only skill dirs touched by git-staged changes.

.PARAMETER Quiet
    Exit code only, minimal output.

.PARAMETER Strict
    Treat non-allowlisted Claude/Anthropic branding as a hard failure
    instead of a warning.

.PARAMETER Help
    Show this help.

.EXAMPLE
    ./scripts/check_skills.ps1
    Check all skills (default).

.EXAMPLE
    ./scripts/check_skills.ps1 -Staged
    Check only git-staged skill dirs.

.EXAMPLE
    ./scripts/check_skills.ps1 -Quiet
    Exit code only, minimal output.

.NOTES
    Exit codes:
      0  all checks passed
      1  one or more checks failed (human-readable output)
      2  usage error (unknown parameter; reported by PowerShell's binder)

    Requires PowerShell 7+ (pwsh). Both `-Staged` and `--staged` spellings work,
    so muscle memory from the bash version carries over.
#>
[CmdletBinding()]
param(
    [switch]$Staged,
    [switch]$Quiet,
    [switch]$Strict,
    [switch]$Help
)

if ($Help) { Get-Help $PSCommandPath -Full; exit 0 }

# Emit UTF-8 so ✓/✅/❌ survive redirection and CI logs (PowerShell defaults to the OEM code page).
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}

$ErrorActionPreference = 'Stop'

# Repo root = parent of the scripts/ dir holding this file; everything below is relative to it.
Set-Location (Split-Path $PSScriptRoot -Parent)

$script:failures = 0
$script:warnings = 0
function Log($msg) { if (-not $Quiet) { $msg } }
function Warn($msg) { Log "[warn] $msg"; $script:warnings++ }
function Fail($msg) { Log "[FAIL] $msg"; $script:failures++ }

# ---------------------------------------------------------------------------
# 0. Registry validity
# ---------------------------------------------------------------------------
$registryPath = '.opencode/skills.json'
$registry = $null
if (Test-Path $registryPath -PathType Leaf) {
    try { $registry = Get-Content $registryPath -Raw | ConvertFrom-Json }
    catch { Fail "Registry $registryPath is not valid JSON" }
} else {
    Fail "Registry missing: $registryPath"
}

# ---------------------------------------------------------------------------
# Branding allowlist: each line is <skill>|<exact-substring> that is a
# legitimate functional reference (e.g. SDK imports) and may stay.
# See scripts/branding-allowlist.txt. Comments (#) and blanks never match.
# ---------------------------------------------------------------------------
$allowlist = @(Get-Content 'scripts/branding-allowlist.txt' -ErrorAction SilentlyContinue |
    ForEach-Object { $skill, $pattern = $_.Split('|', 2); [pscustomobject]@{ Skill = $skill; Pattern = $pattern } } |
    Where-Object Pattern)

# ---------------------------------------------------------------------------
# Determine skill directories to check
# ---------------------------------------------------------------------------
if ($Staged) {
    # Only skill dirs touched by staged changes
    $skillDirs = @(git diff --cached --name-only 2>$null |
        ForEach-Object { ($_ -split '/')[0] } |
        Sort-Object -Unique |
        Where-Object { $_ -and (Test-Path "$_/SKILL.md" -PathType Leaf) })
} else {
    # Every top-level directory that IS itself a skill (has its own SKILL.md),
    # excluding: collection dirs that only hold sub-skill dirs (e.g. document-skills),
    # and non-skill project dirs (MCP servers, scripts).
    $notSkills = 'scripts', 'opencode-skills-mcp-server', 'opencode-skills-mcp-server-ts'
    $skillDirs = @(Get-ChildItem -Directory |
        Where-Object { $_.Name -notin $notSkills -and (Test-Path "$($_.Name)/SKILL.md" -PathType Leaf) } |
        Sort-Object Name |
        ForEach-Object Name)
}

$total = 0
foreach ($skill in $skillDirs) {
    $total++

    # --- 1. SKILL.md + valid frontmatter ------------------------------------
    if (-not (Test-Path "$skill/SKILL.md" -PathType Leaf)) {
        Fail "[$skill] missing SKILL.md"
        continue
    }
    $frontmatter = Get-Content "$skill/SKILL.md"
    if (-not ($frontmatter -cmatch '^name:\s*\S')) {
        Fail "[$skill] SKILL.md has no frontmatter 'name:'"
    }
    if (-not ($frontmatter -cmatch '^description:\s*\S')) {
        Fail "[$skill] SKILL.md has no frontmatter 'description:'"
    }

    # --- 2. LICENSE / credit file -------------------------------------------
    # Every skill we migrate in must carry its license so credit & terms are
    # preserved. Vendored external skills MUST include the upstream LICENSE.
    if (-not (Get-ChildItem $skill -Filter 'LICENSE*' -File -ErrorAction SilentlyContinue)) {
        Fail "[$skill] missing LICENSE file (license/credit must be preserved per migrated skill)"
    }

    # --- 3. Stale branding --------------------------------------------------
    # Scan the same file types as the bash version's grep. Select-String
    # MatchInfo gives us file, line number and text in one pass.
    $hits = Get-ChildItem $skill -Recurse -Force -File -Include *.md, *.py, *.sh, *.cjs, *.js, *.ts, *.json |
        Select-String -Pattern 'Claude|Anthropic|anthropic' -CaseSensitive

    # A hit survives unless some allowlist entry for this skill is contained in the line.
    $violations = @(foreach ($hit in $hits) {
        $allowed = $allowlist | Where-Object {
            $_.Skill -eq $skill -and $hit.Line.Contains($_.Pattern, [StringComparison]::Ordinal)
        }
        if (-not $allowed) {
            $rel = ([IO.Path]::GetRelativePath((Get-Location).Path, $hit.Path)) -replace '\\', '/'
            "{0}:{1}: {2}" -f $rel, $hit.LineNumber, $hit.Line
        }
    })

    if ($violations) {
        if ($Strict) {
            Fail "[$skill] contains Claude/Anthropic branding (not allowlisted). See scripts/branding-allowlist.txt"
        } else {
            Warn "[$skill] contains Claude/Anthropic branding (not allowlisted) — run -Strict to gate, or add to scripts/branding-allowlist.txt"
        }
        $violations | Select-Object -First 12 | ForEach-Object { Log "        $_" }
    }

    Log "  ✓ $skill"
}

# ---------------------------------------------------------------------------
# Registry <-> disk consistency
# ---------------------------------------------------------------------------
if ($registry) {
    if (-not "$($registry.version)".Trim()) { Fail "$registryPath missing version" }
    $seen = @{}
    foreach ($s in @($registry.skills)) {
        if ($seen[$s.name]) { Fail "$registryPath duplicate skill entry: $($s.name)" }
        $seen[$s.name] = $true
        $dir = "$($s.path)" -replace '^\./', ''
        if (-not $dir -or -not (Test-Path $dir -PathType Container)) {
            Fail "registry path does not resolve: $($s.name) -> $($s.path)"
        } elseif (-not (Test-Path "$dir/SKILL.md" -PathType Leaf)) {
            Fail "registry entry missing SKILL.md: $($s.name) -> $($s.path)"
        }
        if (-not $s.category) { Fail "registry entry missing category: $($s.name)" }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if ($script:failures -eq 0) {
    if (-not $Quiet) {
        ''
        if ($script:warnings -gt 0) {
            "✅ Checks passed ($total skills, $($script:warnings) warning(s), registry OK). Run with -Strict to gate branding."
        } else {
            "✅ All checks passed ($total skills, registry OK)."
        }
    }
    exit 0
}
''
[Console]::Error.WriteLine("❌ $($script:failures) check(s) failed across $total skills.")
exit 1
