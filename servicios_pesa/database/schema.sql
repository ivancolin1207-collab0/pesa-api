-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║           SERVICIOS PESA — ESQUEMA DE BASE DE DATOS POSTGRESQL             ║
-- ║           Versión: 1.0.0  |  Compatibilidad: PostgreSQL 14+                ║
-- ║           Autor: Equipo de Desarrollo Básculas PESA                        ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- INSTRUCCIONES DE INSTALACIÓN:
--   1. Crear base de datos:  CREATE DATABASE servicios_pesa;
--   2. Crear usuario:        CREATE USER pesa_app WITH PASSWORD 'tu_contrasena';
--   3. Otorgar permisos:     GRANT ALL PRIVILEGES ON DATABASE servicios_pesa TO pesa_app;
--   4. Conectar a la BD:     \c servicios_pesa
--   5. Ejecutar este script: \i schema.sql
--
-- ──────────────────────────────────────────────────────────────────────────────

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- SECCIÓN 1: EXTENSIONES
-- ══════════════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- Búsqueda difusa de texto

-- ══════════════════════════════════════════════════════════════════════════════
-- SECCIÓN 2: FUNCIÓN AUXILIAR — Actualización automática de updated_at
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION fn_update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ══════════════════════════════════════════════════════════════════════════════
-- SECCIÓN 3: CATÁLOGOS ADMINISTRABLES
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 3.1 Catálogo de Clientes (Razones Sociales) ───────────────────────────────
CREATE TABLE IF NOT EXISTS cat_clientes (
    id              SERIAL          PRIMARY KEY,
    razon_social    VARCHAR(300)    NOT NULL,
    direccion       TEXT,
    municipio       VARCHAR(120),
    estado_rep      VARCHAR(80),        -- Estado/entidad federativa
    codigo_postal   CHAR(5),
    telefono        VARCHAR(60),
    email           VARCHAR(200),
    rfc             VARCHAR(20),
    contacto_nombre VARCHAR(200),       -- Nombre del contacto principal
    notas           TEXT,
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_clientes_razon_social UNIQUE (razon_social)
);

CREATE INDEX IF NOT EXISTS idx_clientes_razon_social_trgm
    ON cat_clientes USING GIN (razon_social gin_trgm_ops);

CREATE TRIGGER trg_clientes_updated_at
    BEFORE UPDATE ON cat_clientes
    FOR EACH ROW EXECUTE FUNCTION fn_update_updated_at();

COMMENT ON TABLE  cat_clientes IS 'Catálogo de razones sociales / clientes de Básculas PESA';
COMMENT ON COLUMN cat_clientes.activo IS 'FALSE = cliente dado de baja (soft delete)';

