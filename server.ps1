# Wi-Fi Monitor: zero-dependency local page showing Wi-Fi signal and channel crowding.
# Run start.bat, then open http://localhost:8098
param([switch]$NoBrowser)

$Port = 8098
$MyNetworks = @()   # add your own network names to highlight them, e.g. @('HomeWiFi', 'HomeWiFi-5G')

# Asks Windows for a fresh Wi-Fi scan (netsh alone only shows cached results).
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WlanScanner {
    [DllImport("wlanapi.dll")] static extern int WlanOpenHandle(uint v, IntPtr r, out uint nv, out IntPtr h);
    [DllImport("wlanapi.dll")] static extern int WlanEnumInterfaces(IntPtr h, IntPtr r, out IntPtr list);
    [DllImport("wlanapi.dll")] static extern int WlanScan(IntPtr h, ref Guid g, IntPtr ssid, IntPtr ie, IntPtr r);
    [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr p);
    [DllImport("wlanapi.dll")] static extern int WlanCloseHandle(IntPtr h, IntPtr r);
    public static void ScanAll() {
        uint nv; IntPtr h;
        if (WlanOpenHandle(2, IntPtr.Zero, out nv, out h) != 0) return;
        IntPtr list;
        if (WlanEnumInterfaces(h, IntPtr.Zero, out list) == 0) {
            int n = Marshal.ReadInt32(list);
            for (int i = 0; i < n; i++) {
                // list header is 8 bytes; each WLAN_INTERFACE_INFO is 532 bytes (GUID + 256 wchars + state)
                IntPtr item = new IntPtr(list.ToInt64() + 8 + i * 532);
                Guid g = (Guid)Marshal.PtrToStructure(item, typeof(Guid));
                WlanScan(h, ref g, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            }
            WlanFreeMemory(list);
        }
        WlanCloseHandle(h, IntPtr.Zero);
    }
}
"@

function Get-WifiNetworks {
    $nets = @(); $ssid = $null; $cur = $null
    foreach ($line in (netsh wlan show networks mode=bssid)) {
        if ($line -match '^SSID \d+ : ?(.*)$') { $ssid = $Matches[1].Trim(); continue }
        if ($line -match '^\s+BSSID \d+\s+: (.+)$') {
            $cur = [ordered]@{ ssid = $ssid; bssid = $Matches[1].Trim(); signal = 0; band = ''; channel = 0
                               stations = $null; util = $null; mine = ($MyNetworks -contains $ssid) }
            $nets += $cur; continue
        }
        if (-not $cur) { continue }
        if     ($line -match '^\s+Signal\s+: (\d+)%')              { $cur.signal = [int]$Matches[1] }
        elseif ($line -match '^\s+Band\s+: (.+)$')                 { $cur.band = $Matches[1].Trim() }
        elseif ($line -match '^\s+Channel\s+: (\d+)')              { $cur.channel = [int]$Matches[1] }
        elseif ($line -match 'Connected Stations:\s+(\d+)')        { $cur.stations = [int]$Matches[1] }
        elseif ($line -match 'Channel Utilization:.*\((\d+) %\)')  { $cur.util = [int]$Matches[1] }
    }
    $nets
}

function Get-AdapterState {
    foreach ($line in (netsh wlan show interfaces)) {
        if ($line -match '^\s+State\s+: (.+)$') { return $Matches[1].Trim() }
    }
    'not found'
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Wi-Fi Monitor running at http://localhost:$Port  (Ctrl+C to stop)"
if (-not $NoBrowser) { Start-Process "http://localhost:$Port" }

$lastScan = [datetime]::MinValue
$seen = @{}
try {
    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.Wait(500)) {}   # short waits so Ctrl+C works
        $ctx = $task.Result; $res = $ctx.Response
        try {
            if ($ctx.Request.Url.AbsolutePath -eq '/data') {
                if (((Get-Date) - $lastScan).TotalSeconds -ge 10) { [WlanScanner]::ScanAll(); $lastScan = Get-Date }
                # A fresh scan briefly empties the list, so keep networks seen in the last 20 s.
                $now = Get-Date
                foreach ($n in Get-WifiNetworks) { $seen[$n.bssid] = @{ net = $n; time = $now } }
                foreach ($k in @($seen.Keys)) { if (($now - $seen[$k].time).TotalSeconds -gt 20) { $seen.Remove($k) } }
                $body = ConvertTo-Json -Compress -Depth 4 -InputObject @{ adapter = (Get-AdapterState); nets = @($seen.Values | ForEach-Object { $_.net }) }
                $type = 'application/json'
            } else {
                $body = [IO.File]::ReadAllText("$PSScriptRoot\index.html")
                $type = 'text/html; charset=utf-8'
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes($body)
            $res.ContentType = $type
            $res.Headers['Cache-Control'] = 'no-store'
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch { $res.StatusCode = 500 } finally { $res.Close() }
    }
} finally { $listener.Stop() }
