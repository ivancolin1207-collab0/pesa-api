# AUDIT_REPORT.md — Auditoría Técnica Exhaustiva Servicios PESA (v4.0)

**Fecha de auditoría:** 2026-11-26  
**Alcance:** Ecosistema completo — Backend FastAPI/PostgreSQL (`./pesa_api`), Escritorio Windows PyQt6 (`./servicios_pesa`), Aplicación Móvil Android + Samsung Galaxy Z Fold8 Ultra (`./pesa_flutter`), Despliegue Render (`https://pesa-api-za9i.onrender.com`) y Pipeline CI/CD (`.github/workflows/`).

---

## 1. Inventario Real de Arquitectura y Base de Datos

### 1.1 Inventario de Código
- **Backend FastAPI (`./pesa_api`):** 33 archivos Python (11 routers activos: `auth.py`, `os_router.py`, `sync.py`, `catalogos.py`, `admin_router.py`, `usuarios_router.py`, `equipos.py`, `entrega_semanal.py`, `errores_router.py`, `ordenes.py`; núcleo en `core/config.py`, `core/database.py`, `core/security.py`, `core/email_service.py`).
- **Escritorio Windows (`./servicios_pesa`):** 142 archivos Python (15 widgets en `ui/widgets/`, 6 diálogos en `ui/dialogs/`, `ui/main_window.py`, `ui/theme.py`, `ui/styles/theme.py`, 5 iconos SVG en `ui/assets/icons/`, 15 servicios/generadores PDF en `services/`, 7 modelos en `models/`).
- **Android / Z Fold8 Ultra (`./pesa_flutter/lib`):** 85 archivos Dart (20 pantallas en `screens/`, 11 servicios en `services/`, 13 widgets en `widgets/`, 2 archivos de tema/layout plegable en `theme/`).
- **Repositorio Git:** Repositorio unificado en raíz (`origin/main` → `https://github.com/ivancolin1207-collab0/pesa-api.git`). Ningún subdirectorio contiene `.git` independiente.

### 1.2 Esquema Real de PostgreSQL (Render `pesa_db`, 26 objetos públicos)
| Tabla / Vista | Tipo | Registros | Columnas Clave |
| :--- | :--- | ---: | :--- |
| `cat_clientes` | `BASE TABLE` | 456 | `id`, `razon_social`, `direccion`, `email`, `telefono`, `contacto_nombre`, `activo` |
| `cliente_sucursales` | `BASE TABLE` | 498 | `id`, `cliente_id`, `nombre_sucursal`, `direccion`, `contacto_nombre`, `contacto_telefono`, `email`, `activo` |
| `cat_tecnicos` | `BASE TABLE` | 10 | `id`, `nombre_completo`, `usuario`, `rol`, `password_hash`, `activo`, `firma_digital` |
| `tecnicos` | `VIEW` | 10 | Vista directa sobre `cat_tecnicos` (mismo esquema, incluida `firma_digital`) |
| `ordenes_servicio` | `BASE TABLE` | 443 | `id`, `folio_os`, `folio`, `fecha`, `fecha_servicio`, `id_tipo_servicio`, `tipo_servicio`, `id_cliente`, `sucursal_id`, `cliente`, `marca`, `modelo`, `ns`, `id_equipo`, `ubicacion`, `alcance_max`, `div_minima`, `instrumento_capacidad`, `instrumento_division`, `numero_cca`, `numero_dve`, `holograma_anterior`, `holograma_actualizado`, `aplica_excentricidad`, `motivo_no_excentricidad`, `tipo_no_aplica_exc`, `id_lote`, `rango_lote`, `estado`, `estatus`, `modalidad`, `tipo_documento`, `correo_enviado`, `correo_destino`, `correo_cliente`, `correo_cc`, `fecha_envio_correo`, `motivo_cancelacion`, `cancelada_por`, `fecha_cancelacion`, `sin_correo_cliente`, `motivo_sin_correo`, `datos_tecnicos_json`, `pdf_b64`, `pdf_url`, `firma_tecnico`, `firma_cliente` |
| `cat_tipo_servicio` | `BASE TABLE` | 8 | `id`, `nombre`, `descripcion`, `activo` |
| `cat_tipo_instrumento` | `BASE TABLE` | 19 | `id`, `nombre`, `descripcion`, `activo` |
| `cliente_instrumentos` | `BASE TABLE` | 179 | `id`, `cliente_id`, `id_indicador`, `marca`, `modelo`, `numero_serie`, `capacidad_max`, `division_min`, `ubicacion` |
| `cliente_equipos` | `BASE TABLE` | 1 | `id`, `sucursal_id`, `marca`, `modelo`, `numero_serie`, `id_indicador_equipo`, `capacidad_maxima`, `division_minima`, `ubicacion_interna`, `tipo_instrumento` |
| `catalogo_marcas_modelos` | `BASE TABLE` | 112 | `id`, `marca`, `modelo` |
| `control_folios` | `BASE TABLE` | 20 | `id`, `tipo_folio`, `anio`, `ultimo_consecutivo`, `updated_at` |