-- ── 3.2 Catálogo de Técnicos ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cat_tecnicos (
    id              SERIAL          PRIMARY KEY,
    nombre_completo VARCHAR(250)    NOT NULL,
    usuario         VARCHAR(60)     UNIQUE,
    telefono        VARCHAR(60),
    email           VARCHAR(200),
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_tecnicos_updated_at
    BEFORE UPDATE ON cat_tecnicos
    FOR EACH ROW EXECUTE FUNCTION fn_update_updated_at();

COMMENT ON TABLE cat_tecnicos IS 'Catálogo de técnicos responsables de los servicios metrológicos';

-- ── 3.3 Catálogo de Tipos de Servicio ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cat_tipo_servicio (
    id          SERIAL          PRIMARY KEY,
    nombre      VARCHAR(200)    NOT NULL,
    descripcion TEXT,
    activo      BOOLEAN         NOT NULL DEFAULT TRUE,

    CONSTRAINT uq_tipo_servicio_nombre UNIQUE (nombre)
);

COMMENT ON TABLE cat_tipo_servicio IS 'Tipos de servicio metrológico (Ajuste, Calibración, Inspección y combinaciones)';

-- ── 3.4 Catálogo de Tipos de Instrumento ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS cat_tipo_instrumento (
    id          SERIAL          PRIMARY KEY,
    nombre      VARCHAR(200)    NOT NULL,
    descripcion TEXT,
    activo      BOOLEAN         NOT NULL DEFAULT TRUE,

    CONSTRAINT uq_tipo_instrumento_nombre UNIQUE (nombre)
);

COMMENT ON TABLE cat_tipo_instrumento IS 'Tipos de instrumentos de medición de pesaje';

-- ── 3.5 Catálogo de Clases de Exactitud (OIML R 76 / NOM-010-SCFI) ──────────
CREATE TABLE IF NOT EXISTS cat_clase_exactitud (
    id          SERIAL          PRIMARY KEY,
    codigo      VARCHAR(4)      NOT NULL,       -- I, II, III, IV
    nombre      VARCHAR(60)     NOT NULL,       -- Especial, Fina, Media, Ordinaria
    simbolo     VARCHAR(20)     NOT NULL,       -- I, II, III, IIII
    descripcion TEXT,
    orden_display SMALLINT      NOT NULL DEFAULT 0,

    CONSTRAINT uq_clase_exactitud_codigo UNIQUE (codigo)
);

COMMENT ON TABLE cat_clase_exactitud IS 'Clases de exactitud según OIML R 76 y NOM-010-SCFI. Tabla fija, no modificar el código.';

-- ══════════════════════════════════════════════════════════════════════════════
-- SECCIÓN 4: CONTROL DE FOLIOS (CRÍTICO — CONCURRENCIA SEGURA)
-- ══════════════════════════════════════════════════════════════════════════════
--
--  Esta tabla es el corazón del sistema de folios.
--  La función generate_folio() usa INSERT ... ON CONFLICT DO UPDATE con
--  actualización atómica, garantizando que nunca se repita un consecutivo
--  incluso con múltiples clientes conectados simultáneamente.
--
CREATE TABLE IF NOT EXISTS control_folios (
    id                  SERIAL      PRIMARY KEY,
    tipo_folio          CHAR(3)     NOT NULL,
    anio                SMALLINT    NOT NULL,
    ultimo_consecutivo  INTEGER     NOT NULL DEFAULT 0,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_control_folios        UNIQUE (tipo_folio, anio),
    CONSTRAINT chk_tipo_folio           CHECK (tipo_folio IN ('OS', 'RMA', 'RE')),
    CONSTRAINT chk_anio                 CHECK (anio BETWEEN 2024 AND 2099),
    CONSTRAINT chk_consecutivo_positivo CHECK (ultimo_consecutivo >= 0)
);

COMMENT ON TABLE  control_folios IS 'CRÍTICO: Controla los consecutivos de folios por tipo y año. NO modificar manualmente.';
COMMENT ON COLUMN control_folios.ultimo_consecutivo IS 'Último consecutivo asignado. El siguiente folio será este valor + 1.';

-- ══════════════════════════════════════════════════════════════════════════════
-- SECCIÓN 5: FUNCIÓN DE GENERACIÓN DE FOLIO (ATÓMICA — THREAD SAFE)
-- ══════════════════════════════════════════════════════════════════════════════
--
--  Uso desde Python:
--    SELECT generate_folio('OS', 2026);  → 'OS-26-1'
--    SELECT generate_folio('RMA', 2026); → 'RMA-26-1'
--
--  Garantías:
--    • Atómico: un solo UPDATE sin ventana de condición de carrera
--    • Auto-inicializa: crea la fila si es el primer folio del año
--    • Formato: TIPO-AA-N  (sin ceros a la izquierda, como OS-26-443)
--
CREATE OR REPLACE FUNCTION generate_folio(
    p_tipo  CHAR(3),
    p_anio  SMALLINT
)
RETURNS VARCHAR(25)
LANGUAGE plpgsql
AS $$
DECLARE
    v_consecutivo   INTEGER;
    v_anio_corto    TEXT;
BEGIN
    -- Obtener los últimos 2 dígitos del año (2026 → '26')
    v_anio_corto := LPAD((p_anio % 100)::TEXT, 2, '0');

    -- INSERT o UPDATE en una sola operación atómica
    -- Si la fila no existe la crea con consecutivo = 1,
    -- si ya existe incrementa el consecutivo en 1.
    INSERT INTO control_folios (tipo_folio, anio, ultimo_consecutivo, updated_at)
    VALUES (p_tipo, p_anio, 1, NOW())
    ON CONFLICT (tipo_folio, anio) DO UPDATE
        SET ultimo_consecutivo = control_folios.ultimo_consecutivo + 1,
            updated_at         = NOW()
    RETURNING ultimo_consecutivo INTO v_consecutivo;

    -- Formato: OS-26-443
    RETURN p_tipo || '-' || v_anio_corto || '-' || v_consecutivo::TEXT;
END;
$$;

COMMENT ON FUNCTION generate_folio IS
    'Genera el siguiente folio consecutivo de forma atómica y segura. '
    'Invocar siempre dentro de una transacción activa. '
    'Ejemplo: SELECT generate_folio(''OS'', 2026) → ''OS-26-1''';

-- ══════════════════════════════════════════════════════════════════════════════
-- SECCIÓN 6: TABLA PRINCIPAL — ÓRDENES DE SERVICIO
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS ordenes_servicio (
    id                  SERIAL          PRIMARY KEY,

    -- ── Identificación y Tipo ─────────────────────────────────────────────────
    folio_os            VARCHAR(25)     NOT NULL,
    fecha               DATE            NOT NULL DEFAULT CURRENT_DATE,
    id_tipo_servicio    INTEGER         NOT NULL REFERENCES cat_tipo_servicio(id)
                                            ON UPDATE CASCADE ON DELETE RESTRICT,

    -- ── Cliente ───────────────────────────────────────────────────────────────
    id_cliente          INTEGER         NOT NULL REFERENCES cat_clientes(id)
                                            ON UPDATE CASCADE ON DELETE RESTRICT,

    -- ── Datos del Equipo ──────────────────────────────────────────────────────
    marca               VARCHAR(120),
    modelo              VARCHAR(120),
    ns                  VARCHAR(120),       -- Número de Serie
    ubicacion           VARCHAR(300),
    alcance_max         NUMERIC(16, 4),     -- Alcance máximo (kg, lb, etc.)
    div_minima          NUMERIC(16, 4),     -- División mínima (e)
    div_verificacion    NUMERIC(16, 4),     -- División de verificación (d)
    id_equipo           VARCHAR(120),       -- Identificador interno del equipo
    id_tipo_instrumento INTEGER         REFERENCES cat_tipo_instrumento(id)
                                            ON UPDATE CASCADE ON DELETE SET NULL,
    numero_cca          VARCHAR(120),       -- Número de CCA / certificado anterior
    holograma_anterior  VARCHAR(120),

    -- ── Valores de Prueba (resúmenes del encabezado de cada tabla) ────────────
    valor_repetibilidad NUMERIC(16, 4),     -- Campo "VALOR:" de repetibilidad
    valor_excentricidad NUMERIC(16, 4),     -- Campo "VALOR:" de excentricidad

    -- ── Clase de Exactitud ────────────────────────────────────────────────────
    id_clase_exactitud  INTEGER         REFERENCES cat_clase_exactitud(id)
                                            ON UPDATE CASCADE ON DELETE SET NULL,

    -- ── Finalización y Firmas ─────────────────────────────────────────────────
    observaciones       TEXT,
    id_tecnico          INTEGER         REFERENCES cat_tecnicos(id)
                                            ON UPDATE CASCADE ON DELETE SET NULL,
    firma_cliente_nombre VARCHAR(250),      -- Nombre de quien firma de recibido

    -- ── Estado y Trazabilidad ─────────────────────────────────────────────────
    estado              VARCHAR(20)     NOT NULL DEFAULT 'PROCESO',
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_os_folio   UNIQUE (folio_os),
    CONSTRAINT chk_os_estado CHECK (estado IN ('PROCESO', 'CANCELADA', 'ESCANEADA'))
);

-- Índices de rendimiento para búsqueda y filtrado
CREATE INDEX IF NOT EXISTS idx_os_fecha          ON ordenes_servicio (fecha DESC);
CREATE INDEX IF NOT EXISTS idx_os_estado         ON ordenes_servicio (estado);
CREATE INDEX IF NOT EXISTS idx_os_cliente        ON ordenes_servicio (id_cliente);
CREATE INDEX IF NOT EXISTS idx_os_tecnico        ON ordenes_servicio (id_tecnico);
CREATE INDEX IF NOT EXISTS idx_os_folio_trgm     ON ordenes_servicio USING GIN (folio_os gin_trgm_ops);

CREATE TRIGGER trg_os_updated_at
    BEFORE UPDATE ON ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION fn_update_updated_at();

COMMENT ON TABLE  ordenes_servicio IS 'Tabla principal de Órdenes de Servicio metrológicas';
COMMENT ON COLUMN ordenes_servicio.folio_os IS 'Formato: OS-AA-N (ej. OS-26-443). Generado por generate_folio().';
COMMENT ON COLUMN ordenes_servicio.estado   IS 'PROCESO = activa, CANCELADA = anulada, ESCANEADA = terminada con archivo adjunto';

-- ══════════════════════════════════════════════════════════════════════════════
-- SECCIÓN 7: TABLAS DE DETALLE METROLÓGICO
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 7.1 Repetibilidad ─────────────────────────────────────────────────────────
--    Registra N posiciones (típicamente 3) con lecturas inicial y final.
--    El error por fila (|final - inicial|) se calcula como columna generada.
CREATE TABLE IF NOT EXISTS det_repetibilidad (
    id              SERIAL          PRIMARY KEY,
    id_os           INTEGER         NOT NULL REFERENCES ordenes_servicio(id)
                                        ON DELETE CASCADE ON UPDATE CASCADE,
    posicion_id     SMALLINT        NOT NULL,   -- 1, 2, 3, ...
    lectura_inicial NUMERIC(16, 4),
    lectura_final   NUMERIC(16, 4),
    -- Columna generada: error absoluto por fila
    error_fila      NUMERIC(16, 4)  GENERATED ALWAYS AS (
                        ABS(COALESCE(lectura_final, 0) - COALESCE(lectura_inicial, 0))
                    ) STORED,

    CONSTRAINT uq_repetibilidad_os_pos  UNIQUE (id_os, posicion_id),
    CONSTRAINT chk_repetibilidad_pos    CHECK (posicion_id BETWEEN 1 AND 20)
);

CREATE INDEX IF NOT EXISTS idx_rep_os ON det_repetibilidad (id_os);
COMMENT ON TABLE det_repetibilidad IS 'Datos de prueba de Repetibilidad. Relación N:1 con ordenes_servicio.';
COMMENT ON COLUMN det_repetibilidad.error_fila IS 'Calculado automáticamente: |lectura_final - lectura_inicial|';

-- ── 7.2 Excentricidad ─────────────────────────────────────────────────────────
--    Registra N posiciones (típicamente 6) con lecturas inicial y final.
CREATE TABLE IF NOT EXISTS det_excentricidad (
    id              SERIAL          PRIMARY KEY,
    id_os           INTEGER         NOT NULL REFERENCES ordenes_servicio(id)
                                        ON DELETE CASCADE ON UPDATE CASCADE,
    posicion_id     SMALLINT        NOT NULL,   -- 1, 2, 3, 4, 5, 6, ...
    lectura_inicial NUMERIC(16, 4),
    lectura_final   NUMERIC(16, 4),
    error_fila      NUMERIC(16, 4)  GENERATED ALWAYS AS (
                        ABS(COALESCE(lectura_final, 0) - COALESCE(lectura_inicial, 0))
                    ) STORED,

    CONSTRAINT uq_excentricidad_os_pos  UNIQUE (id_os, posicion_id),
    CONSTRAINT chk_excentricidad_pos    CHECK (posicion_id BETWEEN 1 AND 20)
);

CREATE INDEX IF NOT EXISTS idx_exc_os ON det_excentricidad (id_os);
COMMENT ON TABLE det_excentricidad IS 'Datos de prueba de Excentricidad. Relación N:1 con ordenes_servicio.';

-- ── 7.3 Exactitud ─────────────────────────────────────────────────────────────
--    Registra N puntos de prueba (típicamente 10) con valor nominal,
--    lecturas y error calculado.
CREATE TABLE IF NOT EXISTS det_exactitud (
    id              SERIAL          PRIMARY KEY,
    id_os           INTEGER         NOT NULL REFERENCES ordenes_servicio(id)
                                        ON DELETE CASCADE ON UPDATE CASCADE,
    punto_id        SMALLINT        NOT NULL,   -- 1, 2, ..., 10
    valor_nominal   NUMERIC(16, 4),             -- Patrón / peso de referencia
    lectura_inicial NUMERIC(16, 4),
    lectura_final   NUMERIC(16, 4),
    -- Error de exactitud: diferencia entre lectura final y valor nominal
    error_fila      NUMERIC(16, 4)  GENERATED ALWAYS AS (
                        ABS(COALESCE(lectura_final, 0) - COALESCE(valor_nominal, 0))
                    ) STORED,

    CONSTRAINT uq_exactitud_os_punto    UNIQUE (id_os, punto_id),
    CONSTRAINT chk_exactitud_punto      CHECK (punto_id BETWEEN 1 AND 30)
);

CREATE INDEX IF NOT EXISTS idx_exact_os ON det_exactitud (id_os);
COMMENT ON TABLE det_exactitud IS 'Datos de prueba de Exactitud con valor nominal. Relación N:1 con ordenes_servicio.';
COMMENT ON COLUMN det_exactitud.error_fila IS 'Calculado automáticamente: |lectura_final - valor_nominal|';

-- ══════════════════════════════════════════════════════════════════════════════
-- SECCIÓN 8: ARCHIVOS ADJUNTOS (ESCANEOS)
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS adjuntos_os (
    id                  SERIAL          PRIMARY KEY,
    id_os               INTEGER         NOT NULL REFERENCES ordenes_servicio(id)
                                            ON DELETE RESTRICT ON UPDATE CASCADE,
    nombre_archivo      VARCHAR(300)    NOT NULL,   -- OS-26-443-ESCANEADO.pdf
    ruta_completa       VARCHAR(600)    NOT NULL,   -- Ruta UNC completa
    hash_md5            CHAR(32),                   -- Integridad del archivo
    tipo_archivo        VARCHAR(10),                -- pdf, jpg, png, tif
    tamano_bytes        BIGINT,
    id_tecnico_cargador INTEGER         REFERENCES cat_tecnicos(id)
                                            ON UPDATE CASCADE ON DELETE SET NULL,
    fecha_adjunto       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Una OS solo puede tener un escaneo principal
    CONSTRAINT uq_adjuntos_os_principal UNIQUE (id_os)
);

COMMENT ON TABLE  adjuntos_os IS 'Archivos físicos escaneados asociados a cada OS. Ruta apunta al servidor central.';
COMMENT ON COLUMN adjuntos_os.nombre_archivo IS 'Formato: OS-AA-NNN-ESCANEADO.pdf (auto-generado por la app)';
COMMENT ON COLUMN adjuntos_os.hash_md5 IS 'MD5 del archivo para verificar integridad tras la copia a servidor';

-- ══════════════════════════════════════════════════════════════════════════════
-- SECCIÓN 9: VISTAS ANALÍTICAS
-- ══════════════════════════════════════════════════════════════════════════════

-- ── Vista Principal (Dashboard) ───────────────────────────────────────────────
CREATE OR REPLACE VIEW v_ordenes_servicio AS
SELECT
    os.id,
    os.folio_os,
    os.fecha,
    os.estado,
    -- Cliente
    cl.razon_social                         AS cliente,
    cl.direccion                            AS direccion_cliente,
    -- Tipo de servicio
    ts.nombre                               AS tipo_servicio,
    -- Técnico
    tc.nombre_completo                      AS tecnico,
    -- Equipo
    os.marca,
    os.modelo,
    os.ns,
    os.ubicacion,
    os.alcance_max,
    os.div_minima,
    os.div_verificacion,
    os.id_equipo,
    ti.nombre                               AS tipo_instrumento,
    os.numero_cca,
    os.holograma_anterior,
    -- Pruebas
    os.valor_repetibilidad,
    os.valor_excentricidad,
    ce.codigo                               AS clase_exactitud_codigo,
    ce.nombre                               AS clase_exactitud_nombre,
    ce.simbolo                              AS clase_exactitud_simbolo,
    -- Finalización
    os.observaciones,
    os.firma_cliente_nombre,
    -- Archivo adjunto
    adj.nombre_archivo                      AS archivo_escaneado,
    adj.ruta_completa                       AS ruta_escaneado,
    adj.fecha_adjunto,
    -- Timestamps
    os.created_at,
    os.updated_at
FROM ordenes_servicio os
LEFT JOIN cat_clientes          cl  ON os.id_cliente          = cl.id
LEFT JOIN cat_tipo_servicio     ts  ON os.id_tipo_servicio     = ts.id
LEFT JOIN cat_tecnicos          tc  ON os.id_tecnico           = tc.id
LEFT JOIN cat_tipo_instrumento  ti  ON os.id_tipo_instrumento  = ti.id
LEFT JOIN cat_clase_exactitud   ce  ON os.id_clase_exactitud   = ce.id
LEFT JOIN adjuntos_os           adj ON os.id                   = adj.id_os;

COMMENT ON VIEW v_ordenes_servicio IS 'Vista desnormalizada de OS para el dashboard y exportaciones';

-- ── Vista: Resumen de Pruebas Metrológicas por OS ─────────────────────────────
CREATE OR REPLACE VIEW v_resumen_pruebas AS
SELECT
    os.folio_os,
    -- Error máximo de Repetibilidad
    (SELECT MAX(r.error_fila) FROM det_repetibilidad r WHERE r.id_os = os.id)
        AS error_max_repetibilidad,
    -- Error máximo de Excentricidad
    (SELECT MAX(e.error_fila) FROM det_excentricidad e WHERE e.id_os = os.id)
        AS error_max_excentricidad,
    -- Error máximo de Exactitud
    (SELECT MAX(ex.error_fila) FROM det_exactitud ex WHERE ex.id_os = os.id)
        AS error_max_exactitud
FROM ordenes_servicio os;

COMMENT ON VIEW v_resumen_pruebas IS 'Resumen de errores máximos de cada tipo de prueba por OS';

-- ══════════════════════════════════════════════════════════════════════════════
-- SECCIÓN 10: DATOS INICIALES (SEED DATA)
-- ══════════════════════════════════════════════════════════════════════════════

-- Tipos de Servicio
INSERT INTO cat_tipo_servicio (nombre, descripcion) VALUES
    ('Calibración',
     'Determinación de la relación entre los valores indicados por el instrumento y los valores conocidos'),
    ('Ajuste',
     'Conjunto de operaciones para que la báscula indique correctamente'),
    ('Inspección',
     'Verificación del estado metrológico y de funcionamiento del instrumento'),
    ('Calibración + Ajuste',
     'Calibración seguida de ajuste correctivo en la misma visita'),
    ('Calibración + Inspección',
     'Calibración con informe de inspección técnica'),
    ('Ajuste + Inspección',
     'Ajuste correctivo con verificación posterior'),
    ('Calibración + Ajuste + Inspección',
     'Servicio metrológico completo: calibración, ajuste e inspección')
ON CONFLICT (nombre) DO NOTHING;

-- Tipos de Instrumento
INSERT INTO cat_tipo_instrumento (nombre) VALUES
    ('Báscula de plataforma'),
    ('Báscula de piso'),
    ('Báscula camionera / puente de pesaje'),
    ('Báscula de mostrador'),
    ('Báscula de precisión'),
    ('Báscula colgante / de gancho'),
    ('Báscula de laboratorio'),
    ('Báscula de banda / transportadora'),
    ('Dinamómetro'),
    ('Indicador / controlador de peso')
ON CONFLICT (nombre) DO NOTHING;

-- Clases de Exactitud (OIML R 76 / NOM-010-SCFI-2014)
-- Orden visual en formulario: J I A | ORDINARIA | MEDIA | FINA | ESPECIAL
INSERT INTO cat_clase_exactitud (codigo, nombre, simbolo, descripcion, orden_display) VALUES
    ('IV', 'Ordinaria', 'IIII', 'Instrumentos para pesaje bruto industrial y comercial de baja precisión', 1),
    ('III', 'Media',     'III',  'Instrumentos para uso comercial e industrial general',                   2),
    ('II',  'Fina',      'II',   'Instrumentos para pesaje de precisión en comercio y laboratorio',        3),
    ('I',   'Especial',  'I',    'Instrumentos de alta precisión para aplicaciones especiales',            4)
ON CONFLICT (codigo) DO NOTHING;

-- Técnicos del equipo Básculas PESA
INSERT INTO cat_tecnicos (nombre_completo, usuario) VALUES
    ('Luis Fernando',     'luis.fernando'),
    ('Jhonny Jimenez',    'jhonny.jimenez'),
    ('Angel Rosales',     'angel.rosales'),
    ('Alan Terrazas',     'alan.terrazas'),
    ('Nestor Gabriel',    'nestor.gabriel'),
    ('Alan Guevara',      'alan.guevara'),
    ('Alessandro Segovia','alessandro.segovia')
ON CONFLICT (usuario) DO NOTHING;

-- Inicializar control de folios para el año actual y los próximos 3
DO $$
DECLARE
    v_anio_actual SMALLINT := EXTRACT(YEAR FROM NOW())::SMALLINT;
    v_tipo        CHAR(3);
    v_offset      SMALLINT;
BEGIN
    FOREACH v_tipo IN ARRAY ARRAY['OS', 'RMA', 'RE'] LOOP
        FOR v_offset IN 0..3 LOOP
            INSERT INTO control_folios (tipo_folio, anio, ultimo_consecutivo)
            VALUES (v_tipo, v_anio_actual + v_offset, 0)
            ON CONFLICT (tipo_folio, anio) DO NOTHING;
        END LOOP;
    END LOOP;
END;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- SECCIÓN 11: PERMISOS PARA EL USUARIO DE APLICACIÓN
-- ══════════════════════════════════════════════════════════════════════════════

-- Otorgar permisos al usuario de la app (ajustar 'pesa_app' si es necesario)
DO $$
BEGIN
    -- Verificar si el usuario existe antes de otorgar permisos
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pesa_app') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO pesa_app;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO pesa_app;
        GRANT EXECUTE ON FUNCTION generate_folio(CHAR, SMALLINT) TO pesa_app;
    END IF;
END;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- FIN DEL ESQUEMA
-- ══════════════════════════════════════════════════════════════════════════════

COMMIT;

-- Verificación final
SELECT
    schemaname,
    tablename,
    tableowner
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;
