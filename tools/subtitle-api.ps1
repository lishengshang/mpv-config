# Windows PowerShell 5.1. Encrypt subtitle translation credentials for the current user.
[CmdletBinding()]
param(
    [ValidateSet('Configure', 'Read', 'Request')][string]$Action = 'Configure',
    [int]$OwnerPid = 0,
    [string]$Revision = '',
    [string]$RequestPath = '',
    [ValidateRange(1, 900)][int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$encoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $encoding
$config = Split-Path $PSScriptRoot -Parent
$directory = Join-Path $config 'state'
$settingsPath = Join-Path $directory 'subtitle-api.json'
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Net.Http

function Get-ServiceUri([string]$Endpoint) {
    $uri = $null
    if (![Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$uri) -or
            ($uri.Scheme -ne 'https' -and !($uri.Scheme -eq 'http' -and $uri.IsLoopback)) -or
            $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw '请输入完整的 HTTPS Chat Completions 地址，本机服务可用 HTTP。'
    }
    return $uri
}

function Read-Settings {
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $saved = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.revision -match '^[0-9a-f]{32}$' -and $saved.endpoint -and $saved.model -and $saved.protected_key) {
            return $saved
        }
    }
    return $null
}

function Read-Key($Saved) {
    $bytes = [Convert]::FromBase64String($Saved.protected_key)
    return $encoding.GetString([Security.Cryptography.ProtectedData]::Unprotect(
        $bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
}

function Save-Settings([Uri]$Uri, [string]$Model, [string]$Key) {
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        $encoding.GetBytes($Key), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $saved = @{
        endpoint = $Uri.AbsoluteUri
        model = $Model
        revision = [Guid]::NewGuid().ToString('N')
        protected_key = [Convert]::ToBase64String($protected)
    }
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $pending = Join-Path $directory ("subtitle-api.$($saved.revision).tmp")
    try {
        [IO.File]::WriteAllText($pending, ($saved | ConvertTo-Json -Compress) + [char]10, $encoding)
        if ([IO.File]::Exists($settingsPath)) {
            [IO.File]::Replace($pending, $settingsPath, [NullString]::Value)
        } else {
            [IO.File]::Move($pending, $settingsPath)
        }
    } finally {
        if ([IO.File]::Exists($pending)) { [IO.File]::Delete($pending) }
    }
    return $saved
}

function Write-PublicSettings($Saved) {
    @{endpoint = $Saved.endpoint; model = $Saved.model; revision = $Saved.revision} |
        ConvertTo-Json -Compress
}

function Invoke-Completion([Uri]$Uri, [string]$Key, [string]$Json, [int]$Timeout) {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $Uri)
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Key)
        $request.Content = [Net.Http.StringContent]::new($Json, $encoding, 'application/json')
        $reply = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            return @{
                status = [int]$reply.StatusCode
                retry_after = [string]$reply.Headers.RetryAfter
                body = $reply.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
        } finally { $reply.Dispose() }
    } finally {
        $request.Dispose()
        $client.Dispose()
    }
}

