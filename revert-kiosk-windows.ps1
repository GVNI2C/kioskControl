<#
  ============================================================================
  REVERT KIOSK - Desfaz o que o deploy-kiosk-windows.ps1 configurou
  ============================================================================
  Use este script se precisar devolver o PC ao funcionamento normal do
  Windows: restaura a area de trabalho (se o shell foi substituido), remove
  a tarefa agendada e apaga as politicas de bloqueio do navegador.

  Como usar (execucao remota, estilo massgrave.dev):
    Hospede este arquivo por HTTPS, preencha $ScriptUrl abaixo, e rode no
    PC afetado:
      irm https://SEU_LINK_AQUI/revert-kiosk-windows.ps1 | iex

  Como usar (execucao local, arquivo baixado):
    - Clique com o botao direito > "Executar com o PowerShell"

  Se o PC ainda liga em modo kiosk sem area de trabalho (shell substituido),
  entre em Modo de Seguranca primeiro: religue o PC 3x seguidas forcando
  desligamento no botao - o Windows entra no menu de reparo automaticamente
  > Solucionar problemas > Opcoes avancadas > Configuracoes de inicializacao
  > Reiniciar > tecla 4 (Modo de Seguranca). Abra o PowerShell como admin de
  la e rode o comando/script de la.
  Se o navegador so abre via tarefa agendada (nao substituiu o shell), pode
  rodar direto no Windows normal.
  ============================================================================
#>

# Preencha com a URL publica deste mesmo arquivo depois de hospeda-lo.
# Usado so como fallback para reabrir elevado quando o script roda via
# "irm | iex" (nesse modo nao existe um arquivo .ps1 em disco pra reabrir).
$ScriptUrl = "https://raw.githubusercontent.com/GVNI2C/kioskControl/refs/heads/main/revert-kiosk-windows.ps1"

function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Este script precisa ser executado como Administrador. Reabrindo elevado..." -ForegroundColor Yellow
    try {
        if ($PSCommandPath) {
            Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        } elseif ($ScriptUrl -and $ScriptUrl -notmatch "SEU_LINK_AQUI") {
            Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"irm $ScriptUrl | iex`""
        } else {
            throw "Sem arquivo local e sem `$ScriptUrl configurada."
        }
    } catch {
        Write-Host "Abra o PowerShell como Administrador manualmente e rode o script de novo." -ForegroundColor Red
        Write-Host ""
        Read-Host "Pressione ENTER para fechar"
    }
    Exit
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   REVERT KIOSK - restaurando o Windows ao normal - revisão 1.0 " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# 1. Restaura a configuracao de rede alterada pelo deploy
#    Se o deploy transformou o IP atual em fixo, o revert devolve:
#      - IPv4 para DHCP
#      - DNS para obtencao automatica
#    Se o usuario escolheu "Manter a configuracao atual" no deploy, a chave
#    StaticIPAddress nao existe e a rede nao e alterada aqui.
$winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$backupPath = "HKLM:\SOFTWARE\KioskDeploy"

$staticIPAddress = (Get-ItemProperty -Path $backupPath -Name "StaticIPAddress" -ErrorAction SilentlyContinue).StaticIPAddress
$staticInterfaceAlias = (Get-ItemProperty -Path $backupPath -Name "StaticInterfaceAlias" -ErrorAction SilentlyContinue).StaticInterfaceAlias

