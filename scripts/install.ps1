<#
.SYNOPSIS
    Rhizo Windows PowerShell Installer & Uninstaller
.DESCRIPTION
    Installs Rhizo for Windows x86_64:
    1. Installs via Scoop if Scoop is present.
    2. Downloads and installs pre-compiled binary zip from GitHub Releases.
    3. Falls back to installing Nim and compiling from source if no binary is found.
    Configures %LOCALAPPDATA%\Programs\rhizo and updates the User PATH.
.EXAMPLE
    # Install:
    irm https://raw.githubusercontent.com/axiomantic/rhizo/main/scripts/install.ps1 | iex

    # Uninstall:
    & .\scripts\install.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [string]$Version = $env:RHIZO_VERSION,
    [switch]$Uninstall,
    [switch]$BuildFromSource,
    [switch]$NoSkills
)

$ErrorActionPreference = "Stop"
$Repo = "axiomantic/rhizo"
$GitHubUrl = "https://github.com/$Repo"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\rhizo"

# 0. Handle Uninstallation
if ($Uninstall) {
    Write-Host "=== Rhizo Windows Uninstaller ===" -ForegroundColor Cyan
    $removed = $false

    # A. Remove Skills
    Write-Host "Checking for installed Rhizo AI agent skills..." -ForegroundColor Yellow
    if (Get-Command npx -ErrorAction SilentlyContinue) {
        try { & npx -y skills remove rhizo -g -y 2>$null } catch {}
    }
    if (Get-Command skilz -ErrorAction SilentlyContinue) {
        try { & skilz -y remove rhizo 2>$null } catch {}
    }
    $skillPaths = @(
        "$env:USERPROFILE\.claude\skills\rhizo",
        "$env:APPDATA\gemini\skills\rhizo",
        "$env:USERPROFILE\.agents\skills\rhizo",
        "$env:USERPROFILE\.codex\skills\rhizo"
    )
    foreach ($spath in $skillPaths) {
        if (Test-Path $spath) {
            Write-Host "Removing skill directory: $spath..." -ForegroundColor Yellow
            Remove-Item -Path $spath -Recurse -Force -ErrorAction SilentlyContinue
            $removed = $true
        }
    }

    # B. Check Scoop
    if ((Get-Command scoop -ErrorAction SilentlyContinue) -and (scoop list | Select-String "^rhizo\b")) {
        Write-Host "Detected Scoop package. Uninstalling via Scoop..." -ForegroundColor Yellow
        scoop uninstall rhizo
        $removed = $true
    }

    # C. Check Standalone Directory
    if (Test-Path $InstallDir) {
        Write-Host "Removing installation directory: $InstallDir..." -ForegroundColor Yellow
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        $removed = $true
    }

    # D. Clean User PATH
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -split ";" -contains $InstallDir) {
        Write-Host "Removing $InstallDir from User PATH..." -ForegroundColor Yellow
        $newPath = ($userPath -split ";" | Where-Object { $_ -ne $InstallDir -and $_ -ne "" }) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $removed = $true
    }

    if ($removed) {
        Write-Host "[+] Rhizo (binary and AI agent skills) has been successfully uninstalled." -ForegroundColor Green
        Write-Host "Note: Configuration files in %APPDATA%\rhizo were preserved."
    } else {
        Write-Host "Rhizo does not appear to be installed on this system." -ForegroundColor Gray
    }
    exit 0
}

Write-Host "=== Rhizo Windows Installer ===" -ForegroundColor Cyan

# 1. Check Architecture
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error "Rhizo requires a 64-bit Windows operating system (x86_64)."
    exit 1
}

# 2. Resolve Release Version
if (-not $Version) {
    Write-Host "Fetching latest release information from GitHub..."
    try {
        $releaseApi = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing
        $Version = $releaseApi.tag_name
        Write-Host "Latest release found: $Version" -ForegroundColor Green
    }
    catch {
        $Version = "v0.1.2"
        Write-Warning "Could not query GitHub API, defaulting to $Version"
    }
}
elseif (-not ($Version.StartsWith("v"))) {
    $Version = "v$Version"
}

