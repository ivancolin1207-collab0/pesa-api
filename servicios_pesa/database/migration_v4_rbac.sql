-- ============================================================================
--  SERVICIOS PESA v2.0 -- MIGRACION v4: RBAC + EQUIPOS + DIGITAL + AUDITORIA
--  Script: migration_v4_rbac.sql
--  Compatibilidad: PostgreSQL 14+
--  IMPORTANTE: Script ADITIVO. No modifica ni elimina datos existentes.
--
--  Ejecutar:
--      psql -U postgres -d servicios_pesa -f migration_v4_rbac.sql
-- ============================================================================

BEGIN;

-- ============================================================================
-- SECCION 1: EXTENSIONES ADICIONALES
-- ============================================================================

-- pgcrypto para hashing bcrypt de contrasenas
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================================
-- SECCION 2: SISTEMA DE ROLES Y USUARIOS
-- ============================================================================

-- 2.1 Tabla de Roles
CREATE TABLE IF NOT EXISTS roles (
    id          SERIAL          PRIMARY KEY,
    nombre      VARCHAR(30)     NOT NULL,
    descripcion TEXT,
    activo      BOOLEAN         NOT NULL DEFAULT TRUE,

    CONSTRAINT uq_roles_nombre  UNIQUE (nombre),
    CONSTRAINT chk_roles_nombre CHECK (
        nombre IN ('admin', 'logistica', 'servicio', 'recepcion')
    )
);

COMMENT ON TABLE  roles IS 'Roles del sistema RBAC. 4 roles fijos.';
COMMENT ON COLUMN roles.nombre IS
    'admin=acceso total | logistica=crear OS/RMA/RE | servicio=campo/tablet | recepcion=entrega fisica';

-- 2.2 Tabla de Usuarios
CREATE TABLE IF NOT EXISTS usuarios (
    id                  SERIAL          PRIMARY KEY,
    username            VARCHAR(60)     NOT NULL,
    password_hash       VARCHAR(255)    NOT NULL,   -- bcrypt via pgcrypto
    nombre_completo     VARCHAR(250)    NOT NULL,
    email               VARCHAR(200),
    id_rol              INTEGER         NOT NULL
                            REFERENCES roles(id) ON UPDATE CASCADE ON DELETE RESTRICT,
    id_tecnico          INTEGER
                            REFERENCES cat_tecnicos(id) ON UPDATE CASCADE ON DELETE SET NULL,
    activo              BOOLEAN         NOT NULL DEFAULT TRUE,
    ultimo_login        TIMESTAMPTZ,
    token_refresh_hash  VARCHAR(255),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_usuarios_username UNIQUE (username)
);

CREATE INDEX IF NOT EXISTS idx_usuarios_username ON usuarios (username);
CREATE INDEX IF NOT EXISTS idx_usuarios_rol      ON usuarios (id_rol);
CREATE INDEX IF NOT EXISTS idx_usuarios_tecnico  ON usuarios (id_tecnico);

CREATE TRIGGER trg_usuarios_updated_at
    BEFORE UPDATE ON usuarios
    FOR EACH ROW EXECUTE FUNCTION fn_update_updated_at();

COMMENT ON TABLE  usuarios IS 'Usuarios con autenticacion bcrypt y rol RBAC.';
COMMENT ON COLUMN usuarios.id_tecnico IS
    'Solo para rol=servicio: vincula el usuario con su registro en cat_tecnicos.';
COMMENT ON COLUMN usuarios.token_refresh_hash IS
    'Hash SHA256 del ultimo refresh token emitido. NULL = sin sesion activa.';

-- ============================================================================
-- SECCION 3: HISTORIAL DE EQUIPOS (cat_equipos)
-- ============================================================================

CREATE TABLE IF NOT EXISTS cat_equipos (
    id_equipo           VARCHAR(120)    NOT NULL,
    marca               VARCHAR(120),
    modelo              VARCHAR(120),
    ns                  VARCHAR(120),
    id_tipo_instrumento INTEGER
                            REFERENCES cat_tipo_instrumento(id) ON UPDATE CASCADE ON DELETE SET NULL,
    alcance_max         NUMERIC(16, 4),
    div_minima          NUMERIC(16, 4),
    div_verificacion    NUMERIC(16, 4),
    id_cliente          INTEGER
                            REFERENCES cat_clientes(id) ON UPDATE CASCADE ON DELETE SET NULL,
    ultima_os_folio     VARCHAR(25),
    ultima_os_fecha     DATE,
    notas               TEXT,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_cat_equipos PRIMARY KEY (id_equipo)
);

