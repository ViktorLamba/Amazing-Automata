### Amazing Automata 🚀
# Универсальная система автоматической сборки и доставки приложений на различных языках программирования.

## 🌟 Особенности
Умное определение языка и структуры проекта

Автоматическая настройка пайплайнов сборки

Multi-платформенная поддержка (Docker, Kubernetes, Cloud)

Zero-config подход для стандартных проектов

Расширяемая архитектура для кастомных сценариев
____ 

## 📋 Поддерживаемые языки
# 🦀 Rust
Обязательные файлы:

Cargo.toml - зависимости и конфигурация

main.rs/lib.rs/любой .rs файл - точка входа

Автоматически детектирует:

Библиотеки vs исполняемые файлы

Workspace проекты (multiple binaries)

Features и conditional compilation
____

# 🐍 Python
Обязательные файлы:

pyproject.toml ИЛИ requirements.txt - зависимости

main.py/любой .py файл - точка входа

Поддерживает:

Virtual environments (venv, poetry, pipenv)

Package distributions (wheel, setuptools)

ASGI/WSGI приложения
____

# 🐹 Go
Обязательные файлы:

go.mod - модули и зависимости

main.go/любой .go файл - точка входа

Особенности:

Static binary compilation

Multi-arch сборка (amd64, arm64)

Go modules и vendor directory
____

# ⚡ C++
Обязательные файлы:

CMakeLists.txt ИЛИ Makefile - система сборки

main.cpp/.cc/.cxx/.c++ файлы - точка входа

Поддерживаемые системы сборки:

CMake (modern)

Makefile (legacy)

Autotools (configure/make)

### 🚀 Быстрый старт
## Установка
$ git clone https://github.com/ViktorLamba/Amazing-Automata.git .
 


### 🏗️ Структура проекта

Amazing-Automata/
├── ci/
│   ├── ci-scripts/
│   │   └── detect-entry.sh    # Детектор языков
│   └── manifest.json          # Генерируемый манифест
├── project/                   # Ваш проект (симлинк или копия)
├── Makefile                   # Управление задачами
├── .deployrc                 # Конфигурация развертывания
└── README.md

### 🙏 Благодарности
# Разработано с ❤️ для сообщества разработчиков.


### ⭐️ Команда проекта

# Виктор Ламба
тгк - https://t.me/viiiii_tyok
git - @ViktorLamba

# Дмитрий Ефимов
тгк - @PlumBum1538
git - @DmitriyEfimov15

# Андрей Падалко
тгк - @andrew09127
git - @Andrew09127