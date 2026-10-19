$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$installSources = @("install.sh", "lib/common.sh", "lib/dns.sh", "lib/cert.sh", "lib/services.sh", "lib/exits.sh", "lib/rules.sh", "lib/uninstall.sh")
$install = ($installSources | ForEach-Object { Get-Content -Path (Join-Path $root $_) -Raw -Encoding UTF8 }) -join "`n"
$sniproxy = Get-Content -Path (Join-Path $root "lib/sniproxy.conf") -Raw -Encoding UTF8
$guide = Get-Content -Path (Join-Path $root "docs/GUIDE.md") -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string]$Haystack,
        [string]$Needle,
        [string]$Description
    )

    if (-not $Haystack.Contains($Needle)) {
        throw "Missing sniproxy overseas resolver marker: $Description ($Needle)"
    }
}

$mainInstallMatch = [regex]::Match($install, '(?s)main_install\(\) \{.*?\n\}')
if (-not $mainInstallMatch.Success) {
    throw "main_install function not found"
}

$mainInstall = $mainInstallMatch.Value
$servicesIndex = $mainInstall.IndexOf('run_install_step "部署网络服务"')
# Both certificate paths (Cloudflare default, own domain via DOMAIN) must run
# before the services are deployed.
foreach ($stage in @('run_install_step "签发证书并创建 DoT 域名（Cloudflare）"', 'run_install_step "配置域名与 TLS 证书"')) {
    $certificateIndex = $mainInstall.IndexOf($stage)
    if ($certificateIndex -lt 0 -or $servicesIndex -lt 0 -or $certificateIndex -gt $servicesIndex) {
        throw "configure_dns_upstreams must run before install_sniproxy so sniproxy resolver uses custom remote DNS ($stage)"
    }
}

$dnsStageMatch = [regex]::Match($install, '(?s)install_stage_dns_settings\(\) \{.*?\n\}')
if (-not $dnsStageMatch.Success -or -not $dnsStageMatch.Value.Contains("configure_dns_upstreams")) {
    throw "install_stage_dns_settings must configure DNS before service deployment"
}
foreach ($name in @('install_stage_certificate', 'install_stage_cloudflare_certificate')) {
    $stageMatch = [regex]::Match($install, '(?s)' + $name + '\(\) \{.*?\n\}')
    $configuresDns = $stageMatch.Success -and $stageMatch.Value.Contains("install_stage_dns_settings")
    if (-not $configuresDns) {
        throw "$name must configure DNS before service deployment"
    }
}

$servicesStageMatch = [regex]::Match($install, '(?s)install_stage_deploy\(\) \{.*?\n\}')
if (-not $servicesStageMatch.Success -or -not $servicesStageMatch.Value.Contains("install_sniproxy")) {
    throw "install_stage_deploy must install sniproxy"
}

Assert-Contains $sniproxy 'resolver {' 'resolver stanza'
Assert-Contains $sniproxy '__SNIPROXY_NAMESERVERS__' 'sniproxy DNS placeholder'
Assert-Contains $sniproxy 'mode ipv4_only' 'sniproxy forced IPv4 mode'
Assert-Contains $install 'render_sniproxy_dns' 'installer renders sniproxy resolver'
Assert-Contains $install 'REMOTE_DNS' 'installer accepts remote DNS variable'
Assert-Contains $install '/etc/mosdns/.sniproxy_dns' 'installer saves sniproxy DNS config'
Assert-Contains $install '__SNIPROXY_NAMESERVERS__' 'installer replaces sniproxy DNS placeholder'
Assert-Contains $guide 'sniproxy' 'guide documents sniproxy'
Assert-Contains $guide '/etc/sniproxy.conf' 'guide documents reverse proxy DNS config'
Assert-Contains $guide 'ipv4_only' 'guide documents IPv4-only sniproxy resolver'

Write-Output "sniproxy overseas resolver markers OK"