---

## 2. Hallazgos Críticos y Bugs Raíz Detectados

### 2.1 Backend FastAPI, PostgreSQL y Render (`./pesa_api` y `./servicios_pesa`)
1. **Fuga de dependencias de escritorio en `./servicios_pesa/requirements.txt` (`servicios_pesa/requirements.txt:6-24`):**
   - Mientras la raíz (`requirements.txt`) y `pesa_api/requirements.txt` ya están aislados, `servicios_pesa/requirements.txt` todavía incluye `PyQt6>=6.7.0`, `PyQt6-Qt6>=6.7.0` y `pywin32>=306` y carece de `servicios_pesa/requirements-desktop.txt`. Esto fue la causa raíz de fallos históricos de compilación en Linux/Render cuando el directorio raíz o build apuntaba a `servicios_pesa`.
2. **Columna `hologramas` ausente en migraciones DDL de PostgreSQL y SQLite (`pesa_api/main.py:45-78`, `servicios_pesa/database/connection.py`, `pesa_flutter/lib/services/local_db_service.dart`):**
   - Existen `holograma_anterior` y `holograma_actualizado`, pero falta la columna consolidada `hologramas TEXT` y faltaban explícitamente `correo_enviado`, `correo_cc`, `fecha_envio_correo` en el listado de migraciones de `pesa_api/main.py`.
3. **37 registros históricos con `correo_enviado = TRUE` y `correo_destino` nulo/vacío en PostgreSQL:**
   - Ejemplo real: `OS-26-749`, `OS-26-752`, `OS-26-766`, `OS-26-767`, `OS-26-765`, etc. Requieren saneamiento idempotente (rescatar correo real desde `correo_cliente`/`cat_clientes`/`cliente_sucursales` si existe, y garantizar saneamiento de placeholders como `'Cliente'` o `'Sin registrar'`).
4. **Helper RBAC `es_admin(rol)` no unificado (`pesa_api/core/security.py:175-204`):**
   - `security.py` expone `es_rol_admin(user)` sobre dicts, pero no un helper unificado `es_admin(rol_o_user)` que acepte tanto strings (`"Administrador"`, `"superadmin"`, `"jefe"`, `"gerente"`) como dicts de usuario, y `require_roles` en línea 202 hace chequeo manual `user_role_canon == "admin" or "admin" in user_role`.
5. **Plantilla HTML de correos duplicada y desalineada entre Backend y Desktop (`pesa_api/core/email_service.py:496-618` vs `servicios_pesa/services/metrology.py:501-657`):**
   - `servicios_pesa/services/metrology.py:519` **NO excluye órdenes `'CANCELADA'`** al construir asuntos/tablas HTML.
   - Ambos archivos todavía usan tonos Slate (`#0F172A`, `#E2E8F0`, `#F8FAFC`) en lugar de la paleta Apple Minimalista PESA (`#1D1D1F` en `CCA`/`DVE` y texto principal, `#E5E5EA` bordes, `#F5F5F7` fondo alterno/encabezado).
6. **Firma de técnico corrupta/de prueba de 96 bytes en BD (`cat_tecnicos.id = 8`, `Daikki19`):**
   - `cat_tecnicos.firma_digital` tiene un PNG dummy de 10x10px (`96` chars) para `Daikki19`, lo cual pasa el umbral mínimo de 32 chars en `usuarios_router.py:141`. Conviene mantener validación robusta y asegurar paridad total del payload de respuesta (`ok`, `tiene_firma`, `id_tecnico`, `firma_base64`, `firma_digital`).