CREATE EXTENSION IF NOT EXISTS pg_trgm;  -- Ya existe, pero por seguridad

CREATE INDEX IF NOT EXISTS idx_equipos_cliente   ON cat_equipos (id_cliente);
CREATE INDEX IF NOT EXISTS idx_equipos_marca     ON cat_equipos (marca);
CREATE INDEX IF NOT EXISTS idx_equipos_ns        ON cat_equipos (ns);
CREATE INDEX IF NOT EXISTS idx_equipos_id_trgm   ON cat_equipos
    USING GIN (id_equipo gin_trgm_ops);

CREATE TRIGGER trg_equipos_updated_at
    BEFORE UPDATE ON cat_equipos
    FOR EACH ROW EXECUTE FUNCTION fn_update_updated_at();

COMMENT ON TABLE  cat_equipos IS
    'Catalogo historico de equipos por ID. Se auto-actualiza al guardar una OS.';
COMMENT ON COLUMN cat_equipos.id_equipo IS
    'Identificador interno del equipo asignado por el cliente. Clave primaria textual.';

-- ============================================================================
-- SECCION 4: MODIFICACIONES A ordenes_servicio
-- ============================================================================

-- 4.1 Modalidad de trabajo
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS modalidad VARCHAR(10) NOT NULL DEFAULT 'FISICO';

ALTER TABLE ordenes_servicio
    DROP CONSTRAINT IF EXISTS chk_os_modalidad;
ALTER TABLE ordenes_servicio
    ADD CONSTRAINT chk_os_modalidad
    CHECK (modalidad IN ('FISICO', 'DIGITAL'));

COMMENT ON COLUMN ordenes_servicio.modalidad IS
    'FISICO=papel calca impreso | DIGITAL=tablet offline-first';

-- 4.2 Usuario creador (logistica que registro la OS)
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS id_usuario_creador INTEGER
        REFERENCES usuarios(id) ON UPDATE CASCADE ON DELETE SET NULL;

COMMENT ON COLUMN ordenes_servicio.id_usuario_creador IS
    'Usuario de logistica que creo la OS en el sistema.';

-- 4.3 Firmas digitales PNG en base64
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS firma_tecnico_png TEXT;
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS firma_cliente_png  TEXT;

COMMENT ON COLUMN ordenes_servicio.firma_tecnico_png IS
    'PNG en base64 de la firma del tecnico. Solo modo DIGITAL.';
COMMENT ON COLUMN ordenes_servicio.firma_cliente_png IS
    'PNG en base64 de la firma del cliente. Solo modo DIGITAL.';

-- 4.4 Control de sincronizacion Offline-First
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS sync_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS sync_at      TIMESTAMPTZ;
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS device_id    VARCHAR(100);

COMMENT ON COLUMN ordenes_servicio.sync_version IS
    'Contador de sincronizaciones. Incrementa en cada push de tablet.';
COMMENT ON COLUMN ordenes_servicio.sync_at IS
    'Timestamp del ultimo push exitoso desde tablet.';
COMMENT ON COLUMN ordenes_servicio.device_id IS
    'UUID del dispositivo tablet que hizo el ultimo push.';

-- 4.5 Ampliar estados para flujo DIGITAL
--   FISICO: PROCESO -> ESCANEADA | CANCELADA   (sin cambio)
--   DIGITAL: ASIGNADA -> EN_CAMPO -> SYNC_PENDIENTE -> FIRMADA -> COMPLETADA
ALTER TABLE ordenes_servicio
    DROP CONSTRAINT IF EXISTS chk_os_estado;
ALTER TABLE ordenes_servicio
    ADD CONSTRAINT chk_os_estado CHECK (
        estado IN (
            'PROCESO',          -- FISICO: en proceso
            'CANCELADA',        -- Ambos: anulada
            'ESCANEADA',        -- FISICO: terminada con escaneo adjunto
            'ASIGNADA',         -- DIGITAL: asignada al tecnico, pendiente de sync inicial
            'EN_CAMPO',         -- DIGITAL: tecnico tiene la OS en su tablet
            'SYNC_PENDIENTE',   -- DIGITAL: hay cambios en tablet sin subir al servidor
            'FIRMADA',          -- DIGITAL: firmas capturadas, pendiente validacion logistica
            'COMPLETADA'        -- DIGITAL: validada y cerrada
        )
    );

