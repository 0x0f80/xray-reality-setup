## Xray VLESS + Reality — Автоматическая установка

Скрипт для быстрой установки **Xray-core** с протоколом **VLESS + Reality** на VPS. Без доменов, без сертификатов, без панелей — одна команда и готово.
---

## Требования

- VPS с **Ubuntu 22.04** или **24.04** (x64/arm64)
- **1 CPU / 512 MB RAM / 10 GB** диска
- Root-доступ
- Домен **не нужен**

---

## Установка

```bash
wget -qO install_xray.sh https://raw.githubusercontent.com/0x0f80/xray-reality-setup/main/install_xray.sh && bash install_xray.sh
```

Скрипт спросит:

1. **Транспорт** — TCP (классика, все клиенты) или XHTTP (новый, меняет сигнатуру трафика)
2. **Порт** — 443 по умолчанию

После установки на экране появится ссылка и QR-код для подключения.

### Что настраивается автоматически

UFW (файрвол) · Fail2Ban (защита SSH) · TCP BBR · Nginx-заглушка на порту 80 · Ротация логов

---

## Управление

После установки введите `x` в терминале — откроется меню:

```
╔════════════════════════════════════════╗
║     Xray VLESS + Reality — Меню        ║
╠════════════════════════════════════════╣
║  1. Ссылка основного пользователя      ║
║  2. Создать пользователя               ║
║  3. Удалить пользователя               ║
║  4. Ссылка для пользователя            ║
║  5. Список пользователей               ║
║  6. Статус Xray                        ║
║  7. Перезапустить Xray                 ║
║  8. Создать бэкап                      ║
║  9. Помощь                             ║
║  0. Выход                              ║
╚════════════════════════════════════════╝
```

Каждый пункт также доступен как отдельная команда: `mainuser`, `newuser`, `rmuser`, `sharelink`, `userlist`, `xraystatus`, `xraybackup`.

---

## TCP или XHTTP?

| | TCP + Vision | XHTTP |
|---|---|---|
| **Совместимость** | Все клиенты | v2rayNG, v2rayN, Hiddify |
| **Обход DPI** | Стандартный | Другая сигнатура |
| **Рекомендация** | По умолчанию | Если TCP блокируют |

---

## Клиенты

| Платформа | Приложения |
|-----------|-----------|
| **Android** | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid), [v2rayNG](https://github.com/2dust/v2rayNG) |
| **iOS** | [Streisand](https://apps.apple.com/app/streisand/id6450534064), [Happ](https://apps.apple.com/us/app/happ-proxy-utility/id6504287215) |
| **Windows** | [v2rayN](https://github.com/2dust/v2rayN), [Throne](https://github.com/throneproj/Throne) |
| **macOS** | [Throne](https://github.com/throneproj/Throne), [V2RayXS](https://github.com/tzmax/V2RayXS) |
| **Linux** | [Throne](https://github.com/throneproj/Throne), [v2rayN](https://github.com/2dust/v2rayN) |

> Для XHTTP убедитесь, что клиент поддерживает этот транспорт.

---

## Обновление ядра

Обновляет Xray-core без потери пользователей и настроек:

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
systemctl restart xray
```

---

## Удаление

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
rm -rf /usr/local/etc/xray
rm -f /usr/local/bin/{x,mainuser,newuser,rmuser,sharelink,userlist,xraybackup,xraystatus}
rm -f /usr/local/lib/xray_link.sh
rm -f /etc/logrotate.d/xray /etc/fail2ban/jail.d/xray.conf
```

---

## Полезные ссылки

- [Xray-core](https://github.com/XTLS/Xray-core) — ядро
- [Документация на русском](https://xtls.github.io/ru/)