if ($Action -ne 'Configure') {
    try {
        $saved = Read-Settings
        if (!$saved) { exit 3 }
        $key = Read-Key $saved
        if ($Action -eq 'Read') {
            Write-PublicSettings $saved
        } else {
            if ($saved.revision -cne $Revision) { exit 3 }
            $uri = Get-ServiceUri $saved.endpoint
            $payload = [IO.File]::ReadAllText($RequestPath, $encoding)
            Invoke-Completion $uri $key $payload $TimeoutSeconds | ConvertTo-Json -Compress
        }
    } catch {
        # Credentials and errors from the remote service stay out of the player log.
        exit 4
    }
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$existing = $null
try { $existing = Read-Settings } catch { }
$script:result = $null
$form = [Windows.Forms.Form]::new()
$form.Text = '字幕翻译服务'
$form.ClientSize = [Drawing.Size]::new(580, 320)
$form.AutoScaleMode = 'Dpi'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MinimizeBox = $false
$form.MaximizeBox = $false
$form.ShowInTaskbar = $true

function Add-Label([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $label = [Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Location = [Drawing.Point]::new($X, $Y)
    $label.Size = [Drawing.Size]::new($Width, $Height)
    $form.Controls.Add($label)
    return $label
}

function Add-Field([string]$Name, [string]$Value, [int]$Y) {
    $field = [Windows.Forms.TextBox]::new()
    $field.Name = $Name
    $field.AccessibleName = $Name
    $field.Text = $Value
    $field.Location = [Drawing.Point]::new(22, $Y)
    $field.Width = 536
    $form.Controls.Add($field)
    return $field
}

$null = Add-Label '填写 OpenAI 兼容接口的 API Key。测试会发送一句固定短语，翻译时会发送字幕文本。' 22 14 536 30
$null = Add-Label 'Chat Completions 接口地址' 22 57 536 18
$endpoint = Add-Field '接口地址' $(if ($existing) { $existing.endpoint } else { 'https://open.bigmodel.cn/api/paas/v4/chat/completions' }) 79
$null = Add-Label '模型名称' 22 111 536 18
$model = Add-Field '模型名称' $(if ($existing) { $existing.model } else { 'glm-4-flash' }) 132
$null = Add-Label 'API Key' 22 164 536 18
$keyField = Add-Field 'API Key' '' 185
$keyField.UseSystemPasswordChar = $true
$status = Add-Label $(if ($existing) { '已保存设置。粘贴 Key 后可测试并替换。' } else { '可直接粘贴智谱 API Key，或填写其他兼容服务的地址和模型。' }) 22 222 536 37

$save = [Windows.Forms.Button]::new()
$save.Text = '测试并保存'
$save.Location = [Drawing.Point]::new(338, 272)
$save.Size = [Drawing.Size]::new(116, 30)
$form.Controls.Add($save)
$form.AcceptButton = $save
$cancel = [Windows.Forms.Button]::new()
$cancel.Text = '取消'
$cancel.DialogResult = 'Cancel'
$cancel.Location = [Drawing.Point]::new(466, 272)
$cancel.Size = [Drawing.Size]::new(92, 30)
$form.Controls.Add($cancel)
$form.CancelButton = $cancel
$form.ActiveControl = $keyField
$save.Add_Click({
    $key = $keyField.Text.Trim()
    $modelName = $model.Text.Trim()
    if ($key -notmatch '^[!-~]+$' -or !$modelName) {
        $status.Text = '请填写模型和有效的 API Key。'
        return
    }
    try { $uri = Get-ServiceUri $endpoint.Text.Trim() } catch {
        $status.Text = $_.Exception.Message
        return
    }
    $save.Enabled = $false
    $form.UseWaitCursor = $true
    $status.Text = '正在测试接口…'
    $form.Refresh()
    try {
        $test = @{model = $modelName; max_tokens = 32; messages = @(@{role = 'user'; content = 'Reply with OK.'})}
        try {
            $reply = Invoke-Completion $uri $key ($test | ConvertTo-Json -Depth 4 -Compress) 15
            if ($reply.status -lt 200 -or $reply.status -ge 300) {
                $status.Text = "接口返回 HTTP $($reply.status)。请检查地址、模型和 Key。"
                return
            }
            $data = $reply.body | ConvertFrom-Json
            if (!$data.choices -or $data.choices[0].message.content -isnot [string] -or
                    !$data.choices[0].message.content.Trim()) {
                $status.Text = '接口已连接，但响应缺少 Chat Completions 的文本。'
                return
            }
        } catch {
            $status.Text = '接口测试失败。请检查网络、服务地址与响应格式。'
            return
        }
        try { $script:result = Save-Settings $uri $modelName $key } catch {
            $status.Text = '接口测试成功，但设置保存失败。请检查播放器目录的写入权限。'
            return
        }
        $form.DialogResult = 'OK'
    } finally {
        $form.UseWaitCursor = $false
        $save.Enabled = $true
    }
})

$owner = $null
try {
    $ownerProcess = if ($OwnerPid) { Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue }
    if ($ownerProcess -and $ownerProcess.MainWindowHandle -ne [IntPtr]::Zero) {
        $owner = [Windows.Forms.NativeWindow]::new()
        $owner.AssignHandle($ownerProcess.MainWindowHandle)
        $form.StartPosition = 'CenterParent'
        $choice = $form.ShowDialog($owner)
    } else {
        $choice = $form.ShowDialog()
    }
    if ($choice -ne 'OK' -or !$script:result) { exit 2 }
    Write-PublicSettings $script:result
} finally {
    if ($owner) { $owner.ReleaseHandle() }
    $form.Dispose()
}