COMMENT ON COLUMN ordenes_servicio.estado IS
    'FISICO: PROCESO|ESCANEADA|CANCELADA. DIGITAL: ASIGNADA|EN_CAMPO|SYNC_PENDIENTE|FIRMADA|COMPLETADA|CANCELADA';

-- 4.6 FK DEFERRABLE a cat_equipos (para compatibilidad con OS legacy)
ALTER TABLE ordenes_servicio
    DROP CONSTRAINT IF EXISTS fk_os_cat_equipo;
ALTER TABLE ordenes_servicio
    ADD CONSTRAINT fk_os_cat_equipo
        FOREIGN KEY (id_equipo) REFERENCES cat_equipos(id_equipo)
        ON UPDATE CASCADE ON DELETE SET NULL
        DEFERRABLE INITIALLY DEFERRED;

-- ============================================================================
-- SECCION 5: TRIGGER - Auto-actualizar cat_equipos al guardar OS
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_sync_cat_equipos()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.id_equipo IS NULL OR TRIM(NEW.id_equipo) = '' THEN
        RETURN NEW;
    END IF;

    INSERT INTO cat_equipos (
        id_equipo, marca, modelo, ns,
        id_tipo_instrumento, alcance_max, div_minima, div_verificacion,
        id_cliente, ultima_os_folio, ultima_os_fecha, updated_at
    ) VALUES (
        NEW.id_equipo,
        NEW.marca, NEW.modelo, NEW.ns,
        NEW.id_tipo_instrumento, NEW.alcance_max, NEW.div_minima, NEW.div_verificacion,
        NEW.id_cliente, NEW.folio_os, NEW.fecha, NOW()
    )
    ON CONFLICT (id_equipo) DO UPDATE SET
        marca               = EXCLUDED.marca,
        modelo              = EXCLUDED.modelo,
        ns                  = EXCLUDED.ns,
        id_tipo_instrumento = EXCLUDED.id_tipo_instrumento,
        alcance_max         = EXCLUDED.alcance_max,
        div_minima          = EXCLUDED.div_minima,
        div_verificacion    = EXCLUDED.div_verificacion,
        id_cliente          = EXCLUDED.id_cliente,
        ultima_os_folio     = EXCLUDED.ultima_os_folio,
        ultima_os_fecha     = EXCLUDED.ultima_os_fecha,
        updated_at          = NOW();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_os_sync_equipo ON ordenes_servicio;
CREATE TRIGGER trg_os_sync_equipo
    AFTER INSERT OR UPDATE ON ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION fn_sync_cat_equipos();

COMMENT ON FUNCTION fn_sync_cat_equipos IS
    'Mantiene cat_equipos sincronizado con datos de cada OS. Se ejecuta automaticamente.';

-- ============================================================================
-- SECCION 6: ENTREGAS SEMANALES (Auditoria Recepcion)
-- ============================================================================

-- 6.1 Cabecera del acta semanal
CREATE TABLE IF NOT EXISTS entregas_semanales (
    id                      SERIAL          PRIMARY KEY,
    semana_inicio           DATE            NOT NULL,
    semana_fin              DATE            NOT NULL,
    id_tecnico              INTEGER         NOT NULL
                                REFERENCES cat_tecnicos(id) ON UPDATE CASCADE ON DELETE RESTRICT,
    id_usuario_recepcion    INTEGER
                                REFERENCES usuarios(id) ON UPDATE CASCADE ON DELETE SET NULL,
    firma_tecnico_png       TEXT,
    firma_recepcion_png     TEXT,
    estado                  VARCHAR(20)     NOT NULL DEFAULT 'PENDIENTE',
    notas                   TEXT,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_entrega_semana_tecnico UNIQUE (semana_inicio, id_tecnico),
    CONSTRAINT chk_entrega_estado CHECK (
        estado IN ('PENDIENTE', 'ENTREGADA', 'VALIDADA', 'CON_DIFERENCIAS')
    ),
    CONSTRAINT chk_semana_orden CHECK (semana_fin >= semana_inicio)
);

CREATE INDEX IF NOT EXISTS idx_entrega_semana   ON entregas_semanales (semana_inicio DESC);
CREATE INDEX IF NOT EXISTS idx_entrega_tecnico  ON entregas_semanales (id_tecnico);
CREATE INDEX IF NOT EXISTS idx_entrega_estado   ON entregas_semanales (estado);

