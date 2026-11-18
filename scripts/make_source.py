#!/usr/bin/env python3
"""Обновляет apps.json — источник для SideStore / AltStore.
Новая версия добавляется наверх, хранятся последние 10."""
import argparse, json, os, datetime

p = argparse.ArgumentParser()
p.add_argument("--version", required=True)
p.add_argument("--build", required=True)
p.add_argument("--size", type=int, required=True)
p.add_argument("--url", required=True)
p.add_argument("--notes", default="")
p.add_argument("--repo", required=True)
p.add_argument("--branch", required=True)
p.add_argument("--out", default="apps.json")
a = p.parse_args()

raw = f"https://raw.githubusercontent.com/{a.repo}/refs/heads/{a.branch}"
icon = f"{raw}/Lenta/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

old_versions = []
if os.path.exists(a.out):
    try:
        with open(a.out, encoding="utf-8") as f:
            old_versions = json.load(f)["apps"][0].get("versions", [])
    except Exception:
        old_versions = []

new = {
    "version": a.version,
    "buildVersion": a.build,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": a.notes or f"Лента {a.version}",
    "downloadURL": a.url,
    "size": a.size,
    "minOSVersion": "17.0",
}
versions = [new] + [v for v in old_versions if v.get("version") != a.version]
versions = versions[:10]

source = {
    "name": "Лента",
    "identifier": f"io.github.{a.repo.split('/')[0].lower()}.lenta.source",
    "subtitle": "Пульт LED-ленты LEDDMX",
    "description": "Обновления приложения «Лента». Собирается автоматически после каждого изменения.",
    "iconURL": icon,
    "website": "https://led-lenta.vercel.app",
    "tintColor": "#5b93ff",
    "apps": [{
        "name": "Лента",
        "bundleIdentifier": "app.lenta.remote",
        "developerName": a.repo.split("/")[0],
        "subtitle": "Пульт LED-ленты: цвет, режимы, светомузыка",
        "localizedDescription": "Управление LED-лентой LEDDMX по Bluetooth: цветовой круг, 210 режимов, "
                                "светомузыка под свои треки, SoundCloud, Spotify, Яндекс Музыку и микрофон, "
                                "таймер сна и расписание.",
        "iconURL": icon,
        "tintColor": "#5b93ff",
        "category": "utilities",
        "screenshots": [],
        "versions": versions,
        "appPermissions": {
            "entitlements": [],
            "privacy": {
                "NSBluetoothAlwaysUsageDescription": "Bluetooth нужен, чтобы управлять LED-лентой.",
                "NSMicrophoneUsageDescription": "Микрофон нужен для светомузыки по звуку в комнате.",
            },
        },
    }],
    "news": [],
}

with open(a.out, "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("apps.json:", a.version, "→", a.url)
