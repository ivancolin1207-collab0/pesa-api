-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  MIGRACIÓN v13 — Sucursales/Plantas y Catálogo de Equipos por Cliente      ║
-- ║  Fecha: 2026-08  |  Autor: Básculas PESA Dev                              ║
-- ║                                                                            ║
-- ║  Cambios:                                                                  ║
-- ║    1. Crear tabla cliente_sucursales (plantas por cliente)                 ║
-- ║    2. Crear tabla cliente_equipos (básculas por sucursal)                  ║
-- ║    3. Agregar FK sucursal_id y equipo_catalogo_id a ordenes_servicio        ║
-- ║    4. Índices de rendimiento                                               ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Tabla de Sucursales / Plantas por Cliente
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS cliente_sucursales (
    id                SERIAL          PRIMARY KEY,
    cliente_id        INT             NOT NULL
                          REFERENCES cat_clientes(id) ON DELETE CASCADE,
    nombre_sucursal   VARCHAR(150)    NOT NULL,   -- Ej. 'Planta Querétaro', 'Planta SLP'
    direccion         TEXT            NOT NULL,
    contacto_nombre   VARCHAR(150),
    contacto_telefono VARCHAR(50),
    activo            BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_sucursal_nombre_cliente UNIQUE (cliente_id, nombre_sucursal)
);

CREATE INDEX IF NOT EXISTS idx_sucursales_cliente_id
    ON cliente_sucursales (cliente_id);

COMMENT ON TABLE  cliente_sucursales IS 'Sucursales / Plantas de cada cliente. Un cliente puede tener N plantas.';
COMMENT ON COLUMN cliente_sucursales.activo IS 'FALSE = sucursal dada de baja (soft delete)';

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. Tabla de Catálogo de Equipos / Básculas por Sucursal
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS cliente_equipos (
    id                   SERIAL          PRIMARY KEY,
    sucursal_id          INT             NOT NULL
                             REFERENCES cliente_sucursales(id) ON DELETE CASCADE,
    marca                VARCHAR(100),
    modelo               VARCHAR(100),
    numero_serie         VARCHAR(100)    NOT NULL,
    id_indicador_equipo  VARCHAR(100),   -- Tag / ID de planta (Ej. BASC-01)
    ubicacion_interna    VARCHAR(150),   -- Ej. 'Embarques', 'Nave 2'
    capacidad_maxima     VARCHAR(50),    -- Texto libre: '500 kg', '5 t'
    division_minima      VARCHAR(50),    -- Texto libre: '200 g', '0.5 kg'
    tipo_instrumento     VARCHAR(100),
    activo               BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT unique_serie_sucursal UNIQUE (sucursal_id, numero_serie)
);

CREATE INDEX IF NOT EXISTS idx_equipos_sucursal_id
    ON cliente_equipos (sucursal_id);

CREATE TRIGGER trg_equipos_updated_at
    BEFORE UPDATE ON cliente_equipos
    FOR EACH ROW EXECUTE FUNCTION fn_update_updated_at();

COMMENT ON TABLE  cliente_equipos IS 'Catálogo de básculas/equipos registrados por sucursal de cliente.';
COMMENT ON COLUMN cliente_equipos.id_indicador_equipo IS 'Tag de planta asignado por el cliente (ej. BASC-01, PES-003)';
COMMENT ON COLUMN cliente_equipos.activo IS 'FALSE = equipo dado de baja (soft delete)';

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. Agregar FK de sucursal y equipo a ordenes_servicio (nullable — compatibilidad)
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS sucursal_id        INT
        REFERENCES cliente_sucursales(id) ON DELETE SET NULL;

ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS equipo_catalogo_id INT
        REFERENCES cliente_equipos(id) ON DELETE SET NULL;

COMMENT ON COLUMN ordenes_servicio.sucursal_id        IS 'Planta/sucursal del cliente para la que se generó la OS (NULL = sin planta asignada)';
COMMENT ON COLUMN ordenes_servicio.equipo_catalogo_id IS 'Equipo del catálogo cliente_equipos que corresponde a esta OS (NULL = equipo manual)';

CREATE INDEX IF NOT EXISTS idx_os_sucursal_id
    ON ordenes_servicio (sucursal_id) WHERE sucursal_id IS NOT NULL;

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. Función de auto-registro de báscula (para el endpoint sync/push)
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION fn_upsert_equipo_desde_os(
    p_sucursal_id        INT,
    p_numero_serie       VARCHAR,
    p_marca              VARCHAR DEFAULT NULL,
    p_modelo             VARCHAR DEFAULT NULL,
    p_id_indicador       VARCHAR DEFAULT NULL,
    p_ubicacion          VARCHAR DEFAULT NULL,
    p_capacidad          VARCHAR DEFAULT NULL,
    p_division           VARCHAR DEFAULT NULL,
    p_tipo_instrumento   VARCHAR DEFAULT NULL
)
RETURNS INT AS $$
DECLARE
    v_id INT;
BEGIN
    INSERT INTO cliente_equipos (
        sucursal_id, numero_serie, marca, modelo,
        id_indicador_equipo, ubicacion_interna,
        capacidad_maxima, division_minima, tipo_instrumento
    )
    VALUES (
        p_sucursal_id, p_numero_serie, p_marca, p_modelo,
        p_id_indicador, p_ubicacion,
        p_capacidad, p_division, p_tipo_instrumento
    )
    ON CONFLICT (sucursal_id, numero_serie) DO UPDATE SET
        marca               = COALESCE(EXCLUDED.marca,             cliente_equipos.marca),
        modelo              = COALESCE(EXCLUDED.modelo,            cliente_equipos.modelo),
        id_indicador_equipo = COALESCE(EXCLUDED.id_indicador_equipo, cliente_equipos.id_indicador_equipo),
        ubicacion_interna   = COALESCE(EXCLUDED.ubicacion_interna,  cliente_equipos.ubicacion_interna),
        capacidad_maxima    = COALESCE(EXCLUDED.capacidad_maxima,   cliente_equipos.capacidad_maxima),
        division_minima     = COALESCE(EXCLUDED.division_minima,    cliente_equipos.division_minima),
        tipo_instrumento    = COALESCE(EXCLUDED.tipo_instrumento,   cliente_equipos.tipo_instrumento),
        updated_at          = NOW()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_upsert_equipo_desde_os IS
    'Inserta o actualiza un equipo en cliente_equipos. '
    'Llamada automáticamente por el endpoint sync/push cuando el técnico completa una OS digital.';

COMMIT;