7. **`servicios_pesa/utils_metrologia.py:6-22` no reexporta `formatear_division_minima`:**
   - Dificulta importar la normalización de división mínima desde el módulo compartido puro sin tocar PyQt6.

### 2.2 Reglas de Negocio, Metrología y Generación de PDFs (Python + Flutter)
1. **BUG CRÍTICO — Regla condicional `DVE + Hologramas` rota en PDF de Flutter (`pesa_flutter/lib/services/pdf_service.dart:423-427`):**
   - Líneas 423-427 hacen:
     `final bool mostrarCca = rules.pideCca || cca.isNotEmpty;`
     `final bool mostrarDve = rules.pideDve || folioDve.isNotEmpty || holoAnt.isNotEmpty || holoNue.isNotEmpty;`
   - Esto viola la regla estricta: si una orden de `Ajuste` o `Calibración + Ajuste` conserva datos residuales de DVE/holograma, el PDF generado en Android imprime la fila `FOLIO DVE / HOLO. ANTERIOR / HOLO. NUEVO`, rompiendo la paridad 1:1 con `os_pdf_generator.py:975-985`. Debe restringirse estrictamente a `rules.pideCca` y `rules.pideDve` (`rules.tieneInspeccion`).
2. **BUG — `OSOB` en Windows (`servicios_pesa/ui/dialogs/osob_digital_dialog.py`) no persiste borrador en `borradores_captura` al cerrar:**
   - A diferencia de Flutter (`observaciones_bascula_screen.dart`), el diálogo `OSOB` de Windows no tiene auto-guardado en tabla local/remota `borradores_captura` al salir.
3. **Verificación de reglas existentes (confirmadas y protegidas con pruebas en Fase 6):**
   - `formatear_division_minima` (`0.020 kg` → `0.02 kg`) presente en `services/metrology.py:115`, `services/os_pdf_generator.py:82` y `metrology_helper.dart`.
   - `aplica_excentricidad == False`: las 3 casillas de `POSICIONES DE EXCENTRICIDAD` quedan desmarcadas y se dibujan los 5 iconos vectoriales (`Grúa`, `Patín`, `Tanque`, `Tolva`, `Silo`) en ambos PDFs; requiere pruebas automatizadas reales de generación PDF para garantizar cero regresiones.
   - `cantidad == 1` → `id_lote = None` en `batch_generator_widget.py:4697` y `nuevo_doc_screen.dart`.

### 2.3 Escritorio Windows PyQt6 (`./servicios_pesa/ui`)
1. **BUG CRÍTICO DE QSS — Ruta de flecha rota en `QComboBox::down-arrow` y falta de iconos SVG en `QSpinBox` (`servicios_pesa/ui/styles/theme.py:196-201`):**
   - `QComboBox::down-arrow` apunta a `url(assets/images/chevron_down.png)`, archivo que **no existe** (los iconos SVG limpios viven en `ui/assets/icons/chevron_down.svg`, `arrow_up.svg`, `arrow_down.svg`, `check_white.svg`).
   - `QSpinBox::up-arrow` y `down-arrow` no cargan `arrow_up.svg` / `arrow_down.svg`.
2. **BUG DE QSS — Directiva `!important` inválida en Qt (`servicios_pesa/ui/styles/theme.py:403-404`):**
   - `color: #0F172A !important;` y `background-color: #FFFFFF !important;` provocan errores silenciosos de parseo en QSS.
3. **Conflicto de dos sistemas visuales (`ui/styles/theme.py` vs `ui/theme.py`):**
   - `ui/styles/theme.py` usa `#F5F6F8`, `#0F172A`, `#E2E8F0`, `border-radius: 6px` y hover rosado `#FEF2F2` (línea 315), contradiciendo el estándar Apple Minimalista PESA (`#F5F5F7`, `#FFFFFF`, `#E5E5EA`, `#F2F2F7`, `#1D1D1F`, `#6E6E73`, `#C8102E`, `border-radius: 10px`, altura uniforme `38px`).