if ($staticIPAddress -and $staticInterfaceAlias) {
    Write-Host ""
    Write-Host ">> Restaurando configuracao de rede..." -ForegroundColor Yellow
    Write-Host "   Interface: $staticInterfaceAlias" -ForegroundColor DarkGray
    Write-Host "   IP que estava fixo: $staticIPAddress" -ForegroundColor DarkGray

    try {
        $adapter = Get-NetAdapter -Name $staticInterfaceAlias -ErrorAction Stop

        # Primeiro habilita DHCP para IPv4.
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop

        # Remove enderecos IPv4 manuais que possam ter sido deixados pelo deploy.
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PrefixOrigin -eq "Manual" -and
                $_.IPAddress -notlike "169.254.*" -and
                $_.IPAddress -ne "127.0.0.1"
            } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        # Volta o DNS para obtencao automatica pelo DHCP.
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop

        # Aguarda o DHCP devolver um endereco. Nao encerra enquanto a VM
        # estiver apenas reinicializando a interface.
        Write-Host "   Aguardando o DHCP fornecer um novo IP..." -ForegroundColor DarkGray

        $currentIPv4 = $null
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            Start-Sleep -Seconds 2

            try {
                $currentIPv4 = Get-NetIPAddress `
                    -InterfaceIndex $adapter.ifIndex `
                    -AddressFamily IPv4 `
                    -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.IPAddress -notlike "169.254.*" -and
                        $_.IPAddress -ne "127.0.0.1"
                    } |
                    Select-Object -First 1

                if ($currentIPv4) {
                    break
                }
            } catch {
                # Interface ainda reiniciando; continua aguardando.
            }

            Write-Host "   Aguardando DHCP... ($($attempt * 2)s)" -ForegroundColor DarkGray
        }

        if ($currentIPv4) {
            Write-Host "[OK] Rede restaurada para DHCP." -ForegroundColor Green
            Write-Host "     IP atual obtido: $($currentIPv4.IPAddress)" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] DHCP foi habilitado, mas nenhum IPv4 foi obtido em 60 segundos." -ForegroundColor Yellow
            Write-Host "        Verifique a conectividade da rede apos o reinicio." -ForegroundColor Yellow
        }

        # Confirma que o DNS voltou para automatico.
        $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        if (-not $dnsServers -or $dnsServers.Count -eq 0) {
            Write-Host "[OK] DNS configurado para obtencao automatica." -ForegroundColor Green
        } else {
            Write-Host "[OK] DNS atual fornecido/configurado na interface: $($dnsServers -join ', ')" -ForegroundColor Green
        }
    } catch {
        Write-Host "[ERRO] Falha ao restaurar a rede: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "       O restante da reversao continuara." -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "[..] Nenhuma alteracao de IP fixo do deploy encontrada; rede mantida." -ForegroundColor DarkGray
}

# 2. Restaura o shell original, se foi substituido
$winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$backupPath = "HKLM:\SOFTWARE\KioskDeploy"

$originalShell = (Get-ItemProperty -Path $backupPath -Name "OriginalShell" -ErrorAction SilentlyContinue).OriginalShell
if ($originalShell) {
    Set-ItemProperty -Path $winlogonPath -Name "Shell" -Value $originalShell -Force
    Write-Host "[OK] Shell restaurado para: $originalShell" -ForegroundColor Green
} else {
    Set-ItemProperty -Path $winlogonPath -Name "Shell" -Value "explorer.exe" -Force
    Write-Host "[OK] Shell forcado de volta para explorer.exe (nenhum backup encontrado)" -ForegroundColor Green
}

$wrapperPath = "$Env:ProgramData\kiosk-shell.cmd"
if (Test-Path $wrapperPath) {
    Remove-Item $wrapperPath -Force
    Write-Host "[OK] Script de shell do kiosk removido." -ForegroundColor Green
}

# 3. Remove a tarefa agendada, se existir
$taskName = "KioskBrowserStartup"
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "[OK] Tarefa agendada '$taskName' removida." -ForegroundColor Green
} else {
    Write-Host "[..] Nenhuma tarefa agendada de kiosk encontrada." -ForegroundColor DarkGray
}

# 4. Remove as politicas de bloqueio do Chrome e do Edge
foreach ($regPath in @("HKLM:\SOFTWARE\Policies\Google\Chrome", "HKLM:\SOFTWARE\Policies\Microsoft\Edge")) {
    if (Test-Path $regPath) {
        Remove-Item -Path $regPath -Recurse -Force
        Write-Host "[OK] Politicas removidas de $regPath" -ForegroundColor Green
    }
}

# 5. Limpa a chave de backup
if (Test-Path $backupPath) {
    Remove-Item -Path $backupPath -Recurse -Force
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "   Reversao concluida!                                      " -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "   Rede: DHCP restaurado e DNS em obtencao automatica (quando o deploy"
Write-Host "         alterou o IP para fixo)."
Write-Host "   As configuracoes de energia/protetor de tela nao sao revertidas"
Write-Host "   automaticamente - ajuste manualmente em Configuracoes > Energia,"
Write-Host "   se precisar."
Write-Host ""

$reboot = Read-Host "Deseja reiniciar o computador agora? (S/N)"
if ($reboot -match '^[Ss]') {
    Write-Host "Reiniciando em 5 segundos..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}
