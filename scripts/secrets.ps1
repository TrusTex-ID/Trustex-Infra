# Encrypt / decrypt terraform/secrets with age (Windows).
# Requires: age  ->  winget install FiloSottile.age
#
#   .\scripts\secrets.ps1 keygen
#   .\scripts\secrets.ps1 encrypt
#   .\scripts\secrets.ps1 decrypt
#   .\scripts\secrets.ps1 clean
#   .\scripts\secrets.ps1 status
#   .\scripts\secrets.ps1 push -File backend -Secret trustex-dev-backend

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("keygen", "encrypt", "decrypt", "clean", "status", "push", "help")]
    [string]$Command = "help",

    [string]$File,
    [string]$Secret
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$SecretsDir = Join-Path $Root "terraform\secrets"
$AgeKey = Join-Path $SecretsDir ".age.key"
$AgePub = Join-Path $SecretsDir ".age.pubkey"

# The only files that get encrypted. Add a new secret file here to include it.
$ManagedFiles = @("backend", "postgres")

$script:AgeExe = $null
$script:AgeKeygenExe = $null

function Resolve-Tool {
    param([string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # winget writes the new PATH to the registry, but shells that were already
    # open keep their old copy, so a just-installed age looks missing. Reload
    # PATH from the registry instead of forcing the user to reopen the terminal.
    $machine = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $user = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH = "$machine;$user"

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\$Name.exe"),
        (Join-Path $env:ProgramData "chocolatey\bin\$Name.exe"),
        (Join-Path $env:USERPROFILE "scoop\shims\$Name.exe")
    )

    $wingetPkgs = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path $wingetPkgs) {
        $candidates += Get-ChildItem -Path $wingetPkgs -Directory -Filter "*age*" -ErrorAction SilentlyContinue |
            ForEach-Object {
                Get-ChildItem -Path $_.FullName -Filter "$Name.exe" -Recurse -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.FullName }
            }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }

    throw "$Name not found. Install it with: winget install FiloSottile.age"
}

function Get-AgeExe {
    if (-not $script:AgeExe) { $script:AgeExe = Resolve-Tool "age" }
    return $script:AgeExe
}

function Get-AgeKeygenExe {
    if (-not $script:AgeKeygenExe) { $script:AgeKeygenExe = Resolve-Tool "age-keygen" }
    return $script:AgeKeygenExe
}

function Get-PlaintextPath {
    param([string]$Name)
    return (Join-Path $SecretsDir $Name)
}

function Invoke-Keygen {
    $keygen = Get-AgeKeygenExe
    if (Test-Path $AgeKey) {
        throw "Key already exists: $AgeKey"
    }
    if (-not (Test-Path $SecretsDir)) {
        New-Item -ItemType Directory -Path $SecretsDir | Out-Null
    }
    & $keygen -o $AgeKey
    if ($LASTEXITCODE -ne 0) { throw "age-keygen failed" }
    $line = Get-Content $AgeKey | Where-Object { $_ -match '^# public key:' } | Select-Object -First 1
    if (-not $line) { throw "Could not read public key from $AgeKey" }
    ($line -replace '^# public key:\s*', '').Trim() | Set-Content -Path $AgePub -Encoding ascii
    Write-Host ""
    Write-Host "Private key -> $AgeKey  (DO NOT commit)"
    Write-Host "Public key  -> $AgePub  (safe to commit)"
}

function Invoke-Encrypt {
    $age = Get-AgeExe
    if (-not (Test-Path $AgePub)) {
        throw "Missing $AgePub. Run: make secrets-keygen"
    }
    $count = 0
    foreach ($name in $ManagedFiles) {
        $path = Get-PlaintextPath $name
        if (-not (Test-Path $path)) {
            Write-Host "skip     $name (not found)"
            continue
        }
        Write-Host "encrypt  $name -> $name.age"
        & $age -e -R $AgePub -o "$path.age" $path
        if ($LASTEXITCODE -ne 0) { throw "age encrypt failed for $name" }
        $count++
    }
    if ($count -eq 0) {
        Write-Host "Nothing to encrypt. Expected: $($ManagedFiles -join ', ') in terraform\secrets\"
    }
    else {
        Write-Host "Encrypted $count file(s). Commit only *.age - plaintext stays local."
    }
}