4. **Colores "IA" / pastel residuales y >90 emojis en chrome de UI de Windows:**
   - Colores pastel/rosados detectados en: `ui/styles/theme.py:315` (`#FEF2F2`), `ui/dialogs/digital_service_dialog.py:635,1259` (`#8B5CF6`, `#FEF2F2`), `ui/dialogs/modo_formato_dialog.py:280,479` (`#FEF2F2`), `ui/widgets/captura_digital_dialog.py:614` (`#FFF3E0`), `ui/widgets/equipo_search_widget.py:220` (`#FEF2F2`), `ui/dialogs/login_dialog.py:427` (`rgba(184, 29, 36, 0.15)`).
   - Emojis informales (`📋`, `📷`, `✍️`, `📝`, `💾`, `🗑️`, `⚠️`, `✅`, `❌`, `🖨️`, `📱`, `🔍`, `🔄`, `🏭`, `⚖️`, `🔌`, `🗄️`, `💻`, `🔢`, `🔗`, `➕`, `✏️`, `✖️`, `📄`) presentes en `main_window.py`, `batch_generator_widget.py`, `dashboard_widget.py`, `catalogos_widget.py`, `configuracion_widget.py`, `equipo_search_widget.py`, `lp_form_widget.py`, `lv_form_widget.py`, `os_form_widget.py`, `re_form_widget.py`, `recepcion_widget.py`, `rma_form_widget.py`, `scanner_widget.py`, `captura_digital_dialog.py`, `digital_service_dialog.py`, `toma_digital_dialog.py`, `modo_formato_dialog.py`, `login_dialog.py`.
5. **Alturas fijas rígidas con riesgo de recorte y alturas inconsistentes de inputs:**
   - `modo_formato_dialog.py:197` usa `card.setFixedHeight(160)` en tarjeta con texto multilínea (debe ser `setMinimumHeight(140)` + `SizePolicy.MinimumExpanding`).
   - `batch_generator_widget.py` mezcla `setFixedHeight(40)` y `setFixedHeight(38)` en inputs en lugar de `38px` uniforme, y el `QScrollArea` del asistente debe garantizar margen inferior suficiente para que el sticky footer nunca tape controles.
   - `main_window.py:727` agrega `self._header_conn_badge` sin `Qt.AlignmentFlag.AlignVCenter`, pudiendo desalinear verticalmente la píldora `PostgreSQL` respecto a `ADMINISTRADOR`.
6. **Rendimiento y sesión HTTP persistente:**
   - `services/http_client.py` existe pero debemos asegurar que todo módulo de red use `requests.Session` persistente y `QThread`/`QThreadPool` sin bloqueos en el hilo principal.

### 2.4 Android & Samsung Galaxy Z Fold8 Ultra (`./pesa_flutter/lib`)
1. **Banner de sincronización incompleto (`pesa_flutter/lib/services/sync_service.dart:49-65`):**
   - Muestra únicamente `N órdenes, M clientes`, omitiendo el contador real de **direcciones/sucursales (`K direcciones`)** y sin exponer un diagnóstico HTTP claro y compacto en la cabecera cuando algún submódulo reporta advertencia.
2. **Concurrencia `Future.wait` en `sync_service.dart:2007` (`_pushFirmasPendientes`):**
   - A diferencia de línea 732 (que tiene `.catchError`), debemos auditar línea 2007 para asegurar aislamiento total por ítem (`try/catch` individual) de modo que una firma fallida jamás aborte las demás ni bloquee el ciclo de sincronización.
3. **Llamadas deprecadas `.withOpacity(...)` (5 archivos):**
   - `attach_scan_screen.dart:491`, `os_list_screen.dart:3765`, `remision_captura_screen.dart:801`, `revision_bascula_screen.dart:1004`, `excentricidad_table.dart:874`. Deben migrarse a `.withValues(alpha: ...)`.
4. **Emojis informales en UI de Android (7 archivos):**
   - `login_screen.dart:323,342,428` (`🔄`, `⚠️`), `os_list_screen.dart:1490,1519` (`📄`, `✅`), `observaciones_bascula_screen.dart:1021-1022` (`✓`, `⏳`), `nombre_recibe.dart:24,33` (`⚠️`), `attach_scan_screen.dart:260,682,759`, `captura_screen.dart:2516`, `pdf_storage_service.dart:283,444,458`.
