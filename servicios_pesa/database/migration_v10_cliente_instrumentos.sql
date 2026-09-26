-- Migración V10: Catálogo de Instrumentos por Cliente
-- Crea una tabla para almacenar el historial de equipos por cada cliente,
-- agilizando el llenado de datos en el módulo de Generar Formatos.

CREATE TABLE IF NOT EXISTS cliente_instrumentos (
    id SERIAL PRIMARY KEY,
    cliente_id INTEGER NOT NULL REFERENCES cat_clientes(id) ON DELETE CASCADE,
    id_indicador TEXT NOT NULL DEFAULT '',
    marca TEXT,
    modelo TEXT,
    numero_serie TEXT NOT NULL DEFAULT '',
    capacidad_max TEXT,
    division_min TEXT,
    ubicacion TEXT,
    -- Clave única compuesta: un mismo cliente no repite ID de indicador + Serie
    UNIQUE(cliente_id, id_indicador, numero_serie)
);

-- Índices para búsqueda rápida durante autocompletado
CREATE INDEX IF NOT EXISTS idx_cliente_instrumentos_cliente_id ON cliente_instrumentos(cliente_id);
