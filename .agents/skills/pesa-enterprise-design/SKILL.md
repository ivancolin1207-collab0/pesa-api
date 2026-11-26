---
name: pesa-enterprise-design
description: Estándar Apple Minimalista Industrial Empresarial v4.0 de Básculas PESA para Backend (Correos HTML), Escritorio Windows (PyQt6) y Android / Samsung Galaxy Z Fold8 Ultra (Flutter).
---

# Básculas PESA — Enterprise Design System (Apple Minimalista Industrial v4.0)

Este skill define el estándar único e innegociable de diseño, accesibilidad, ergonomía, tipografía y arquitectura UI/UX para todo el ecosistema Servicios PESA (`./pesa_api`, `./servicios_pesa/ui` y `./pesa_flutter/lib`).

## 1. Identidad Cromática (Apple System Gray + Rojo Corporativo PESA)
- **Lienzo / Canvas:** `#F5F5F7` (Apple System Gray 6)
- **Superficies / Tarjetas / Tablas / Inputs:** `#FFFFFF` (blanco puro)
- **Bordes ultrafinos:** `1px solid #E5E5EA` (tarjetas/divisores), `1px solid #D2D2D7` (inputs/botones secundarios)
- **Superficie neutra / hover / badges:** `#F2F2F7`
- **Encabezados de tabla:** `#FBFBFD`
- **Tipografía:** `#1D1D1F` (primario Apple Anthracite), `#6E6E73` (secundario), `#8E8E93` (terciario / deshabilitado / cancelado)
- **Único acento cromático de marca:** `#C8102E` (Rojo Básculas PESA, hover `#A60D26`, pressed `#880B20`) reservado exclusivamente para acciones primarias, foco activo e indicador de navegación activa.
- **Puntos semánticos discretos (6px/6dp dentro de cápsulas neutras `#F2F2F7`):**
  - `#34C759` — Cerrado / Sincronizado / Conectado
  - `#FF9500` — En Proceso / En Cola / Offline
  - `#C8102E` — Pendiente / Requerido / Alerta
  - `#6E6E73` — Cancelada / No utilizada / Neutro
- **PROHIBICIONES ABSOLUTAS:**
  - Cero colores "IA" / pastel / arcoíris (`#EEF2FF`, `#F3E8FF`, `#ECFDF5`, `#FEF2F2`, `#FDF2F8`, `#FFF1F2`, `#E0F2FE`, `#DBEAFE`, `#FFF3E0`, `#FEF3C7`, `#8B5CF6`).
  - Cero filas rosadas o tintadas en tablas.
  - Cero emojis informales en chrome de UI (botones, encabezados, pestañas, alertas, badges). Usar iconografía vectorial limpia (SVG / `QPainter` en PyQt6, `Icons.*` en Flutter).

## 2. Estándar Windows PyQt6 (`./servicios_pesa/ui`)
- **QSS hermético único** (`ui/styles/theme.py` alineado 1:1 con `ui/theme.py`):
  - Regla global absoluta: `QLabel { border: none; background-color: transparent; color: #1D1D1F; }`.
  - Nunca usar `!important` en QSS (inválido en Qt).
  - Bordes y fondos únicamente por `objectName` o propiedades dinámicas (`[card="true"]`, `[variant="primary"]`).
  - Altura uniforme `38px` y `border-radius: 10px` en todos los inputs (`QLineEdit`, `QComboBox`, `QSpinBox`, `QDoubleSpinBox`, `QDateEdit`).
  - Iconos SVG nítidos (`ui/assets/icons/chevron_down.svg`, `arrow_up.svg`, `arrow_down.svg`, `check_white.svg`) resueltos con rutas absolutas en tiempo de ejecución para `QComboBox::down-arrow`, `QSpinBox` y `QCheckBox`.
- **Cero recortes de texto:** prohibido `setFixedHeight` rígido en tarjetas con texto multilínea (`ModeCard`, `DocTypeCard`, cards de resumen); usar `setMinimumHeight`, `setWordWrap(True)` y `SizePolicy.MinimumExpanding`.
- **Seguridad `QPainter`:** toda coordenada debe ser `QPointF`/`QRectF` o `int(round(...))`.
- **Rendimiento no bloqueante:** lazy loading de pestañas, caché de catálogos, debouncing `250ms` en búsqueda, `QThread`/`QThreadPool` para red/BD/PDF/correo y notificaciones Toast no bloqueantes.

## 3. Estándar Android & Samsung Galaxy Z Fold8 Ultra (`./pesa_flutter/lib`)
- **Estética Apple iOS/iPadOS:** `surfaceTintColor: Colors.transparent`, tarjetas `#FFFFFF` con borde `#E5E5EA` y radio `14px`, botones mínimo `48dp`, `FontFeature.tabularFigures()` en números metrológicos, badges en `Wrap` (cero `RenderFlex overflow`).
- **Continuidad Dual-Screen + Bisagra (`FoldableLayout`):**
  - `AndroidManifest.xml` con `resizeableActivity="true"` y `configChanges` completos.
  - Nunca instanciar `TextEditingController`, `SignatureController` ni estado mutable dentro de `build()`.
  - Pantalla externa (`< 600dp`): 1 columna ergonómica + `NavigationBar` inferior.
  - Pantalla interna desplegada (`>= 600dp`): `NavigationRail` lateral + `FoldableTwoPane` con conciencia de bisagra (`MediaQuery.displayFeatures`) + formularios 2 columnas + firmas Técnico | Cliente lado a lado.
  - Bloqueo de scroll padre (`SigningScrollLock` / `SignatureGestureShield` con `Listener`) mientras se firma.

## 4. Correos HTML Institucionales (`pesa_api/core/email_service.py` y `servicios_pesa/services/metrology.py`)
- Excluir estrictamente órdenes `'CANCELADA'` de envíos, reenvíos y ZIPs.
- Asunto exacto:
  - 1 orden: `Orden de Servicio {folio} - {cliente} | Básculas PESA` (o nombre del formato si no es OS).
  - Lote: `Orden de Servicio {folio_inicio} a {folio_fin} - {cliente} | Básculas PESA`.
- Tabla HTML limpia: columnas `#`, `ID` (solo folio), `Marca`, `Modelo`, `ID / Equipo`, y dinámicamente `CCA` / `DVE` solo si al menos 1 orden del envío las posee.
- Celdas `CCA` y `DVE`: texto `#1D1D1F`, `font-weight: 600` (sin píldoras de color). Celdas vacías en blanco `""` (prohibido `"-"` o `"—"`).