CREATE TRIGGER trg_entrega_updated_at
    BEFORE UPDATE ON entregas_semanales
    FOR EACH ROW EXECUTE FUNCTION fn_update_updated_at();

COMMENT ON TABLE entregas_semanales IS
    'Actas de entrega semanal de formatos fisicos. Firmadas por tecnico y recepcion.';
COMMENT ON COLUMN entregas_semanales.estado IS
    'PENDIENTE | ENTREGADA | VALIDADA | CON_DIFERENCIAS';

-- 6.2 Items del acta
CREATE TABLE IF NOT EXISTS entregas_semanales_items (
    id                  SERIAL          PRIMARY KEY,
    id_entrega          INTEGER         NOT NULL
                            REFERENCES entregas_semanales(id) ON DELETE CASCADE ON UPDATE CASCADE,
    folio               VARCHAR(25)     NOT NULL,
    tipo                CHAR(3)         NOT NULL,
    modalidad           VARCHAR(10)     NOT NULL,
    incluido_fisico     BOOLEAN         NOT NULL DEFAULT FALSE,
    fecha_formato       DATE,
    observacion_item    TEXT,

    CONSTRAINT chk_item_tipo      CHECK (tipo IN ('OS', 'RMA', 'RE')),
    CONSTRAINT chk_item_modalidad CHECK (modalidad IN ('FISICO', 'DIGITAL'))
);

CREATE INDEX IF NOT EXISTS idx_entrega_items_entrega ON entregas_semanales_items (id_entrega);
CREATE INDEX IF NOT EXISTS idx_entrega_items_folio   ON entregas_semanales_items (folio);

COMMENT ON TABLE  entregas_semanales_items IS
    'Formatos listados en cada acta de entrega semanal.';
COMMENT ON COLUMN entregas_semanales_items.incluido_fisico IS
    'TRUE=el papel fisico fue entregado en recepcion.';

-- ============================================================================
-- SECCION 7: ACTUALIZAR VISTA v_ordenes_servicio
-- ============================================================================

CREATE OR REPLACE VIEW v_ordenes_servicio AS
SELECT
    os.id,
    os.folio_os,
    os.fecha,
    os.estado,
    os.modalidad,

    -- Usuario creador
    uc.username                             AS creado_por_usuario,
    uc.nombre_completo                      AS creado_por_nombre,

    -- Cliente
    cl.razon_social                         AS cliente,
    cl.direccion                            AS direccion_cliente,

    -- Tipo de servicio
    ts.nombre                               AS tipo_servicio,

    -- Tecnico
    tc.id                                   AS id_tecnico,
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

    -- Finalizacion y firmas
    os.observaciones,
    os.firma_cliente_nombre,
    (os.firma_tecnico_png IS NOT NULL)      AS tiene_firma_tecnico,
    (os.firma_cliente_png IS NOT NULL)      AS tiene_firma_cliente,

    -- Archivo adjunto (modo fisico)
    adj.nombre_archivo                      AS archivo_escaneado,
    adj.ruta_completa                       AS ruta_escaneado,
    adj.fecha_adjunto,

    -- Sync
    os.sync_version,
    os.sync_at,
    os.device_id,

    -- Timestamps
    os.created_at,
    os.updated_at
FROM ordenes_servicio os
LEFT JOIN cat_clientes          cl  ON os.id_cliente          = cl.id
LEFT JOIN cat_tipo_servicio     ts  ON os.id_tipo_servicio     = ts.id
LEFT JOIN cat_tecnicos          tc  ON os.id_tecnico           = tc.id
LEFT JOIN cat_tipo_instrumento  ti  ON os.id_tipo_instrumento  = ti.id
LEFT JOIN cat_clase_exactitud   ce  ON os.id_clase_exactitud   = ce.id
LEFT JOIN adjuntos_os           adj ON os.id                   = adj.id_os
LEFT JOIN usuarios              uc  ON os.id_usuario_creador   = uc.id;

COMMENT ON VIEW v_ordenes_servicio IS
    'Vista principal de OS con modalidad, firmas digitales, sync y usuario creador. v2.0';

