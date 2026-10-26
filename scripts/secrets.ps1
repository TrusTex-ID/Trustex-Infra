# Encrypt / decrypt the secrets, tfvars and tfstate under terraform/ with age (Windows).
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
$TerraformDir = Join-Path $Root "terraform"
$SecretsDir = Join-Path $TerraformDir "secrets"
$AgeKey = Join-Path $SecretsDir ".age.key"
$AgePub = Join-Path $SecretsDir ".age.pubkey"

# The only files that get encrypted, relative to terraform/. Add a new one here
# and in scripts/secrets.sh, and un-ignore its .age in .gitignore.
$ManagedFiles = @("secrets/backend", "secrets/postgres", "terraform.tfvars", "terraform.tfstate")

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
    return (Join-Path $TerraformDir $Name)
}

# age output is randomised, so re-encrypting identical content still changes the
# .age. Comparing against the decrypted copy is the only way to tell whether the
# plaintext actually differs. $null means it cannot be told (no private key).
function Test-MatchesEncrypted {
    param([string]$Path)
    if (-not (Test-Path $AgeKey)) { return $null }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        & (Get-AgeExe) -d -i $AgeKey -o $tmp "$Path.age"
        if ($LASTEXITCODE -ne 0) { throw "age decrypt failed for $Path.age" }
        return ((Get-FileHash $tmp).Hash -eq (Get-FileHash $Path).Hash)
    }
    finally {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
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
        if ((Test-Path "$path.age") -and (Test-MatchesEncrypted $path)) {
            Write-Host "same     $name (unchanged)"
            continue
        }
        Write-Host "encrypt  $name -> $name.age"
        & $age -e -R $AgePub -o "$path.age" $path
        if ($LASTEXITCODE -ne 0) { throw "age encrypt failed for $name" }
        $count++
    }
    if ($count -eq 0) {
        Write-Host "Nothing new to encrypt. Managed under terraform\: $($ManagedFiles -join ', ')"
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
        $path = Get-PlaintextPath $name
        $enc = "$path.age"
        if (-not (Test-Path $enc)) {
            Write-Host "skip     $name.age (not found)"
            continue
        }
        # A local copy that differs may be newer than the committed one (a
        # tfstate after an apply that was never encrypted). Never overwrite it.
        if (Test-Path $path) {
            if (Test-MatchesEncrypted $path) {
                Write-Host "same     $name (already up to date)"
            }
            else {
                Write-Host "skip     $name (local copy differs from $name.age - encrypt it, or delete it to take the committed one)"
            }
            continue
        }
        Write-Host "decrypt  $name.age -> $name"
        & $age -d -i $AgeKey -o $path $enc
        if ($LASTEXITCODE -ne 0) { throw "age decrypt failed for $name.age" }
        $count++
    }
    if ($count -eq 0) {
        Write-Host "Nothing decrypted."
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
        if (-not (Test-Path "$path.age")) {
            Write-Host "skip     $name (no $name.age - encrypt first)"
            continue
        }
        $same = Test-MatchesEncrypted $path
        if ($null -eq $same) {
            Write-Host "skip     $name (no private key to check $name.age is current)"
        }
        elseif (-not $same) {
            Write-Host "skip     $name (differs from $name.age - encrypt first)"
        }
        else {
            Write-Host "remove   $name"
            Remove-Item -Force $path
            $count++
        }
    }
    Write-Host "Removed $count plaintext file(s)."
}

function Invoke-Status {
    Write-Host "=== $TerraformDir ==="
    if (Test-Path $AgeKey) { Write-Host "private key: present" } else { Write-Host "private key: MISSING (run: make secrets-keygen)" }
    if (Test-Path $AgePub) { Write-Host "public key:  present" } else { Write-Host "public key:  MISSING (run: make secrets-keygen)" }
    Write-Host ""
    Write-Host ("{0,-19} {1,-10} {2}" -f "file", "plaintext", "encrypted")
    Write-Host ("{0,-19} {1,-10} {2}" -f "----", "---------", "---------")
    foreach ($name in $ManagedFiles) {
        $path = Get-PlaintextPath $name
        $hasPlain = Test-Path $path
        $hasEnc = Test-Path "$path.age"
        $plain = if ($hasPlain) { "yes" } else { "no" }
        $enc = if (-not $hasEnc) { "no" }
        elseif (-not $hasPlain) { "yes" }
        else {
            $same = Test-MatchesEncrypted $path
            if ($null -eq $same) { "yes (unverified)" }
            elseif ($same) { "yes" }
            else { "STALE (run make secrets-encrypt)" }
        }
        Write-Host ("{0,-19} {1,-10} {2}" -f $name, $plain, $enc)
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
Secrets (age) - encrypts, under terraform\: $($ManagedFiles -join ', ')

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
