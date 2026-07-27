<#
.SYNOPSIS
    Autonomous gate enrollment for Windows — zero-operator mesh provisioning.

.DESCRIPTION
    Windows equivalent of gate-enroll.sh. Generates WireGuard keys, SSH keys,
    and calls mesh.gate_enroll on golgiBody to join the ecosystem mesh.

    Run from any Windows machine with WireGuard installed.

.PARAMETER Hub
    Enrollment hub hostname (default: primals.eco)

.PARAMETER Gate
    Gate name (e.g. blueGate, swiftGate)

.PARAMETER Token
    Pre-shared enrollment token

.PARAMETER Compose
    Composition profile (tower, compute, nest, full)

.PARAMETER HubPort
    Hub enrollment port (default: 7780)

.EXAMPLE
    .\gate-enroll.ps1 -Gate blueGate -Token <token> -Compose tower
#>

param(
    [string]$Hub = "primals.eco",
    [Parameter(Mandatory)][string]$Gate,
    [Parameter(Mandatory)][string]$Token,
    [string]$Compose = "tower",
    [int]$HubPort = 7780
)

$ErrorActionPreference = "Stop"

$EcoRoot = Join-Path $env:USERPROFILE "Development\ecoPrimals"

function Write-Phase {
    param([string]$Phase, [string]$Message)
    Write-Host "[$Phase] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  OK: $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  WARN: $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  FAIL: $Message" -ForegroundColor Red
}

# ── Phase 1: Prerequisites ──────────────────────────────────────

Write-Phase "1/7" "Checking prerequisites"

$wgExe = Get-Command wg -ErrorAction SilentlyContinue
if (-not $wgExe) {
    $wgPath = "C:\Program Files\WireGuard\wg.exe"
    if (Test-Path $wgPath) {
        $env:PATH += ";C:\Program Files\WireGuard"
    } else {
        Write-Fail "WireGuard not found. Install from https://www.wireguard.com/install/"
        exit 1
    }
}
Write-Ok "WireGuard found"

if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    Write-Fail "ssh-keygen not found. Enable OpenSSH in Windows Features."
    exit 1
}
Write-Ok "OpenSSH found"

# ── Phase 2: Generate WireGuard keypair ─────────────────────────

Write-Phase "2/7" "Generating WireGuard keypair"

$wgDir = Join-Path $env:USERPROFILE ".wireguard"
New-Item -ItemType Directory -Force -Path $wgDir | Out-Null

$wgPrivKeyFile = Join-Path $wgDir "privatekey"
$wgPubKeyFile = Join-Path $wgDir "publickey"

if (Test-Path $wgPubKeyFile) {
    $WgPubKey = Get-Content $wgPubKeyFile -Raw
    $WgPubKey = $WgPubKey.Trim()
    Write-Ok "Existing WG keypair found"
} else {
    $privKey = & wg genkey
    $privKey | Set-Content $wgPrivKeyFile -NoNewline
    $WgPubKey = $privKey | & wg pubkey
    $WgPubKey | Set-Content $wgPubKeyFile -NoNewline
    $WgPubKey = $WgPubKey.Trim()

    $acl = Get-Acl $wgPrivKeyFile
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        "FullControl", "Allow")
    $acl.SetAccessRule($rule)
    Set-Acl $wgPrivKeyFile $acl

    Write-Ok "WG keypair generated"
}
Write-Host "  Public key: $WgPubKey"

# ── Phase 3: Generate SSH keypair ───────────────────────────────

Write-Phase "3/7" "Generating SSH keypair"

$sshDir = Join-Path $env:USERPROFILE ".ssh"
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

$sshKeyFile = Join-Path $sshDir "id_ed25519_$Gate"
if (Test-Path $sshKeyFile) {
    Write-Ok "Existing SSH key found"
} else {
    & ssh-keygen -t ed25519 -f $sshKeyFile -N '""' -C "$Gate@ecoPrimals" -q
    Write-Ok "SSH key generated"
}

$SshPubKey = (Get-Content "$sshKeyFile.pub" -Raw).Trim()

# ── Phase 4: Build enrollment request ──────────────────────────

Write-Phase "4/7" "Enrolling with golgiBody ($Hub)"

$body = @{
    gate_name = $Gate
    wg_public_key = $WgPubKey
    ssh_public_key = $SshPubKey
    physical_proof = @{
        type = "token"
        token = $Token
    }
    composition = $Compose
} | ConvertTo-Json -Depth 5

$uri = "http://${Hub}:${HubPort}/enroll/mesh.gate_enroll"

try {
    $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 30
} catch {
    try {
        $wanUri = "https://${Hub}/enroll/mesh.gate_enroll"
        $response = Invoke-RestMethod -Uri $wanUri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 30
    } catch {
        Write-Fail "Cannot reach enrollment endpoint at $Hub"
        Write-Host "  Error: $_"
        exit 1
    }
}

