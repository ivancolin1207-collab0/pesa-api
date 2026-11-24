---
name: pesa-ui-ux-system
description: Sistema de Diseño Corporativo Minimalista y User-Friendly de Básculas PESA para PyQt6 (Windows .exe) y Flutter (Android .apk). Sin estética genérica IA, rejilla de 8px, estados semánticos con punto de 6px y seguridad QPainter.
---

# Básculas PESA — Sistema de Diseño UI/UX Corporativo Minimalista

Este skill rige obligatoriamente el diseño visual, la ergonomía y la seguridad gráfica en `./servicios_pesa` (PyQt6) y `./pesa_flutter` (Flutter).

## 1. Cero Estética Genérica "IA"
- **PROHIBIDO:** degradados neón, sombras exageradas, fondos rosados en filas (`#FEF2F2`, `#FDF2F8`, `#FFF1F2`, `rgba(184,29,36,12)`), píldoras arcoíris/pastel (índigo `#EEF2FF`, morado `#F3E8FF`, menta `#ECFDF5`, naranja chillón `#FFF3E0`, azul cielo `#E0F2FE`).
- **PROHIBIDO:** emojis informales en menús, pestañas, encabezados o botones (`📋`, `📷`, `✍️`, `📝`, `📤`, `🗑️`, `👤`, `⏳`, `✉`, `✓`). Usar únicamente iconografía vectorial monocromática limpia (`QPainter` con `QPointF`/`int` en PyQt6 e `Icons.*` en Flutter).

## 2. Paleta Corporativa Minimalista Básculas PESA
- **Canvas / Fondo principal:** `#F6F7F9` (gris cálido ultra suave)
- **Tarjetas, tablas y formularios:** `#FFFFFF` (blanco puro) con borde sutil `1px solid #E5E7EB`
- **Separadores de tabla / hover:** separador `#F3F4F6`, encabezado de tabla `#F9FAFB` (`11px` uppercase `#6B7280`), hover `#F8FAFC`
- **Texto primario:** `#111827` (carbón profundo)
- **Texto secundario:** `#6B7280`
- **Texto terciario / hints:** `#9CA3AF`
- **Acento primario de marca:** `#C8102E` (Rojo Básculas PESA, hover `#A60D26`), reservado únicamente para la acción principal (`+ Nuevo Documento`, `Capturar`, `Generar / Asignar`, `Finalizar y Generar PDF`) y la barra indicadora izquierda (`3px`) de la sección activa.
- **Estados semánticos discretos (Punto de 6px):**
  - Contenedor siempre neutro: fondo `#F8FAFC`, borde `1px solid #CBD5E1`, texto `#111827`, `border-radius: 6px`.
  - Acompañado de un **punto circular de `6px`**:
    - `#16A34A` — Cerrado / Sincronizado / Conectado / Abierto
    - `#D97706` — En Proceso / En Tablet / Offline
    - `#C8102E` — Pendiente de Formato / Alerta / Cancelada / Requerido

## 3. Sistema de Espaciado, Tipografía y Ergonomía
- **Rejilla de 8px:** márgenes y espaciados estrictamente en múltiplos de `8, 12, 16, 20, 24px`.
- **Radios consistentes:** `8px` en inputs, selects y botones; `12px` en tarjetas (`SectionCard` / `PesaCard`) y paneles.
- **Tipografía:** `Segoe UI` / `Inter` / sistema nativo con **números tabulares** (`tabular-nums` / `FontFeature.tabularFigures()`) para folios, series, capacidades y mediciones.
- **Ergonomía Android / Campo:** área táctil mínima `48x48dp` en todos los botones, chips, checkboxes y campos; layout adaptativo (`NavigationRail` >= `720dp`, `NavigationBar` inferior < `720dp`).
- **Tablas sin amontonamiento (Windows):** dejar visibles máximo 2 acciones primarias por fila (`PDF` + `Capturar`/`Descargar`) y agrupar acciones secundarias (`Reenviar`, `Rehacer`, `Cambiar a Físico/Digital`, `Eliminar`) en un botón menú limpio `⋯`.
- **Feedback no intrusivo:** usar notificaciones flotantes tipo **Toast** (3 segundos, esquina inferior derecha) para confirmaciones exitosas en lugar de ventanas modales bloqueantes.

## 4. Seguridad Gráfica en PyQt6 (`QPainter`)
- Toda coordenada pasada a `QPainter` (`drawLine`, `drawRect`, `drawEllipse`, `drawRoundedRect`, `fillRect`, `drawArc`) DEBE convertirse explícitamente con `int(round(...))` o envolverse en `QPointF(...)` / `QRectF(...)`.
- Nunca pasar resultados de división `/` o multiplicaciones decimales directamente como argumentos posicionales `int` en PyQt6.

## 5. Fluidez y Rendimiento (Cero Congelamientos)
- Toda consulta a PostgreSQL/Render, carga de tabla o envío de correo corre en hilos secundarios (`QThread` / `QRunnable` en Windows; `Future.wait` + SQLite indexado en Android) con barra de progreso lineal sutil en la parte superior.
- Mantener caché local de catálogos (`CatalogCache` en Windows, SQLite en Android) para apertura instantánea de formularios.