-- ============================================================================
-- SECCION 8: FUNCION - OS para tablet por tecnico
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_os_para_tablet(
    p_id_tecnico INTEGER,
    p_since      TIMESTAMPTZ DEFAULT '1970-01-01'
)
RETURNS TABLE (
    folio_os        VARCHAR(25),
    estado          VARCHAR(20),
    modalidad       VARCHAR(10),
    updated_at      TIMESTAMPTZ,
    sync_version    INTEGER
)
LANGUAGE sql STABLE AS $$
    SELECT folio_os, estado, modalidad, updated_at, sync_version
    FROM ordenes_servicio
    WHERE id_tecnico = p_id_tecnico
      AND modalidad  = 'DIGITAL'
      AND estado     NOT IN ('CANCELADA', 'COMPLETADA')
      AND updated_at > p_since
    ORDER BY updated_at DESC;
$$;

COMMENT ON FUNCTION fn_os_para_tablet IS
    'Retorna OS digitales asignadas a un tecnico modificadas desde p_since. Usada por la API de sync.';

-- ============================================================================
-- SECCION 9: SEED DATA - Roles y Usuarios iniciales
-- ============================================================================

-- 9.1 Roles
INSERT INTO roles (nombre, descripcion) VALUES
    ('admin',     'Acceso total a todos los modulos, catalogos, configuracion y reportes'),
    ('logistica', 'Crear y gestionar OS/RMA/RE. Asignar tecnicos. Descargar escaneos'),
    ('servicio',  'Acceso exclusivo en Tablet. Solo OS/RMA/RE asignadas a su usuario'),
    ('recepcion', 'Control de entrega fisica de expedientes y recepcion de formatos semanales')
ON CONFLICT (nombre) DO UPDATE SET descripcion = EXCLUDED.descripcion;

-- 9.2 Usuario administrador (contrasena: Admin2026! -- CAMBIAR EN PRODUCCION)
INSERT INTO usuarios (username, password_hash, nombre_completo, email, id_rol)
SELECT 'admin',
       crypt('Admin2026!', gen_salt('bf', 12)),
       'Administrador del Sistema',
       'admin@basculaspesa.com.mx',
       r.id
FROM roles r WHERE r.nombre = 'admin'
ON CONFLICT (username) DO NOTHING;

-- 9.3 Usuario de Logistica (contrasena: Pesa2026!)
INSERT INTO usuarios (username, password_hash, nombre_completo, id_rol)
SELECT 'logistica',
       crypt('Pesa2026!', gen_salt('bf', 12)),
       'Usuario Logistica',
       r.id
FROM roles r WHERE r.nombre = 'logistica'
ON CONFLICT (username) DO NOTHING;

-- 9.4 Usuario de Recepcion (contrasena: Pesa2026!)
INSERT INTO usuarios (username, password_hash, nombre_completo, id_rol)
SELECT 'recepcion',
       crypt('Pesa2026!', gen_salt('bf', 12)),
       'Usuario Recepcion',
       r.id
FROM roles r WHERE r.nombre = 'recepcion'
ON CONFLICT (username) DO NOTHING;

-- 9.5 Usuarios de servicio para tecnicos existentes
-- (Solo crea si el tecnico existe en cat_tecnicos)
INSERT INTO usuarios (username, password_hash, nombre_completo, id_rol, id_tecnico)
SELECT t.usuario,
       crypt('Servicio2026!', gen_salt('bf', 12)),
       t.nombre_completo,
       r.id,
       t.id
FROM cat_tecnicos t, roles r
WHERE r.nombre = 'servicio'
  AND t.usuario IS NOT NULL
  AND t.activo = TRUE
ON CONFLICT (username) DO NOTHING;

-- ============================================================================
-- SECCION 10: PERMISOS ACTUALIZADOS PARA pesa_app
-- ============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pesa_app') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO pesa_app;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO pesa_app;
        GRANT EXECUTE ON FUNCTION generate_folio(CHAR, SMALLINT)             TO pesa_app;
        GRANT EXECUTE ON FUNCTION fn_sync_cat_equipos()                      TO pesa_app;
        GRANT EXECUTE ON FUNCTION fn_os_para_tablet(INTEGER, TIMESTAMPTZ)    TO pesa_app;
    END IF;
END;
$$;

-- ============================================================================
-- VERIFICACION FINAL
-- ============================================================================
COMMIT;

SELECT tablename AS tabla,
       CASE WHEN tablename IN ('roles','usuarios','cat_equipos','entregas_semanales','entregas_semanales_items')
            THEN 'NUEVA' ELSE 'MODIFICADA' END AS tipo
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN (
      'roles','usuarios','cat_equipos',
      'entregas_semanales','entregas_semanales_items',
      'ordenes_servicio'
  )
ORDER BY tipo, tabla;