# Helper: Build from Source
function Build-FromSource {
    Write-Host "`n=== Building Rhizo from Source ===" -ForegroundColor Cyan

    # Check for Nim
    if (-not (Get-Command nim -ErrorAction SilentlyContinue)) {
        Write-Host "Nim compiler not detected. Attempting automatic installation..." -ForegroundColor Yellow
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "Installing Nim via winget..."
            winget install --id Nim.Nim -e --silent --accept-source-agreements --accept-package-agreements
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        }
    }

    if (-not (Get-Command nim -ErrorAction SilentlyContinue)) {
        Write-Error "Nim compiler not found. Please install Nim: https://nim-lang.org/install_windows.html"
        exit 1
    }

    Write-Host "Using Nim: $((nim --version)[0])" -ForegroundColor Green

    if (Test-Path "src\rhizo.nim") {
        Write-Host "Compiling native Rhizo binary from local source tree..." -ForegroundColor Green
        if (-not (Test-Path $InstallDir)) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }
        if (Test-Path "bin\rhizo.exe") {
            Copy-Item -Path "bin\rhizo.exe" -Destination "$InstallDir\rhizo.exe" -Force
        } elseif (Get-Command nimble -ErrorAction SilentlyContinue) {
            nimble build -y -d:release
            Copy-Item -Path "bin\rhizo.exe" -Destination "$InstallDir\rhizo.exe" -Force
        } else {
            nim c -d:release -d:ssl --threads:on --opt:speed -o:"$InstallDir\rhizo.exe" src\rhizo.nim
        }
        return
    }

    $tempDir = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $srcZip = Join-Path $tempDir "source.zip"

    Write-Host "Fetching Rhizo source ($Version)..."
    $srcUrl = "$GitHubUrl/archive/refs/tags/$Version.zip"
    try {
        Invoke-WebRequest -Uri $srcUrl -OutFile $srcZip -UseBasicParsing
    } catch {
        Write-Host "Release zip not found, falling back to main branch..."
        Invoke-WebRequest -Uri "$GitHubUrl/archive/refs/heads/main.zip" -OutFile $srcZip -UseBasicParsing
    }

    Expand-Archive -Path $srcZip -DestinationPath $tempDir -Force
    $extractedDir = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    Write-Host "Compiling native binary with optimizations..."
    Push-Location $extractedDir.FullName
    try {
        if (Get-Command nimble -ErrorAction SilentlyContinue) {
            nimble build -y -d:release
            Copy-Item -Path "bin\rhizo.exe" -Destination "$InstallDir\rhizo.exe" -Force
        } else {
            nim c -d:release --opt:speed -o:"$InstallDir\rhizo.exe" src\rhizo.nim
        }
    } finally {
        Pop-Location
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Helper: Install AI Agent Skills
function Install-Skills {
    if ($NoSkills -or ($env:NO_SKILLS -eq "1")) {
        Write-Host "Skipping AI agent skill installation (-NoSkills requested)." -ForegroundColor Gray
        return
    }

    Write-Host "`n=== Installing Rhizo AI Agent Skills ===" -ForegroundColor Cyan
    $skillInstalled = $false

    # Option A: skills.sh via npx
    if ((-not $env:RHIZO_SKIP_NPX) -and (Get-Command npx -ErrorAction SilentlyContinue)) {
        Write-Host "Attempting global skill installation via skills.sh (npx)..." -ForegroundColor Yellow
        try {
            & npx -y skills add axiomantic/rhizo -g -a '*' -y
            Write-Host "[+] Rhizo skill installed globally via skills.sh." -ForegroundColor Green
            $skillInstalled = $true
        }
        catch {}
    }

    # Option B: skilz
    if (-not $skillInstalled -and (Get-Command skilz -ErrorAction SilentlyContinue)) {
        Write-Host "Attempting global skill installation via skilz..." -ForegroundColor Yellow
        try {
            & skilz -y install https://github.com/axiomantic/rhizo
            Write-Host "[+] Rhizo skill installed globally via skilz." -ForegroundColor Green
            $skillInstalled = $true
        }
        catch {}
    }

    # Option C: Direct fallback to standard assistant directories
    if (-not $skillInstalled) {
        Write-Host "Configuring skills directly for detected AI coding assistants..." -ForegroundColor Yellow
        $localSkill = "skills\rhizo\SKILL.md"
        $localSpec = "skills\rhizo\references\wire_spec.md"
        $tempSkillDir = $null

        try {
            if (Test-Path $localSkill) {
                $skillFile = (Resolve-Path $localSkill).Path
                $specFile = if (Test-Path $localSpec) { (Resolve-Path $localSpec).Path } else { $null }
            } else {
                $skillUrl = "https://raw.githubusercontent.com/$Repo/main/skills/rhizo/SKILL.md"
                $specUrl = "https://raw.githubusercontent.com/$Repo/main/skills/rhizo/references/wire_spec.md"
                $tempSkillDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
                New-Item -ItemType Directory -Path $tempSkillDir -Force | Out-Null
                $skillFile = Join-Path $tempSkillDir "SKILL.md"
                $specFile = Join-Path $tempSkillDir "wire_spec.md"
                Invoke-WebRequest -Uri $skillUrl -OutFile $skillFile -UseBasicParsing -ErrorAction SilentlyContinue
                Invoke-WebRequest -Uri $specUrl -OutFile $specFile -UseBasicParsing -ErrorAction SilentlyContinue
            }

            $candidateDirs = @(
                "$env:USERPROFILE\.claude\skills\rhizo",
                "$env:APPDATA\gemini\skills\rhizo",
                "$env:USERPROFILE\.agents\skills\rhizo",
                "$env:USERPROFILE\.codex\skills\rhizo"
            )

            foreach ($targetSkill in $candidateDirs) {
                $parentDir = Split-Path (Split-Path $targetSkill -Parent) -Parent
                if (Test-Path $parentDir) {
                    $refDir = Join-Path $targetSkill "references"
                    New-Item -ItemType Directory -Path $refDir -Force | Out-Null
                    Copy-Item -Path $skillFile -Destination (Join-Path $targetSkill "SKILL.md") -Force
                    if ($specFile -and (Test-Path $specFile)) {
                        Copy-Item -Path $specFile -Destination (Join-Path $refDir "wire_spec.md") -Force
                    }
                    Write-Host "  [+] Installed Rhizo skill to: $targetSkill" -ForegroundColor Green
                    $skillInstalled = $true
                }
            }
        }
        catch {}
        finally {
            if ($tempSkillDir -and (Test-Path $tempSkillDir)) {
                Remove-Item -Path $tempSkillDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($skillInstalled) {
        Write-Host "[+] AI Agent Skills configured successfully." -ForegroundColor Green
    } else {
        Write-Host "Notice: No coding assistant directories detected yet." -ForegroundColor Gray
        Write-Host "Install the skill into your assistant at any time using:"
        Write-Host "    npx skills add axiomantic/rhizo -g"
        Write-Host "    # Or: skilz install https://github.com/axiomantic/rhizo"
    }
}

# 3. Check for Scoop Package Manager
if (-not $BuildFromSource -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Host "Detected Scoop package manager. Installing via Scoop..." -ForegroundColor Green
    if (scoop install "https://raw.githubusercontent.com/$Repo/main/packaging/scoop/rhizo.json") {
        Write-Host "[+] Rhizo successfully installed via Scoop." -ForegroundColor Green
        Install-Skills
        exit 0
    }
    Write-Warning "Scoop installation failed. Falling back to binary release..."
}

# 4. Standalone Binary Installation
$installed = $false
if (-not $BuildFromSource) {
    $zipFile = "rhizo-windows-amd64.zip"
    $downloadUrl = "$GitHubUrl/releases/download/$Version/$zipFile"
    $tempDir = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $tempZip = Join-Path $tempDir $zipFile

    Write-Host "Downloading pre-compiled binary from $downloadUrl..."
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing
        if (-not (Test-Path $InstallDir)) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }
        Write-Host "Extracting archive to $InstallDir..."
        Expand-Archive -Path $tempZip -DestinationPath $InstallDir -Force
        $installed = $true
    }
    catch {
        Write-Warning "Pre-compiled binary was not found or download failed."
    }
    finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 5. Fallback: Build from source if binary was not found
if (-not $installed) {
    Build-FromSource
}

$exePath = Join-Path $InstallDir "rhizo.exe"
if (-not (Test-Path $exePath)) {
    Write-Error "rhizo.exe was not found at $exePath."
    exit 1
}

# 6. Configure User PATH
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -split ";" -notcontains $InstallDir) {
    Write-Host "Adding $InstallDir to User PATH..." -ForegroundColor Yellow
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    $env:Path = "$env:Path;$InstallDir"
}

Write-Host "[+] Rhizo successfully installed to: $exePath" -ForegroundColor Green

# 7. Verification
try {
    & $exePath --help | Out-Null
    Write-Host "[+] Rhizo executable verified and ready to use!" -ForegroundColor Green
    Write-Host "Run 'rhizo --help' to get started."
}
catch {
    Write-Warning "Executable installed, but execution check failed. You may need to restart your terminal."
}

# 8. Install Skills
Install-Skills
