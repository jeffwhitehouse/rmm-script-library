<#
================================================================================
  RMM Script Library - Get-AIAppInventory
================================================================================
  PURPOSE : READ-ONLY inventory of AI applications, coding assistants, local
            LLM runtimes and model files on an endpoint. Built to answer
            "is this user running AI apps or local models on their laptop"
            without remoting in. Checks:
              - installed programs (machine + loaded user hives) and Store apps
              - known AI install / model-store folders per profile
              - Start Menu / Desktop shortcuts (catches browser PWAs)
              - dev tooling: npm globals, pip site-packages, VS Code/Cursor
                extensions, CUDA toolkit, Python/conda, Docker, WSL distros
              - model files (gguf/safetensors/ckpt/...) and all files >= 1 GB
                on every fixed drive (robocopy list mode, skips C:\Windows)
              - execution evidence: running processes, GPU compute apps,
                listening ports, services, scheduled tasks, autostarts,
                Prefetch, BAM (execution history), UserAssist (launch counts)
              - browser extensions (Chrome/Edge/Brave/Firefox) by name
              - AI web endpoints currently in the DNS resolver cache
              - Defender exclusions that reference AI tooling
            Browser HISTORY is deliberately NOT read. No user documents are
            opened; only file names, sizes and locations are reported.

  RMM SETTINGS:
    - Script type : PowerShell
    - Run as      : System
    - Max run time: 20 minutes (drive scan is the slow part)

  EXIT CODES:  0 = no AI indicators found (RESULT: OK)
               1 = AI indicators found - review the list (RESULT: NEEDS-ATTENTION)
               2 = script error (RESULT: SCRIPT-ERROR)

  OUTPUT  : Console shows a capped summary per section. The FULL detail is in
            the log + a JSON twin at C:\ProgramData\RMMScripts\Logs\
            (Get-AIAppInventory-<timestamp>.log / .json). Retrieve with your RMM's
            file transfer or a follow-up Get-Content run.

  VERSION : 0.1-DEV (2026-09-15)  - initial build
================================================================================
#>

# ---- If launched as 32-bit PowerShell on 64-bit Windows, relaunch 64-bit -----
if ($env:PROCESSOR_ARCHITEW6432) {
    $sysnative = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $sysnative) {
        & $sysnative -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
}

$ScriptName    = 'Get-AIAppInventory'
$ScriptVersion = '0.1-DEV'
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$script:OutBuf   = New-Object System.Collections.Generic.List[string]
$script:Issues   = New-Object System.Collections.Generic.List[string]
$script:Findings = New-Object System.Collections.Generic.List[object]
$script:Data     = [ordered]@{}
$script:MaxShow  = 15
$script:Started  = Get-Date

function W    { param([string]$Text = '') $script:OutBuf.Add($Text) | Out-Null; Write-Output $Text }
function L    { param([string]$Text = '') $script:OutBuf.Add($Text) | Out-Null }   # log only
function Flag { param([string]$Text) $script:Issues.Add($Text) | Out-Null }
function Sect { param([string]$Title) W ''; W (("---- {0} " -f $Title).PadRight(64, '-')) }

function Add-Finding {
    param([string]$Category, [string]$Text, [switch]$Strong)
    $script:Findings.Add([pscustomobject]@{ Category = $Category; Strong = [bool]$Strong; Text = $Text }) | Out-Null
    if ($Strong) { Flag ("[{0}] {1}" -f $Category, $Text) }
}

# Print up to MaxShow lines to console, the rest to the log only.
function Show-List {
    param([string[]]$Lines, [string]$Empty = '  (none)')
    if (-not $Lines -or $Lines.Count -eq 0) { W $Empty; return }
    $i = 0
    foreach ($ln in $Lines) {
        $i++
        if ($i -le $script:MaxShow) { W ("  {0}" -f $ln) } else { L ("  {0}" -f $ln) }
    }
    if ($Lines.Count -gt $script:MaxShow) { W ("  (+{0} more - see log file)" -f ($Lines.Count - $script:MaxShow)) }
}

function Save-Log {
    try {
        $dir = 'C:\ProgramData\RMMScripts\Logs'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $file  = Join-Path $dir ("{0}-{1}.log"  -f $ScriptName, $stamp)
        $json  = Join-Path $dir ("{0}-{1}.json" -f $ScriptName, $stamp)
        $script:OutBuf | Set-Content -Path $file -Encoding UTF8
        $script:Data['Findings'] = $script:Findings.ToArray()
        $script:Data['Issues']   = $script:Issues.ToArray()
        $script:Data | ConvertTo-Json -Depth 6 | Set-Content -Path $json -Encoding UTF8
        W ("Full log : {0}" -f $file)
        W ("JSON     : {0}" -f $json)
    } catch { W ("(log save failed: {0})" -f $_.Exception.Message) }
}

