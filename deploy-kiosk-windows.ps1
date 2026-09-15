<#
  ============================================================================
  KIOSK DEPLOY - Configurador automatico de TV (Windows 10/11)
  ============================================================================
  Como usar (execucao remota, estilo massgrave.dev):
    1. Hospede este arquivo em algum lugar publico por HTTPS (GitHub raw,
       Gist raw, seu proprio servidor, etc.) e preencha a variavel
       $ScriptUrl logo abaixo com esse link, ANTES de hospedar.
    2. No mini PC, abra o PowerShell (de preferencia ja como Administrador)
       e rode:
         irm https://SEU_LINK_AQUI/deploy-kiosk-windows.ps1 | iex
    3. Responda as perguntas do menu. No final ele salva tudo e pergunta
       se quer reiniciar.

  Como usar (execucao local, arquivo baixado):
    - Clique com o botao direito no .ps1 > "Executar com o PowerShell"
      (ou rode: powershell -ExecutionPolicy Bypass -File .\deploy-kiosk-windows.ps1)

  O que este script faz:
    - Pergunta qual Windows esta sendo configurado (10 ou 11)
    - Pergunta qual navegador usar (Chrome ou Edge)
    - Instala o navegador escolhido se ele nao estiver presente
    - Pede a URL do kiosk (a que voce pega no painel admin)
    - Configura o navegador para abrir em tela cheia/kiosk, sem sair
    - Trava configuracoes do navegador (extensoes, modo anonimo, etc.)
    - Converte automaticamente o IPv4 atual (DHCP) para IP fixo, preservando IP, gateway e DNS
    - Exibe no final o IP fixo definido
    - Desativa suspensao/protetor de tela
    - Configura inicializacao automatica (tarefa agendada OU substituindo
      o shell do Windows, para nunca mostrar a area de trabalho)
    - No final, pergunta se quer reiniciar agora

  Existe um script irmao, revert-kiosk-windows.ps1, para desfazer tudo
  isso caso precise voltar o PC ao normal.
  ============================================================================
#>

# Preencha com a URL publica deste mesmo arquivo depois de hospeda-lo.
# Usado so como fallback para reabrir elevado quando o script roda via
# "irm | iex" (nesse modo nao existe um arquivo .ps1 em disco pra reabrir).
$ScriptUrl = "https://raw.githubusercontent.com/GVNI2C/kioskControl/refs/heads/main/deploy-kiosk-windows.ps1"

# ---------------------------------------------------------------------------
# 0. Garante que esta rodando como Administrador
# ---------------------------------------------------------------------------
function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Este script precisa ser executado como Administrador. Reabrindo elevado..." -ForegroundColor Yellow
    try {
        if ($PSCommandPath) {
            # Rodando como arquivo .ps1 local
            Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        } elseif ($ScriptUrl -and $ScriptUrl -notmatch "SEU_LINK_AQUI") {
            # Rodando via irm | iex (sem arquivo em disco) - reabre baixando de novo
            Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"irm $ScriptUrl | iex`""
        } else {
            throw "Sem arquivo local e sem `$ScriptUrl configurada."
        }
    } catch {
        Write-Host "Nao foi possivel elevar automaticamente." -ForegroundColor Red
        Write-Host "Abra o PowerShell como Administrador primeiro e rode o comando de novo." -ForegroundColor Red
        Write-Host ""
        Read-Host "Pressione ENTER para fechar"
    }
    Exit
}

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Utilitarios de tela
# ---------------------------------------------------------------------------
function Show-Banner {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   KIOSK DEPLOY - Configurador automatico de TV (Windows)  " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step($text) {
    Write-Host ""
    Write-Host ">> $text" -ForegroundColor Yellow
}

function Write-Ok($text) {
    Write-Host "   [OK] $text" -ForegroundColor Green
}

function Exit-WithPause {
    param([int]$Code = 1)
    Write-Host ""
    Read-Host "Pressione ENTER para fechar"
    Exit $Code
}

