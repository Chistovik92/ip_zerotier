# ZeroTier «модем»: локалка для игр + VPN одним скриптом

Скрипт `zt_exitnode.sh` превращает Linux-сервер (VPS) в шлюз ZeroTier:

- **игры по локальной сети с друзьями**: все в одной виртуальной LAN, broadcast включён;
- **VPN**: весь интернет-трафик клиентов может идти через сервер (Discord, Telegram и т. д.);
- VPN включается **на каждом устройстве отдельно**: кто хочет только поиграть, играет без VPN.

Работает на **бесплатном** аккаунте ZeroTier.

## Быстрый старт

На сервере (Ubuntu/Debian/CentOS/Alma/Rocky/Fedora, root):

```bash
curl -fsSL https://raw.githubusercontent.com/Chistovik92/ip_zerotier/main/zt_exitnode.sh -o zt_exitnode.sh
```

```bash
sudo bash zt_exitnode.sh
```

Скрипт спросит API-токен ZeroTier:

| Есть токен | Нет токена |
|---|---|
| Скрипт сам создаёт или выбирает сеть, назначает IP, включает broadcast, добавляет маршрут `0.0.0.0/0` через сервер и авторизует сервер. | Вы вводите Network ID. Скрипт по шагам показывает, что нажать в веб-панели, ждёт, пока вы это сделаете, и **сам проверяет** результат. |

**Где взять токен:** [my.zerotier.com](https://my.zerotier.com) → *Account* → *API Access Tokens* → *New Token*.
Если ваш аккаунт уже в новом интерфейсе Central, API там есть только на платных тарифах. Тогда просто нажмите Enter и используйте ручной режим.

Полностью автоматическая установка без вопросов:

```bash
ZT_TOKEN=ваш_токен sudo -E bash zt_exitnode.sh -y --save-token
```

В конце скрипт выводит Network ID, IP сервера и готовые инструкции для друзей. Всё это также сохраняется в `/etc/zt-modem/info.txt`.

## Подключение друзей

**Windows** (автоматически). PowerShell от имени администратора:

```powershell
irm https://raw.githubusercontent.com/Chistovik92/ip_zerotier/main/client/zt-client-windows.ps1 -OutFile zt-client.ps1
```

```powershell
powershell -ExecutionPolicy Bypass -File .\zt-client.ps1 -NetworkId <NETWORK_ID> -Vpn on
```

Клиентский скрипт ставит ZeroTier (через winget), входит в сеть и делает сеть «Частной», чтобы брандмауэр не резал игры. Ещё он ставит адаптеру метрику 1, чтобы игры находили LAN-серверы, а при `-Vpn on` прописывает DNS 1.1.1.1/8.8.8.8 через VPN.
Режимы: `-Vpn on` (VPN и LAN), `-Vpn off` (только LAN), `-Leave` (выйти из сети).

**Вручную на других устройствах:**

- **Windows/macOS:** [zerotier.com/download](https://www.zerotier.com/download/) → значок в трее → *Join New Network*. Для VPN отметьте в меню сети *Allow Default Route Override*.
- **Android/iOS:** приложение ZeroTier One → «+» → ID сети. Для VPN включите *Route all traffic through ZeroTier*.
- **Linux:** `sudo zerotier-cli join <ID>`, для VPN ещё `sudo zerotier-cli set <ID> allowDefault=1`.

Каждое новое устройство нужно **авторизовать**: веб-панель → *Members* → галочка *Auth*. Если при установке вы сохранили токен (`--save-token`), можно прямо на сервере:

```bash
sudo zt-modem members
```

> На бесплатном тарифе ZeroTier ограничено число устройств в сети, и сервер тоже занимает одно место.

## Управление

```bash
sudo zt-modem status      # состояние ZeroTier, правил и сети
sudo zt-modem members     # участники сети и авторизация новых (нужен токен)
sudo zt-modem uninstall   # убрать правила и сервис (--purge удалит и ZeroTier)
```

Повторный запуск `zt_exitnode.sh` безопасен: скрипт идемпотентный.

Опции: `--no-vpn` (только LAN, без выхода в интернет через сервер), `-n <ID>` (существующая сеть), `-s 10.147.20.0/24` (своя подсеть), `--allow-private` (см. ниже), `--help`.

## Почему скрипт не мешает другим сервисам на сервере

- Все правила лежат в **собственных цепочках** `ZTMODEM-FWD`, `ZTMODEM-IN`, `ZTMODEM-NAT`, `ZTMODEM-MSS` (или в таблице nft `ztmodem`). Правила Docker, ufw, fail2ban и прочих сервисов не трогаются. `iptables-persistent` не используется, поэтому снимок чужих правил не сохраняется.
- NAT применяется **только к трафику из подсети ZeroTier**. Собственный трафик сервера и контейнеров не меняется.
- Правила восстанавливает systemd-сервис `zt-modem` после `zerotier-one`, Docker, ufw, firewalld и nftables.
- С firewalld скрипт работает через отдельную зону `ztmodem`.
- Клиентам VPN по умолчанию **закрыт доступ** к приватным сетям за сервером (10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16), в том числе к metadata-сервису облака. Открыть его можно флагом `--allow-private`.
- Включается MSS clamping, чтобы через VPN не «висели» сайты и загрузки.
- Если на сервере стояла **старая версия** этого скрипта, её правила (MASQUERADE на весь трафик) удаляются автоматически. Для `/etc/iptables/rules.v4` сохраняется бэкап.

## Проблемы

| Симптом | Что сделать |
|---|---|
| `ACCESS_DENIED` / нет IP | Авторизуйте устройство в *Members* |
| Друзья не видят игру по LAN | В настройках сети включите *Enable Broadcast*. На Windows сеть ZeroTier должна быть «Частной», а игра разрешена в брандмауэре. Попробуйте подключиться по IP из ZeroTier |
| VPN не работает | Проверьте маршрут `0.0.0.0/0 via <IP сервера>` в *Managed Routes* и включённый *Allow Default Route Override* на клиенте. Затем `sudo zt-modem status` |
| Discord/Telegram всё ещё блокируются | Причина может быть в DNS или IPv6 провайдера. Поставьте DNS 1.1.1.1 (клиентский скрипт делает это сам) и отключите IPv6 на основном адаптере |
| Медленно, высокий пинг | `zerotier-cli peers`: если у сервера `RELAY`, откройте UDP 9993 у хостера (фаервол в панели VPS) |
| Нет `/dev/net/tun` (OpenVZ/LXC) | Включите TUN/TAP в панели хостера |
| После `systemctl restart nftables` пропал NAT | `sudo systemctl restart zt-modem` |

Логи: `journalctl -u zt-modem -u zerotier-one`.

## Лицензия

MIT (см. [LICENSE](LICENSE)). Используйте в соответствии с правилами вашего хостера и законодательством.
