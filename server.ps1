param(
    [int]$Port = 8090,
    [string]$Root = $PSScriptRoot
)

$dataFile = Join-Path $Root "data.json"
$uploadsDir = Join-Path $Root "uploads"
$staticRoot = Join-Path $Root "public"
if (-not (Test-Path $uploadsDir)) { New-Item -ItemType Directory -Path $uploadsDir | Out-Null }

$mimeMap = @{
    ".html" = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif"  = "image/gif"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
    ".pdf"  = "application/pdf"
    ".docx" = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    ".xlsx" = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
}

function Read-HttpRequest {
    param($stream)

    # Read raw bytes until we hit the header/body separator (CRLFCRLF),
    # byte-by-byte so we never over-read past it (important for UTF-8 Thai bodies).
    $headerBytes = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1
    while ($true) {
        $n = $stream.Read($one, 0, 1)
        if ($n -eq 0) { break }
        $headerBytes.Add($one[0])
        $len = $headerBytes.Count
        if ($len -ge 4 -and
            $headerBytes[$len-4] -eq 13 -and $headerBytes[$len-3] -eq 10 -and
            $headerBytes[$len-2] -eq 13 -and $headerBytes[$len-1] -eq 10) {
            break
        }
    }

    $headerText = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $lines = $headerText -split "`r`n"
    $requestLine = $lines[0]

    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^([^:]+):\s*(.*)$') {
            $headers[$matches[1].ToLower()] = $matches[2]
        }
    }

    $method = ""
    $path = "/"
    if ($requestLine -match '^(\S+)\s+(\S+)\s+HTTP') {
        $method = $matches[1]
        $path = [System.Uri]::UnescapeDataString($matches[2])
    }

    $bodyBytes = [byte[]]@()
    if ($headers.ContainsKey('content-length')) {
        $contentLength = [int]$headers['content-length']
        $bodyBytes = New-Object byte[] $contentLength
        $read = 0
        while ($read -lt $contentLength) {
            $n = $stream.Read($bodyBytes, $read, $contentLength - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    }

    return [PSCustomObject]@{
        Method    = $method
        Path      = $path.Split('?')[0]
        Headers   = $headers
        BodyBytes = $bodyBytes
    }
}

function Send-Response {
    param($stream, [int]$StatusCode, [string]$StatusText, [byte[]]$Bytes, [string]$ContentType)
    $writer = New-Object System.IO.BinaryWriter($stream)
    $header = "HTTP/1.1 $StatusCode $StatusText`r`nContent-Type: $ContentType`r`nContent-Length: $($Bytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $writer.Write([System.Text.Encoding]::ASCII.GetBytes($header))
    if ($Bytes.Length -gt 0) { $writer.Write($Bytes) }
    $writer.Flush()
}

$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any, $Port)
$listener.Start()
Write-Host "Novel Helper server running at http://localhost:$Port"
Write-Host "Data file: $dataFile"
Write-Host "Press Ctrl+C to stop."

while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $stream.WriteTimeout = 5000
        $req = Read-HttpRequest $stream

        if ($req.Path -eq "/" -or $req.Path -eq "") { $req.Path = "/index.html" }

        if ($req.Path -eq "/api/data" -and $req.Method -eq "GET") {
            if (Test-Path $dataFile) {
                $bytes = [System.IO.File]::ReadAllBytes($dataFile)
            } else {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("null")
            }
            Send-Response $stream 200 "OK" $bytes "application/json; charset=utf-8"
        }
        elseif ($req.Path -eq "/api/data" -and $req.Method -eq "POST") {
            try {
                $bodyText = [System.Text.Encoding]::UTF8.GetString($req.BodyBytes)
                # Validate it's well-formed JSON before touching the file on disk.
                $bodyText | ConvertFrom-Json | Out-Null
                if (Test-Path $dataFile) {
                    Copy-Item $dataFile "$dataFile.bak" -Force
                }
                [System.IO.File]::WriteAllText($dataFile, $bodyText, (New-Object System.Text.UTF8Encoding($false)))
                $ok = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                Send-Response $stream 200 "OK" $ok "application/json; charset=utf-8"
            } catch {
                $err = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"invalid json"}')
                Send-Response $stream 400 "Bad Request" $err "application/json; charset=utf-8"
            }
        }
        elseif ($req.Path -eq "/api/upload" -and $req.Method -eq "POST") {
            try {
                $rawName = "file"
                if ($req.Headers.ContainsKey('x-file-name')) {
                    $rawName = [System.Uri]::UnescapeDataString($req.Headers['x-file-name'])
                }
                $safeName = ($rawName -replace '[\\/:*?"<>|]', '_').Trim()
                if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "file" }
                $finalName = ([guid]::NewGuid().ToString("N").Substring(0,10)) + "_" + $safeName
                $destPath = Join-Path $uploadsDir $finalName
                [System.IO.File]::WriteAllBytes($destPath, $req.BodyBytes)
                $respObj = @{ ok = $true; url = "/uploads/$finalName"; name = $rawName } | ConvertTo-Json -Compress
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($respObj)
                Send-Response $stream 200 "OK" $bytes "application/json; charset=utf-8"
            } catch {
                $err = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"upload failed"}')
                Send-Response $stream 500 "Internal Server Error" $err "application/json; charset=utf-8"
            }
        }
        elseif ($req.Method -eq "OPTIONS") {
            Send-Response $stream 200 "OK" ([byte[]]@()) "text/plain"
        }
        else {
            $relative = $req.Path.TrimStart("/")
            $isUpload = $relative.StartsWith("uploads/")
            $base = if ($isUpload) { $Root } else { $staticRoot }
            $filePath = Join-Path $base $relative
            $fullRoot = (Resolve-Path $base).Path
            $resolved = try { (Resolve-Path $filePath -ErrorAction Stop).Path } catch { $null }

            if ($resolved -and $resolved.StartsWith($fullRoot) -and (Test-Path $filePath -PathType Leaf)) {
                $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
                $contentType = if ($mimeMap.ContainsKey($ext)) { $mimeMap[$ext] } else { "application/octet-stream" }
                $bytes = [System.IO.File]::ReadAllBytes($filePath)
                Send-Response $stream 200 "OK" $bytes $contentType
            } else {
                $body = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
                Send-Response $stream 404 "Not Found" $body "text/plain; charset=utf-8"
            }
        }
    } catch {
        Write-Host "Request error: $_"
    } finally {
        $client.Close()
    }
}