function Invoke-Decrypt {
    $age = Get-AgeExe
    if (-not (Test-Path $AgeKey)) {
        throw "Missing private key $AgeKey. Restore it before decrypting."
    }
    $count = 0
    foreach ($name in $ManagedFiles) {
        $enc = (Get-PlaintextPath $name) + ".age"
        if (-not (Test-Path $enc)) {
            Write-Host "skip     $name.age (not found)"
            continue
        }
        Write-Host "decrypt  $name.age -> $name"
        & $age -d -i $AgeKey -o (Get-PlaintextPath $name) $enc
        if ($LASTEXITCODE -ne 0) { throw "age decrypt failed for $name.age" }
        $count++
    }
    if ($count -eq 0) {
        Write-Host "No *.age files to decrypt in terraform\secrets\"
    }
    else {
        Write-Host "Decrypted $count file(s)."
    }
}

function Invoke-Clean {
    $count = 0
    foreach ($name in $ManagedFiles) {
        $path = Get-PlaintextPath $name
        if (-not (Test-Path $path)) { continue }
        if (Test-Path "$path.age") {
            Write-Host "remove   $name"
            Remove-Item -Force $path
            $count++
        }
        else {
            Write-Host "skip     $name (no $name.age - encrypt first)"
        }
    }
    Write-Host "Removed $count plaintext file(s)."
}

function Invoke-Status {
    Write-Host "=== $SecretsDir ==="
    if (Test-Path $AgeKey) { Write-Host "private key: present" } else { Write-Host "private key: MISSING (run: make secrets-keygen)" }
    if (Test-Path $AgePub) { Write-Host "public key:  present" } else { Write-Host "public key:  MISSING (run: make secrets-keygen)" }
    Write-Host ""
    Write-Host "file        plaintext  encrypted"
    Write-Host "----        ---------  ---------"
    foreach ($name in $ManagedFiles) {
        $path = Get-PlaintextPath $name
        $plain = if (Test-Path $path) { "yes" } else { "no " }
        $enc = if (Test-Path "$path.age") { "yes" } else { "no" }
        Write-Host ("{0,-11} {1,-10} {2}" -f $name, $plain, $enc)
    }
    Write-Host ""
    Write-Host "Only *.age files are committed. Plaintext is gitignored."
}

function Invoke-Push {
    if (-not $File -or -not $Secret) {
        throw "Usage: make secrets-push FILE=backend SECRET=trustex-dev-backend"
    }
    $path = Join-Path $SecretsDir $File
    if (-not (Test-Path $path)) {
        throw "Missing $path. Run make secrets-decrypt first."
    }
    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
        throw "Install Google Cloud SDK (gcloud)"
    }
    $exists = $true
    gcloud secrets describe $Secret 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $exists = $false }
    if (-not $exists) {
        Write-Host "Creating secret $Secret..."
        gcloud secrets create $Secret --replication-policy=automatic
        if ($LASTEXITCODE -ne 0) { throw "gcloud secrets create failed" }
    }
    gcloud secrets versions add $Secret --data-file=$path
    if ($LASTEXITCODE -ne 0) { throw "gcloud secrets versions add failed" }
    Write-Host "Uploaded $path -> Secret Manager: $Secret"
}

function Show-Help {
    @"
Secrets (age) - encrypts: $($ManagedFiles -join ', ')

  make secrets-keygen
  make secrets-encrypt
  make secrets-decrypt
  make secrets-clean
  make secrets-status
  make secrets-push FILE=backend SECRET=trustex-dev-backend

Without make:  .\scripts\secrets.ps1 <keygen|encrypt|decrypt|clean|status>

Install age: winget install FiloSottile.age
"@ | Write-Host
}

# Report failures as a plain message: a raw PowerShell exception buries the
# actual problem in a stack trace when these run through make.
try {
    switch ($Command) {
        "keygen" { Invoke-Keygen }
        "encrypt" { Invoke-Encrypt }
        "decrypt" { Invoke-Decrypt }
        "clean" { Invoke-Clean }
        "status" { Invoke-Status }
        "push" { Invoke-Push }
        default { Show-Help }
    }
}
catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    exit 1
}
