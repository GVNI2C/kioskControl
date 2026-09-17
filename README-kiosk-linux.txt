KIOSK DEPLOY - LINUX

Arquivos:
- deploy-kiosk-linux.sh  -> instala/configura o kiosk
- revert-kiosk-linux.sh  -> desfaz a configuracao

REQUISITOS
- Linux desktop com sessao grafica (X11 ou Wayland)
- sudo/root
- iproute2 (comando ip)
- systemd e/ou NetworkManager para persistencia de rede
- Uma conta de usuario que tenha sessao grafica

EXECUCAO REMOTA
1. Hospede deploy-kiosk-linux.sh por HTTPS.
2. Execute:
   curl -fsSL https://SEU_LINK/deploy-kiosk-linux.sh | sudo bash

EXECUCAO LOCAL
   chmod +x deploy-kiosk-linux.sh
   sudo bash deploy-kiosk-linux.sh

O DEPLOY
- Detecta a interface com rota padrao IPv4.
- Mostra o IP atual e pergunta:
  [1] transformar o IP atual em fixo
  [2] manter a rede como esta
- No modo [1], usa DNS 8.8.8.8 e 1.1.1.1.
- Prioridade para NetworkManager; depois systemd-networkd; depois fallback ip+systemd.
- Permite Chromium, Google Chrome ou Firefox.
- Cria modo kiosk e autostart para o usuario grafico.
- Reabre o navegador se ele for encerrado.
- Tenta desativar bloqueio de tela/suspensao na sessao grafica.
- Salva backup em /var/lib/kiosk-deploy/.

OBSERVACAO IMPORTANTE
"Nao importa a distribuicao" nao significa que todas as distros Linux possuem o mesmo
gerenciador de rede ou o mesmo desktop. Este script foi feito para ser amplo em
distribuicoes desktop modernas e possui caminhos de fallback. Para um kiosk sem
login, o sistema tambem precisa estar configurado com auto-login da conta grafica;
o script nao altera o gerenciador de login porque essa parte varia entre GDM, SDDM,
LightDM e outros.

REVERSAO
   sudo bash revert-kiosk-linux.sh

O revert remove o autostart/launcher e, quando existe backup, restaura DHCP e DNS
automaticos no backend de rede detectado.
