---
name: pesa-industrial-design
description: Sistema de Diseño Industrial Corporativo Minimalista Básculas PESA para PyQt6 (Windows .exe) y Flutter (Android / Samsung Galaxy Z Fold8 Ultra .apk).
---

# Sistema de Diseño Industrial Corporativo Minimalista — Básculas PESA

## 1. Filosofía y Estética ("Industrial Precision, Zero AI Fluff")
- **Cero colores "IA"**: prohibidos los gradientes neón, chips índigo/morado/azul pastel, filas rosadas/salmón, sombras difusas exageradas y emojis informales en controles/botones/headers.
- **Paleta única autorizada**:
  - Canvas / Fondo principal: `#F5F6F8` / `#F6F7F9`
  - Superficies, tarjetas, modales y barra lateral: `#FFFFFF`
  - Superficies neutras / hover de tabla / chips: `#F8FAFC` / `#F9FAFB`
  - Texto primario (carbón alto contraste AAA): `#111827`
  - Texto secundario / labels: `#6B7280`
  - Texto terciario / placeholders: `#9CA3AF`
  - Bordes estructurales / separadores: `#E5E7EB` (1px) y `#CBD5E1` / `#D1D5DB` en inputs
  - Único acento corporativo Básculas PESA: `#C8102E` (hover `#A60D26`, pressed `#880B20`, tinte activo sutil `#FFF5F6`)
  - Indicadores semánticos discretos (únicamente punto circular de 6px/6dp en badges): Verde `#16A34A` (Cerrado / Conectado), Ámbar `#D97706` (En Proceso / Pendiente), Rojo `#C8102E` (Alerta / Pendiente Crítico), Neutro `#6B7280`.

## 2. Reglas Estrictas de QSS Sin Fugas (PyQt6)
1. **Regla anti-fuga obligatoria en cada `setStyleSheet` y en `theme_apple.qss`**:
   - Definir globalmente `QLabel { border: none; background: transparent; }`.
   - **PROHIBIDO** usar selectores genéricos `QFrame { border: ...; background: ...; }` o `QWidget { background: ...; }` en estilos locales de contenedores padres (como `EquipoCard`, `_section_card`, tarjetas de pasos o diálogos): en Qt `QLabel` hereda de `QFrame`, causando recuadros/fondos grises en cada texto hijo.
   - Todo contenedor con fondo o borde DEBE usar selector explícito `#objectName` (p. ej. `QFrame#section_card`, `QFrame#equipo_card`) o propiedad dinámica (`QFrame[card="true"]`), y nunca `QFrame { ... }` desnudo.
2. **Iconografía Vectorial SVG (Cero PNGs borrosos / Cero cuadros rotos en Fusion)**:
   - Todos los iconos de navegación, acciones, calendario, cierre y flechas de controles (`chevron_down.svg`, `arrow_up.svg`, `arrow_down.svg`, etc.) se almacenan en `servicios_pesa/ui/assets/icons/` y se empaquetan en PyInstaller.
   - `QComboBox::down-arrow` utiliza `chevron_down.svg` (`12x12px`) alineado a la derecha con `drop-down` limpio.
   - `QSpinBox` y `QDoubleSpinBox` tienen ancho mínimo `116px` (`min-width: 112px`), `padding: 0 26px 0 10px`, botones `::up-button` / `::down-button` de `22px` con `arrow_up.svg` y `arrow_down.svg` centrados (`10x10px`), garantizando cero amontonamiento o cuadros sólidos.
3. **Inputs y Layout PyQt6**:
   - Altura estándar de inputs (`QLineEdit`, `QComboBox`, `QDateEdit`, `QSpinBox`): `38px` (`min-height: 36px; max-height: 38px;`), `border-radius: 8px`, `border: 1px solid #D1D5DB`, foco `1.5px solid #C8102E`.
   - Sidebar fija `232px` con fondo `#FFFFFF`, ítem activo `#FFF5F6` / `#F8FAFC` con barra izquierda `3px solid #C8102E`.
   - TopBar de `60px` (`#FFFFFF`, borde inferior `#E5E7EB`).
   - Tarjetas seleccionables (`SelectCard`): `minHeight: 84px`, `wordWrap: true` con `heightForWidth` real y ancho libre para 2-3 líneas limpias sin clipping.
   - `QScrollArea` con margen inferior `>= 32px` antes de cualquier footer fijo.
   - Tablas: filas compactas y legibles, columnas numéricas/folio con ancho fijo o mínimo holgado, badges monocromáticos `CCA` / `DVE` (`#F8FAFC`, `#CBD5E1`, `#111827`), botón `⋯` para acciones secundarias.
   - Seguridad `QPainter`: toda llamada a `drawLine`, `drawRect`, `drawEllipse`, `drawRoundedRect`, `fillRect` debe usar `int(round(...))` o `QPointF` / `QRectF`. Jamás pasar `float` crudo.

## 3. Reglas de Diseño Android / Samsung Galaxy Z Fold8 Ultra (Flutter)
1. **Material 3 Descontaminado**:
   - `surfaceTintColor: Colors.transparent`, `elevation: 0` en `CardThemeData` y `AppBarTheme`.
   - Radios: `10dp` tarjetas (`1px solid #E5E7EB`), `8dp` inputs y botones (`48dp` mínimo táctil en toda acción primaria/secundaria).
   - `FontFeature.tabularFigures()` en folios, fechas, mediciones y contadores KPI.
2. **Plegables y Dual-Screen Continuity**:
   - `< 600dp` (pantalla externa Cover / teléfono): navegación inferior `NavigationBar` (`<= 4` destinos clave + perfil/ajustes), formularios de 1 columna sin desbordes horizontales.
   - `>= 600dp` (pantalla interna Z Fold8 Ultra / tablet): `NavigationRail` lateral, patrón Master-Detail en órdenes y catálogos cuando el ancho libre es `>= 840dp` respetando `MediaQuery.displayFeatures` (bisagra vertical libre de elementos interactivos partidos), formularios de 2 columnas (`FoldableTwoColumn` / `FoldableFormGrid`) y captura de firmas Técnico | Cliente lado a lado.
   - Modales de firma (`PesaSignatureModal` / `CapturFirmaTecnicoDialog`) protegidos contra scroll vertical (`Listener` + `NeverScrollableScrollPhysics` durante trazo), exportación PNG transparente mínima `400x160px`, validación de trazo real no vacío y persistencia garantizada local + backend con retroalimentación explícita.

## 4. Reglas Metrológicas y de Dominio Condicionales
- **DVE y Hologramas (Anterior / Actualizado)**: visibles, editables, serializados en BD/correo y renderizados en PDF **EXCLUSIVAMENTE** cuando el `Tipo de Servicio` normalizado incluye inspección (`inspeccion`, `verificacion`, `dve`). Al cambiar a un servicio sin inspección (p. ej. `Ajuste`, `Mantenimiento`), ocultarse de inmediato y limpiar valores para no contaminar registros.
- **CCA e Inicial J/I/A**: visibles y serializados **EXCLUSIVAMENTE** cuando el `Tipo de Servicio` normalizado incluye calibración (`calibracion`, `cca`).
- **RBAC Administrador**: roles equivalentes (`admin`, `administrador`, `superadmin`, `jefe`, `gerente`) con paridad total Web/Windows/Android (visibilidad global, creación/edición de clientes, sucursales y técnicos, creación/asignación de todos los formatos `OS`, `RMA`, `RE`, `LP`, `LV`, `OSOB`, `OSOCC`, lotes `1..N`, Digital/Físico/Híbrido).