function Finish {
    W ''
    W ('=' * 64)
    W ("Elapsed: {0:N0} s" -f ((Get-Date) - $script:Started).TotalSeconds)
    $strong = @($script:Findings | Where-Object { $_.Strong }).Count
    $weak   = @($script:Findings | Where-Object { -not $_.Strong }).Count
    W ("Findings: {0} strong indicator(s), {1} weak/contextual" -f $strong, $weak)
    if ($script:Issues.Count -gt 0) {
        W 'ISSUES FOUND (AI indicators - review, this script judges nothing):'
        foreach ($i in $script:Issues) { W ("  ! {0}" -f $i) }
        W ''
        W ("RESULT: NEEDS-ATTENTION ({0} indicator(s))" -f $script:Issues.Count)
        Save-Log
        exit 1
    } else {
        W 'No AI indicators found.'
        W ''
        W 'RESULT: OK'
        Save-Log
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Keyword engine
# ---------------------------------------------------------------------------
$LooseTerms = @(
  'ollama','lm studio','lmstudio','lm-studio','gpt4all','nomic','anythingllm','open webui','open-webui','openwebui',
  'koboldcpp','koboldai','llama.cpp','llama-cpp','llama_cpp','llamacpp','llama-server','llamafile','text-generation-webui',
  'oobabooga','comfyui','stable diffusion','stable-diffusion','stablediffusion','automatic1111','invokeai','fooocus','vllm',
  'localai','lmdeploy','exllama','whisper','sillytavern','pinokio','msty','jan.ai','janai','cortex.cpp',
  'claude','anthropic','chatgpt','openai','copilot','windsurf','codeium','tabnine','perplexity','deepseek','huggingface',
  'hugging face','transformers','pytorch','tensorflow','onnxruntime','stabilityai','stability ai','midjourney','character.ai',
  'characterai','writesonic','grammarly','fireflies','chatsonic','genspark','autogpt','crewai','flowise','langchain',
  'llamaindex','llama-index','llama_index','diffusers','ctransformers','bitsandbytes','xformers','cudnn','tensorrt',
  'openvino','directml','notebooklm','mixtral','gguf','ggml','safetensors','ai toolkit','foundry local','textgen',
  'gpt-','gpt4','gpt-oss','llama2','llama3','llama-2','llama-3','gemma','qwen','phi-3','phi-4','mistral',
  'cline','roo-cline','claude-dev','amazon-q','geminicodeassist','kilocode','supermaven','blackbox','continue.continue',
  'continue.dev','litellm','tiktoken','sentence-transformers','sentence_transformers','huggingface_hub','auto_gptq',
  'exllamav2','peft','openrouter','elevenlabs','runwayml','leonardo.ai','civitai','replicate','together.ai','groq',
  'nvidia gpu computing toolkit','cuda toolkit','ai studio','aistudio','meta.ai','moonshot','kimi'
)
$WordTerms = @('cursor','jan','codex','gemini','grok','torch','merlin','sider','harpa','phind','replit','lovable','manus',
               'aider','dify','n8n','cuda','poe','llm','llama','lora','suno')
$rxLoose = ($LooseTerms | ForEach-Object { [regex]::Escape($_) }) -join '|'
$rxWord  = ($WordTerms  | ForEach-Object { [regex]::Escape($_) }) -join '|'
$script:AiRx = New-Object System.Text.RegularExpressions.Regex(("(?:{0})|(?<![a-z0-9])(?:{1})(?![a-z0-9])" -f $rxLoose, $rxWord), 'IgnoreCase')
function Test-AI { param([string]$Text) if ([string]::IsNullOrEmpty($Text)) { return $false } return $script:AiRx.IsMatch($Text) }
function Get-AIHit { param([string]$Text) if ([string]::IsNullOrEmpty($Text)) { return '' } $m = $script:AiRx.Match($Text); if ($m.Success) { return $m.Value } return '' }

# Microsoft-published Copilot pieces are usually corporate-sanctioned; label them.
function Test-MicrosoftCopilot { param([string]$Name, [string]$Publisher)
    return (($Name -match 'copilot') -and (($Publisher -match 'microsoft') -or ($Name -match '^Microsoft')))
}

$AiDomainRx = New-Object System.Text.RegularExpressions.Regex(
  '(openai\.com|chatgpt\.com|oaistatic\.com|oaiusercontent\.com|anthropic\.com|claude\.ai|gemini\.google\.com|aistudio\.google\.com|generativelanguage\.googleapis\.com|notebooklm\.google\.com|copilot\.microsoft\.com|githubcopilot\.com|copilot-proxy\.githubusercontent\.com|huggingface\.co|hf\.co|ollama\.com|ollama\.ai|lmstudio\.ai|openrouter\.ai|perplexity\.ai|deepseek\.com|mistral\.ai|x\.ai|grok\.com|poe\.com|character\.ai|midjourney\.com|replicate\.com|together\.ai|groq\.com|civitai\.com|cursor\.sh|cursor\.com|codeium\.com|windsurf\.com|tabnine\.com|jasper\.ai|writesonic\.com|otter\.ai|fireflies\.ai|stability\.ai|leonardo\.ai|runwayml\.com|elevenlabs\.io|suno\.com|you\.com|phind\.com|meta\.ai|manus\.im|genspark\.ai|lovable\.dev|bolt\.new|v0\.dev|replit\.com|moonshot\.cn|moonshot\.ai|qwen\.ai|doubao\.com|kimi\.com|nomic\.ai|gpt4all\.io|jan\.ai|anythingllm\.com|msty\.app|pinokio\.computer|comfy\.org)$',
  'IgnoreCase')

$ModelExtStrong = @('.gguf','.ggml','.safetensors','.ckpt','.llamafile','.nemo')
$ModelExtWeak   = @('.pt','.pth','.onnx','.bin','.mlmodel','.tflite','.h5','.pb','.msgpack','.engine','.npz')

function Get-DirSizeGB { param([string]$Path)
    try { $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
          if (-not $s) { $s = 0 }; return [math]::Round($s / 1GB, 2) } catch { return 0 }
}
function Rot13 { param([string]$s)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) { $c = [int]$ch
        if ($c -ge 65 -and $c -le 90)      { [void]$sb.Append([char]((($c - 65 + 13) % 26) + 65)) }
        elseif ($c -ge 97 -and $c -le 122) { [void]$sb.Append([char]((($c - 97 + 13) % 26) + 97)) }
        else { [void]$sb.Append($ch) } }
    return $sb.ToString()
}
function Sid-ToName { param([string]$Sid)
    try { return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { return $Sid }
}
function Read-ExtName { param([string]$VerDir)
    try {
        $mf = Join-Path $VerDir 'manifest.json'; if (-not (Test-Path -LiteralPath $mf)) { return $null }
        $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $name = [string]$m.name
        if ($name -match '^__MSG_(.+)__$') {
            $key = $matches[1]; $loc = $m.default_locale; if (-not $loc) { $loc = 'en' }
            foreach ($lc in @($loc, 'en', 'en_US', 'en_GB')) {
                $mj = Join-Path $VerDir ("_locales\{0}\messages.json" -f $lc)
                if (Test-Path -LiteralPath $mj) { $msgs = Get-Content -LiteralPath $mj -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $prop = $msgs.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1
                    if ($prop) { $name = [string]$prop.Value.message; break } }
            }
        }
        return $name
    } catch { return $null }
}

try {
    W ('=' * 64)
    W (" {0}  v{1}" -f $ScriptName, $ScriptVersion)
    W ('=' * 64)
    W (" Computer   : {0}" -f $env:COMPUTERNAME)
    W (" Running as : {0}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    W (" Time       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    W (" Elevated   : {0}" -f $isAdmin)
    if (-not $isAdmin) { W ' NOTE: not elevated - Store apps (all users), Prefetch, BAM, features and other-user data will be incomplete.' }
    $script:Data['Computer'] = $env:COMPUTERNAME; $script:Data['RunAs'] = [Security.Principal.WindowsIdentity]::GetCurrent().Name; $script:Data['Time'] = (Get-Date).ToString('s')

    # ---------------- User profiles ----------------
    Sect 'User profiles on this machine'
    $profiles = New-Object System.Collections.Generic.List[object]
    $plist = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue
    foreach ($p in $plist) {
        $sid = $p.PSChildName
        if ($sid -notmatch '^S-1-(5-21|12-1)-') { continue }
        $path = (Get-ItemProperty $p.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $path -or -not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { continue }
        $loaded = Test-Path ("Registry::HKEY_USERS\{0}" -f $sid) -ErrorAction SilentlyContinue
        $lastUse = (Get-Item -LiteralPath (Join-Path $path 'NTUSER.DAT') -Force -ErrorAction SilentlyContinue).LastWriteTime
        $profiles.Add([pscustomobject]@{ Sid = $sid; Path = $path; User = (Split-Path $path -Leaf); Loaded = $loaded; LastUse = $lastUse }) | Out-Null
    }
    $profLines = @(); foreach ($pr in $profiles) { $profLines += ("{0,-22} {1,-45} hive loaded={2}  NTUSER last write={3}" -f $pr.User, $pr.Path, $pr.Loaded, $(if ($pr.LastUse) { $pr.LastUse.ToString('yyyy-MM-dd') } else { '?' })) }
    Show-List $profLines
    $script:Data['Profiles'] = @($profiles | Select-Object User, Path, Loaded, @{n='LastUse';e={ if ($_.LastUse) { $_.LastUse.ToString('s') } else { $null } }})
    $lo = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | ForEach-Object { try { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction Stop; "{0}\{1}" -f $o.Domain, $o.User } catch { } } | Sort-Object -Unique
    W ("Interactive sessions now : {0}" -f $(if ($lo) { $lo -join ', ' } else { 'none' }))
    W 'Note: per-user REGISTRY checks only cover loaded hives (signed-in users). File-system checks cover every profile.'

    # ---------------- Installed programs ----------------
    Sect 'Installed programs (AI keyword matches)'
    $progs = New-Object System.Collections.Generic.List[object]
    $unKeys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    foreach ($pr in $profiles) { if ($pr.Loaded) { $unKeys += ("Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Uninstall" -f $pr.Sid) } }
    $total = 0
    foreach ($k in $unKeys) {
        $scope = 'machine'
        if ($k -like 'Registry::HKEY_USERS*') { $owner = $profiles | Where-Object { $k -like ("*{0}*" -f $_.Sid) } | Select-Object -First 1; $scope = 'user:' + $owner.User }
        Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object {
            $v = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($v.DisplayName) {
                $total++
                $blob = "{0} {1} {2} {3}" -f $v.DisplayName, $v.Publisher, $v.InstallLocation, $v.UninstallString
                if (Test-AI $blob) {
                    $progs.Add([pscustomobject]@{ Scope = $scope; Name = $v.DisplayName; Version = $v.DisplayVersion; Publisher = $v.Publisher; InstallDate = $v.InstallDate; Location = $v.InstallLocation; Hit = (Get-AIHit $blob); MsCopilot = (Test-MicrosoftCopilot $v.DisplayName $v.Publisher) }) | Out-Null
                }
            }
        }
    }
    W ("Uninstall entries scanned: {0}" -f $total)
    $lines = @(); foreach ($p in ($progs | Sort-Object Name -Unique)) {
        $tag = ''; if ($p.MsCopilot) { $tag = ' [Microsoft Copilot - likely sanctioned]' }
        $lines += ("{0,-8} {1}  v{2}  ({3}) installed={4} {5}{6}" -f $p.Scope, $p.Name, $p.Version, $p.Publisher, $p.InstallDate, $p.Location, $tag)
        if ($p.MsCopilot) { Add-Finding 'Installed' ("{0} (Microsoft Copilot component)" -f $p.Name) } else { Add-Finding 'Installed' ("{0} v{1} by {2} [{3}]" -f $p.Name, $p.Version, $p.Publisher, $p.Scope) -Strong }
    }
    Show-List $lines
    $script:Data['InstalledPrograms'] = $progs.ToArray()

    # ---------------- Store / MSIX apps ----------------
    Sect 'Store / MSIX apps (AI keyword matches)'
    $appx = @()
    try { $appx = Get-AppxPackage -AllUsers -ErrorAction Stop } catch { try { $appx = Get-AppxPackage -ErrorAction Stop; W '(current-user Appx only - not elevated)' } catch { W '(Appx enumeration unavailable)' } }
    $appxHits = New-Object System.Collections.Generic.List[object]
    foreach ($a in $appx) {
        if (Test-AI ("{0} {1}" -f $a.Name, $a.InstallLocation)) {
            $users = @(); try { $users = @($a.PackageUserInformation | ForEach-Object { $_.UserSecurityId.Username }) } catch { }
            $appxHits.Add([pscustomobject]@{ Name = $a.Name; Version = $a.Version; Publisher = $a.Publisher; Users = ($users -join ','); Location = $a.InstallLocation; MsCopilot = (Test-MicrosoftCopilot $a.Name $a.Publisher) }) | Out-Null
        }
    }
    W ("Packages scanned: {0}" -f @($appx).Count)
    $lines = @(); foreach ($a in ($appxHits | Sort-Object Name -Unique)) {
        $isMs = ($a.MsCopilot -or $a.Name -match '^Microsoft(Windows)?\.')
        $tag = ''; if ($isMs) { $tag = ' [Microsoft-published]' }
        $lines += ("{0}  v{1}  users={2}{3}" -f $a.Name, $a.Version, $a.Users, $tag)
        if ($isMs) { Add-Finding 'StoreApp' ("{0} (Microsoft-published)" -f $a.Name) } else { Add-Finding 'StoreApp' ("{0} v{1} users={2}" -f $a.Name, $a.Version, $a.Users) -Strong }
    }
    Show-List $lines
    $script:Data['StoreApps'] = $appxHits.ToArray()

    # ---------------- Known AI folders ----------------
    Sect 'Known AI app / model-store folders'
    # label, relative path under profile, isModelStore
    $userDirs = @(
      @('Ollama app',              'AppData\Local\Programs\Ollama',                     $false),
      @('Ollama models',           '.ollama',                                           $true),
      @('LM Studio app',           'AppData\Local\Programs\LM Studio',                  $false),
      @('LM Studio app (alt)',     'AppData\Local\LM-Studio',                           $false),
      @('LM Studio data/models',   '.lmstudio',                                         $true),
      @('LM Studio models (old)',  '.cache\lm-studio',                                  $true),
      @('GPT4All',                 'AppData\Local\nomic.ai',                            $true),
      @('Jan',                     'AppData\Roaming\Jan',                               $true),
      @('Jan data',                'jan',                                               $true),
      @('Msty',                    'AppData\Local\Programs\Msty',                       $false),
      @('Msty data',               'AppData\Roaming\Msty',                              $true),
      @('AnythingLLM',             'AppData\Roaming\anythingllm-desktop',               $true),
      @('Pinokio',                 'pinokio',                                           $true),
      @('Hugging Face cache',      '.cache\huggingface',                                $true),
      @('Torch cache',             '.cache\torch',                                      $true),
      @('Whisper cache',           '.cache\whisper',                                    $true),
      @('Keras models',            '.keras',                                            $true),
      @('Claude Desktop (legacy)', 'AppData\Local\AnthropicClaude',                     $false),
      @('Claude Desktop data',     'AppData\Roaming\Claude',                            $false),
      @('Claude Code config',      '.claude',                                           $false),
      @('OpenAI Codex CLI',        '.codex',                                            $false),
      @('Gemini CLI',              '.gemini',                                           $false),
      @('ChatGPT desktop pkg',     'AppData\Local\Packages\OpenAI.ChatGPT-Desktop_2p2nqsd0c76g0', $false),
      @('Cursor IDE',              'AppData\Local\Programs\cursor',                     $false),
      @('Cursor config',           '.cursor',                                           $false),
      @('Windsurf IDE',            'AppData\Local\Programs\Windsurf',                   $false),
      @('Windsurf/Codeium config', '.codeium',                                          $false),
      @('Continue.dev',            '.continue',                                         $false),
      @('Aider',                   '.aider',                                            $false),
      @('Python (user install)',   'AppData\Local\Programs\Python',                     $false),
      @('Anaconda',                'anaconda3',                                         $false),
      @('Miniconda',               'miniconda3',                                        $false),
      @('conda config',            '.conda',                                            $false),
      @('uv cache',                'AppData\Local\uv',                                  $false),
      @('Docker user data',        '.docker',                                           $false),
      @('Docker Desktop data',     'AppData\Local\Docker',                              $true),
      @('WSL data',                'AppData\Local\wsl',                                 $true),
      @('npm global (@anthropic-ai)', 'AppData\Roaming\npm\node_modules\@anthropic-ai', $false),
      @('npm global (@openai)',    'AppData\Roaming\npm\node_modules\@openai',          $false),
      @('npm global (@google)',    'AppData\Roaming\npm\node_modules\@google',          $false)
    )
    $machineDirs = @(
      @('Ollama (machine)',        'C:\Program Files\Ollama',                           $false),
      @('LM Studio (machine)',     'C:\Program Files\LM Studio',                        $false),
      @('CUDA Toolkit',            'C:\Program Files\NVIDIA GPU Computing Toolkit',     $false),
      @('Docker Desktop',          'C:\Program Files\Docker',                           $false),
      @('Docker Desktop data',     'C:\ProgramData\DockerDesktop',                      $true),
      @('Anaconda (all users)',    'C:\ProgramData\Anaconda3',                          $false),
      @('Miniconda (all users)',   'C:\ProgramData\miniconda3',                         $false),
      @('npm global (ProgramData)','C:\ProgramData\npm\node_modules',                   $false),
      @('C:\AI',                   'C:\AI',                                             $true),
      @('C:\models',               'C:\models',                                         $true),
      @('C:\ollama',               'C:\ollama',                                         $true),
      @('C:\ComfyUI',              'C:\ComfyUI',                                        $true),
      @('C:\stable-diffusion-webui','C:\stable-diffusion-webui',                        $true),
      @('C:\text-generation-webui','C:\text-generation-webui',                          $true),
      @('C:\pinokio',              'C:\pinokio',                                        $true)
    )
    $dirHits = New-Object System.Collections.Generic.List[object]
    $checks = @()
    foreach ($pr in $profiles) { foreach ($d in $userDirs) { $checks += ,@($d[0], (Join-Path $pr.Path $d[1]), $d[2], $pr.User) } }
    foreach ($d in $machineDirs) { $checks += ,@($d[0], $d[1], $d[2], 'machine') }
    foreach ($c in $checks) {
        if (Test-Path -LiteralPath $c[1] -ErrorAction SilentlyContinue) {
            $it = Get-Item -LiteralPath $c[1] -Force -ErrorAction SilentlyContinue
            $size = -1; if ($c[2]) { $size = Get-DirSizeGB $c[1] }
            $dirHits.Add([pscustomobject]@{ Label = $c[0]; Path = $c[1]; Owner = $c[3]; SizeGB = $size; Modified = $it.LastWriteTime }) | Out-Null
        }
    }
    $lines = @(); foreach ($h in $dirHits) {
        $sz = ''; if ($h.SizeGB -ge 0) { $sz = ("{0} GB" -f $h.SizeGB) }
        $lines += ("{0,-26} {1}  {2} modified={3}" -f $h.Label, $h.Path, $sz, $h.Modified.ToString('yyyy-MM-dd'))
        $contextOnly = ($h.Label -match 'Python|conda|uv cache|Docker|WSL|CUDA|npm global \(ProgramData\)')
        if ($contextOnly) { Add-Finding 'Folder' ("{0} present at {1} {2}" -f $h.Label, $h.Path, $sz) }
        else { Add-Finding 'Folder' ("{0} present at {1} {2}" -f $h.Label, $h.Path, $sz) -Strong }
    }
    Show-List $lines
    $script:Data['KnownFolders'] = @($dirHits | Select-Object Label, Path, Owner, SizeGB, @{n='Modified';e={$_.Modified.ToString('s')}})

    # Non-standard top-level folders on C:
    $stdTop = @('Windows','Program Files','Program Files (x86)','ProgramData','Users','Recovery','$Recycle.Bin','PerfLogs','Intel','Drivers','Windows.old','System Volume Information','inetpub','OneDriveTemp','Temp','Dell','Lenovo','SWSetup','ESD','$WinREAgent','MSOCache','Config.Msi','OEM','Documents and Settings','$SysReset','$GetCurrent','$Windows.~BT','$Windows.~WS','DumpStack.log.tmp','AMD','NVIDIA')
    $odd = Get-ChildItem 'C:\' -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $stdTop -notcontains $_.Name } | Select-Object -ExpandProperty Name
    W ("Non-standard top-level folders on C:\ : {0}" -f $(if ($odd) { $odd -join ', ' } else { 'none' }))
    foreach ($o in $odd) { if (Test-AI $o) { Add-Finding 'Folder' ("Top-level folder C:\{0} matches AI keyword" -f $o) -Strong } }
    $script:Data['NonStandardTopLevel'] = @($odd)

    # Per-profile quick look: profile root, Desktop/Documents/Downloads/source/repos (depth 1) names + recent AI installers
    Sect 'User folders: AI-named items and installers (names only)'
    $userItemHits = @()
    foreach ($pr in $profiles) {
        $roots = @($pr.Path)
        foreach ($sub in 'Desktop','Documents','Downloads','source\repos','repos','Projects','dev','git') { $roots += (Join-Path $pr.Path $sub) }
        # Known Folder Move: OneDrive-redirected Desktop/Documents
        Get-ChildItem -LiteralPath $pr.Path -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OneDrive*' } | ForEach-Object { $roots += (Join-Path $_.FullName 'Desktop'); $roots += (Join-Path $_.FullName 'Documents') }
        foreach ($r in $roots) {
            if (-not (Test-Path -LiteralPath $r -ErrorAction SilentlyContinue)) { continue }
            Get-ChildItem -LiteralPath $r -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -like 'OneDrive*' -or $_.Name -eq 'AppData') { return }
                if (Test-AI $_.Name) {
                    $kind = 'file'; if ($_.PSIsContainer) { $kind = 'dir ' }
                    $sz = ''; if (-not $_.PSIsContainer) { $sz = ("{0:N0} MB" -f ($_.Length / 1MB)) }
                    $userItemHits += ("{0} {1}  {2} modified={3}" -f $kind, $_.FullName, $sz, $_.LastWriteTime.ToString('yyyy-MM-dd'))
                    $isInstaller = ($_.Extension -match '^\.(exe|msi|msix|msixbundle|appx|zip|7z|dmg)$')
                    if ($isInstaller -or $_.PSIsContainer) { Add-Finding 'UserFolder' ("{0} {1}" -f $kind.Trim(), $_.FullName) -Strong } else { Add-Finding 'UserFolder' ("{0} {1}" -f $kind.Trim(), $_.FullName) }
                }
            }
        }
    }
    Show-List $userItemHits
    $script:Data['UserFolderHits'] = @($userItemHits)

    # ---------------- Shortcuts (Start Menu / Desktop; catches PWAs) ----------------
    Sect 'Shortcuts: Start Menu + Desktop (AI keyword matches, incl. browser PWAs)'
    $lnkHits = @()
    $lnkRoots = @('C:\ProgramData\Microsoft\Windows\Start Menu\Programs', 'C:\Users\Public\Desktop')
    foreach ($pr in $profiles) {
        $lnkRoots += (Join-Path $pr.Path 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs')
        $lnkRoots += (Join-Path $pr.Path 'Desktop')
        Get-ChildItem -LiteralPath $pr.Path -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OneDrive*' } | ForEach-Object { $lnkRoots += (Join-Path $_.FullName 'Desktop') }
    }
    $wsh = $null; try { $wsh = New-Object -ComObject WScript.Shell } catch { }
    foreach ($r in $lnkRoots) {
        if (-not (Test-Path -LiteralPath $r -ErrorAction SilentlyContinue)) { continue }
        Get-ChildItem -LiteralPath $r -Recurse -Filter '*.lnk' -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $target = ''; $largs = ''
            if ($wsh) { try { $sc = $wsh.CreateShortcut($_.FullName); $target = [string]$sc.TargetPath; $largs = [string]$sc.Arguments } catch { } }
            $blob = "{0} {1} {2}" -f $_.BaseName, $target, $largs
            if (Test-AI $blob) {
                $pwa = ''; if ($largs -match '--app-id=|--app=') { $pwa = ' [browser PWA]' }
                $shortArgs = $largs; if ($shortArgs.Length -gt 60) { $shortArgs = $shortArgs.Substring(0,60) + '...' }
                $lnkHits += ("{0}  ->  {1} {2}{3}" -f $_.FullName, $target, $shortArgs, $pwa)
                $msc = (Test-MicrosoftCopilot $_.BaseName $target)
                if ($msc) { Add-Finding 'Shortcut' ("{0} (Microsoft Copilot)" -f $_.BaseName) } else { Add-Finding 'Shortcut' ("{0}{1} -> {2}" -f $_.BaseName, $pwa, $target) -Strong }
            }
        }
    }
    Show-List $lnkHits
    $script:Data['Shortcuts'] = @($lnkHits)

    # ---------------- Dev tooling ----------------
    Sect 'Dev tooling: npm globals, pip packages, editor extensions'
    $devHits = @()
    # npm globals
    $npmRoots = @('C:\Program Files\nodejs\node_modules', 'C:\ProgramData\npm\node_modules')
    foreach ($pr in $profiles) { $npmRoots += (Join-Path $pr.Path 'AppData\Roaming\npm\node_modules') }
    foreach ($r in $npmRoots) {
        if (-not (Test-Path -LiteralPath $r -ErrorAction SilentlyContinue)) { continue }
        Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -like '@*') {
                $scopeName = $_.Name
                Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object { $n = "{0}/{1}" -f $scopeName, $_.Name; if (Test-AI $n) { $devHits += ("npm   {0}  ({1})" -f $n, $r); Add-Finding 'DevTool' ("npm global package {0} in {1}" -f $n, $r) -Strong } }
            } elseif (Test-AI $_.Name) { $devHits += ("npm   {0}  ({1})" -f $_.Name, $r); Add-Finding 'DevTool' ("npm global package {0} in {1}" -f $_.Name, $r) -Strong }
        }
    }
    # pip site-packages (known roots only)
    $pyRoots = @()
    $pyRoots += Get-ChildItem 'C:\Program Files\Python*','C:\Python*','C:\ProgramData\Anaconda3','C:\ProgramData\miniconda3' -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    foreach ($pr in $profiles) {
        $pyRoots += Get-ChildItem (Join-Path $pr.Path 'AppData\Local\Programs\Python\Python*') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        $pyRoots += Get-ChildItem (Join-Path $pr.Path 'AppData\Roaming\Python\Python*') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        $pyRoots += Get-ChildItem (Join-Path $pr.Path 'AppData\Local\Packages\PythonSoftwareFoundation.Python*\LocalCache\local-packages\Python*') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        foreach ($cd in 'anaconda3','miniconda3','.conda') { $b = Join-Path $pr.Path $cd; if (Test-Path -LiteralPath $b -ErrorAction SilentlyContinue) { $pyRoots += $b; $pyRoots += Get-ChildItem (Join-Path $b 'envs') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName } }
        $pyRoots += Get-ChildItem (Join-Path $pr.Path '.virtualenvs') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    }
    $pyRoots = @($pyRoots | Where-Object { $_ } | Sort-Object -Unique)
    $pyPkgHits = @()
    foreach ($r in $pyRoots) {
        $sp = @()
        if (Test-Path -LiteralPath (Join-Path $r 'Lib\site-packages') -ErrorAction SilentlyContinue) { $sp += (Join-Path $r 'Lib\site-packages') }
        if (Test-Path -LiteralPath (Join-Path $r 'site-packages') -ErrorAction SilentlyContinue) { $sp += (Join-Path $r 'site-packages') }
        foreach ($s in ($sp | Sort-Object -Unique)) {
            $names = Get-ChildItem -LiteralPath $s -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.dist-info$|^__pycache__$' } | Select-Object -ExpandProperty Name
            $ai = @($names | Where-Object { Test-AI $_ })
            if ($ai.Count -gt 0) { $pyPkgHits += ("pip   {0}: {1}" -f $s, ($ai -join ', ')); Add-Finding 'DevTool' ("Python packages in {0}: {1}" -f $s, ($ai -join ', ')) -Strong }
        }
    }
    if ($pyRoots.Count -gt 0) { $devHits += ("python roots found: {0}" -f ($pyRoots -join '; ')) }
    $devHits += $pyPkgHits
    # editor extensions
    foreach ($pr in $profiles) {
        foreach ($ed in '.vscode\extensions','.vscode-insiders\extensions','.cursor\extensions','.windsurf\extensions') {
            $e = Join-Path $pr.Path $ed
            if (Test-Path -LiteralPath $e -ErrorAction SilentlyContinue) {
                $ext = Get-ChildItem -LiteralPath $e -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
                $ai = @($ext | Where-Object { Test-AI $_ })
                $aiTxt = 'none'; if ($ai.Count -gt 0) { $aiTxt = $ai -join ', ' }
                $devHits += ("ext   {0}: {1} extension(s); AI: {2}" -f $e, @($ext).Count, $aiTxt)
                foreach ($x in $ai) { Add-Finding 'DevTool' ("Editor extension {0} in {1}" -f $x, $e) -Strong }
            }
        }
    }
    Show-List $devHits
    $script:Data['DevTooling'] = @($devHits)

    # ---------------- Model files + large files (robocopy list mode) ----------------
    Sect 'Model files and large files (>= 100 MB scanned; robocopy /L)'
    $bigFiles = New-Object System.Collections.Generic.List[object]
    $rc = Join-Path $env:WINDIR 'System32\robocopy.exe'
    $nullDest = 'C:\ProgramData\RMMScripts\Logs\_robonull'
    $drives = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DeviceID
    foreach ($dv in $drives) {
        $root = $dv + '\'
        $rcArgs = @($root, $nullDest, '/L', '/S', '/XJ', '/NJH', '/NJS', '/NDL', '/NC', '/NP', '/BYTES', '/R:0', '/W:0', '/MIN:104857600', '/XD', 'System Volume Information', '$Recycle.Bin\S-1-5-18')
        if ($dv -ieq 'C:') { $rcArgs += @('C:\Windows', 'C:\Windows.old', 'C:\Program Files\WindowsApps', 'C:\ProgramData\Microsoft\Windows Defender', 'C:\ProgramData\Microsoft\Windows\Containers', 'C:\ProgramData\Package Cache') }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = & $rc @rcArgs 2>&1
        $rcExit = $LASTEXITCODE
        $sw.Stop()
        $n = 0
        foreach ($ln in $out) {
            $s = [string]$ln
            if ($s -match '^\s*(\d+)\s+(\S.*?)\s*$') {
                $n++
                $bigFiles.Add([pscustomobject]@{ Size = [int64]$matches[1]; Path = $matches[2] }) | Out-Null
            }
        }
        W ("{0}  scanned in {1:N0} s, {2} file(s) >= 100 MB (robocopy rc={3})" -f $root, $sw.Elapsed.TotalSeconds, $n, $rcExit)
    }
    $modelHits = @(); $modelLines = @()
    $nonModelExt = @('.exe','.dll','.msi','.msix','.msixbundle','.appx','.zip','.7z','.rar','.iso','.vhdx','.vhd','.vmdk','.mp4','.mkv','.mov','.avi','.wav','.mp3','.pst','.ost','.bak','.log','.output','.txt','.pdf','.docx','.xlsx','.pptx','.jpg','.png','.tif','.tiff','.dwg','.rvt','.rfa','.nwd','.nwc','.ifc','.cab','.wim','.esd','.sys','.etl','.dmp','.db','.sqlite','.pak','.asar','.node','.jar','.blob')
    $storeRx = '\\\.ollama\\|\\models\\blobs\\|\\\.lmstudio\\models\\|\\lm-studio\\models\\|\\huggingface\\hub\\models--|\\nomic\.ai\\GPT4All\\|\\Jan\\data\\models\\|\\anythingllm|\\ComfyUI\\models\\|\\stable-diffusion-webui\\models\\|\\koboldcpp|\\text-generation-webui\\models\\'  # gitleaks:allow
    foreach ($f in $bigFiles) {
        $ext  = [IO.Path]::GetExtension($f.Path).ToLower()
        $leaf = [IO.Path]::GetFileName($f.Path)
        $nameHit   = (Test-AI $leaf) -and ($nonModelExt -notcontains $ext)
        $storeHit  = ($f.Path -match $storeRx)
        $strongExt = $ModelExtStrong -contains $ext
        $weakExt   = $ModelExtWeak   -contains $ext
        if ($strongExt -or $storeHit -or $nameHit -or ($weakExt -and $f.Size -ge 200MB)) {
            $why = @(); if ($strongExt) { $why += 'model-ext' }; if ($storeHit) { $why += 'model-store-path' }; if ($weakExt) { $why += 'possible-model-ext' }; if ($nameHit) { $why += ('name:' + (Get-AIHit $leaf)) }
            $modelLines += ("{0,8:N2} GB  {1}  [{2}]" -f ($f.Size / 1GB), $f.Path, ($why -join ','))
            $modelHits += [pscustomobject]@{ SizeGB = [math]::Round($f.Size / 1GB, 2); Path = $f.Path; Why = ($why -join ',') }
            if ($strongExt -or $storeHit -or ($nameHit -and $weakExt)) { Add-Finding 'ModelFile' ("{0:N2} GB {1}" -f ($f.Size / 1GB), $f.Path) -Strong } else { Add-Finding 'ModelFile' ("{0:N2} GB {1} ({2})" -f ($f.Size / 1GB), $f.Path, ($why -join ',')) }
        }
    }
    W 'Model-file candidates:'
    Show-List $modelLines
    $top = @($bigFiles | Sort-Object Size -Descending | Select-Object -First 25 | ForEach-Object { "{0,8:N2} GB  {1}" -f ($_.Size / 1GB), $_.Path })
    W 'Largest 25 files (>= 100 MB, outside C:\Windows):'
    Show-List $top
    $ge1 = @($bigFiles | Where-Object { $_.Size -ge 1GB }).Count
    W ("Files >= 1 GB total: {0}" -f $ge1)
    $script:Data['ModelFiles'] = @($modelHits)
    $script:Data['Largest25']  = @($bigFiles | Sort-Object Size -Descending | Select-Object -First 25 | Select-Object @{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}}, Path)
    try { if (Test-Path $nullDest) { Remove-Item $nullDest -Force -Recurse -ErrorAction SilentlyContinue } } catch { }

    # ---------------- Running processes ----------------
    Sect 'Running processes (AI keyword matches) + top memory users'
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    $pLines = @(); $pHits = @()
    $matched = @()
    foreach ($p in $procs) {
        $strongHit = Test-AI ("{0} {1}" -f $p.Name, $p.ExecutablePath)
        $cmdHit    = (-not $strongHit) -and (Test-AI ([string]$p.CommandLine))
        if ($strongHit -or $cmdHit) {
            $owner = ''; try { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop; $owner = "{0}\{1}" -f $o.Domain, $o.User } catch { }
            $matched += [pscustomobject]@{ Pid = $p.ProcessId; Name = $p.Name; Owner = $owner; WorkingSetMB = [int]($p.WorkingSetSize / 1MB); Path = [string]$p.ExecutablePath; CommandLine = [string]$p.CommandLine; Strong = $strongHit }
        }
    }
    $pHits = $matched
    foreach ($g in ($matched | Group-Object Name, Path, Owner, Strong)) {
        $first = $g.Group | Select-Object -First 1
        $mem = ($g.Group | Measure-Object WorkingSetMB -Sum).Sum
        $pids = ($g.Group | Select-Object -ExpandProperty Pid) -join ','
        $cl = $first.CommandLine; if ($cl.Length -gt 120) { $cl = $cl.Substring(0,120) + '...' }
        $kind = 'name/path'; if (-not $first.Strong) { $kind = 'cmdline only' }
        $pLines += ("{0,-24} x{1,-3} {2,7:N0} MB  {3}  [{4}]  {5}  pids={6}" -f $first.Name, $g.Count, $mem, $first.Owner, $kind, $first.Path, $pids)
        if (-not $first.Strong) { $pLines += ("      cmd: {0}" -f $cl) }
        $msc = (($first.Name -match 'copilot') -and ($first.Path -match 'Microsoft|WindowsApps\\Microsoft'))
        if ($msc) { Add-Finding 'Process' ("{0} (Microsoft Copilot) running as {1}" -f $first.Name, $first.Owner) }
        elseif ($first.Strong) { Add-Finding 'Process' ("{0} x{1} running as {2}: {3}" -f $first.Name, $g.Count, $first.Owner, $first.Path) -Strong }
        else { Add-Finding 'Process' ("{0} x{1} ({2}) command line references AI tooling: {3}" -f $first.Name, $g.Count, $first.Owner, $cl) }
    }
    Show-List $pLines
    $topMem = @($procs | Sort-Object WorkingSetSize -Descending | Select-Object -First 8 | ForEach-Object { "{0,-28} {1,7:N0} MB  pid {2}" -f $_.Name, ($_.WorkingSetSize / 1MB), $_.ProcessId })
    W 'Top 8 processes by working set:'
    Show-List $topMem
    $script:Data['Processes'] = @($pHits)

    # ---------------- GPU ----------------
    Sect 'GPU (nvidia-smi)'
    $smi = @("$env:WINDIR\System32\nvidia-smi.exe", 'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe') | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if ($smi) {
        try {
            $g = & $smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>&1
            foreach ($gl in $g) { W ("GPU: {0}" -f $gl) }
            $apps = & $smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>&1
            $apps = @($apps | Where-Object { $_ -and ($_ -notmatch 'No running|not supported|^\s*$') })
            W ("CUDA compute processes now: {0}" -f $apps.Count)
            foreach ($ap in $apps) { W ("  {0}" -f $ap); Add-Finding 'GPU' ("CUDA compute process active: {0}" -f $ap) -Strong }
            $script:Data['GpuComputeApps'] = @($apps); $script:Data['Gpu'] = @($g)
        } catch { W ("nvidia-smi failed: {0}" -f $_.Exception.Message) }
    } else {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        W ("nvidia-smi not found. Video controllers: {0}" -f ($gpus -join '; '))
    }

    # ---------------- Listening ports ----------------
    Sect 'Listening TCP ports (known local-LLM ports flagged)'
    $knownPorts = @{ 11434='Ollama'; 1234='LM Studio'; 4891='GPT4All'; 1337='Jan'; 39281='Jan/Cortex'; 7860='Gradio (SD/oobabooga)'; 8188='ComfyUI'; 3000='Open WebUI/dev'; 3001='AnythingLLM'; 8080='Open WebUI/generic'; 8000='vLLM/FastAPI'; 5000='textgen API'; 5001='koboldcpp'; 8501='Streamlit' }
    $lst = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Group-Object LocalPort, OwningProcess | ForEach-Object { $_.Group | Select-Object -First 1 }
    $portLines = @()
    foreach ($c in ($lst | Sort-Object LocalPort)) {
        $pn = ''; try { $pn = (Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName } catch { }
        $known = $knownPorts[[int]$c.LocalPort]
        $aiProc = Test-AI $pn
        if ($known -or $aiProc) {
            $knownTxt = ''; if ($known) { $knownTxt = '<- ' + $known }
            $portLines += ("{0,6}  {1,-22} pid {2,-6} {3}  {4}" -f $c.LocalPort, $c.LocalAddress, $c.OwningProcess, $pn, $knownTxt)
            if ($aiProc -or ($known -and $pn -match 'python|node|ollama|llama|lm|jan|kobold|uvicorn|gunicorn|docker|wsl|vmmem|com\.docker')) { Add-Finding 'Port' ("Port {0} listening ({1}) by {2}" -f $c.LocalPort, $known, $pn) -Strong }
            else { Add-Finding 'Port' ("Port {0} ({1}) listening by {2}" -f $c.LocalPort, $known, $pn) }
        } else { L ("{0,6}  {1,-22} pid {2,-6} {3}" -f $c.LocalPort, $c.LocalAddress, $c.OwningProcess, $pn) }
    }
    W ("Listening sockets: {0} (all listed in log; known/AI matches below)" -f @($lst).Count)
    Show-List $portLines
    $script:Data['ListeningPortsFlagged'] = @($portLines)

    # ---------------- Services / tasks / autostart ----------------
    Sect 'Services, scheduled tasks, autostart entries (AI keyword matches)'
    $auto = @()
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | ForEach-Object { if (Test-AI ("{0} {1} {2}" -f $_.Name, $_.DisplayName, $_.PathName)) { $auto += ("service  {0} ({1}) state={2}  {3}" -f $_.Name, $_.DisplayName, $_.State, $_.PathName); Add-Finding 'Autostart' ("Service {0} ({1}) {2}" -f $_.Name, $_.State, $_.PathName) -Strong } }
    try {
        Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
            $t = $_; foreach ($a in $t.Actions) { $blob = "{0} {1} {2} {3}" -f $t.TaskName, $t.TaskPath, $a.Execute, $a.Arguments
                if (Test-AI $blob) { $auto += ("task     {0}{1}  {2} {3} state={4}" -f $t.TaskPath, $t.TaskName, $a.Execute, $a.Arguments, $t.State); Add-Finding 'Autostart' ("Scheduled task {0}{1} -> {2}" -f $t.TaskPath, $t.TaskName, $a.Execute) -Strong } }
        }
    } catch { L ("(scheduled tasks unavailable: {0})" -f $_.Exception.Message) }
    $runKeys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce')
    foreach ($pr in $profiles) { if ($pr.Loaded) { $runKeys += ("Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Run" -f $pr.Sid); $runKeys += ("Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\RunOnce" -f $pr.Sid) } }
    foreach ($rk in $runKeys) {
        $v = Get-ItemProperty $rk -ErrorAction SilentlyContinue
        if ($v) { foreach ($pn in ($v.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) { if (Test-AI ("{0} {1}" -f $pn.Name, $pn.Value)) { $auto += ("run-key  {0} : {1} = {2}" -f $rk, $pn.Name, $pn.Value); Add-Finding 'Autostart' ("Run key {0} = {1}" -f $pn.Name, $pn.Value) -Strong } } }
    }
    $startupDirs = @('C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp'); foreach ($pr in $profiles) { $startupDirs += (Join-Path $pr.Path 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup') }
    foreach ($sd in $startupDirs) { Get-ChildItem -LiteralPath $sd -Force -ErrorAction SilentlyContinue | ForEach-Object { if (Test-AI $_.Name) { $auto += ("startup  {0}" -f $_.FullName); Add-Finding 'Autostart' ("Startup folder item {0}" -f $_.FullName) -Strong } } }
    Show-List $auto
    $script:Data['Autostart'] = @($auto)

    # ---------------- Execution history: Prefetch / BAM / UserAssist ----------------
    Sect 'Execution history: Prefetch, BAM, UserAssist (AI keyword matches)'
    $hist = @()
    $pf = Get-ChildItem 'C:\Windows\Prefetch\*.pf' -Force -ErrorAction SilentlyContinue
    if ($pf) {
        $pfHits = @($pf | Where-Object { Test-AI $_.Name } | Sort-Object LastWriteTime -Descending)
        W ("Prefetch entries: {0}; AI matches: {1}" -f @($pf).Count, $pfHits.Count)
        foreach ($h in $pfHits) { $exe = ($h.BaseName -replace '-[0-9A-F]{8}(-\d+)?$', ''); $hist += ("prefetch   {0,-40} last run~{1}" -f $exe, $h.LastWriteTime.ToString('yyyy-MM-dd HH:mm')); Add-Finding 'ExecHistory' ("Prefetch: {0} last run ~{1}" -f $exe, $h.LastWriteTime.ToString('yyyy-MM-dd')) -Strong }
    } else { W 'Prefetch: not readable or disabled.' }
    $bamRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings'
    $bamKeys = Get-ChildItem $bamRoot -ErrorAction SilentlyContinue
    if ($bamKeys) {
        $bamCount = 0; $bamHits = @()
        foreach ($bk in $bamKeys) {
            $who = Sid-ToName $bk.PSChildName
            $vals = Get-ItemProperty $bk.PSPath -ErrorAction SilentlyContinue
            foreach ($vp in ($vals.PSObject.Properties | Where-Object { $_.Name -match '^\\Device\\' })) {
                $bamCount++
                if (Test-AI $vp.Name) {
                    $when = ''; try { $bytes = [byte[]]$vp.Value; if ($bytes.Length -ge 8) { $when = [DateTime]::FromFileTime([BitConverter]::ToInt64($bytes, 0)).ToString('yyyy-MM-dd HH:mm') } } catch { }
                    $shortPath = ($vp.Name -replace '^\\Device\\HarddiskVolume\d+', '')  # gitleaks:allow
                    $bamHits += ("bam        {0}  {1}  {2}" -f $when, $who, $shortPath)
                    Add-Finding 'ExecHistory' ("BAM: {0} ran {1} at {2}" -f $who, $shortPath, $when) -Strong
                }
            }
        }
        W ("BAM execution records: {0}; AI matches: {1}" -f $bamCount, $bamHits.Count)
        $hist += ($bamHits | Sort-Object -Descending)
    } else { W 'BAM: not readable.' }
    $uaCount = 0; $uaHits = @()
    foreach ($pr in $profiles) {
        if (-not $pr.Loaded) { continue }
        $uaRoot = "Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist" -f $pr.Sid
        Get-ChildItem $uaRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $ck = Get-Item (Join-Path $_.PSPath 'Count') -ErrorAction SilentlyContinue
            if ($ck) { foreach ($vn in $ck.GetValueNames()) {
                $uaCount++
                $dec = Rot13 $vn
                if (Test-AI $dec) {
                    $cnt = ''; $last = ''
                    try { $bytes = [byte[]]$ck.GetValue($vn); if ($bytes.Length -ge 68) { $cnt = [BitConverter]::ToInt32($bytes, 4); $ft = [BitConverter]::ToInt64($bytes, 60); if ($ft -gt 0) { $last = [DateTime]::FromFileTime($ft).ToString('yyyy-MM-dd HH:mm') } } } catch { }
                    $neverRun = (($cnt -is [int]) -and ($cnt -eq 0) -and [string]::IsNullOrEmpty($last))
                    if (-not $neverRun) {
                        $uaHits += ("userassist {0}  {1}  runs={2}  {3}" -f $last, $pr.User, $cnt, $dec)
                        Add-Finding 'ExecHistory' ("UserAssist: {0} launched {1} x{2}, last {3}" -f $pr.User, $dec, $cnt, $last) -Strong
                    }
                } } }
        }
    }
    W ("UserAssist entries (loaded hives): {0}; AI matches: {1}" -f $uaCount, $uaHits.Count)
    $hist += $uaHits
    Show-List $hist
    $script:Data['ExecutionHistory'] = @($hist)

    # ---------------- Browser extensions ----------------
    Sect 'Browser extensions (all names listed in log; AI matches shown)'
    $extAll = @(); $extHits = @()
    foreach ($pr in $profiles) {
        $browsers = @(@('Chrome', 'AppData\Local\Google\Chrome\User Data'), @('Edge', 'AppData\Local\Microsoft\Edge\User Data'), @('Brave', 'AppData\Local\BraveSoftware\Brave-Browser\User Data'))
        foreach ($b in $browsers) {
            $ud = Join-Path $pr.Path $b[1]
            if (-not (Test-Path -LiteralPath $ud -ErrorAction SilentlyContinue)) { continue }
            $bName = $b[0]
            Get-ChildItem -LiteralPath $ud -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
                $profName = $_.Name
                $extDir = Join-Path $_.FullName 'Extensions'
                Get-ChildItem -LiteralPath $extDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    $id = $_.Name
                    $ver = Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
                    if ($ver) { $nm = Read-ExtName $ver.FullName; if ($nm) { $line = ("{0,-8} {1,-8} {2,-16} {3}  [{4}]" -f $pr.User, $bName, $profName, $nm, $id); $extAll += $line; if (Test-AI $nm) { $extHits += $line; Add-Finding 'BrowserExt' ("{0} {1} extension: {2}" -f $pr.User, $bName, $nm) -Strong } } }
                }
            }
        }
        $ffRoot = Join-Path $pr.Path 'AppData\Roaming\Mozilla\Firefox\Profiles'
        Get-ChildItem (Join-Path $ffRoot '*\extensions.json') -ErrorAction SilentlyContinue | ForEach-Object {
            try { $j = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($ad in $j.addons) { $nm = $ad.defaultLocale.name; if ($nm) { $line = ("{0,-8} Firefox  {1,-16} {2}" -f $pr.User, $_.Directory.Name, $nm); $extAll += $line; if (Test-AI $nm) { $extHits += $line; Add-Finding 'BrowserExt' ("{0} Firefox extension: {1}" -f $pr.User, $nm) -Strong } } } } catch { }
        }
    }
    W ("Extensions found: {0}" -f $extAll.Count)
    foreach ($l in $extAll) { L ("    {0}" -f $l) }
    Show-List $extHits
    $script:Data['BrowserExtensionsAll'] = @($extAll); $script:Data['BrowserExtensionsAI'] = @($extHits)

    # ---------------- DNS cache ----------------
    Sect 'DNS resolver cache: AI web endpoints (transient - only what is cached right now)'
    $dnsHits = @()
    try {
        $entries = Get-DnsClientCache -ErrorAction Stop | Select-Object -ExpandProperty Entry -Unique
        $dnsHits = @($entries | Where-Object { $AiDomainRx.IsMatch($_) } | Sort-Object -Unique)
        W ("Cached names: {0}; AI endpoints: {1}" -f @($entries).Count, $dnsHits.Count)
        foreach ($d in $dnsHits) { Add-Finding 'DnsCache' ("Recently resolved: {0}" -f $d) }
    } catch { W ("DNS cache unavailable: {0}" -f $_.Exception.Message) }
    Show-List $dnsHits
    W 'Browser history was NOT read by this script.'
    $script:Data['DnsAiEndpoints'] = @($dnsHits)

    # ---------------- WSL / virtualization / containers ----------------
    Sect 'WSL, virtualization, containers'
    $virt = @()
    try {
        foreach ($fn in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform', 'Microsoft-Hyper-V-All', 'Containers-DisposableClientVM', 'Containers') {
            $f = Get-WindowsOptionalFeature -Online -FeatureName $fn -ErrorAction SilentlyContinue
            if ($f) { $virt += ("feature  {0,-40} {1}" -f $fn, $f.State) }
        }
    } catch { $virt += ("(features unavailable: {0})" -f $_.Exception.Message) }
    foreach ($pr in $profiles) {
        if ($pr.Loaded) {
            $lx = "Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Lxss" -f $pr.Sid
            Get-ChildItem $lx -ErrorAction SilentlyContinue | ForEach-Object {
                $v = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($v.DistributionName) {
                    $bp = [string]$v.BasePath; $bp = $bp -replace '^\\\\\?\\', ''
                    $vhd = Join-Path $bp 'ext4.vhdx'; $sz = ''
                    if (Test-Path -LiteralPath $vhd -ErrorAction SilentlyContinue) { $sz = ("{0:N1} GB" -f ((Get-Item -LiteralPath $vhd).Length / 1GB)) }
                    $virt += ("wsl      {0}: {1}  {2}  {3}" -f $pr.User, $v.DistributionName, $bp, $sz)
                    Add-Finding 'WSL' ("WSL distro {0} for {1} ({2}) - Linux side not inspected; could host Ollama/Docker models" -f $v.DistributionName, $pr.User, $sz) -Strong
                }
            }
        }
        Get-ChildItem (Join-Path $pr.Path 'AppData\Local\Packages') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(CanonicalGroupLimited|TheDebianProject|KaliLinux|46932SUSE|WhitewaterFoundryLtd|Fedora)' } | ForEach-Object { $virt += ("wsl-pkg  {0}: {1}" -f $pr.User, $_.Name) }
        $dd = Join-Path $pr.Path 'AppData\Local\Docker\wsl'
        if (Test-Path -LiteralPath $dd -ErrorAction SilentlyContinue) { $ddSize = Get-DirSizeGB $dd; $virt += ("docker   {0}: Docker Desktop WSL data {1} ({2} GB)" -f $pr.User, $dd, $ddSize); Add-Finding 'Container' ("Docker Desktop data for {0} ({1} GB) - images not inspected" -f $pr.User, $ddSize) -Strong }
    }
    if (Test-Path 'C:\Program Files\Docker\Docker' -ErrorAction SilentlyContinue) { $virt += 'docker   Docker Desktop installed (C:\Program Files\Docker\Docker)' }
    $vmm = $procs | Where-Object { $_.Name -match '^(vmmem|vmmemWSL|vmwp|vmware-vmx|VirtualBoxVM|VBoxHeadless)' } | ForEach-Object { "{0} {1:N0} MB" -f $_.Name, ($_.WorkingSetSize / 1MB) }
    if ($vmm) { $virt += ("vm-procs {0}" -f ($vmm -join '; ')) }
    Show-List $virt
    $script:Data['Virtualization'] = @($virt)

    # ---------------- Defender exclusions ----------------
    Sect 'Defender exclusions (AI matches flagged; all in log)'
    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $ex = @(); foreach ($e in @($mp.ExclusionPath))      { if ($e) { $ex += ("path      {0}" -f $e) } }
        foreach ($e in @($mp.ExclusionProcess))   { if ($e) { $ex += ("process   {0}" -f $e) } }
        foreach ($e in @($mp.ExclusionExtension)) { if ($e) { $ex += ("extension {0}" -f $e) } }
        W ("Exclusions: {0}" -f $ex.Count)
        foreach ($e in $ex) { L ("    {0}" -f $e) }
        $exHits = @($ex | Where-Object { Test-AI $_ })
        foreach ($e in $exHits) { Add-Finding 'Defender' ("Exclusion references AI tooling: {0}" -f $e) -Strong }
        Show-List $exHits
        $script:Data['DefenderExclusionsAll'] = @($ex)
    } catch { W ("Defender preferences unavailable: {0}" -f $_.Exception.Message) }

    # ---------------- Summary by category ----------------
    Sect 'Summary by category'
    $cats = $script:Findings | Group-Object Category | Sort-Object Name
    foreach ($c in $cats) {
        $s = @($c.Group | Where-Object { $_.Strong }).Count; $w = @($c.Group | Where-Object { -not $_.Strong }).Count
        W ("{0,-12} strong={1,-3} contextual={2}" -f $c.Name, $s, $w)
    }
    if (@($cats).Count -eq 0) { W '(nothing matched in any category)' }

    Finish
}
catch {
    W ''
    W ("SCRIPT ERROR: {0}" -f $_.Exception.Message)
    W ("  at: {0}" -f $_.InvocationInfo.PositionMessage)
    W 'RESULT: SCRIPT-ERROR'
    Save-Log
    exit 2
}
