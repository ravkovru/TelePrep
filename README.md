# TelePrep — Telegram API Access Assistant

Небольшая macOS SwiftUI-утилита для подготовки получения `api_id` и `api_hash` Telegram.

## Режимы

- **Демо** — выполняет `nslookup`, показывает условный KZ-IP и проходит сценарий без VPN, без изменений `/etc/hosts` и без открытия Safari.
- **Рабочий** — ждёт подтверждения подключения VPN, проверяет реальный внешний IP и страну `KZ`, проверяет HTTPS-доступ через `--resolve`, временно обновляет `/etc/hosts`, очищает DNS-кэш и открывает приватное окно Safari.

## Запуск

```bash
swift run KZTelegramAPIUtility
```

Или собрать бинарник:

```bash
swift build
.build/arm64-apple-macosx/debug/KZTelegramAPIUtility
```

Рабочий режим требует права администратора для изменения `/etc/hosts` и разрешение macOS на управление Safari через System Events. Публичные VLESS-ключи в приложение не зашиваются: их следует импортировать в отдельный V2Ray-клиент.