function Write-Fail($text) {
    Write-Host "   [ERRO] $text" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# 0.1. Converte o IPv4 atual (DHCP) em IP fixo, preservando a configuracao
# ---------------------------------------------------------------------------
function Set-CurrentIPv4AsStatic {
    param(
        [switch]$Skip
    )

    try {
        # -------------------------------------------------------------------
        # IMPORTANTE:
        # Em algumas VMs (especialmente VMware/Hyper-V), Set-NetIPInterface
        # pode remover o lease DHCP antes que Get-NetIPAddress consiga
        # localiza-lo novamente. Por isso a troca final usa NETSH, que e mais
        # tolerante nesse cenario.
        # -------------------------------------------------------------------

        $defaultRoute = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" |
            Where-Object { $_.NextHop -and $_.State -eq "Alive" } |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1

        if (-not $defaultRoute) {
            throw "Nao foi encontrada uma rota padrao IPv4."
        }

        $interfaceIndex = $defaultRoute.InterfaceIndex
        $adapter = Get-NetAdapter -InterfaceIndex $interfaceIndex -ErrorAction Stop
        $interfaceAlias = $adapter.Name

        $ipConfig = Get-NetIPConfiguration -InterfaceIndex $interfaceIndex -ErrorAction Stop

        $ipv4 = @(
            $ipConfig.IPv4Address |
                Where-Object {
                    $_.IPAddress -notmatch '^169\.254\.' -and
                    $_.IPAddress -ne '127.0.0.1'
                }
        ) | Select-Object -First 1

        if (-not $ipv4) {
            throw "Nao foi encontrado um endereco IPv4 valido na interface '$interfaceAlias'."
        }

        $ipAddress = $ipv4.IPAddress
        $prefixLength = [int]$ipv4.PrefixLength

        # Converte /XX para mascara decimal para uso com NETSH.
        function Convert-PrefixToMask([int]$prefix) {
            if ($prefix -lt 0 -or $prefix -gt 32) {
                throw "Prefixo IPv4 invalido: /$prefix"
            }

            $mask = [uint32]0
            if ($prefix -gt 0) {
                $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix))
            }

            $bytes = [BitConverter]::GetBytes($mask)
            if ([BitConverter]::IsLittleEndian) {
                [array]::Reverse($bytes)
            }

            return ($bytes -join '.')
        }

        $subnetMask = Convert-PrefixToMask $prefixLength

        $gateway = $null
        if ($ipConfig.IPv4DefaultGateway) {
            $gateway = $ipConfig.IPv4DefaultGateway.NextHop
        }
        if (-not $gateway) {
            $gateway = $defaultRoute.NextHop
        }

        $dnsServers = @(
            (Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses |
                Where-Object { $_ -and $_ -notmatch '^0\.0\.0\.0$' }
        ) | Select-Object -Unique

        if (-not $dnsServers -or $dnsServers.Count -eq 0) {
            if ($gateway) {
                $dnsServers = @($gateway)
            }
        }

        if ($Skip) {
            Write-Ok "IP mantido como esta: $ipAddress/$prefixLength"

            return [PSCustomObject]@{
                InterfaceName = $interfaceAlias
                IPAddress     = $ipAddress
                PrefixLength  = $prefixLength
                SubnetMask    = $subnetMask
                Gateway       = $gateway
                DNSServers    = $dnsServers
                DHCP          = "Mantido"
            }
        }

        Write-Step "Convertendo o IP atual para IP fixo..."
        Write-Host "   Interface:   $interfaceAlias" -ForegroundColor DarkGray
        Write-Host "   IP atual:    $ipAddress/$prefixLength" -ForegroundColor DarkGray
        Write-Host "   Mascara:     $subnetMask" -ForegroundColor DarkGray
        Write-Host "   Gateway:     $gateway" -ForegroundColor DarkGray
        Write-Host "   DNS:         $($dnsServers -join ', ')" -ForegroundColor DarkGray

        # Guarda a configuracao.
        $backupPath = "HKLM:\SOFTWARE\KioskDeploy"
        if (-not (Test-Path $backupPath)) {
            New-Item -Path $backupPath -Force | Out-Null
        }

        New-ItemProperty -Path $backupPath -Name "StaticIPAddress" -PropertyType String -Value $ipAddress -Force | Out-Null
        New-ItemProperty -Path $backupPath -Name "StaticPrefixLength" -PropertyType DWord -Value $prefixLength -Force | Out-Null
        New-ItemProperty -Path $backupPath -Name "StaticSubnetMask" -PropertyType String -Value $subnetMask -Force | Out-Null
        New-ItemProperty -Path $backupPath -Name "StaticGateway" -PropertyType String -Value $gateway -Force | Out-Null
        New-ItemProperty -Path $backupPath -Name "StaticInterfaceAlias" -PropertyType String -Value $interfaceAlias -Force | Out-Null

        # -------------------------------------------------------------------
        # Faz a troca diretamente pelo NETSH.
        # Isso evita a falha observada em VMs onde Set-NetIPInterface provoca
        # a remocao do objeto MSFT_NetIPAddress antes da proxima consulta.
        # -------------------------------------------------------------------
        Write-Host "   Aplicando configuracao estatica..." -ForegroundColor DarkGray

        $netshArgs = @(
            'interface', 'ipv4', 'set', 'address',
            "name=$interfaceAlias",
            'source=static',
            "address=$ipAddress",
            "mask=$subnetMask"
        )

        if ($gateway) {
            $netshArgs += "gateway=$gateway"
            $netshArgs += "gwmetric=1"
        }

        $netshOutput = & netsh.exe @netshArgs 2>&1
        $netshExit = $LASTEXITCODE

        if ($netshExit -ne 0) {
            throw "NETSH nao conseguiu aplicar o IP fixo. Codigo $netshExit. $($netshOutput -join ' ')"
        }

        Start-Sleep -Seconds 2

        # Define DNS preservando os servidores que estavam configurados.
        if ($dnsServers -and $dnsServers.Count -gt 0) {
            & netsh.exe interface ip set dns name="$interfaceAlias" source=static addr=$dnsServers[0] register=primary | Out-Null

            if ($LASTEXITCODE -ne 0) {
                throw "Nao foi possivel configurar o DNS primario."
            }

            for ($i = 1; $i -lt $dnsServers.Count; $i++) {
                & netsh.exe interface ip add dns name="$interfaceAlias" addr=$dnsServers[$i] index=($i + 1) | Out-Null
            }
        }

        # -------------------------------------------------------------------
        # A interface pode levar alguns segundos para voltar depois da troca.
        # Nao encerramos o deploy nesse intervalo: aguardamos ate 60 segundos.
        # Isso e especialmente importante em VMware/Hyper-V/VirtualBox.
        # -------------------------------------------------------------------
        Write-Host "   Aguardando a interface de rede voltar..." -ForegroundColor DarkGray

        $finalIpv4 = $null
        $dhcpState = $null
        $netshVerifyText = ""
        $networkReady = $false

        for ($attempt = 1; $attempt -le 30; $attempt++) {
            Start-Sleep -Seconds 2

            try {
                $finalConfig = Get-NetIPConfiguration -InterfaceIndex $interfaceIndex -ErrorAction SilentlyContinue

                if ($finalConfig) {
                    $finalIpv4 = @(
                        $finalConfig.IPv4Address |
                            Where-Object { $_.IPAddress -eq $ipAddress }
                    ) | Select-Object -First 1
                }

                $dhcpState = (Get-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp

                $netshVerify = & netsh.exe interface ipv4 show config name="$interfaceAlias" 2>&1
                $netshVerifyText = $netshVerify -join "`n"

                if ($finalIpv4 -and $netshVerifyText -notmatch 'DHCP enabled:\s+Yes') {
                    $networkReady = $true
                    break
                }
            } catch {
                # A interface ainda esta sendo reinicializada. Continua aguardando.
            }

            Write-Host "   Aguardando rede... ($($attempt * 2)s)" -ForegroundColor DarkGray
        }

        if (-not $networkReady) {
            throw "A rede nao estabilizou dentro de 60 segundos apos definir o IP fixo."
        }

        Write-Ok "IP convertido para fixo com sucesso: $ipAddress/$prefixLength"

        return [PSCustomObject]@{
            InterfaceName = $interfaceAlias
            IPAddress     = $ipAddress
            PrefixLength  = $prefixLength
            SubnetMask    = $subnetMask
            Gateway       = $gateway
            DNSServers    = $dnsServers
            DHCP          = $dhcpState
        }
    }
    catch {
        Write-Fail "Nao foi possivel definir o IP atual como fixo: $($_.Exception.Message)"
        Write-Host "   O restante do deploy sera interrompido para evitar uma configuracao parcial." -ForegroundColor Red
        Exit-WithPause
    }
}

# ---------------------------------------------------------------------------
# 1. Pergunta o sistema operacional
# ---------------------------------------------------------------------------
function Select-WindowsVersion {
    $detected = (Get-CimInstance Win32_OperatingSystem).Caption
    Write-Host "Sistema detectado automaticamente: $detected" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Qual sistema operacional esta sendo configurado?"
    Write-Host "  [1] Windows 10"
    Write-Host "  [2] Windows 11"
    do {
        $choice = Read-Host "Digite o numero da opcao"
    } while ($choice -notin @("1", "2"))
    if ($choice -eq "1") { return "Windows 10" } else { return "Windows 11" }
}

# ---------------------------------------------------------------------------
# 2. Pergunta o navegador e garante que esta instalado
# ---------------------------------------------------------------------------
function Select-Browser {
    Write-Host ""
    Write-Host "Qual navegador usar no kiosk?"
    Write-Host "  [1] Google Chrome (instala automaticamente se nao tiver)"
    Write-Host "  [2] Microsoft Edge (ja vem no Windows - mais rapido, sem download)"
    do {
        $choice = Read-Host "Digite o numero da opcao"
    } while ($choice -notin @("1", "2"))
    if ($choice -eq "1") { return "chrome" } else { return "edge" }
}

function Test-BrowserInstalled {
    param([string]$Browser)
    if ($Browser -eq "chrome") {
        $paths = @(
            "$Env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${Env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "$Env:LocalAppData\Google\Chrome\Application\chrome.exe"
        )
    } else {
        $paths = @(
            "$Env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
            "${Env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        )
    }
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Install-Chrome {
    Write-Step "Instalando o Google Chrome..."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        try {
            winget install --id Google.Chrome -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
        } catch {
            Write-Host "   winget falhou, tentando instalador direto..." -ForegroundColor DarkYellow
        }
    }

    $chromePath = Test-BrowserInstalled -Browser "chrome"
    if (-not $chromePath) {
        $installer = "$Env:TEMP\chrome_installer.exe"
        Write-Host "   Baixando instalador oficial..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri "https://dl.google.com/chrome/install/latest/chrome_installer.exe" -OutFile $installer -UseBasicParsing
        Start-Process -FilePath $installer -ArgumentList "/silent /install" -Wait
        Remove-Item $installer -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    $chromePath = Test-BrowserInstalled -Browser "chrome"
    if (-not $chromePath) {
        Write-Fail "Nao foi possivel instalar o Chrome automaticamente."
        Write-Host "   Baixe manualmente em https://www.google.com/chrome/ e rode o script de novo." -ForegroundColor Red
        Exit-WithPause
    }
    Write-Ok "Chrome instalado em: $chromePath"
    return $chromePath
}

function Get-BrowserPath {
    param([string]$Browser)
    Write-Step "Verificando o navegador escolhido..."
    $path = Test-BrowserInstalled -Browser $Browser

    if ($path) {
        Write-Ok "Ja instalado em: $path"
        return $path
    }

    if ($Browser -eq "edge") {
        Write-Fail "Microsoft Edge nao encontrado neste Windows (incomum)."
        Write-Host "   Instale o Edge manualmente ou escolha Chrome na proxima execucao." -ForegroundColor Red
        Exit-WithPause
    }

    return Install-Chrome
}

# ---------------------------------------------------------------------------
# 3. Pede a URL do kiosk
# ---------------------------------------------------------------------------
function Get-KioskUrl {
    Write-Step "Configuracao da URL"
    Write-Host "   Cole a URL de configuracao do kiosk (a mesma cadastrada no painel admin)." -ForegroundColor DarkGray
    Write-Host "   Exemplo: http://192.168.1.32:8080/kiosk.html?id=kiosk-01&token=SEU_TOKEN" -ForegroundColor DarkGray
    do {
        $url = Read-Host "URL"
    } while ($url -notmatch '^https?://')
    return $url
}

# ---------------------------------------------------------------------------
# 4. Energia: nunca suspender/apagar tela
# ---------------------------------------------------------------------------
function Disable-SleepAndScreensaver {
    Write-Step "Desativando suspensao e protetor de tela..."
    try {
        powercfg /change monitor-timeout-ac 0 | Out-Null
        powercfg /change standby-timeout-ac 0 | Out-Null
        powercfg /change hibernate-timeout-ac 0 | Out-Null
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name ScreenSaveActive -Value 0 -ErrorAction SilentlyContinue
        Write-Ok "Tela e energia configuradas para nunca desligar."
    } catch {
        Write-Fail "Nao foi possivel configurar totalmente a energia: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 5. Trava as configuracoes do navegador (equivalente a policy de organizacao)
# ---------------------------------------------------------------------------
function Set-BrowserLockdownPolicies {
    param([string]$Browser, [string]$Url)

    Write-Step "Aplicando politicas de bloqueio do navegador..."

    if ($Browser -eq "chrome") {
        $regPath = "HKLM:\SOFTWARE\Policies\Google\Chrome"
    } else {
        $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    }

    try {
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

        $dwordPolicies = @{
            "IncognitoModeAvailability"    = 1   # desativa modo anonimo
            "DeveloperToolsAvailability"   = 2   # desativa ferramentas do desenvolvedor
            "BrowserGuestModeEnabled"      = 0   # desativa modo convidado
            "BrowserAddPersonEnabled"      = 0   # nao deixa adicionar outro perfil
            "EditBookmarksEnabled"         = 0   # nao deixa editar favoritos
            "PasswordManagerEnabled"       = 0   # desativa gerenciador de senhas
            "DefaultBrowserSettingEnabled" = 0   # nao pergunta navegador padrao
            "PrintingEnabled"              = 0   # desativa impressao (opcional, remova se precisar)
            "BookmarkBarEnabled"           = 0
            "TranslateEnabled"             = 0
            "SyncDisabled"                 = 1
            "RestoreOnStartup"             = 4   # abre URLs especificas ao iniciar
        }

        foreach ($name in $dwordPolicies.Keys) {
            New-ItemProperty -Path $regPath -Name $name -PropertyType DWord -Value $dwordPolicies[$name] -Force | Out-Null
        }

        New-ItemProperty -Path $regPath -Name "HomepageLocation" -PropertyType String -Value $Url -Force | Out-Null
        New-ItemProperty -Path $regPath -Name "HomepageIsNewTabPage" -PropertyType DWord -Value 0 -Force | Out-Null

        $startupUrlsPath = "$regPath\RestoreOnStartupURLs"
        if (-not (Test-Path $startupUrlsPath)) { New-Item -Path $startupUrlsPath -Force | Out-Null }
        New-ItemProperty -Path $startupUrlsPath -Name "1" -PropertyType String -Value $Url -Force | Out-Null

        # Bloqueia instalacao de qualquer extensao
        $extBlockPath = "$regPath\ExtensionInstallBlocklist"
        if (-not (Test-Path $extBlockPath)) { New-Item -Path $extBlockPath -Force | Out-Null }
        New-ItemProperty -Path $extBlockPath -Name "1" -PropertyType String -Value "*" -Force | Out-Null

        Write-Ok "Politicas aplicadas em $regPath"
    } catch {
        Write-Fail "Erro ao aplicar politicas: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 6. Inicializacao automatica
# ---------------------------------------------------------------------------
function Get-KioskArguments {
    param([string]$Browser, [string]$Url)
    if ($Browser -eq "edge") {
        return "--kiosk `"$Url`" --edge-kiosk-type=fullscreen --no-first-run --noerrdialogs --disable-translate --overscroll-history-navigation=0"
    } else {
        return "--kiosk `"$Url`" --no-first-run --noerrdialogs --disable-translate --disable-pinch --overscroll-history-navigation=0"
    }
}

function Select-StartupMode {
    Write-Host ""
    Write-Host "Como o navegador deve iniciar com o Windows?"
    Write-Host "  [1] Substituir o shell do Windows - a area de trabalho NUNCA chega a"
    Write-Host "      carregar, o navegador abre direto. Mais rapido, porem mais dificil"
    Write-Host "      de reverter se algo der errado (use o script revert-kiosk-windows.ps1)."
    Write-Host "  [2] Tarefa agendada no login - mais seguro e facil de desfazer, mas pode"
    Write-Host "      mostrar a area de trabalho por um instante antes do navegador abrir."
    do {
        $choice = Read-Host "Digite o numero da opcao"
    } while ($choice -notin @("1", "2"))
    if ($choice -eq "1") { return "shell" } else { return "task" }
}

function Register-KioskTask {
    param([string]$BrowserPath, [string]$Arguments)

    Write-Step "Criando tarefa agendada de inicializacao..."
    $taskName = "KioskBrowserStartup"

    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action = New-ScheduledTaskAction -Execute $BrowserPath -Argument $Arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero)
        $principal = New-ScheduledTaskPrincipal -UserId $Env:UserName -RunLevel Highest -LogonType Interactive

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
        Write-Ok "Tarefa '$taskName' criada. Reinicia sozinha se o navegador cair."
    } catch {
        Write-Fail "Erro ao criar tarefa agendada: $($_.Exception.Message)"
    }
}

function Register-KioskShell {
    param([string]$BrowserPath, [string]$Arguments)

    Write-Step "Substituindo o shell do Windows pelo navegador em kiosk..."
    try {
        $wrapperPath = "$Env:ProgramData\kiosk-shell.cmd"
        $wrapperContent = @"
@echo off
:loop
"$BrowserPath" $Arguments
goto loop
"@
        Set-Content -Path $wrapperPath -Value $wrapperContent -Encoding ASCII

        $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        $currentShell = (Get-ItemProperty -Path $winlogonPath -Name Shell -ErrorAction SilentlyContinue).Shell
        if (-not $currentShell) { $currentShell = "explorer.exe" }

        # Guarda o shell original (so na primeira vez) para o script de reversao usar
        $backupPath = "HKLM:\SOFTWARE\KioskDeploy"
        if (-not (Test-Path $backupPath)) { New-Item -Path $backupPath -Force | Out-Null }
        if (-not (Get-ItemProperty -Path $backupPath -Name "OriginalShell" -ErrorAction SilentlyContinue)) {
            New-ItemProperty -Path $backupPath -Name "OriginalShell" -PropertyType String -Value $currentShell -Force | Out-Null
        }

        Set-ItemProperty -Path $winlogonPath -Name "Shell" -Value $wrapperPath -Force
        Write-Ok "Shell substituido. O navegador em kiosk vai abrir no lugar da area de trabalho."
        Write-Host "   (shell original salvo em HKLM:\SOFTWARE\KioskDeploy para reversao)" -ForegroundColor DarkGray
    } catch {
        Write-Fail "Erro ao substituir o shell: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Fluxo principal
# ---------------------------------------------------------------------------
function Main {
    Show-Banner

    $winVer = Select-WindowsVersion
    Write-Ok "Sistema selecionado: $winVer"

    $browser = Select-Browser
    $browserPath = Get-BrowserPath -Browser $browser

    # -----------------------------------------------------------------------
    # Opcao de IP fixo
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "Configuracao de rede" -ForegroundColor Cyan
    Write-Host "O IP atualmente utilizado pode ser transformado em IP fixo."
    Write-Host "Se escolher NAO, a configuracao de rede sera mantida como esta."
    Write-Host ""
    Write-Host "  [1] Definir o IP atual como fixo"
    Write-Host "  [2] Manter a configuracao atual"
    do {
        $networkChoice = Read-Host "Digite o numero da opcao"
    } while ($networkChoice -notin @("1", "2"))

    if ($networkChoice -eq "1") {
        $staticNetwork = Set-CurrentIPv4AsStatic
    } else {
        $staticNetwork = Set-CurrentIPv4AsStatic -Skip
    }

    $url = Get-KioskUrl
    Write-Ok "URL configurada: $url"

    Disable-SleepAndScreensaver
    Set-BrowserLockdownPolicies -Browser $browser -Url $url

    $arguments = Get-KioskArguments -Browser $browser -Url $url
    $mode = Select-StartupMode

    if ($mode -eq "shell") {
        Register-KioskShell -BrowserPath $browserPath -Arguments $arguments
    } else {
        Register-KioskTask -BrowserPath $browserPath -Arguments $arguments
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "   Configuracao concluida com sucesso!                      " -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "   Sistema:      $winVer"
    Write-Host "   Navegador:    $(if ($browser -eq 'chrome') {'Google Chrome'} else {'Microsoft Edge'})"
    Write-Host "   URL:          $url"
    Write-Host "   Inicializacao: $(if ($mode -eq 'shell') {'Shell substituido (sem area de trabalho)'} else {'Tarefa agendada no login'})"
    Write-Host ""
    Write-Host "   ========================================================" -ForegroundColor Cyan
    if ($networkChoice -eq "1") {
        Write-Host "   IP FIXO DEFINIDO: $($staticNetwork.IPAddress)" -ForegroundColor Cyan
    } else {
        Write-Host "   IP ATUAL:         $($staticNetwork.IPAddress)" -ForegroundColor Cyan
        Write-Host "   IP FIXO:          NAO ALTERADO" -ForegroundColor Cyan
    }
    Write-Host "   Mascara/prefixo:  /$($staticNetwork.PrefixLength)" -ForegroundColor Cyan
    Write-Host "   Gateway:          $($staticNetwork.Gateway)" -ForegroundColor Cyan
    Write-Host "   Interface:        $($staticNetwork.InterfaceName)" -ForegroundColor Cyan
    Write-Host "   ========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   Para desfazer tudo isso depois, use revert-kiosk-windows.ps1" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "IP atual da maquina: $($staticNetwork.IPAddress)" -ForegroundColor Green
    Write-Host ""
    $reboot = Read-Host "Deseja reiniciar o computador agora para aplicar tudo? (S/N)"
    if ($reboot -match '^[Ss]') {
        Write-Host "Reiniciando em 5 segundos..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    } else {
        Write-Host "Ok, nao reiniciado agora. As mudancas so valem a partir do proximo boot/login." -ForegroundColor Yellow
    }
}

Main