if ($response.result) {
    $result = $response.result
} else {
    $result = $response
}

if (-not $result.enrolled) {
    Write-Fail "Enrollment rejected: $($result.reason)"
    foreach ($phase in $result.phases) {
        $color = if ($phase.ok) { "Green" } else { "Red" }
        Write-Host "  $($phase.name): $($phase.detail)" -ForegroundColor $color
    }
    exit 1
}

$MeshIp = $result.mesh_ip
Write-Ok "Enrolled! Mesh IP: $MeshIp"

foreach ($phase in $result.phases) {
    $color = if ($phase.ok) { "Green" } else { "Yellow" }
    Write-Host "  $($phase.name): $($phase.detail)" -ForegroundColor $color
}

# ── Phase 5: Configure WireGuard ────────────────────────────────

Write-Phase "5/7" "Configuring WireGuard"

if ($result.wg_config) {
    $wgConf = $result.wg_config
    $wgPrivKey = Get-Content $wgPrivKeyFile -Raw
    $wgPrivKey = $wgPrivKey.Trim()

    $confContent = @"
[Interface]
PrivateKey = $wgPrivKey
Address = $MeshIp/24
DNS = 10.13.37.1

[Peer]
PublicKey = $($wgConf.hub_public_key)
Endpoint = $($wgConf.hub_endpoint)
AllowedIPs = 10.13.37.0/24
PersistentKeepalive = 25
"@

    $wgConfPath = Join-Path $wgDir "wg0.conf"
    $confContent | Set-Content $wgConfPath -Encoding UTF8
    Write-Ok "WireGuard config written to $wgConfPath"
    Write-Host "  Import into WireGuard Windows app: $wgConfPath"
} else {
    Write-Warn "No WG config in response — configure manually"
}

# ── Phase 6: Configure Forgejo SSH ──────────────────────────────

Write-Phase "6/7" "Configuring Forgejo SSH"

$sshConfigPath = Join-Path $sshDir "config"
$forgejoEntry = @"

Host forgejo
    HostName $Hub
    Port 2222
    User git
    IdentityFile $sshKeyFile
    StrictHostKeyChecking accept-new
"@

$hasEntry = $false
if (Test-Path $sshConfigPath) {
    $hasEntry = (Get-Content $sshConfigPath -Raw) -match "Host forgejo"
}

if (-not $hasEntry) {
    Add-Content $sshConfigPath $forgejoEntry
    Write-Ok "SSH config for Forgejo added"
} else {
    Write-Ok "SSH config for Forgejo already exists"
}

New-Item -ItemType Directory -Force -Path $EcoRoot | Out-Null
Write-Ok "Ecosystem root: $EcoRoot"

# ── Phase 7: Save family seed ───────────────────────────────────

Write-Phase "7/7" "Finalizing enrollment"

if ($result.family_seed_encrypted) {
    $configDir = Join-Path $env:USERPROFILE ".config\ecoPrimals"
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    $seedPath = Join-Path $configDir "family_seed.enc"
    $result.family_seed_encrypted | Set-Content $seedPath
    $acl = Get-Acl $seedPath
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        "FullControl", "Allow")
    $acl.SetAccessRule($rule)
    Set-Acl $seedPath $acl
    Write-Ok "Family seed saved (encrypted)"
} else {
    Write-Warn "No family seed delivered — request manually or re-enroll"
}

# ── Summary ─────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Green
Write-Host "  Gate $Gate enrolled successfully!" -ForegroundColor Green
Write-Host ("=" * 55) -ForegroundColor Green
Write-Host ""
Write-Host "  Mesh IP:     $MeshIp"
Write-Host "  WG Config:   $wgDir\wg0.conf"
Write-Host "  Hub:         $Hub"
Write-Host "  Forgejo:     ssh://git@${Hub}:2222"
Write-Host "  Eco Root:    $EcoRoot"
Write-Host ""
Write-Host "Next steps (composition: $Compose):" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Import WG config:     Open WireGuard app -> Import tunnel -> $wgDir\wg0.conf"
Write-Host "  2. Activate tunnel:      Enable the wg0 tunnel in WireGuard app"
Write-Host "  3. Verify mesh:          ping 10.13.37.1"
Write-Host "  4. Clone repos:          cd $EcoRoot"
Write-Host "     git clone ssh://git@${Hub}:2222/ecoPrimals/wateringHole.git infra/wateringHole"
Write-Host "     git clone ssh://git@${Hub}:2222/ecoPrimals/plasmidBin.git infra/plasmidBin"
Write-Host "  5. Fetch binaries:       cd infra\plasmidBin && .\fetch.sh pull"
Write-Host ""
Write-Host "The gate is reachable via mesh at $MeshIp."