5. **Auditoría de pantallas secundarias y continuidad Dual-Screen Z Fold8 Ultra:**
   - `AndroidManifest.xml` ya tiene `resizeableActivity="true"`, `configChanges` completos, `max_aspect="2.4"`, `supports_size_changes="true"`.
   - `PesaTheme` ya tiene `surfaceTintColor: Colors.transparent`, `#F5F5F7`, `#FFFFFF`, `#E5E5EA` radio `14px`, botones `48dp`.
   - Se deben auditar todas las pantallas para garantizar que **ningún controlador** se cree dentro de `build()`, que las pantallas clave (`login_screen`, `os_list_screen`, `catalogos_screen`, `nuevo_doc_screen`, `mi_firma_screen`, `buscar_historial_screen`, `settings_screen`, `attach_scan_screen`) usen estética Apple consistente, `FontFeature.tabularFigures()` en cifras metrológicas y pasen pruebas de widget dual-screen (`380x840` cover + `840x920` unfolded) con **0 `RenderFlex overflow`**.

---

## 3. Plan de Remediación Ordenado (Fases 2 a 7)
1. **Fase 2 (Backend & Render):** Limpiar `servicios_pesa/requirements.txt` + crear `servicios_pesa/requirements-desktop.txt`; unificar `es_admin(rol)` en `pesa_api/core/security.py`; agregar `hologramas` y columnas de correo en migraciones idempotentes + saneamiento histórico de `correo_destino`; centralizar plantilla HTML Apple `#1D1D1F` excluyendo `CANCELADA` en `pesa_api/core/email_service.py` y `servicios_pesa/services/metrology.py`; validar endpoints críticos (`/api/clientes`, `/api/admin/catalogos`, `/api/ordenes?q=`, `/api/ordenes/{folio}/instrumento`, `/api/ordenes/{folio}/cancelar`, `/api/ordenes/{folio}/reactivar`, `/api/usuarios/{id}/firma`).
2. **Fase 3 (Reglas & PDFs 1:1):** Corregir `mostrarCca`/`mostrarDve` en `pesa_flutter/lib/services/pdf_service.dart`; añadir auto-guardado de borradores en `osob_digital_dialog.py`; exportar `formatear_division_minima` en `utils_metrologia.py`; blindar `OS`, `RMA`, `RE`, `LP`, `LV`, `OSOB`, `OSOCC`, excentricidad no apta (3 casillas vacías + 5 iconos vectoriales), lotes (`cantidad == 1` → `id_lote = None`) y flujo poka-yoke.
3. **Fase 4 (Windows PyQt6):** Reconstruir `ui/styles/theme.py` en Apple Minimalista PESA con rutas SVG absolutas (`chevron_down.svg`, `arrow_up.svg`, `arrow_down.svg`, `check_white.svg`), `QLabel { border: none; background: transparent; }`, altura uniforme `38px` (`border-radius: 10px`), cero `!important`, cero colores pastel/IA, cero emojis en chrome en TODOS los archivos de `servicios_pesa/ui/`, alineación vertical del TopBar `56px`, cards flexibles sin recortes (`modo_formato_dialog.py`, `batch_generator_widget.py`) y rendimiento no bloqueante.
4. **Fase 5 (Android + Z Fold8 Ultra):** Añadir contador `K direcciones` y banner de diagnóstico HTTP claro en `sync_service.dart` + aislamiento total en `_pushFirmasPendientes`; eliminar `.withOpacity` y emojis en toda la UI; estandarizar pantallas y `tabularFigures` y verificar continuidad dual-screen sin `RenderFlex overflow`.
5. **Fase 6 (Pruebas Automatizadas & Render Live):** Ejecutar suite `pytest`/Python (importación headless bloqueando `PyQt6`, reglas metrológicas, HTML de correo, PDFs reales OS/OSOB/OSOCC), pruebas offscreen PyQt6 (`QT_QPA_PLATFORM=offscreen`), `flutter analyze` + widget tests dual-screen (`380x840` y `840x920`), push a `main` y verificación HTTP `200 OK` en vivo en Render.
6. **Fase 7 (Ejecutables v4.0.0+150):** Compilar `Servicios_PESA.exe` y `Servicios_PESA_Tablet_v4.0.0+150.apk` (vía GitHub Actions) en `./Ejecutables/` preservando intactos todos los `.pdf` y `.env`.
