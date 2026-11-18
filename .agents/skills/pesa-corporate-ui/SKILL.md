---
name: pesa-corporate-ui
description: Básculas PESA Corporate Minimalist Design System & Non-Blocking UI Architecture for PyQt6 Desktop (.exe) and Flutter Android (.apk).
---

# Básculas PESA — Corporate Minimalist UI/UX & Performance Guidelines

## 1. Visual Identity & Color Tokens
- **Primary Background:** Pure White (`#FFFFFF`)
- **Secondary Surface / Subtle Headers / Filter Tracks:** Ultra-Light Slate (`#F8FAFC`)
- **Hover Surface:** Soft Slate (`#F1F5F9`)
- **Borders & Dividers:** Crisp `1px solid #E2E8F0` (strong border `#CBD5E1`)
- **Primary Text:** Deep Charcoal (`#0F172A`)
- **Secondary Text:** Corporate Slate (`#475569`, muted `#64748B`)
- **Brand Primary Accent (Rojo Corporativo Básculas PESA):** `#C8102E`
  - Hover: `#A50D26` | Pressed: `#880B20`
  - Active Tint Surface: `#FFF1F2` | Active Tint Border: `#FECDD3`
- **Semantic Badges:**
  - Success / Sent / Closed: Text `#065F46`, Background `#ECFDF5`, Border `#A7F3D0`
  - Warning / In Progress: Text `#92400E`, Background `#FFFBEB`, Border `#FDE68A`
  - Regulatory CCA: Text `#3730A3`, Background `#EEF2FF`, Border `#C7D2FE`
  - Regulatory DVE: Text `#065F46`, Background `#ECFDF5`, Border `#A7F3D0`

## 2. Typography & Iconography Rules
- **Zero Informal Emojis:** Never place emojis (`📷`, `✍️`, `📝`, `📤`, `🗑️`, `👤`, `📋`, `🔄`) in window titles, navigation rails, tab headers, KPI cards, or action buttons. Use crisp vector icons (`QPainter` geometric strokes in PyQt6; `Icons.*_outlined` / `Icons.*_rounded` in Flutter).
- **Hierarchy:**
  - Page Title: `18–20px`, weight `700`, `#0F172A`
  - KPI Value: `26–28px`, weight `700`, `#0F172A` (with `3px` top semantic accent bar)
  - Table Header: `11px` uppercase, letter-spacing `0.5px`, weight `700`, `#475569` on `#F8FAFC`
  - Table Primary Cell: `12.5–13px`, weight `600`, `#0F172A`
  - Table Secondary Spec / Audit Line: `11px`, `#475569`, full word-wrap (`setWordWrap(True)` / `softWrap: true`), never truncated with `...`.

## 3. Non-Blocking Performance Rules
- **Desktop (PyQt6):**
  - Never run PostgreSQL or HTTP queries on the main GUI thread; always dispatch via `QThread` / `QRunnable` with `pyqtSignal`.
  - Serve `clientes`, `sucursales`, `tecnicos`, and `tipos_servicio` from an in-memory + SQLite cache (`< 50ms` dialog open).
  - Wrap bulk `QTreeWidget` / `QTableWidget` updates in `setUpdatesEnabled(False)` ... `setUpdatesEnabled(True)`, cap initial widget materialization to 80 items, and lazily instantiate child widgets when batch nodes expand.
- **Mobile/Tablet (Flutter):**
  - Parallelize independent API/catalog requests with `Future.wait([...])`.
  - Maintain SQLite indexes on `folio_os`, `folio`, `id_lote`, `estatus`, and `fecha`.
  - Use `ListView.builder`, `const` constructors, and `RepaintBoundary` on complex rows.
