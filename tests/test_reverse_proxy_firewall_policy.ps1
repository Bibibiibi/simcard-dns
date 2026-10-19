$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
# Firewall/tuning helpers live in sourced modules and lib/host-setup.sh.
$installSources = @("install.sh", "lib/common.sh", "lib/dns.sh", "lib/cert.sh", "lib/services.sh", "lib/exits.sh", "lib/rules.sh", "lib/uninstall.sh", "lib/host-setup.sh")
$install = ($installSources | ForEach-Object { Get-Content -Path (Join-Path $root $_) -Raw -Encoding UTF8 }) -join "`n"
$readme = Get-Content -Path (Join-Path $root "README.md") -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string]$Haystack,
        [string]$Needle,
        [string]$Description
    )

    if (-not $Haystack.Contains($Needle)) {
        throw "Missing reverse proxy firewall marker: $Description ($Needle)"
    }
}

function Assert-NotContains {
    param(
        [string]$Haystack,
        [string]$Needle,
        [string]$Description
    )

    if ($Haystack.Contains($Needle)) {
        throw "Unexpected reverse proxy firewall marker: $Description ($Needle)"
    }
}

Assert-Contains $install 'ip saddr { __CLIENT_CIDRS__ } tcp dport { 80, 443 } accept' 'nft TCP reverse proxy client allow'
Assert-Contains $install 'ip saddr { __CLIENT_CIDRS__ } udp dport 443 accept' 'nft UDP reverse proxy client allow'
Assert-NotContains $install 'DEFAULT_CLIENT_CIDRS' 'no carrier is built in as the default client network'
Assert-Contains $install 'CLIENT_NONE="0.0.0.0/32"' 'no client networks match nobody in the firewall'
Assert-NotContains $install '172.22.0.0/16' 'private client network is no longer built in'
Assert-NotContains $install 'ip saddr 0.0.0.0/0' 'reverse proxy must never be opened to every source'
Assert-Contains $install 'tcp dport 853 meter dns_rate_dot' 'nft DoT per-IP QPS rate limit'
Assert-NotContains $install 'meter dns_rate_tcp53' 'obsolete nft DNS TCP/53 rate limit'
Assert-NotContains $install 'meter dns_rate_udp53' 'obsolete nft DNS UDP/53 rate limit'
Assert-Contains $install 'iptables -A INPUT -s "${net}" -p tcp -m multiport --dports 80,443 -j ACCEPT' 'iptables TCP reverse proxy client allow'
Assert-Contains $install 'iptables -A INPUT -s "${net}" -p udp --dport 443 -j ACCEPT' 'iptables UDP reverse proxy client allow'
Assert-Contains $install 'hashlimit-name dns_dot' 'iptables DoT per-IP QPS rate limit'
Assert-Contains $install 'iptables -F INPUT' 'iptables fallback flushes stale public reverse proxy rules'
Assert-Contains $install '--comment simcard-dns-cert-http' 'temporary HTTP rule is tagged'
Assert-Contains $install 'open_cert_http_port()' 'cert flow opens HTTP-01 port temporarily'
Assert-Contains $install 'restore_reverse_proxy_firewall()' 'cert flow restores reverse proxy whitelist'
Assert-Contains $install '--pre-hook /usr/local/bin/simcard-dns-open-cert-http.sh' 'certbot pre-hook opens port 80'
Assert-Contains $install '--post-hook /usr/local/bin/simcard-dns-restore-firewall.sh' 'certbot post-hook restores firewall'
Assert-Contains $install '/etc/letsencrypt/renewal-hooks/pre/10-simcard-dns-open-http.sh' 'automatic renew pre-hook'
Assert-Contains $install '/etc/letsencrypt/renewal-hooks/post/90-simcard-dns-restore-firewall.sh' 'automatic renew post-hook'
Assert-Contains $install 'Firewall configured (reverse proxy whitelist: $(current_client_cidrs))' 'firewall status message'
Assert-Contains $readme '--set-client-cidrs' 'README documents the client network whitelist'
Assert-Contains $readme '80/443' 'README documents reverse proxy ports'
Assert-Contains $readme '443' 'README documents reverse proxy port'

Write-Output "reverse proxy firewall markers OK"
